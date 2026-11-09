//! The app's own Metal (`ui.metalDevice`, `Texture.mtl_texture`): the
//! device nanoui draws with, which formats of an app's texture hold linear
//! light, and reading one back for the CPU renderer.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");

var device_once: ?objc.Object = null;

/// The Metal device every nanoui window draws with (the system's
/// default): make the textures given as `Texture.mtl_texture` on it.
/// nanoui keeps it; don't release it.
pub fn metalDevice() ?*anyopaque {
    if (device_once == null) device_once = cf.MTLCreateSystemDefaultDevice();
    return if (device_once) |d| @ptrCast(d) else null;
}

/// Whether a texture of MTLPixelFormat `pf` samples as linear light: a
/// float format, or an sRGB one (decoded as it is sampled). The colour
/// stage encodes those for the display.
pub fn samplesLinear(pf: objc.NSUInteger) bool {
    return switch (pf) {
        25, 55, 65, 105, 115, 125, 92, 93 => true, // R16F, R32F, RG16F, RG32F, RGBA16F, RGBA32F, RG11B10F, RGB9E5
        11, 31, 71, 81 => true, // R8, RG8, RGBA8, BGRA8 _sRGB
        else => false,
    };
}

/// Whether MTLPixelFormat `pf` is an sRGB one: display light once decoded,
/// so never tone mapped.
pub fn isSrgb(pf: objc.NSUInteger) bool {
    return pf == 11 or pf == 31 or pf == 71 or pf == 81;
}

/// An app's texture's pixels: BGRA8 as stored (`half` false; display
/// values, `linear` false) or RGBA half floats in linear light.
pub const ReadBack = struct {
    bytes: []u8,
    width: usize,
    height: usize,
    stride: usize,
    half: bool,
    linear: bool,

    pub fn deinit(r: *ReadBack, gpa: std.mem.Allocator) void {
        gpa.free(r.bytes);
    }
};

const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };

/// Reads an app's 2D texture back (BGRA8, RGBA8, their sRGB forms, or
/// RGBA16Float): one the CPU can't see (private or managed storage) is
/// first copied to a shared one on the GPU.
pub fn readBack(gpa: std.mem.Allocator, mt: *anyopaque) ?ReadBack {
    const pool = objc.Pool.push();
    defer pool.pop();
    const tex: objc.Object = @ptrCast(mt);
    const pf = objc.msg(objc.NSUInteger, tex, "pixelFormat", .{});
    const bpp: usize = switch (pf) {
        80, 81, 70, 71 => 4,
        115 => 8,
        else => return null,
    };
    const w = objc.msg(objc.NSUInteger, tex, "width", .{});
    const h = objc.msg(objc.NSUInteger, tex, "height", .{});
    if (w == 0 or h == 0) return null;
    var src = tex;
    var staging: ?objc.Object = null;
    defer if (staging) |s| objc.release(s);
    if (objc.msg(objc.NSUInteger, tex, "storageMode", .{}) != 0) {
        const device = objc.msg(objc.Object, tex, "device", .{});
        const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ pf, w, h, objc.NO });
        objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 0)});
        objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1)});
        staging = objc.msg(?objc.Object, device, "newTextureWithDescriptor:", .{desc}) orelse return null;
        const queue = objc.msg(objc.Object, device, "newCommandQueue", .{});
        defer objc.release(queue);
        const cmd = objc.msg(objc.Object, queue, "commandBuffer", .{});
        const blit = objc.msg(objc.Object, cmd, "blitCommandEncoder", .{});
        objc.msg(void, blit, "copyFromTexture:toTexture:", .{ tex, staging.? });
        objc.msg(void, blit, "endEncoding", .{});
        objc.msg(void, cmd, "commit", .{});
        objc.msg(void, cmd, "waitUntilCompleted", .{});
        src = staging.?;
    }
    const stride = w * bpp;
    const bytes = gpa.alloc(u8, stride * h) catch return null;
    objc.msg(void, src, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{
        @as(*anyopaque, bytes.ptr), stride, Region{ .x = 0, .y = 0, .z = 0, .w = w, .h = h, .d = 1 }, @as(objc.NSUInteger, 0),
    });
    // RGBA8 to BGRA8.
    if (pf == 70 or pf == 71) {
        var i: usize = 0;
        while (i < bytes.len) : (i += 4) std.mem.swap(u8, &bytes[i], &bytes[i + 2]);
    }
    return .{ .bytes = bytes, .width = w, .height = h, .stride = stride, .half = bpp == 8, .linear = pf == 115 };
}
