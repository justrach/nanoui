//! The pixels a window shows where the CPU renderer draws them (Linux,
//! Windows), and what they were drawn from, so that a frame draws again
//! only what it changed.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const TextSystem = @import("text.zig").TextSystem;

/// One frame to show: its instances, drawn over `clear` at `scale` into
/// `size` points, from the atlases of `text`.
pub const Frame = struct {
    instances: []const gpu.Instance,
    text: *const TextSystem,
    clear: types.Color,
    size: types.Size,
    scale: f32,

    fn pixelSize(f: Frame) [2]usize {
        return .{ @intFromFloat(@max(1, @round(f.size.w * f.scale))), @intFromFloat(@max(1, @round(f.size.h * f.scale))) };
    }
};

pub const Canvas = struct {
    /// BGRA, premultiplied, `width` × `height`.
    bytes: []u8 = &.{},
    width: usize = 0,
    height: usize = 0,
    /// What the pixels show.
    drawn: std.ArrayList(gpu.Instance) = .empty,
    clear: types.Color = .{},
    glyph_resets: u64 = 0,
    picture_resets: u64 = 0,

    pub fn deinit(cv: *Canvas, gpa: std.mem.Allocator) void {
        gpa.free(cv.bytes);
        cv.drawn.deinit(gpa);
    }

    /// The pixels (x0, y0, x1, y1) in which `f` differs from what was
    /// drawn; null when none do. All of them when the size or background
    /// changed, or either atlas started over (what's added to one goes
    /// where nothing drawn was).
    pub fn damage(cv: *const Canvas, f: Frame) ?[4]usize {
        const w, const h = f.pixelSize();
        if (w != cv.width or h != cv.height or
            !std.meta.eql(cv.clear, f.clear) or
            cv.glyph_resets != f.text.atlas.resets or
            cv.picture_resets != f.text.images.resets)
            return .{ 0, 0, w, h };
        return raster.damage(w, h, cv.drawn.items, f.instances, f.scale);
    }

    /// Draws what `f` changed into the pixels, sized to it.
    pub fn draw(cv: *Canvas, gpa: std.mem.Allocator, f: Frame) void {
        const region = cv.damage(f) orelse return;
        const w, const h = f.pixelSize();
        if (w != cv.width or h != cv.height) {
            const px = gpa.alloc(u8, w * h * 4) catch return;
            gpa.free(cv.bytes);
            cv.bytes = px;
            cv.width = w;
            cv.height = h;
        }
        raster.drawRegion(.{ .bytes = cv.bytes, .width = w, .height = h }, f.instances, f.text.atlas.mask(), f.text.images.pictures(), f.scale, f.clear, region);
        cv.clear = f.clear;
        cv.glyph_resets = f.text.atlas.resets;
        cv.picture_resets = f.text.images.resets;
        cv.drawn.clearRetainingCapacity();
        // Out of memory: the next frame is drawn whole.
        cv.drawn.appendSlice(gpa, f.instances) catch {
            cv.glyph_resets -%= 1;
        };
    }
};
