//! An extended (EDR) Metal surface's own resources (`Surface.setColour`,
//! `metal.zig`'s `encodeExtended`): the UI's 8-bit target, the plane the
//! frame's `.surface_linear` textures are drawn into, and the two pipelines
//! that draw the plane and compose both into the RGBA16Float drawable
//! (`fs_hdr_compose` in shader.metal). Made the first time a frame is drawn
//! extended; an SDR surface never makes any of it.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const gpu = @import("gpu.zig");
const types = @import("types.zig");
const metal = @import("metal.zig");
const Renderer = metal.Renderer;

/// MTLPixelFormatRGBA16Float: the extended drawable and the plane.
pub const rgba16f: objc.NSUInteger = 115;
/// MTLPixelFormatBGRA8Unorm: the UI's target, as an SDR drawable is.
pub const bgra8: objc.NSUInteger = 80;

/// What `fs_hdr_compose` reads at buffer 0.
pub const Compose = extern struct {
    scale: f32,
    plane: u32,
};

pub const Hdr = struct {
    /// The plane's pipeline: `fs_plane` into RGBA16Float.
    plane_pipeline: ?objc.Object = null,
    /// `vs_hdr_compose` + `fs_hdr_compose` into RGBA16Float, no blending.
    compose_pipeline: ?objc.Object = null,
    /// The UI's target (BGRA8, what the frame draws into instead of the
    /// drawable) and the plane (RGBA16Float), both the drawable's size.
    ui: ?objc.Object = null,
    plane: ?objc.Object = null,
    w: usize = 0,
    h: usize = 0,

    /// Makes both pipelines from `library` (which holds shader.metal), once.
    pub fn ensurePipelines(h: *Hdr, device: objc.Object, library: objc.Object, makePlane: *const fn (objc.Object, objc.Object) anyerror!objc.Object) !void {
        if (h.plane_pipeline == null) h.plane_pipeline = try makePlane(device, library);
        if (h.compose_pipeline == null) h.compose_pipeline = try composePipeline(device, library);
    }

    /// The UI target and the plane at `w` × `h`, made or remade to fit.
    pub fn targets(h: *Hdr, device: objc.Object, w: usize, ht: usize) ?struct { ui: objc.Object, plane: objc.Object } {
        if (h.w != w or h.h != ht) h.releaseTargets();
        if (h.ui == null) h.ui = texture(device, bgra8, w, ht);
        if (h.plane == null) h.plane = texture(device, rgba16f, w, ht);
        h.w = w;
        h.h = ht;
        return .{ .ui = h.ui orelse return null, .plane = h.plane orelse return null };
    }

    pub fn releaseTargets(h: *Hdr) void {
        if (h.ui) |t| objc.release(t);
        if (h.plane) |t| objc.release(t);
        h.ui = null;
        h.plane = null;
        h.w = 0;
        h.h = 0;
    }

    pub fn deinit(h: *Hdr) void {
        h.releaseTargets();
        if (h.plane_pipeline) |p| objc.release(p);
        if (h.compose_pipeline) |p| objc.release(p);
        h.* = .{};
    }

    fn texture(device: objc.Object, format: objc.NSUInteger, w: usize, h: usize) ?objc.Object {
        const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            format, @as(objc.NSUInteger, @max(w, 1)), @as(objc.NSUInteger, @max(h, 1)), objc.NO,
        });
        objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1 | 4)}); // shader read, render target
        objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 2)}); // private
        return objc.msg(?objc.Object, device, "newTextureWithDescriptor:", .{desc});
    }

    fn composePipeline(device: objc.Object, library: objc.Object) !objc.Object {
        const vs = objc.msg(?objc.Object, library, "newFunctionWithName:", .{objc.nsString("vs_hdr_compose")}) orelse return error.PipelineCreate;
        defer objc.release(vs);
        const fs = objc.msg(?objc.Object, library, "newFunctionWithName:", .{objc.nsString("fs_hdr_compose")}) orelse return error.PipelineCreate;
        defer objc.release(fs);
        const desc = objc.new("MTLRenderPipelineDescriptor");
        defer objc.release(desc);
        objc.msg(void, desc, "setVertexFunction:", .{vs});
        objc.msg(void, desc, "setFragmentFunction:", .{fs});
        const ca = objc.msg(objc.Object, objc.msg(objc.Object, desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(objc.NSUInteger, 0)});
        objc.msg(void, ca, "setPixelFormat:", .{rgba16f});
        var err: ?objc.Object = null;
        return objc.msg(?objc.Object, device, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err }) orelse error.PipelineCreate;
    }
};

/// Shows the layer's pixels as `c`: `.extended_linear` makes it an
/// RGBA16Float, extended-linear-sRGB layer that wants EDR, and frames
/// draw the UI into an 8-bit target of their own, then compose it
/// (decoded, times `sdr_white_scale`) with the `.surface_linear`
/// textures into the drawable; `.sdr_srgb` is the layer every surface
/// starts with. The next drawable has the new format; a frame already
/// given one is drawn for the format it has.
pub fn setColour(self: *Renderer, c: gpu.SurfaceColour) !void {
    if (c == self.colour) return;
    const ext = c == .extended_linear;
    if (ext) try self.hdr.ensurePipelines(self.device, self.library, metal.makePlanePipeline);
    const pool = objc.Pool.push();
    defer pool.pop();
    objc.msg(void, self.layer, "setPixelFormat:", .{if (ext) rgba16f else metal.pixel_format});
    if (objc.msg(objc.BOOL, self.layer, "respondsToSelector:", .{objc.sel("setWantsExtendedDynamicRangeContent:")}))
        objc.msg(void, self.layer, "setWantsExtendedDynamicRangeContent:", .{if (ext) objc.YES else objc.NO});
    if (objc.msg(objc.BOOL, self.layer, "respondsToSelector:", .{objc.sel("setColorspace:")})) {
        if (cf.CGColorSpaceCreateWithName(if (ext) cf.kCGColorSpaceExtendedLinearSRGB else cf.kCGColorSpaceSRGB)) |space| {
            defer cf.CGColorSpaceRelease(space);
            objc.msg(void, self.layer, "setColorspace:", .{space});
        }
    }
    self.colour = c;
    if (!ext) {
        self.waitIdle();
        self.hdr.releaseTargets();
    }
}

/// An extended frame (`setColour`): the UI exactly as an SDR frame draws
/// it, into the 8-bit UI target, with each `.surface_linear` texture's
/// shape cut out of it; those textures, in order, into the plane; then
/// both composed into `texture` (RGBA16Float) by `fs_hdr_compose`.
pub fn encodeExtended(self: *Renderer, cmd: objc.Object, texture: objc.Object, instance_buffer: ?objc.Object, instances: []const gpu.Instance, atlas: objc.Object, size: types.Size, clear: types.Color) void {
    const w = objc.msg(objc.NSUInteger, texture, "width", .{});
    const h = objc.msg(objc.NSUInteger, texture, "height", .{});
    const t = self.hdr.targets(self.device, w, h) orelse {
        objc.msg(void, Renderer.pass(cmd, texture, clear), "endEncoding", .{});
        return;
    };
    var first: usize = 0;
    if (instance_buffer) |buffer| {
        const cover = gpu.lastCover(instances, size);
        first = if (cover) |k| k + 1 else 0;
        const frame_clear: types.Color = if (cover) |k| .{ .r = instances[k].color[0], .g = instances[k].color[1], .b = instances[k].color[2], .a = 1 } else clear;
        self.encodeRange(cmd, t.ui, buffer, instances, atlas, size, first, instances.len, 0, frame_clear, false);
    } else {
        objc.msg(void, Renderer.pass(cmd, t.ui, clear), "endEncoding", .{});
    }
    // The plane: every `.surface_linear` texture the frame draws, each
    // with its own clip and corners (`fs_plane`), the last on top.
    var planes: u32 = 0;
    if (instance_buffer) |buffer| {
        var penc: ?objc.Object = null;
        for (instances[first..], first..) |inst, k| {
            if (inst.kind != gpu.Kind.texture) continue;
            const slot: usize = @intFromFloat(inst.border_width);
            if (!self.inPlane(slot)) continue;
            const tex = self.frame_textures.get(slot) orelse continue;
            const enc = penc orelse blk: {
                penc = Renderer.pass(cmd, t.plane, types.Color.transparent);
                break :blk penc.?;
            };
            objc.msg(void, enc, "setFragmentTexture:atIndex:", .{ tex, @as(objc.NSUInteger, 3) });
            self.drawRange(enc, self.hdr.plane_pipeline.?, buffer, atlas, atlas, size, k, 1);
            planes += 1;
        }
        if (penc) |enc| objc.msg(void, enc, "endEncoding", .{});
    }
    const k: Compose = .{ .scale = self.sdr_white_scale, .plane = @intFromBool(planes > 0) };
    const cenc = Renderer.pass(cmd, texture, null);
    objc.msg(void, cenc, "setRenderPipelineState:", .{self.hdr.compose_pipeline.?});
    objc.msg(void, cenc, "setFragmentBytes:length:atIndex:", .{ @as(*const anyopaque, &k), @as(objc.NSUInteger, @sizeOf(Compose)), @as(objc.NSUInteger, 0) });
    objc.msg(void, cenc, "setFragmentTexture:atIndex:", .{ t.ui, @as(objc.NSUInteger, 0) });
    objc.msg(void, cenc, "setFragmentTexture:atIndex:", .{ if (planes > 0) t.plane else t.ui, @as(objc.NSUInteger, 1) });
    objc.msg(void, cenc, "drawPrimitives:vertexStart:vertexCount:", .{ @as(objc.NSUInteger, 3), @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 3) });
    objc.msg(void, cenc, "endEncoding", .{});
}

/// The sRGB EOTF `fs_hdr_compose` decodes the UI with (tests compare against
/// it).
pub fn srgbEotf(c: f32) f32 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}
