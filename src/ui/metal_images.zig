//! The picture atlas on the GPU (`images.zig`): pictures put straight into
//! it as they are packed, or the atlas copied when its generation changes.
const std = @import("std");
const objc = @import("../objc.zig");
const metal = @import("metal.zig");
const Renderer = metal.Renderer;
const Images = @import("images.zig").Images;
const pixel_format = metal.pixel_format;

/// Brings the GPU's copy of the image atlas up to date (made on the
/// first picture).
/// Puts a packed picture straight into the GPU's image atlas (the
/// `Images.Sink` of a window): no copy of the atlas stays in memory.
pub fn uploadImage(ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, bgra: []const u8, atlas_side: u32) void {
    const self: *Renderer = @ptrCast(@alignCast(ctx));
    if (self.images_texture == null or self.images_side != atlas_side) {
        makeImagesTexture(self, atlas_side);
    } else if (x == 0 and y == 0) {
        self.waitIdle();
    }
    const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
    objc.msg(void, self.images_texture.?, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
        Region{ .x = x, .y = y, .z = 0, .w = w, .h = h, .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, bgra.ptr), @as(objc.NSUInteger, w) * 4,
    });
}

/// The picture atlas's texture at a side, frames using an older one done.
fn makeImagesTexture(self: *Renderer, atlas_side: u32) void {
    if (self.images_texture) |t| {
        self.waitIdle();
        objc.release(t);
    }
    const side: objc.NSUInteger = atlas_side;
    const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ pixel_format, side, side, objc.NO });
    self.images_texture = objc.msg(objc.Object, self.device, "newTextureWithDescriptor:", .{desc});
    self.images_side = atlas_side;
    self.images_generation = std.math.maxInt(u64);
}

pub fn syncImages(self: *Renderer, im: *Images) void {
    if (im.sink != null or im.pixels.len == 0 or im.generation == self.images_generation) return;
    const side: objc.NSUInteger = im.side;
    if (self.images_texture == null or self.images_side != im.side) makeImagesTexture(self, im.side);
    const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
    // Only the rows that changed, unless the texture is new.
    const rows: [2]u32 = if (self.images_generation == std.math.maxInt(u64)) .{ 0, @intCast(side) } else im.dirty orelse .{ 0, 0 };
    if (rows[1] > rows[0]) objc.msg(void, self.images_texture.?, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
        Region{ .x = 0, .y = rows[0], .z = 0, .w = side, .h = rows[1] - rows[0], .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, im.pixels.ptr + @as(usize, rows[0]) * side * 4), side * 4,
    });
    im.dirty = null;
    self.images_generation = im.generation;
}
