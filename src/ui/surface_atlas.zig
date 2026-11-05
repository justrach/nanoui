//! The atlas texture a surface hands its renderer.
const std = @import("std");
const objc = @import("../objc.zig");
const text = @import("text.zig");
const Surface = @import("surface.zig").Surface;

/// The atlas texture the renderer samples: CoreText's, or the one
/// nanoui's own text rasterized into memory, uploaded when it changed.
pub fn texture(self: *Surface) objc.Object {
    if (!text.portable) return self.text.texture();
    const a = &self.text.atlas;
    const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
    const side: usize = a.size;
    if (self.atlas_texture) |t| if (objc.msg(objc.NSUInteger, t, "width", .{}) != side) {
        objc.release(t);
        self.atlas_texture = null;
    };
    if (self.atlas_texture == null) {
        const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            @as(objc.NSUInteger, 10), side, side, objc.NO, // R8Unorm
        });
        self.atlas_texture = objc.msg(objc.Object, self.renderer.device, "newTextureWithDescriptor:", .{desc});
        self.atlas_generation = std.math.maxInt(u64);
    }
    const t = self.atlas_texture.?;
    if (self.atlas_generation != a.generation) {
        objc.msg(void, t, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            Region{ .x = 0, .y = 0, .z = 0, .w = side, .h = side, .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, a.pixels.ptr), side,
        });
        self.atlas_generation = a.generation;
    }
    return t;
}
