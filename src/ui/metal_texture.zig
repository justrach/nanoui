//! The frame's textures on the GPU (`ui.texture`): a CVPixelBuffer wrapped
//! as Metal textures without a copy (CVMetalTextureCache), a plane at a
//! time; BGRA bytes uploaded into a texture kept for its slot; or an app's
//! own MTLTexture. Wrapped planes are held until the GPU is done with the
//! frame that drew them.
//!
//! A frame that isn't display BGRA, or that has a LUT, first runs the
//! colour stage (`texture_post.metal`, the real app's post-process pass)
//! into a BGRA texture of its own size kept for its slot, which the frame
//! then samples as it samples any texture.
const std = @import("std");
const objc = @import("../objc.zig");
const gpu = @import("gpu.zig");
const color = @import("color.zig");
const metal_app = @import("metal_app.zig");
const pixel_buffer = @import("pixel_buffer.zig");

const CVReturn = i32;
extern "c" fn CVMetalTextureCacheCreate(allocator: ?*anyopaque, attrs: ?*anyopaque, device: objc.Object, texture_attrs: ?*anyopaque, out: *?*anyopaque) CVReturn;
extern "c" fn CVMetalTextureCacheCreateTextureFromImage(allocator: ?*anyopaque, cache: *anyopaque, image: *anyopaque, attrs: ?*anyopaque, format: objc.NSUInteger, width: usize, height: usize, plane: usize, out: *?*anyopaque) CVReturn;
extern "c" fn CVMetalTextureGetTexture(texture: *anyopaque) ?objc.Object;
extern "c" fn CVMetalTextureCacheFlush(cache: *anyopaque, options: u64) void;
extern "c" fn CFRelease(obj: *anyopaque) void;

const bgra8: objc.NSUInteger = 80;
const r8: objc.NSUInteger = 10;
const rg8: objc.NSUInteger = 30;
const r16: objc.NSUInteger = 20;
const rg16: objc.NSUInteger = 60;
const rgba16f: objc.NSUInteger = 115;

const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };

/// A LUT's 3D texture, kept by its key.
const LutEntry = struct { key: u64, size: u16, texture: objc.Object, used: u64 };

pub const Textures = struct {
    gpa: std.mem.Allocator,
    cache: ?*anyopaque = null,
    /// Textures for bytes, by slot, and their sizes.
    uploads: std.ArrayList(?objc.Object) = .empty,
    sizes: std.ArrayList([2]u32) = .empty,
    /// The colour stage's pipeline and its LUT sampler.
    post: ?objc.Object = null,
    lut_sampler: ?objc.Object = null,
    /// The colour stage's output, by slot.
    targets: std.ArrayList(?objc.Object) = .empty,
    luts: std.ArrayList(LutEntry) = .empty,
    /// What each slot of this frame samples (`prepare`).
    resolved: std.ArrayList(?objc.Object) = .empty,
    frame: u64 = 0,

    /// Makes the colour stage's pipeline from the library holding
    /// `texture_post.metal`.
    pub fn initPost(t: *Textures, device: objc.Object, library: objc.Object) !void {
        const vs = objc.msg(objc.Object, library, "newFunctionWithName:", .{objc.nsString("alc_post_vs")});
        defer objc.release(vs);
        const fs = objc.msg(objc.Object, library, "newFunctionWithName:", .{objc.nsString("alc_post_fs")});
        defer objc.release(fs);
        const desc = objc.new("MTLRenderPipelineDescriptor");
        defer objc.release(desc);
        objc.msg(void, desc, "setVertexFunction:", .{vs});
        objc.msg(void, desc, "setFragmentFunction:", .{fs});
        const ca = objc.msg(objc.Object, objc.msg(objc.Object, desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(objc.NSUInteger, 0)});
        objc.msg(void, ca, "setPixelFormat:", .{bgra8});
        var err: ?objc.Object = null;
        t.post = objc.msg(?objc.Object, device, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err }) orelse return error.PipelineCreate;
        const sd = objc.new("MTLSamplerDescriptor");
        defer objc.release(sd);
        objc.msg(void, sd, "setMinFilter:", .{@as(objc.NSUInteger, 1)}); // linear
        objc.msg(void, sd, "setMagFilter:", .{@as(objc.NSUInteger, 1)});
        objc.msg(void, sd, "setSAddressMode:", .{@as(objc.NSUInteger, 0)}); // clamp to edge
        objc.msg(void, sd, "setTAddressMode:", .{@as(objc.NSUInteger, 0)});
        objc.msg(void, sd, "setRAddressMode:", .{@as(objc.NSUInteger, 0)});
        t.lut_sampler = objc.msg(?objc.Object, device, "newSamplerStateWithDescriptor:", .{sd});
    }

    pub fn deinit(t: *Textures) void {
        for (t.uploads.items) |u| if (u) |o| objc.release(o);
        for (t.targets.items) |u| if (u) |o| objc.release(o);
        for (t.luts.items) |e| objc.release(e.texture);
        t.uploads.deinit(t.gpa);
        t.sizes.deinit(t.gpa);
        t.targets.deinit(t.gpa);
        t.luts.deinit(t.gpa);
        t.resolved.deinit(t.gpa);
        if (t.post) |p| objc.release(p);
        if (t.lut_sampler) |s| objc.release(s);
        if (t.cache) |c| CFRelease(c);
    }

    /// Readies every texture of the frame before its passes: wraps or
    /// uploads it, and runs the colour stage into `cmd` where it needs it.
    /// Wrapped planes join `held` (`release` once the frame is done).
    pub fn prepare(t: *Textures, device: objc.Object, cmd: objc.Object, textures: []const gpu.Texture, held: *std.ArrayList(*anyopaque)) void {
        t.frame +%= 1;
        t.resolved.clearRetainingCapacity();
        for (textures, 0..) |tex, slot| {
            const r = t.resolve(device, cmd, tex, slot, held);
            t.resolved.append(t.gpa, r) catch return;
        }
    }

    /// What slot `slot` samples this frame (`prepare`).
    pub fn get(t: *const Textures, slot: usize) ?objc.Object {
        return if (slot < t.resolved.items.len) t.resolved.items[slot] else null;
    }

    fn resolve(t: *Textures, device: objc.Object, cmd: objc.Object, tex: gpu.Texture, slot: usize, held: *std.ArrayList(*anyopaque)) ?objc.Object {
        var planes: [2]?objc.Object = .{ null, null };
        var mode = color.sourceMode(tex.format);
        var u_tex = tex;
        if (tex.mtl_texture) |mt| {
            planes[0] = @ptrCast(mt);
            const pf = objc.msg(objc.NSUInteger, planes[0].?, "pixelFormat", .{});
            mode = if (metal_app.samplesLinear(pf)) 3 else 0;
            // An sRGB texture's values are display light once decoded: no tone map.
            u_tex.tone_map = tex.tone_map and !metal_app.isSrgb(pf);
        } else if (tex.pixel_buffer) |pb| {
            const formats: [2]objc.NSUInteger = switch (tex.format) {
                .bgra8 => .{ bgra8, 0 },
                .ycbcr420_8 => .{ r8, rg8 },
                .ycbcr420_10, .ycbcr422_10, .ycbcr444_10 => .{ r16, rg16 },
                .rgba16f => .{ rgba16f, 0 },
            };
            for (formats, 0..) |f, plane| if (f != 0) {
                const sz = pixel_buffer.planeSize(pb, plane);
                planes[plane] = t.wrap(device, pb, f, sz[0], sz[1], plane, held) orelse return null;
            };
        } else {
            planes[0] = t.upload(device, tex, slot) orelse return null;
        }
        const needs = mode != 0 or tex.lut != null or tex.source_lut != null;
        if (!needs) return planes[0];
        return t.colourStage(device, cmd, slot, planes, color.uniforms(u_tex, mode), tex);
    }

    fn wrap(t: *Textures, device: objc.Object, pb: *anyopaque, format: objc.NSUInteger, w: usize, h: usize, plane: usize, held: *std.ArrayList(*anyopaque)) ?objc.Object {
        if (t.cache == null) {
            var cache: ?*anyopaque = null;
            if (CVMetalTextureCacheCreate(null, null, device, null, &cache) != 0) return null;
            t.cache = cache;
        }
        var cv: ?*anyopaque = null;
        if (CVMetalTextureCacheCreateTextureFromImage(null, t.cache.?, pb, null, format, w, h, plane, &cv) != 0) return null;
        held.append(t.gpa, cv.?) catch {
            CFRelease(cv.?);
            return null;
        };
        return CVMetalTextureGetTexture(cv.?);
    }

    fn upload(t: *Textures, device: objc.Object, tex: gpu.Texture, slot: usize) ?objc.Object {
        if (tex.bgra.len == 0 or tex.width == 0 or tex.height == 0) return null;
        while (t.uploads.items.len <= slot) {
            t.uploads.append(t.gpa, null) catch return null;
            t.sizes.append(t.gpa, .{ 0, 0 }) catch return null;
        }
        if (t.uploads.items[slot] == null or t.sizes.items[slot][0] != tex.width or t.sizes.items[slot][1] != tex.height) {
            if (t.uploads.items[slot]) |o| objc.release(o);
            const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
                bgra8, @as(objc.NSUInteger, tex.width), @as(objc.NSUInteger, tex.height), objc.NO,
            });
            objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1)}); // shader read
            t.uploads.items[slot] = objc.msg(?objc.Object, device, "newTextureWithDescriptor:", .{desc});
            t.sizes.items[slot] = .{ tex.width, tex.height };
        }
        const o = t.uploads.items[slot] orelse return null;
        const stride = if (tex.stride > 0) tex.stride else @as(usize, tex.width) * 4;
        objc.msg(void, o, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            Region{ .x = 0, .y = 0, .z = 0, .w = tex.width, .h = tex.height, .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, tex.bgra.ptr), @as(objc.NSUInteger, stride),
        });
        return o;
    }

    /// The colour stage's output texture for `slot`, `w` × `h`.
    fn target(t: *Textures, device: objc.Object, slot: usize, w: usize, h: usize) ?objc.Object {
        while (t.targets.items.len <= slot) t.targets.append(t.gpa, null) catch return null;
        if (t.targets.items[slot]) |o| {
            if (objc.msg(objc.NSUInteger, o, "width", .{}) == w and objc.msg(objc.NSUInteger, o, "height", .{}) == h) return o;
            objc.release(o);
            t.targets.items[slot] = null;
        }
        const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ bgra8, w, h, objc.NO });
        objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1 | 4)}); // shader read, render target
        objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 2)}); // private
        t.targets.items[slot] = objc.msg(?objc.Object, device, "newTextureWithDescriptor:", .{desc});
        return t.targets.items[slot];
    }

    /// A LUT's 3D RGBA16Float texture, made the first time its key is seen.
    fn lutTexture(t: *Textures, device: objc.Object, l: gpu.Lut) ?objc.Object {
        if (!l.valid()) return null;
        for (t.luts.items) |*e| if (e.key == l.key and e.size == l.size) {
            e.used = t.frame;
            return e.texture;
        };
        const n: usize = l.size;
        const desc = objc.new("MTLTextureDescriptor");
        defer objc.release(desc);
        objc.msg(void, desc, "setTextureType:", .{@as(objc.NSUInteger, 7)}); // 3D
        objc.msg(void, desc, "setPixelFormat:", .{rgba16f});
        objc.msg(void, desc, "setWidth:", .{n});
        objc.msg(void, desc, "setHeight:", .{n});
        objc.msg(void, desc, "setDepth:", .{n});
        objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1)});
        objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 0)});
        const tex = objc.msg(?objc.Object, device, "newTextureWithDescriptor:", .{desc}) orelse return null;
        objc.msg(void, tex, "replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:", .{
            Region{ .x = 0, .y = 0, .z = 0, .w = n, .h = n, .d = n }, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 0), @as(*const anyopaque, l.data.ptr), n * 8, n * n * 8,
        });
        // A handful kept: the least recently used goes.
        if (t.luts.items.len >= 16) {
            var oldest: usize = 0;
            for (t.luts.items, 0..) |e, k| if (e.used < t.luts.items[oldest].used) {
                oldest = k;
            };
            objc.release(t.luts.items[oldest].texture);
            _ = t.luts.swapRemove(oldest);
        }
        t.luts.append(t.gpa, .{ .key = l.key, .size = l.size, .texture = tex, .used = t.frame }) catch {
            objc.release(tex);
            return null;
        };
        return tex;
    }

    /// `alc_post_fs` from `planes` into the slot's own BGRA texture, the
    /// size of the first plane, as the real app's render graph runs it.
    fn colourStage(t: *Textures, device: objc.Object, cmd: objc.Object, slot: usize, planes: [2]?objc.Object, u_in: color.Uniforms, tex: gpu.Texture) ?objc.Object {
        const post = t.post orelse return null;
        const src0 = planes[0] orelse return null;
        const w = objc.msg(objc.NSUInteger, src0, "width", .{});
        const h = objc.msg(objc.NSUInteger, src0, "height", .{});
        const out = t.target(device, slot, w, h) orelse return null;
        var u = u_in;
        const lut = if (tex.lut) |l| t.lutTexture(device, l) else null;
        const slut = if (tex.source_lut) |l| t.lutTexture(device, l) else null;
        if (lut == null) u.lut_enabled = 0;
        if (slut == null) u.source_lut_enabled = 0;
        const desc = objc.msg(objc.Object, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
        const ca = objc.msg(objc.Object, objc.msg(objc.Object, desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(objc.NSUInteger, 0)});
        objc.msg(void, ca, "setTexture:", .{out});
        objc.msg(void, ca, "setLoadAction:", .{@as(objc.NSUInteger, 0)}); // don't care
        objc.msg(void, ca, "setStoreAction:", .{@as(objc.NSUInteger, 1)});
        const enc = objc.msg(objc.Object, cmd, "renderCommandEncoderWithDescriptor:", .{desc});
        objc.msg(void, enc, "setRenderPipelineState:", .{post});
        objc.msg(void, enc, "setFragmentBytes:length:atIndex:", .{ @as(*const anyopaque, &u), @as(objc.NSUInteger, @sizeOf(color.Uniforms)), @as(objc.NSUInteger, 0) });
        objc.msg(void, enc, "setFragmentTexture:atIndex:", .{ src0, @as(objc.NSUInteger, 0) });
        objc.msg(void, enc, "setFragmentTexture:atIndex:", .{ planes[1] orelse src0, @as(objc.NSUInteger, 1) });
        if (lut) |l| objc.msg(void, enc, "setFragmentTexture:atIndex:", .{ l, @as(objc.NSUInteger, 2) });
        // Unsampled without a source LUT; bound so the slot is never empty.
        if (slut orelse lut) |l| objc.msg(void, enc, "setFragmentTexture:atIndex:", .{ l, @as(objc.NSUInteger, 3) });
        if (t.lut_sampler) |s| objc.msg(void, enc, "setFragmentSamplerState:atIndex:", .{ s, @as(objc.NSUInteger, 0) });
        objc.msg(void, enc, "drawPrimitives:vertexStart:vertexCount:", .{ @as(objc.NSUInteger, 3), @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 3) });
        objc.msg(void, enc, "endEncoding", .{});
        return out;
    }

    /// Releases a done frame's wrapped buffers.
    pub fn release(t: *Textures, held: *std.ArrayList(*anyopaque)) void {
        for (held.items) |cv| CFRelease(cv);
        held.clearRetainingCapacity();
        if (t.cache) |c| CVMetalTextureCacheFlush(c, 0);
    }
};
