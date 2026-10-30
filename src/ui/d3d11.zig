//! The Direct3D 11 renderer (Windows): the same instances `shader.metal`
//! and the CPU renderer (`raster.zig`) draw, drawn by `shader.hlsl` in one
//! instanced draw, split by panes of glass, each of which reads what was
//! drawn before it. The frame is drawn into a texture of the renderer's own
//! (so that glass can read it), then copied to the target: a window's swap
//! chain back buffer, or an offscreen texture in the tests. `d3d.zig` still
//! makes the swap chain and presents what this draws; `d3d11_glue.zig` is
//! Direct3D 11's own vocabulary.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const glass = @import("glass.zig");
const raster = @import("raster.zig");
const source = @embedFile("shader.hlsl");

const api = @import("d3d11_glue.zig");
const Target = api.Target;
const texture2D = api.texture2D;
const textureSrv = api.textureSrv;
const uploadAtlas = api.uploadAtlas;
const Com = api.Com;
const Blob = api.Blob;
const HRESULT = api.HRESULT;
const Texture2DDesc = api.Texture2DDesc;
const BufferDesc = api.BufferDesc;
const SrvDesc = api.SrvDesc;
const Mapped = api.Mapped;
const Viewport = api.Viewport;
const Box = api.Box;
const BlendDesc = api.BlendDesc;
const RasterizerDesc = api.RasterizerDesc;
const SamplerDesc = api.SamplerDesc;
const Params = api.Params;
const D3D11CreateDevice = api.D3D11CreateDevice;
const D3DCompile = api.D3DCompile;
const check = api.check;
const must = api.must;
const bgra8 = api.bgra8;
const r8_unorm = api.r8_unorm;
const bind_constant = api.bind_constant;
const bind_shader_resource = api.bind_shader_resource;
const bind_render_target = api.bind_render_target;
const usage_staging = api.usage_staging;
const cpu_read = api.cpu_read;
const map_read = api.map_read;
const map_write_discard = api.map_write_discard;
const misc_structured = api.misc_structured;
const srv_buffer = api.srv_buffer;
const topology_strip = api.topology_strip;
const sdk_version = api.sdk_version;
const bgra_support = api.bgra_support;
const VSSetConstantBuffers = api.VSSetConstantBuffers;
const PSSetShaderResources = api.PSSetShaderResources;
const PSSetShader = api.PSSetShader;
const PSSetSamplers = api.PSSetSamplers;
const VSSetShader = api.VSSetShader;
const Draw = api.Draw;
const Map = api.Map;
const Unmap = api.Unmap;
const PSSetConstantBuffers = api.PSSetConstantBuffers;
const IASetInputLayout = api.IASetInputLayout;
const DrawInstanced = api.DrawInstanced;
const IASetPrimitiveTopology = api.IASetPrimitiveTopology;
const VSSetShaderResources = api.VSSetShaderResources;
const OMSetRenderTargets = api.OMSetRenderTargets;
const OMSetBlendState = api.OMSetBlendState;
const RSSetState = api.RSSetState;
const RSSetViewports = api.RSSetViewports;
const CopyResource = api.CopyResource;
const CopySubresourceRegion = api.CopySubresourceRegion;
const UpdateSubresource = api.UpdateSubresource;
const ClearRenderTargetView = api.ClearRenderTargetView;
const CreateBuffer = api.CreateBuffer;
const CreateTexture2D = api.CreateTexture2D;
const CreateShaderResourceView = api.CreateShaderResourceView;
const CreateRenderTargetView = api.CreateRenderTargetView;
const CreateVertexShader = api.CreateVertexShader;
const CreatePixelShader = api.CreatePixelShader;
const CreateBlendState = api.CreateBlendState;
const CreateRasterizerState = api.CreateRasterizerState;
const CreateSamplerState = api.CreateSamplerState;

/// A shader of `source`, entry point `entry`, as `create` makes it.
fn shader(device: *Com, comptime entry: [:0]const u8, comptime target: [:0]const u8, comptime create: usize) !*Com {
    var blob: ?*Blob = null;
    var errors: ?*Blob = null;
    const hr = D3DCompile(source, source.len, "shader.hlsl", null, null, entry, target, 0, 0, &blob, &errors);
    if (errors) |e| {
        if (hr < 0) std.log.err("nanoui: HLSL {s} ({s}):\n{s}", .{ entry, target, e.bytes()[0..e.size()] });
        e.release();
    }
    try check(hr);
    const b = blob orelse return error.ShaderCompile;
    defer b.release();
    var out: ?*Com = null;
    try check(device.slot(*const fn (*Com, [*]const u8, usize, ?*anyopaque, *?*Com) callconv(.winapi) HRESULT, create)(device, b.bytes(), b.size(), null, &out));
    return out orelse error.ShaderCompile;
}

/// The GPU renderer: one device, every program, and the frame it draws.
pub const Renderer = struct {
    device: *Com,
    context: *Com,
    quad_vs: *Com,
    quad_ps: *Com,
    glass_ps: *Com,
    pass_vs: *Com,
    down_ps: *Com,
    blur_ps: *Com,
    blend: *Com,
    rasterizer: *Com,
    sampler: *Com,
    params: *Com,
    /// The instances, as a structured buffer the vertex shader reads.
    instances: ?*Com = null,
    instance_srv: ?*Com = null,
    instance_bytes: usize = 0,
    atlas: ?*Com = null,
    atlas_srv: ?*Com = null,
    images: ?*Com = null,
    images_srv: ?*Com = null,
    atlas_size: u32 = 0,
    atlas_generation: u64 = std.math.maxInt(u64),
    images_size: u32 = 0,
    images_generation: u64 = std.math.maxInt(u64),
    frame: Target = .{},
    /// The size the last frame was drawn at, which the frame texture may be
    /// larger than (it is grown, never shrunk): what `read` and the copy to
    /// the swap chain use.
    frame_w: usize = 0,
    frame_h: usize = 0,
    /// The frame copied for the panes to read: Direct3D 11 leaves a texture's
    /// reads undefined while its render target view is still bound, so the
    /// backdrop is taken from this copy rather than from `frame` itself.
    snap: Target = .{},
    /// A pane's backdrop ends in `a`; `b` holds the blur between passes.
    a: Target = .{},
    b: Target = .{},
    /// Whether `deinit` releases the device and context: it does only when
    /// this made them.
    owns_device: bool = false,

    /// A hardware device (WARP when there is none), every shader, and the
    /// state one frame is drawn with.
    ///
    /// `error.NoDevice` is the only error that means "this machine has no
    /// Direct3D 11", and it is the only one a caller should skip on. Everything
    /// after the device is made — a shader that will not compile, a state object
    /// that will not be created — reports its own error, and is a bug in this
    /// repository.
    ///
    /// They used to share one name: every failure from here was
    /// `error.Direct3D`, so a broken shader looked exactly like a machine
    /// without a GPU. Four parity tests skipped on a machine with Direct3D 11
    /// and a shader whose `Instance` was 96 bytes instead of 144, and printed
    /// numbers from an earlier, working build while doing it.
    pub fn init() !Renderer {
        var device: ?*Com = null;
        var context: ?*Com = null;
        if (D3D11CreateDevice(null, 1, null, bgra_support, null, 0, sdk_version, &device, null, &context) < 0) {
            if (D3D11CreateDevice(null, 5, null, bgra_support, null, 0, sdk_version, &device, null, &context) < 0)
                return error.NoDevice;
        }
        const dev = device orelse return error.NoDevice;
        const ctx = context orelse return error.NoDevice;
        errdefer {
            ctx.release();
            dev.release();
        }
        var r = try prepare(dev, ctx);
        r.owns_device = true;
        return r;
    }

    /// On a device someone else owns — the window's swap chain — so that
    /// what this draws can be copied into that swap chain's back buffer
    /// without a second device, which D3D would refuse to copy across.
    pub fn initOn(device: *Com, context: *Com) !Renderer {
        return prepare(device, context);
    }

    fn prepare(dev: *Com, ctx: *Com) !Renderer {
        var r: Renderer = .{
            .device = dev,
            .context = ctx,
            .quad_vs = try shader(dev, "quad_vs", "vs_5_0", CreateVertexShader),
            .quad_ps = try shader(dev, "quad_ps", "ps_5_0", CreatePixelShader),
            .glass_ps = try shader(dev, "glass_ps", "ps_5_0", CreatePixelShader),
            .pass_vs = try shader(dev, "pass_vs", "vs_5_0", CreateVertexShader),
            .down_ps = try shader(dev, "down_ps", "ps_5_0", CreatePixelShader),
            .blur_ps = try shader(dev, "blur_ps", "ps_5_0", CreatePixelShader),
            .blend = undefined,
            .rasterizer = undefined,
            .sampler = undefined,
            .params = undefined,
        };
        const bd: BlendDesc = .{};
        try check(dev.slot(*const fn (*Com, *const BlendDesc, *?*Com) callconv(.winapi) HRESULT, CreateBlendState)(dev, &bd, @ptrCast(&r.blend)));
        const rd: RasterizerDesc = .{};
        try check(dev.slot(*const fn (*Com, *const RasterizerDesc, *?*Com) callconv(.winapi) HRESULT, CreateRasterizerState)(dev, &rd, @ptrCast(&r.rasterizer)));
        const sd: SamplerDesc = .{};
        try check(dev.slot(*const fn (*Com, *const SamplerDesc, *?*Com) callconv(.winapi) HRESULT, CreateSamplerState)(dev, &sd, @ptrCast(&r.sampler)));
        const cb: BufferDesc = .{ .byte_width = @sizeOf(Params), .bind = bind_constant };
        try check(dev.slot(*const fn (*Com, *const BufferDesc, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, CreateBuffer)(dev, &cb, null, @ptrCast(&r.params)));
        return r;
    }

    pub fn deinit(r: *Renderer) void {
        if (r.instance_srv) |v| v.release();
        if (r.instances) |b| b.release();
        if (r.atlas_srv) |t| t.release();
        if (r.atlas) |t| t.release();
        if (r.images_srv) |t| t.release();
        if (r.images) |t| t.release();
        for ([_]*Com{ r.params, r.sampler, r.rasterizer, r.blend, r.quad_vs, r.quad_ps, r.glass_ps, r.pass_vs, r.down_ps, r.blur_ps }) |s| s.release();
        r.frame.deinit();
        r.a.deinit();
        r.b.deinit();
        if (r.owns_device) {
            r.context.release();
            r.device.release();
        }
    }

    /// Brings the GPU's copies of the glyph and picture atlases up to date.
    pub fn sync(r: *Renderer, mask: raster.Mask, mask_generation: u64, pictures: raster.Pictures, pictures_generation: u64) void {
        if (mask.size > 0 and (mask_generation != r.atlas_generation or mask.size != r.atlas_size)) {
            if (r.atlas_srv) |t| t.release();
            r.atlas_srv = null;
            if (r.atlas) |t| t.release();
            r.atlas = texture2D(r.device, r8_unorm, mask.size, mask.size, bind_shader_resource);
            r.atlas_size = mask.size;
            r.atlas_generation = mask_generation;
            if (r.atlas) |t| {
                uploadAtlas(r.context, t, mask.pixels, mask.size, 1);
                r.atlas_srv = textureSrv(r.device, t);
            }
        }
        if (pictures.size > 0 and (pictures_generation != r.images_generation or pictures.size != r.images_size)) {
            if (r.images_srv) |t| t.release();
            r.images_srv = null;
            if (r.images) |t| t.release();
            r.images = texture2D(r.device, bgra8, pictures.size, pictures.size, bind_shader_resource);
            r.images_size = pictures.size;
            r.images_generation = pictures_generation;
            if (r.images) |t| {
                uploadAtlas(r.context, t, pictures.pixels, pictures.size, 4);
                r.images_srv = textureSrv(r.device, t);
            }
        }
    }

    /// Draws `instances` over `clear`, `size` points at `scale`, into the
    /// renderer's frame, then copies it into `target` — a window's swap
    /// chain back buffer, or null to keep it where `read` finds it.
    pub fn draw(r: *Renderer, instances: []const gpu.Instance, size: types.Size, scale: f32, clear: types.Color, target: ?*Com) void {
        const g = r.context;
        const w: usize = @intFromFloat(@max(1, @round(size.w * scale)));
        const h: usize = @intFromFloat(@max(1, @round(size.h * scale)));
        // The frame texture is grown, never rebuilt: a diagonal resize changes
        // the size every frame, and a texture remade every frame (with its views
        // and a swap chain ResizeBuffers) is what made resizing stutter. What
        // is drawn is the window's own `w` × `h`, and only that reaches the
        // swap chain.
        r.frame.reserve(r.device, w, h, false);
        const f = &r.frame;
        if (f.rtv == null or f.srv == null) return;
        r.frame_w = w;
        r.frame_h = h;

        setViewport(g, @floatFromInt(w), @floatFromInt(h));
        bindTarget(g, f.rtv.?);
        const rgba: [4]f32 = .{ clear.r, clear.g, clear.b, 1 };
        g.slot(*const fn (*Com, *Com, *const [4]f32) callconv(.winapi) void, ClearRenderTargetView)(g, f.rtv.?, &rgba);
        // The instances go up first: `setState` binds their view, and on the
        // first frame the buffer and its view are only made by the upload.
        r.uploadInstances(instances);
        r.setState();

        var first: usize = 0;
        while (first < instances.len) {
            // What comes before the next pane, in one draw.
            var end = first;
            while (end < instances.len and instances[end].kind != gpu.Kind.glass) end += 1;
            r.drawRange(false, size, scale, first, end - first, .{});
            if (end == instances.len) break;
            r.drawPane(instances, end, size, scale);
            first = end + 1;
        }
        if (target) |t| {
            const src: Box = .{ .right = @intCast(w), .bottom = @intCast(h) };
            g.slot(*const fn (*Com, *Com, u32, u32, u32, u32, *Com, u32, ?*const Box) callconv(.winapi) void, CopySubresourceRegion)(g, t, 0, 0, 0, 0, f.texture.?, 0, &src);
        }
    }

    /// The last frame's pixels: BGRA, premultiplied, top row first.
    pub fn read(r: *Renderer, gpa: std.mem.Allocator) !gpu.Pixels {
        const w = r.frame_w;
        const h = r.frame_h;
        const bytes = try gpa.alloc(u8, w * h * 4);
        errdefer gpa.free(bytes);
        if (w == 0 or h == 0) return .{ .bytes = bytes, .width = w, .height = h };
        const desc: Texture2DDesc = .{ .width = @intCast(w), .height = @intCast(h), .usage = usage_staging, .cpu = cpu_read };
        var staging: ?*Com = null;
        try must(r.device.slot(*const fn (*Com, *const Texture2DDesc, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, CreateTexture2D)(r.device, &desc, null, &staging), "CreateTexture2D(staging)");
        defer staging.?.release();
        const g = r.context;
        // The frame texture may be larger than this frame: copy its corner.
        const src: Box = .{ .right = @intCast(w), .bottom = @intCast(h) };
        g.slot(*const fn (*Com, *Com, u32, u32, u32, u32, *Com, u32, ?*const Box) callconv(.winapi) void, CopySubresourceRegion)(g, staging.?, 0, 0, 0, 0, r.frame.texture.?, 0, &src);
        var mapped: Mapped = undefined;
        try must(g.slot(*const fn (*Com, *Com, u32, u32, u32, *Mapped) callconv(.winapi) HRESULT, Map)(g, staging.?, 0, map_read, 0, &mapped), "Map(staging)");
        defer g.slot(*const fn (*Com, *Com, u32) callconv(.winapi) void, Unmap)(g, staging.?, 0);
        const row = w * 4;
        for (0..h) |y| @memcpy(bytes[y * row ..][0..row], mapped.data[y * mapped.row_pitch ..][0..row]);
        return .{ .bytes = bytes, .width = w, .height = h };
    }

    /// The state every draw shares: premultiplied alpha, no culling, the
    /// constants and sampler bound, no input layout (the vertex comes from
    /// `SV_VertexID`, the instance from the structured buffer).
    /// Premultiplied alpha over the target, or off while a pass writes one
    /// whole texel at a time.
    fn setBlend(r: *Renderer, on: bool) void {
        const g = r.context;
        g.slot(*const fn (*Com, ?*Com, ?*const [4]f32, u32) callconv(.winapi) void, OMSetBlendState)(g, if (on) r.blend else null, &[4]f32{ 0, 0, 0, 0 }, 0xffffffff);
    }

    fn setState(r: *Renderer) void {
        const g = r.context;
        r.setBlend(true);
        g.slot(*const fn (*Com, ?*Com) callconv(.winapi) void, RSSetState)(g, r.rasterizer);
        var samplers = [1]?*Com{r.sampler};
        for ([_]u32{ 1, 2, 3 }) |at| g.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, PSSetSamplers)(g, at, 1, &samplers);
        var cb = [1]?*Com{r.params};
        g.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, VSSetConstantBuffers)(g, 0, 1, &cb);
        g.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, PSSetConstantBuffers)(g, 0, 1, &cb);
        g.slot(*const fn (*Com, ?*Com) callconv(.winapi) void, IASetInputLayout)(g, null);
        g.slot(*const fn (*Com, u32) callconv(.winapi) void, IASetPrimitiveTopology)(g, topology_strip);
    }

    /// Instances [first, first + count) in one instanced draw, into the frame.
    fn drawRange(r: *Renderer, pane: bool, size: types.Size, scale: f32, first: usize, count: usize, extra: Params) void {
        if (count == 0) return;
        const g = r.context;
        var p: Params = extra;
        p.start_instance = @intCast(first);
        r.setParams(size, scale, p);
        g.slot(*const fn (*Com, ?*Com, ?*const anyopaque, u32) callconv(.winapi) void, VSSetShader)(g, r.quad_vs, null, 0);
        g.slot(*const fn (*Com, ?*Com, ?*const anyopaque, u32) callconv(.winapi) void, PSSetShader)(g, if (pane) r.glass_ps else r.quad_ps, null, 0);
        var inst = [1]?*Com{r.instance_srv};
        g.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, VSSetShaderResources)(g, 0, 1, &inst);
        var views = [4]?*Com{ r.instance_srv, r.atlas_srv, r.images_srv, r.a.srv };
        g.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, PSSetShaderResources)(g, 0, 4, &views);
        // The instance offset goes through `Params`: StartInstanceLocation
        // only moves vertex-buffer reads, not this structured buffer's.
        g.slot(*const fn (*Com, u32, u32, u32, u32) callconv(.winapi) void, DrawInstanced)(g, 4, @intCast(count), 0, 0);
    }

    /// Pane `at`: its backdrop averaged and blurred from what was drawn,
    /// then the pane itself over the frame.
    fn drawPane(r: *Renderer, instances: []const gpu.Instance, at: usize, size: types.Size, scale: f32) void {
        // Whatever happens below, the frame is bound again and its viewport set
        // when this returns: a pane that cannot draw must never leave the
        // renderer pointed at a backdrop texture, or every later instance is
        // drawn where no one sees it.
        const g = r.context;
        defer {
            setViewport(g, @floatFromInt(r.frame_w), @floatFromInt(r.frame_h));
            bindTarget(g, r.frame.rtv.?);
            // The passes rebound the target, the vertex shader and its
            // resources: `setState` puts back what the next quad draw needs.
            r.setState();
        }
        const b = glass.backdropOf(instances[at].rect, instances[at].border_width, scale, r.frame_w, r.frame_h) orelse return;
        const w: usize = @intCast(b.w);
        const h: usize = @intCast(b.h);
        r.a.reserve(r.device, w, h, false);
        r.b.reserve(r.device, w, h, false);
        if (r.a.rtv == null or r.a.srv == null or r.b.rtv == null or r.b.srv == null) return;
        // The panes read what was drawn before them. Direct3D 11 leaves a
        // texture's reads undefined while its render target view is bound, so
        // the frame is copied first: `snap` is what `down_ps` samples. Its RTV
        // is never bound, only its SRV is read.
        r.snap.reserve(r.device, r.frame_w, r.frame_h, false);
        if (r.snap.srv == null or r.snap.texture == null or r.frame.texture == null) return;
        const frame_box: Box = .{ .right = @intCast(r.frame_w), .bottom = @intCast(r.frame_h) };
        g.slot(*const fn (*Com, *Com, u32, u32, u32, u32, *Com, u32, ?*const Box) callconv(.winapi) void, CopySubresourceRegion)(g, r.snap.texture.?, 0, 0, 0, 0, r.frame.texture.?, 0, &frame_box);
        // The passes read the frame's area in `down`-pixel squares and write
        // `size` texels: both are the backdrop's, not the frame's.
        const back: Params = .{
            .area = b.area,
            .down = @floatFromInt(b.down),
            .frame_height = @intCast(r.frame_h),
            .radius = b.radius,
            .sigma = b.sigma,
            .size = .{ @floatFromInt(b.w), @floatFromInt(b.h) },
        };
        r.pass(r.down_ps, r.snap.srv.?, r.a.rtv.?, back, b.w, b.h);
        if (b.sigma > 0) {
            var across = back;
            across.dir = .{ 1, 0 };
            r.pass(r.blur_ps, r.a.srv.?, r.b.rtv.?, across, b.w, b.h);
            var down_dir = back;
            down_dir.dir = .{ 0, 1 };
            r.pass(r.blur_ps, r.b.srv.?, r.a.rtv.?, down_dir, b.w, b.h);
        }
        // The pane itself over the frame, reading `a` as its backdrop.
        setViewport(g, @floatFromInt(r.frame_w), @floatFromInt(r.frame_h));
        bindTarget(g, r.frame.rtv.?);
        r.setBlend(true);
        r.drawRange(true, size, scale, at, 1, .{
            .origin = .{ @floatFromInt(b.area[0]), @floatFromInt(b.area[1]) },
            .size = .{ @floatFromInt(b.w), @floatFromInt(b.h) },
            .down = @floatFromInt(b.down),
        });
    }

    /// One pass of a pane's backdrop: `ps` reading `src` into `dst`, the
    /// whole target covered by one triangle.
    fn pass(r: *Renderer, ps: *Com, src: *Com, dst: *Com, p: Params, w: i32, h: i32) void {
        const g = r.context;
        setViewport(g, @floatFromInt(w), @floatFromInt(h));
        bindTarget(g, dst);
        r.setBlend(false);
        r.setParams(.{ .w = @floatFromInt(w), .h = @floatFromInt(h) }, 1, p);
        g.slot(*const fn (*Com, ?*Com, ?*const anyopaque, u32) callconv(.winapi) void, VSSetShader)(g, r.pass_vs, null, 0);
        g.slot(*const fn (*Com, ?*Com, ?*const anyopaque, u32) callconv(.winapi) void, PSSetShader)(g, ps, null, 0);
        var srcs = [1]?*Com{src};
        g.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, PSSetShaderResources)(g, 0, 1, &srcs);
        g.slot(*const fn (*Com, u32, u32) callconv(.winapi) void, Draw)(g, 3, 0);
    }

    /// Writes the frame's constants: the viewport in points and the scale,
    /// over whichever glass or pass parameters `extra` carries.
    fn setParams(r: *Renderer, size: types.Size, scale: f32, extra: Params) void {
        const g = r.context;
        var p: Params = extra;
        p.viewport = .{ size.w, size.h };
        p.scale = scale;
        // A dynamic buffer is written by mapping it, one call each way; that is
        // what `D3D11_USAGE_DYNAMIC` is for.
        var mapped: Mapped = undefined;
        const hr = g.slot(*const fn (*Com, *Com, u32, u32, u32, *Mapped) callconv(.winapi) HRESULT, Map)(g, r.params, 0, map_write_discard, 0, &mapped);
        if (hr < 0) return;
        @memcpy(mapped.data[0..@sizeOf(Params)], std.mem.asBytes(&p));
        g.slot(*const fn (*Com, *Com, u32) callconv(.winapi) void, Unmap)(g, r.params, 0);
    }

    /// The instances in a structured buffer the vertex shader reads, grown
    /// when a frame has more than the last.
    fn uploadInstances(r: *Renderer, instances: []const gpu.Instance) void {
        const bytes = instances.len * @sizeOf(gpu.Instance);
        if (r.instances == null or bytes > r.instance_bytes) {
            if (r.instance_srv) |v| v.release();
            if (r.instances) |b| b.release();
            r.instance_srv = null;
            // A structured buffer's ByteWidth must be a whole number of
            // elements, or CreateBuffer refuses it.
            const stride: usize = @sizeOf(gpu.Instance);
            const want = @max(bytes, 1 << 14);
            const capacity: u32 = @intCast(((want + stride - 1) / stride) * stride);
            const desc: BufferDesc = .{ .byte_width = capacity, .bind = bind_shader_resource, .misc = misc_structured, .stride = stride };
            var buf: ?*Com = null;
            must(r.device.slot(*const fn (*Com, *const BufferDesc, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, CreateBuffer)(r.device, &desc, null, &buf), "CreateBuffer(instances)") catch return;
            r.instances = buf;
            r.instance_bytes = capacity;
        }
        const g = r.context;
        if (r.instance_srv == null) {
            const sd: SrvDesc = .{ .dimension = srv_buffer, .count = @intCast(r.instance_bytes / @sizeOf(gpu.Instance)) };
            var srv: ?*Com = null;
            must(r.device.slot(*const fn (*Com, *Com, *const SrvDesc, *?*Com) callconv(.winapi) HRESULT, CreateShaderResourceView)(r.device, r.instances.?, &sd, &srv), "CreateShaderResourceView(instances)") catch return;
            r.instance_srv = srv;
        }
        var mapped: Mapped = undefined;
        must(g.slot(*const fn (*Com, *Com, u32, u32, u32, *Mapped) callconv(.winapi) HRESULT, Map)(g, r.instances.?, 0, map_write_discard, 0, &mapped), "Map(instances)") catch return;
        if (bytes > 0) @memcpy(mapped.data[0..bytes], std.mem.sliceAsBytes(instances)[0..bytes]);
        g.slot(*const fn (*Com, *Com, u32) callconv(.winapi) void, Unmap)(g, r.instances.?, 0);
    }
};

/// Makes `rtv` the only render target of the next draws.
fn bindTarget(context: *Com, rtv: *Com) void {
    var views = [1]?*Com{rtv};
    context.slot(*const fn (*Com, u32, [*]const ?*Com, ?*anyopaque) callconv(.winapi) void, OMSetRenderTargets)(context, 1, &views, null);
}

/// The one viewport the next draws cover: `w` × `h` pixels, top left.
fn setViewport(context: *Com, w: f32, h: f32) void {
    var vp = [1]Viewport{.{ .w = w, .h = h }};
    context.slot(*const fn (*Com, u32, [*]const Viewport) callconv(.winapi) void, RSSetViewports)(context, 1, &vp);
}
