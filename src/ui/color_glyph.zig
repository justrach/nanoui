//! Glyphs of color fonts (Apple Color Emoji) on macOS and iOS: drawn once in
//! their own colors into a premultiplied BGRA bitmap and shown as pictures,
//! untinted, through the image atlas. The glyph atlas is one channel of
//! coverage filled with the text's color, which turned 👋 into a black hand.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const images_mod = @import("images.zig");

extern "c" fn CTFontGetSymbolicTraits(font: cf.CTFontRef) u32;
extern "c" fn CTFontGetBoundingRectsForGlyphs(font: cf.CTFontRef, orientation: u32, glyphs: [*]const u16, rects: ?[*]objc.CGRect, count: cf.CFIndex) objc.CGRect;
extern "c" fn CTFontDrawGlyphs(font: cf.CTFontRef, glyphs: [*]const u16, positions: [*]const objc.CGPoint, count: usize, ctx: cf.CGContextRef) void;
extern "c" fn CGContextTranslateCTM(ctx: cf.CGContextRef, tx: f64, ty: f64) void;

/// `kCTFontTraitColorGlyphs`: the font draws its glyphs in color.
const color_glyphs_trait: u32 = 1 << 13;
const pad: u32 = 1;
/// The longest side a color glyph is drawn at, in pixels.
const max_side: u32 = 512;

/// Where a color glyph sits from its pen position on the baseline, in
/// points, and its pixels.
const Raster = struct {
    decoded: images_mod.Decoded,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

const Key = struct { font: u16, glyph: u16, scale_bits: u32 };

pub const Cache = struct {
    /// Whether each run font draws in color, by its index.
    color_fonts: std.AutoHashMapUnmanaged(u16, bool) = .empty,
    /// Drawn glyphs (null: nothing to draw, as a space).
    glyphs: std.AutoHashMapUnmanaged(Key, ?Raster) = .empty,

    pub fn deinit(c: *Cache, gpa: std.mem.Allocator) void {
        var it = c.glyphs.valueIterator();
        while (it.next()) |r| if (r.*) |x| gpa.free(x.decoded.bgra);
        c.glyphs.deinit(gpa);
        c.color_fonts.deinit(gpa);
    }

    pub fn isColor(c: *Cache, gpa: std.mem.Allocator, font_id: u16, font: cf.CTFontRef) bool {
        if (c.color_fonts.get(font_id)) |v| return v;
        const v = CTFontGetSymbolicTraits(font) & color_glyphs_trait != 0;
        c.color_fonts.put(gpa, font_id, v) catch {};
        return v;
    }

    /// The glyph `g` of color font `font` at `scale`, packed into `images`:
    /// a sprite whose `uv` is the image atlas's.
    pub fn sprite(c: *Cache, gpa: std.mem.Allocator, images: *images_mod.Images, font_id: u16, font: cf.CTFontRef, g: u16, scale: f32) ?Sprite {
        const k: Key = .{ .font = font_id, .glyph = g, .scale_bits = @bitCast(scale) };
        const r = c.glyphs.get(k) orelse blk: {
            const drawn = rasterize(gpa, font, g, scale);
            c.glyphs.put(gpa, k, drawn) catch {
                if (drawn) |x| gpa.free(x.decoded.bgra);
                return null;
            };
            break :blk drawn;
        } orelse return null;
        const image_key = std.hash.Wyhash.hash(0xe3071, std.mem.asBytes(&k));
        const e = images.getDrawn(image_key, r.decoded) orelse return null;
        return .{ .uv = e.uv, .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    }
};

pub const Sprite = struct { uv: [4]f32, x: f32, y: f32, w: f32, h: f32 };

fn rasterize(gpa: std.mem.Allocator, font: cf.CTFontRef, g: u16, scale: f32) ?Raster {
    var glyphs = [1]u16{g};
    const bounds = CTFontGetBoundingRectsForGlyphs(font, 0, &glyphs, null, 1);
    if (bounds.size.width <= 0 or bounds.size.height <= 0) return null;
    const s: f64 = scale;
    const x0 = @floor(bounds.origin.x * s);
    const y0 = @floor(bounds.origin.y * s);
    const x1 = @ceil((bounds.origin.x + bounds.size.width) * s);
    const y1 = @ceil((bounds.origin.y + bounds.size.height) * s);
    const w: u32 = @as(u32, @intFromFloat(x1 - x0)) + 2 * pad;
    const h: u32 = @as(u32, @intFromFloat(y1 - y0)) + 2 * pad;
    if (w > max_side or h > max_side) return null;
    const bgra = gpa.alloc(u8, @as(usize, w) * h * 4) catch return null;
    @memset(bgra, 0);
    const space = cf.CGColorSpaceCreateWithName(cf.kCGColorSpaceSRGB) orelse {
        gpa.free(bgra);
        return null;
    };
    defer cf.CGColorSpaceRelease(space);
    // Premultiplied BGRA, the image atlas's own layout; its first row is
    // the glyph's top.
    const ctx = cf.CGBitmapContextCreate(bgra.ptr, w, h, 8, w * 4, space, 2 | (2 << 12)) orelse {
        gpa.free(bgra);
        return null;
    };
    defer cf.CGContextRelease(ctx);
    cf.CGContextSetShouldAntialias(ctx, true);
    CGContextTranslateCTM(ctx, @as(f64, pad) - x0, @as(f64, pad) - y0);
    cf.CGContextScaleCTM(ctx, s, s);
    const at = [1]objc.CGPoint{.{}};
    CTFontDrawGlyphs(font, &glyphs, &at, 1, ctx);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    return .{
        .decoded = .{ .width = w, .height = h, .w = w, .h = h, .bgra = bgra },
        .x = (@as(f32, @floatCast(x0)) - @as(f32, pad)) / scale,
        .y = -(@as(f32, @floatCast(y0)) - @as(f32, pad) + fh) / scale,
        .w = fw / scale,
        .h = fh / scale,
    };
}
