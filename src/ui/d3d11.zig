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
const raster = @import("raster.zig");
const text_blend = @import("text_blend.zig");
const d3d11_glass = @import("d3d11_glass.zig");
const d3d11_texture = @import("d3d11_texture.zig");
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
const D3DCompile = api.d3dCompile;
const check = api.check;
const must = api.must;
const bgra8 = api.bgra8;
const rgba8 = api.rgba8;
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
fn shader(device: *Com, cache_root: ?[]const u8, comptime entry: [:0]const u8, comptime target: [:0]const u8, comptime create: usize) !*Com {
    return api.shaderFrom(device, source, "shader.hlsl", entry, target, create, cache_root);
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// NANOUI_D3D_RGB_TEXT=0 is deliberately only an A/B diagnostic: it restores
/// the old scalar glyph branch without changing the GDI or CPU renderer.
fn rgbTextEnabled() bool {
    const value = getenv("NANOUI_D3D_RGB_TEXT") orelse return true;
    return !std.mem.eql(u8, std.mem.span(value), "0");
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
    native_atlas: ?*Com = null,
    native_atlas_srv: ?*Com = null,
    images: ?*Com = null,
    images_srv: ?*Com = null,
    atlas_size: u32 = 0,
    atlas_generation: u64 = std.math.maxInt(u64),
    images_size: u32 = 0,
    images_generation: u64 = std.math.maxInt(u64),
    text_params: text_blend.Params = .{},
    classic_text_params: text_blend.Params = .{},
    classic_gray_params: text_blend.Params = .{},
    rgb_text: bool = true,
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
    /// The frame's textures (`ui.texture`), set by whoever draws it, as
    /// `metal.zig`'s are; `slots` holds their GPU copies.
    textures: []const gpu.Texture = &.{},
    slots: d3d11_texture.Slots = .{},
    /// The texture the next draw samples at t5 (one texture instance's).
    bound_texture: ?*Com = null,
    groups: std.ArrayList(Target) = .empty,
    group_depth: usize = 0,

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
    pub fn init(cache_root: ?[]const u8) !Renderer {
        // Made as the app's shared device is (`d3d11_device.zig`): video
        // support where there is some, multithread protected.
        const pair = try @import("d3d11_device.zig").create();
        const dev = pair.device;
        const ctx = pair.context;
        errdefer {
            ctx.release();
            dev.release();
        }
        var r = try prepare(dev, ctx, cache_root);
        r.owns_device = true;
        return r;
    }

    /// On a device someone else owns — the window's swap chain — so that
    /// what this draws can be copied into that swap chain's back buffer
    /// without a second device, which D3D would refuse to copy across.
    pub fn initOn(device: *Com, context: *Com, cache_root: ?[]const u8) !Renderer {
        return prepare(device, context, cache_root);
    }

    fn prepare(dev: *Com, ctx: *Com, cache_root: ?[]const u8) !Renderer {
        var r: Renderer = .{
            .device = dev,
            .context = ctx,
            .quad_vs = undefined,
            .quad_ps = undefined,
            .glass_ps = undefined,
            .pass_vs = undefined,
            .down_ps = undefined,
            .blur_ps = undefined,
            .blend = undefined,
            .rasterizer = undefined,
            .sampler = undefined,
            .params = undefined,
            .rgb_text = rgbTextEnabled(),
        };
        // Every shader now: bytecode from the cache is a millisecond each.
        r.quad_vs = try shader(dev, cache_root, "quad_vs", "vs_5_0", CreateVertexShader);
        errdefer r.quad_vs.release();
        r.quad_ps = try shader(dev, cache_root, "quad_ps", "ps_5_0", CreatePixelShader);
        errdefer r.quad_ps.release();
        r.glass_ps = try shader(dev, cache_root, "glass_ps", "ps_5_0", CreatePixelShader);
        errdefer r.glass_ps.release();
        r.pass_vs = try shader(dev, cache_root, "pass_vs", "vs_5_0", CreateVertexShader);
        errdefer r.pass_vs.release();
        r.down_ps = try shader(dev, cache_root, "down_ps", "ps_5_0", CreatePixelShader);
        errdefer r.down_ps.release();
        r.blur_ps = try shader(dev, cache_root, "blur_ps", "ps_5_0", CreatePixelShader);
        errdefer r.blur_ps.release();
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
        if (r.native_atlas_srv) |t| t.release();
        if (r.native_atlas) |t| t.release();
        if (r.images_srv) |t| t.release();
        if (r.images) |t| t.release();
        r.params.release();
        r.sampler.release();
        r.rasterizer.release();
        r.blend.release();
        r.quad_vs.release();
        r.quad_ps.release();
        r.glass_ps.release();
        r.pass_vs.release();
        r.down_ps.release();
        r.blur_ps.release();
        r.slots.deinit();
        r.frame.deinit();
        for (r.groups.items) |*group| group.deinit();
        r.groups.deinit(std.heap.page_allocator);
        r.snap.deinit();
        r.a.deinit();
        r.b.deinit();
        if (r.owns_device) {
            r.context.release();
            r.device.release();
        }
    }

    /// Brings the GPU's copies of the glyph and picture atlases up to date.
    pub fn sync(r: *Renderer, mask: raster.Mask, mask_generation: u64, pictures: raster.Pictures, pictures_generation: u64) void {
        r.text_params = mask.text_params;
        r.classic_text_params = mask.classic_text_params;
        r.classic_gray_params = mask.classic_gray_params;
        if (mask.size > 0 and (mask_generation != r.atlas_generation or mask.size != r.atlas_size)) {
            if (r.atlas_srv) |t| t.release();
            r.atlas_srv = null;
            if (r.atlas) |t| t.release();
            if (r.native_atlas_srv) |t| t.release();
            r.native_atlas_srv = null;
            if (r.native_atlas) |t| t.release();
            r.native_atlas = null;
            r.atlas = texture2D(r.device, r8_unorm, mask.size, mask.size, bind_shader_resource);
            r.atlas_size = mask.size;
            r.atlas_generation = mask_generation;
            if (r.atlas) |t| {
                uploadAtlas(r.context, t, mask.pixels, mask.size, 1);
                r.atlas_srv = textureSrv(r.device, t);
            }
            if (mask.native_pixels.len >= @as(usize, mask.size) * mask.size * 4) {
                r.native_atlas = texture2D(r.device, rgba8, mask.size, mask.size, bind_shader_resource);
                if (r.native_atlas) |t| {
                    uploadAtlas(r.context, t, mask.native_pixels, mask.size, 4);
                    r.native_atlas_srv = textureSrv(r.device, t);
                }
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
        // The textures first: an app's D3D11 texture may be converted by the
        // colour stage, which draws into its slot's target with a viewport
        // of its own, so the frame's target and viewport are set after it.
        r.slots.prepare(r.device, g, r.textures);

        setViewport(g, @floatFromInt(w), @floatFromInt(h));
        bindTarget(g, f.rtv.?);
        const rgba: [4]f32 = .{ clear.r, clear.g, clear.b, 1 };
        g.slot(*const fn (*Com, *Com, *const [4]f32) callconv(.winapi) void, ClearRenderTargetView)(g, f.rtv.?, &rgba);
        // The instances go up first: `setState` binds their view, and on the
        // first frame the buffer and its view are only made by the upload.
        r.uploadInstances(instances);
        r.setState();

        r.drawSpan(instances, size, scale, 0, instances.len, 0, false);
        if (target) |t| {
            const src: Box = .{ .right = @intCast(w), .bottom = @intCast(h) };
            g.slot(*const fn (*Com, *Com, u32, u32, u32, u32, *Com, u32, ?*const Box) callconv(.winapi) void, CopySubresourceRegion)(g, t, 0, 0, 0, 0, f.texture.?, 0, &src);
        }
    }

    fn drawSpan(r: *Renderer, instances: []const gpu.Instance, size: types.Size, scale: f32, begin: usize, last: usize, depth: usize, skip_glass: bool) void {
        const g = r.context;
        var first = begin;
        while (first < last) {
            var end = first;
            while (end < last and instances[end].kind != gpu.Kind.glass and instances[end].kind != gpu.Kind.layer_begin) end += 1;
            r.drawRun(instances, size, scale, first, end);
            if (end == last) break;
            if (instances[end].kind == gpu.Kind.glass) {
                if (!skip_glass) d3d11_glass.drawPane(r, instances, end, size, scale);
                first = end + 1;
                continue;
            }
            const close = gpu.groupEnd(instances[0..last], end) orelse break;
            const masked = instances[close].border_color[2] > 0 or instances[close].border_color[3] > 0;
            if (!masked) {
                var at = end + 1;
                while (at < close) : (at += 1) {
                    if (instances[at].kind == gpu.Kind.layer_begin) {
                        at = gpu.groupEnd(instances[0..close], at) orelse break;
                        continue;
                    }
                    if (instances[at].kind == gpu.Kind.glass) d3d11_glass.drawPane(r, instances, at, size, scale);
                }
            }
            while (r.groups.items.len <= depth) r.groups.append(std.heap.page_allocator, .{}) catch return;
            var group = r.groups.items[depth];
            group.reserve(r.device, r.frame_w, r.frame_h, false);
            r.groups.items[depth] = group;
            if (group.rtv == null or group.srv == null) return;
            const parent = r.frame;
            r.frame = group;
            var empty = [1]?*Com{null};
            g.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, PSSetShaderResources)(g, 5, 1, &empty);
            bindTarget(g, group.rtv.?);
            g.slot(*const fn (*Com, *Com, *const [4]f32) callconv(.winapi) void, ClearRenderTargetView)(g, group.rtv.?, &[4]f32{ 0, 0, 0, 0 });
            r.group_depth += 1;
            r.drawSpan(instances, size, scale, end + 1, close, depth + 1, !masked);
            r.group_depth -= 1;
            r.groups.items[depth] = r.frame;
            r.frame = parent;
            bindTarget(g, parent.rtv.?);
            r.bound_texture = group.srv;
            r.drawRange(false, size, scale, close, 1, .{});
            r.bound_texture = null;
            first = close + 1;
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
    pub fn setBlend(r: *Renderer, on: bool) void {
        const g = r.context;
        g.slot(*const fn (*Com, ?*Com, ?*const [4]f32, u32) callconv(.winapi) void, OMSetBlendState)(g, if (on) r.blend else null, &[4]f32{ 0, 0, 0, 0 }, 0xffffffff);
    }

    pub fn setState(r: *Renderer) void {
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

    /// Instances [first, end) with the quad shader: a texture's quad
    /// (`ui.texture`) alone, its slot's texture bound at t5, as `metal.zig`'s
    /// `drawRun` draws it.
    fn drawRun(r: *Renderer, instances: []const gpu.Instance, size: types.Size, scale: f32, first: usize, end: usize) void {
        var from = first;
        for (first..end) |i| {
            if (instances[i].kind != gpu.Kind.texture) continue;
            r.drawRange(false, size, scale, from, i - from, .{});
            from = i + 1;
            const tex = r.slots.get(@intFromFloat(@max(0, instances[i].border_width))) orelse continue;
            r.bound_texture = tex;
            defer r.bound_texture = null;
            r.drawRange(false, size, scale, i, 1, .{});
        }
        r.drawRange(false, size, scale, from, end - from, .{});
    }

    /// Instances [first, first + count) in one instanced draw, into the frame.
    pub fn drawRange(r: *Renderer, pane: bool, size: types.Size, scale: f32, first: usize, count: usize, extra: Params) void {
        if (count == 0) return;
        const g = r.context;
        var p: Params = extra;
        p.start_instance = @intCast(first);
        r.setParams(size, scale, p);
        const ps = if (pane) r.glass_ps else r.quad_ps;
        g.slot(*const fn (*Com, ?*Com, ?*const anyopaque, u32) callconv(.winapi) void, VSSetShader)(g, r.quad_vs, null, 0);
        g.slot(*const fn (*Com, ?*Com, ?*const anyopaque, u32) callconv(.winapi) void, PSSetShader)(g, ps, null, 0);
        var inst = [1]?*Com{r.instance_srv};
        g.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, VSSetShaderResources)(g, 0, 1, &inst);
        var views = [6]?*Com{ r.instance_srv, r.atlas_srv, r.images_srv, r.a.srv, r.native_atlas_srv, r.bound_texture };
        g.slot(*const fn (*Com, u32, u32, [*]const ?*Com) callconv(.winapi) void, PSSetShaderResources)(g, 0, 6, &views);
        // The instance offset goes through `Params`: StartInstanceLocation
        // only moves vertex-buffer reads, not this structured buffer's.
        g.slot(*const fn (*Com, u32, u32, u32, u32) callconv(.winapi) void, DrawInstanced)(g, 4, @intCast(count), 0, 0);
    }

    /// Writes the frame's constants: the viewport in points and the scale,
    /// over whichever glass or pass parameters `extra` carries.
    pub fn setParams(r: *Renderer, size: types.Size, scale: f32, extra: Params) void {
        const g = r.context;
        var p: Params = extra;
        p.viewport = .{ size.w, size.h };
        p.scale = scale;
        p.rgb_text = if (!r.rgb_text) 0 else if (r.group_depth > 0) -1 else 1;
        p.gamma = r.text_params.gamma;
        p.contrast = r.text_params.contrast;
        p.grayscale_contrast = r.text_params.grayscale_contrast;
        p.classic_gamma = r.classic_text_params.gamma;
        p.classic_gray_gamma = r.classic_gray_params.gamma;
        p.classic_contrast = r.classic_text_params.contrast;
        p.classic_gray_contrast = r.classic_gray_params.grayscale_contrast;
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
pub fn bindTarget(context: *Com, rtv: *Com) void {
    var views = [1]?*Com{rtv};
    context.slot(*const fn (*Com, u32, [*]const ?*Com, ?*anyopaque) callconv(.winapi) void, OMSetRenderTargets)(context, 1, &views, null);
}

/// The one viewport the next draws cover: `w` × `h` pixels, top left.
pub fn setViewport(context: *Com, w: f32, h: f32) void {
    var vp = [1]Viewport{.{ .w = w, .h = h }};
    context.slot(*const fn (*Com, u32, [*]const Viewport) callconv(.winapi) void, RSSetViewports)(context, 1, &vp);
}
