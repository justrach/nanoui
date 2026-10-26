//! The glyph atlas: each glyph rasterized once per font, quarter pixel of
//! horizontal position and stroke weight, at the display's scale, into one
//! R8 texture the renderer samples. Shelf packed; it grows when full, then
//! resets.
//!
//! Strokes are thickened as macOS thickens them with font smoothing on:
//! more for lighter text, so light text on a dark ground doesn't read thin
//! (`dilationFor`; the levels AppKit and GPUI use).
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const types = @import("types.zig");

extern "c" fn CTFontGetBoundingRectsForGlyphs(font: cf.CTFontRef, orientation: u32, glyphs: [*]const u16, rects: ?[*]objc.CGRect, count: cf.CFIndex) objc.CGRect;
extern "c" fn CTFontDrawGlyphs(font: cf.CTFontRef, glyphs: [*]const u16, positions: [*]const objc.CGPoint, count: usize, ctx: cf.CGContextRef) void;
extern "c" fn CGContextDrawImage(ctx: cf.CGContextRef, rect: objc.CGRect, image: *anyopaque) void;
extern "c" fn CGContextTranslateCTM(ctx: cf.CGContextRef, tx: f64, ty: f64) void;
extern "c" fn UIGraphicsPushContext(ctx: cf.CGContextRef) void;
extern "c" fn UIGraphicsPopContext() void;

/// The atlas starts small and doubles when full, up to `max_size`.
const initial_size: u32 = 512;
const max_size: u32 = 4096;
const pad: u32 = 1;
/// Horizontal positions are snapped to quarters of a pixel.
pub const subpixel_bins = 4;

/// A glyph in the atlas, placed relative to its pen position on the
/// baseline, in points.
pub const Sprite = struct {
    uv: [4]f32,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

const Key = struct { font: u16, glyph: u16, bin: u8, dilation: u8 };

/// How much CoreGraphics thickens text of this colour, 0 to 4: the level it
/// picks from the fill's luminance with font smoothing on, none when the
/// user turned smoothing off (`AppleFontSmoothing` 0).
pub fn dilationFor(r: f32, g: f32, b: f32) u8 {
    if (!smoothingAllowed()) return 0;
    const luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    return @intFromFloat(std.math.clamp(@floor(4 * luminance + 0.5), 0, 4));
}

/// Tests and other platforms set this; null asks macOS once.
pub var smoothing_allowed: ?bool = null;

fn smoothingAllowed() bool {
    if (smoothing_allowed) |v| return v;
    var allowed = true;
    const key = cf.string("AppleFontSmoothing");
    defer cf.CFRelease(@ptrCast(key));
    if (cf.CFPreferencesCopyAppValue(key, cf.kCFPreferencesCurrentApplication)) |v| {
        defer cf.CFRelease(v);
        // Only an explicit 0 turns smoothing off.
        var n: i64 = 1;
        if (cf.CFGetTypeID(v) == cf.CFNumberGetTypeID() and cf.CFNumberGetValue(v, cf.number_sint64, &n)) allowed = n != 0;
    }
    smoothing_allowed = allowed;
    return allowed;
}
const SymbolKey = struct { name: u64, size_bits: u32, weight: u8 };

pub const Atlas = struct {
    gpa: std.mem.Allocator,
    device: objc.Object,
    texture: objc.Object,
    size: u32 = initial_size,
    scale: f32 = 2,
    sprites: std.AutoHashMapUnmanaged(Key, ?Sprite) = .empty,
    symbols: std.AutoHashMapUnmanaged(SymbolKey, ?Sprite) = .empty,
    shelf_x: u32 = 0,
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,
    /// Set when the atlas was reset during a frame, whose earlier glyphs
    /// are then stale: the frame must be painted again.
    reset_during_frame: bool = false,
    pixels: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, device: objc.Object) Atlas {
        return .{ .gpa = gpa, .device = device, .texture = makeTexture(device, initial_size) };
    }

    fn makeTexture(device: objc.Object, side: u32) objc.Object {
        const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            @as(objc.NSUInteger, 10), @as(objc.NSUInteger, side), @as(objc.NSUInteger, side), objc.NO, // R8Unorm
        });
        return objc.msg(objc.Object, device, "newTextureWithDescriptor:", .{desc});
    }

    /// Makes room when the atlas is full: a texture twice as large while it
    /// can grow, else the same one emptied. Either way every glyph is
    /// rasterized again, and the frame painted again.
    fn makeRoom(a: *Atlas) void {
        if (a.size < max_size) {
            a.size *= 2;
            objc.release(a.texture);
            a.texture = makeTexture(a.device, a.size);
        }
        a.reset();
        a.reset_during_frame = true;
    }

    pub fn deinit(a: *Atlas) void {
        a.sprites.deinit(a.gpa);
        a.symbols.deinit(a.gpa);
        a.pixels.deinit(a.gpa);
        objc.release(a.texture);
    }

    pub fn setScale(a: *Atlas, scale: f32) void {
        if (scale == a.scale) return;
        a.scale = scale;
        a.reset();
    }

    pub fn reset(a: *Atlas) void {
        a.sprites.clearRetainingCapacity();
        a.symbols.clearRetainingCapacity();
        a.shelf_x = 0;
        a.shelf_y = 0;
        a.shelf_h = 0;
    }

    /// The sprite of `glyph` of `font` (whose id is `font_id`) drawn at
    /// `bin` quarters of a pixel right of a pixel boundary, its strokes
    /// thickened `dilation` levels; null for blank glyphs (spaces).
    pub fn glyph(a: *Atlas, font_id: u16, font: cf.CTFontRef, g: u16, bin: u8, dilation: u8) ?Sprite {
        const key: Key = .{ .font = font_id, .glyph = g, .bin = bin, .dilation = dilation };
        if (a.sprites.get(key)) |sp| return sp;
        const sp = a.rasterize(font, g, bin, dilation);
        a.sprites.put(a.gpa, key, sp) catch {};
        return sp;
    }

    fn rasterize(a: *Atlas, font: cf.CTFontRef, g: u16, bin: u8, dilation: u8) ?Sprite {
        const scale = a.scale;
        var glyphs = [1]u16{g};
        const bounds = CTFontGetBoundingRectsForGlyphs(font, 0, &glyphs, null, 1);
        if (bounds.size.width <= 0 or bounds.size.height <= 0) return null;
        const sub: f64 = @as(f64, @floatFromInt(bin)) / subpixel_bins;
        const s: f64 = scale;
        const x0 = @floor(bounds.origin.x * s + sub);
        const y0 = @floor(bounds.origin.y * s);
        const x1 = @ceil((bounds.origin.x + bounds.size.width) * s + sub);
        const y1 = @ceil((bounds.origin.y + bounds.size.height) * s);
        const w: u32 = @as(u32, @intFromFloat(x1 - x0)) + 2 * pad;
        const h: u32 = @as(u32, @intFromFloat(y1 - y0)) + 2 * pad;
        if (w > max_size or h > max_size) return null;
        const origin = a.allocate(w, h) orelse blk: {
            a.makeRoom();
            break :blk a.allocate(w, h) orelse return null;
        };

        a.pixels.resize(a.gpa, w * h) catch return null;
        @memset(a.pixels.items, 0);
        const gray = cf.CGColorSpaceCreateDeviceGray() orelse return null;
        defer cf.CGColorSpaceRelease(gray);
        const ctx = cf.CGBitmapContextCreate(a.pixels.items.ptr, w, h, 8, w, gray, cf.image_alpha_only) orelse return null;
        defer cf.CGContextRelease(ctx);
        cf.CGContextSetAllowsAntialiasing(ctx, true);
        cf.CGContextSetShouldAntialias(ctx, true);
        cf.CGContextSetAllowsFontSubpixelPositioning(ctx, true);
        cf.CGContextSetShouldSubpixelPositionFonts(ctx, true);
        // The glyph at its exact quarter-pixel offset, not CoreText's own
        // quantized one (GPUI's rasterize_glyph turns quantizing off).
        cf.CGContextSetAllowsFontSubpixelQuantization(ctx, false);
        cf.CGContextSetShouldSubpixelQuantizeFonts(ctx, false);
        // Smoothing thickens strokes by the fill's luminance; the alpha
        // drawn is the same whatever the fill.
        cf.CGContextSetShouldSmoothFonts(ctx, dilation > 0);
        cf.CGContextSetGrayFillColor(ctx, @as(f64, @floatFromInt(dilation)) * 0.25, 1);
        // The glyph's origin, in pixels from the bitmap's bottom left.
        CGContextTranslateCTM(ctx, @as(f64, pad) - x0 + sub, @as(f64, pad) - y0);
        cf.CGContextScaleCTM(ctx, s, s);
        const at = [1]objc.CGPoint{.{}};
        CTFontDrawGlyphs(font, &glyphs, &at, 1, ctx);

        a.upload(origin, w, h);
        const as: f32 = @floatFromInt(a.size);
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        return .{
            .uv = .{
                @as(f32, @floatFromInt(origin[0])) / as,
                @as(f32, @floatFromInt(origin[1])) / as,
                @as(f32, @floatFromInt(origin[0] + w)) / as,
                @as(f32, @floatFromInt(origin[1] + h)) / as,
            },
            // Relative to the pen position snapped to the pixel boundary.
            .x = (@as(f32, @floatCast(x0)) - @as(f32, pad)) / scale,
            .y = -(@as(f32, @floatCast(y0)) - @as(f32, pad) + fh) / scale,
            .w = fw / scale,
            .h = fh / scale,
        };
    }

    /// The SF Symbol `name` at `point_size` and `weight` (0 regular … 3
    /// bold), as a mask: `x`, `y` are 0 and `w`, `h` its size in points.
    pub fn symbol(a: *Atlas, name: []const u8, point_size: f32, weight: u8) ?Sprite {
        const key: SymbolKey = .{ .name = std.hash.Wyhash.hash(0, name), .size_bits = @bitCast(point_size), .weight = weight };
        if (a.symbols.get(key)) |sp| return sp;
        const sp = a.rasterizeSymbol(name, point_size, weight);
        a.symbols.put(a.gpa, key, sp) catch {};
        return sp;
    }

    fn rasterizeSymbol(a: *Atlas, name: []const u8, point_size: f32, weight: u8) ?Sprite {
        const pool = objc.Pool.push();
        defer pool.pop();
        const img = symbolImage(name, point_size, weight) orelse return null;
        const sz = objc.msg(objc.CGSize, img, "size", .{});
        if (sz.width <= 0 or sz.height <= 0) return null;
        const scale = a.scale;
        const w: u32 = @intFromFloat(@ceil(sz.width * scale));
        const h: u32 = @intFromFloat(@ceil(sz.height * scale));
        if (w + 2 * pad > max_size or h + 2 * pad > max_size) return null;
        const rect: objc.CGRect = .{ .origin = .{ .x = pad, .y = pad }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } };
        const bw = w + 2 * pad;
        const bh = h + 2 * pad;
        const origin = a.allocate(bw, bh) orelse blk: {
            a.makeRoom();
            break :blk a.allocate(bw, bh) orelse return null;
        };
        // AppKit draws the symbol, into color (it can't into a mask), and
        // the mask keeps its coverage: the symbol's CGImage holds only the
        // strokes' outlines on recent macOS.
        const rgba = a.gpa.alloc(u8, bw * bh * 4) catch return null;
        defer a.gpa.free(rgba);
        @memset(rgba, 0);
        const space = cf.CGColorSpaceCreateWithName(cf.kCGColorSpaceSRGB) orelse return null;
        defer cf.CGColorSpaceRelease(space);
        const ctx = cf.CGBitmapContextCreate(rgba.ptr, bw, bh, 8, bw * 4, space, 2 | (2 << 12)) orelse return null;
        defer cf.CGContextRelease(ctx);
        if (objc.uikit) {
            // UIKit draws top down: flip the bitmap's coordinates to its own.
            CGContextTranslateCTM(ctx, 0, @floatFromInt(bh));
            cf.CGContextScaleCTM(ctx, 1, -1);
            UIGraphicsPushContext(ctx);
            objc.msg(void, img, "drawInRect:", .{rect});
            UIGraphicsPopContext();
        } else {
            const gc = objc.msg(objc.Object, objc.class("NSGraphicsContext"), "graphicsContextWithCGContext:flipped:", .{ @as(*anyopaque, ctx), objc.NO });
            objc.msg(void, objc.class("NSGraphicsContext"), "saveGraphicsState", .{});
            objc.msg(void, objc.class("NSGraphicsContext"), "setCurrentContext:", .{gc});
            objc.msg(void, img, "drawInRect:fromRect:operation:fraction:", .{ rect, objc.CGRect{}, @as(objc.NSUInteger, 2), @as(f64, 1) });
            objc.msg(void, objc.class("NSGraphicsContext"), "restoreGraphicsState", .{});
        }
        a.pixels.resize(a.gpa, bw * bh) catch return null;
        for (a.pixels.items, 0..) |*m, i| m.* = rgba[i * 4 + 3];
        a.upload(origin, bw, bh);
        const as: f32 = @floatFromInt(a.size);
        const p: f32 = @as(f32, pad) / scale;
        return .{
            .uv = .{
                @as(f32, @floatFromInt(origin[0])) / as,
                @as(f32, @floatFromInt(origin[1])) / as,
                @as(f32, @floatFromInt(origin[0] + bw)) / as,
                @as(f32, @floatFromInt(origin[1] + bh)) / as,
            },
            .x = -p,
            .y = -p,
            .w = @as(f32, @floatFromInt(bw)) / scale,
            .h = @as(f32, @floatFromInt(bh)) / scale,
        };
    }

    /// The atlas's texels, read back from the GPU: for the CPU renderer's
    /// test against the Metal renderer.
    pub fn read(a: *Atlas, gpa: std.mem.Allocator) ![]u8 {
        const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
        const bytes = try gpa.alloc(u8, @as(usize, a.size) * a.size);
        objc.msg(void, a.texture, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{
            @as(*anyopaque, bytes.ptr), @as(objc.NSUInteger, a.size), Region{ .x = 0, .y = 0, .z = 0, .w = a.size, .h = a.size, .d = 1 }, @as(objc.NSUInteger, 0),
        });
        return bytes;
    }

    fn upload(a: *Atlas, origin: [2]u32, w: u32, h: u32) void {
        const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
        objc.msg(void, a.texture, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            Region{ .x = origin[0], .y = origin[1], .z = 0, .w = w, .h = h, .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, a.pixels.items.ptr), @as(objc.NSUInteger, w),
        });
    }

    fn allocate(a: *Atlas, w: u32, h: u32) ?[2]u32 {
        if (a.shelf_x + w > a.size) {
            a.shelf_y += a.shelf_h;
            a.shelf_x = 0;
            a.shelf_h = 0;
        }
        if (a.shelf_y + h > a.size) return null;
        const at: [2]u32 = .{ a.shelf_x, a.shelf_y };
        a.shelf_x += w;
        a.shelf_h = @max(a.shelf_h, h);
        return at;
    }
};

/// The SF Symbol `name` at `point_size` and `weight` (regular, medium,
/// semibold, bold): an NSImage on macOS, a UIImage on iOS.
fn symbolImage(name: []const u8, point_size: f32, weight: u8) ?objc.Object {
    if (objc.uikit) {
        // UIImageSymbolWeight: regular is 4, then medium, semibold, bold.
        const config = objc.msg(objc.Object, objc.class("UIImageSymbolConfiguration"), "configurationWithPointSize:weight:", .{
            @as(f64, point_size), @as(objc.NSInteger, 4 + @as(objc.NSInteger, @min(weight, 3))),
        });
        return objc.msg(?objc.Object, objc.class("UIImage"), "systemImageNamed:withConfiguration:", .{ objc.nsString(name), config });
    }
    const base = objc.msg(?objc.Object, objc.class("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", .{
        objc.nsString(name), @as(?objc.Object, null),
    }) orelse return null;
    // NSFontWeight: regular, medium, semibold, bold.
    const weights = [_]f64{ 0, 0.23, 0.3, 0.4 };
    const config = objc.msg(objc.Object, objc.class("NSImageSymbolConfiguration"), "configurationWithPointSize:weight:", .{
        @as(f64, point_size), weights[@min(weight, 3)],
    });
    return objc.msg(?objc.Object, base, "imageWithSymbolConfiguration:", .{config});
}
