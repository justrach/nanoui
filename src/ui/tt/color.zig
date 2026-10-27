//! Color glyphs read directly from a font, where nanoui reads fonts itself
//! (Linux, Windows, Android, `-Dportable`): emoji drawn in their own colors.
//!
//! - CBDT with its index CBLC (Noto Color Emoji on Linux and Android) and
//!   Apple's sbix (Apple Color Emoji): a PNG per glyph at a few sizes, the
//!   nearest at least as large scaled down.
//! - COLR version 0 with its palettes CPAL (Segoe UI Emoji on Windows): a
//!   glyph as outlines stacked in palette colors.
//!
//! Out: premultiplied BGRA, placed from the pen on the baseline, which the
//! text system packs into the image atlas and the renderers draw untinted.
const std = @import("std");
const font = @import("font.zig");
const tt_raster = @import("raster.zig");
const png_decode = @import("../png_decode.zig");

const be16 = font.be16;
const bei16 = font.bei16;
const be32 = font.be32;

pub fn has(f: *const font.Font) bool {
    return (f.t.cbdt != 0 and f.t.cblc != 0) or f.t.sbix != 0 or (f.t.colr != 0 and f.t.cpal != 0);
}

/// A glyph's PNG at one of its strikes: where its top left is from the
/// pen, in that strike's pixels (y up).
pub const Picture = struct {
    png: []const u8,
    ppem: f32,
    left: f32,
    top: f32,
};

/// The glyph's PNG at the smallest strike of at least `px` pixels an em,
/// else the largest.
pub fn picture(f: *const font.Font, g: u16, px: f32) ?Picture {
    if (f.t.cbdt != 0 and f.t.cblc != 0) if (cbdtPicture(f, g, px)) |p| return p;
    if (f.t.sbix != 0) if (sbixPicture(f, g, px)) |p| return p;
    return null;
}

fn better(best: ?f32, ppem: f32, px: f32) bool {
    const b = best orelse return true;
    if (b < px) return ppem > b;
    return ppem >= px and ppem < b;
}

fn cbdtPicture(f: *const font.Font, g: u16, px: f32) ?Picture {
    const d = f.data;
    const cblc = f.t.cblc;
    var strike: ?usize = null;
    var best: ?f32 = null;
    for (0..be32(d, cblc + 4)) |i| {
        const rec = cblc + 8 + 48 * i;
        if (rec + 48 > d.len) break;
        if (g < be16(d, rec + 40) or g > be16(d, rec + 42)) continue;
        const ppem: f32 = @floatFromInt(d[rec + 45]);
        if (better(best, ppem, px)) {
            best = ppem;
            strike = rec;
        }
    }
    const rec = strike orelse return null;
    const arr = cblc + be32(d, rec);
    for (0..be32(d, rec + 8)) |j| {
        const e = arr + 8 * j;
        const first = be16(d, e);
        if (g < first or g > be16(d, e + 2)) continue;
        const sub = arr + be32(d, e + 4);
        return cbdtImage(f, sub, g, first, best.?);
    }
    return null;
}

/// The image of glyph `g` in index subtable `sub` (formats 1 to 5).
fn cbdtImage(f: *const font.Font, sub: usize, g: u16, first: u16, ppem: f32) ?Picture {
    const d = f.data;
    const index_format = be16(d, sub);
    const image_format = be16(d, sub + 2);
    const base = f.t.cbdt + be32(d, sub + 4);
    const k: usize = g - first;
    // The metrics format 19 images leave to their index (formats 2 and 5).
    var shared: ?usize = null;
    const start: usize, const end: usize = switch (index_format) {
        1 => .{ base + be32(d, sub + 8 + 4 * k), base + be32(d, sub + 12 + 4 * k) },
        3 => .{ base + be16(d, sub + 8 + 2 * k), base + be16(d, sub + 10 + 2 * k) },
        2 => blk: {
            const size = be32(d, sub + 8);
            shared = sub + 12;
            break :blk .{ base + size * k, base + size * (k + 1) };
        },
        4 => blk: {
            const n = be32(d, sub + 8);
            for (0..n) |i| {
                const p = sub + 12 + 4 * i;
                if (be16(d, p) == g) break :blk .{ base + be16(d, p + 2), base + be16(d, p + 6) };
            }
            return null;
        },
        5 => blk: {
            const size = be32(d, sub + 8);
            shared = sub + 12;
            const n = be32(d, sub + 20);
            for (0..n) |i| if (be16(d, sub + 24 + 2 * i) == g) break :blk .{ base + size * i, base + size * (i + 1) };
            return null;
        },
        else => return null,
    };
    if (end <= start or end > d.len) return null;
    const left: f32, const top: f32, const data: usize = switch (image_format) {
        17 => .{ @floatFromInt(@as(i8, @bitCast(d[start + 2]))), @floatFromInt(@as(i8, @bitCast(d[start + 3]))), start + 5 },
        18 => .{ @floatFromInt(@as(i8, @bitCast(d[start + 2]))), @floatFromInt(@as(i8, @bitCast(d[start + 3]))), start + 8 },
        19 => blk: {
            const m = shared orelse return null;
            break :blk .{ @floatFromInt(@as(i8, @bitCast(d[m + 2]))), @floatFromInt(@as(i8, @bitCast(d[m + 3]))), start };
        },
        else => return null,
    };
    const len = be32(d, data);
    if (data + 4 + len > end) return null;
    return .{ .png = d[data + 4 ..][0..len], .ppem = ppem, .left = left, .top = top };
}

fn sbixPicture(f: *const font.Font, g: u16, px: f32) ?Picture {
    const d = f.data;
    const sb = f.t.sbix;
    if (g >= f.num_glyphs) return null;
    var strike: ?usize = null;
    var best: ?f32 = null;
    for (0..be32(d, sb + 4)) |i| {
        const so = sb + be32(d, sb + 8 + 4 * i);
        const ppem: f32 = @floatFromInt(be16(d, so));
        if (ppem > 0 and better(best, ppem, px)) {
            best = ppem;
            strike = so;
        }
    }
    const so = strike orelse return null;
    var glyph = g;
    // A `dupe` record points at another glyph's picture; follow one.
    for (0..2) |_| {
        const a = be32(d, so + 4 + 4 * @as(usize, glyph));
        const b = be32(d, so + 8 + 4 * @as(usize, glyph));
        if (b <= a + 8 or so + b > d.len) return null;
        const at = so + a;
        const data = d[at + 8 .. so + b];
        switch (be32(d, at + 4)) {
            std.mem.readInt(u32, "png ", .big) => {
                const h = pngHeight(data) orelse return null;
                const bottom: f32 = @floatFromInt(bei16(d, at + 2));
                return .{ .png = data, .ppem = best.?, .left = @floatFromInt(bei16(d, at)), .top = bottom + @as(f32, @floatFromInt(h)) };
            },
            std.mem.readInt(u32, "dupe", .big) => glyph = be16(data, 0),
            else => return null,
        }
    }
    return null;
}

fn pngHeight(png: []const u8) ?u32 {
    if (png.len < 24 or !std.mem.startsWith(u8, png, "\x89PNG")) return null;
    return std.mem.readInt(u32, png[20..24], .big);
}

/// One outline of a COLR glyph and its color, premultiplied BGRA (null:
/// the text's own color).
pub const Layer = struct { glyph: u16, bgra: ?[4]u8 };

/// The glyph's layers, bottom first, in `out` (version 0 records, which
/// version 1 fonts keep too).
pub fn layers(f: *const font.Font, g: u16, out: []Layer) []Layer {
    const d = f.data;
    const c = f.t.colr;
    if (c == 0 or f.t.cpal == 0) return out[0..0];
    const n_base = be16(d, c + 2);
    const bases = c + be32(d, c + 4);
    const layer_records = c + be32(d, c + 8);
    var lo: usize = 0;
    var hi: usize = n_base;
    const rec = while (lo < hi) {
        const mid = (lo + hi) / 2;
        const r = bases + 6 * mid;
        const id = be16(d, r);
        if (id == g) break r;
        if (id < g) lo = mid + 1 else hi = mid;
    } else return out[0..0];
    const first = be16(d, rec + 2);
    const n = @min(be16(d, rec + 4), out.len);
    const p = f.t.cpal;
    const entries = be16(d, p + 2);
    const colors = p + be32(d, p + 8);
    const palette0 = be16(d, p + 12);
    for (0..n) |i| {
        const lr = layer_records + 4 * (@as(usize, first) + i);
        const index = be16(d, lr + 2);
        out[i] = .{ .glyph = be16(d, lr), .bgra = if (index == 0xffff or index >= entries) null else blk: {
            const at = colors + 4 * (@as(usize, palette0) + index);
            if (at + 4 > d.len) break :blk null;
            const a: u16 = d[at + 3];
            break :blk .{ @intCast(d[at] * a / 255), @intCast(d[at + 1] * a / 255), @intCast(d[at + 2] * a / 255), d[at + 3] };
        } };
    }
    return out[0..n];
}

/// A color glyph drawn: its pixels and where its top left is from the
/// pen, in pixels (x right, y up).
pub const Drawn = struct {
    bgra: []u8,
    w: u32,
    h: u32,
    left: f32,
    top: f32,
};

/// Glyph `g` drawn `px` pixels an em, or null when it has no colors.
pub fn draw(gpa: std.mem.Allocator, f: *const font.Font, g: u16, px: f32) ?Drawn {
    if (picture(f, g, px)) |p| return drawPicture(gpa, p, px);
    var buf: [64]Layer = undefined;
    const ls = layers(f, g, &buf);
    if (ls.len > 0) return drawLayers(gpa, f, ls, px);
    return null;
}

const pad: u32 = 1;
/// The longest side a color glyph is drawn at, in pixels.
const max_side: u32 = 512;

fn drawPicture(gpa: std.mem.Allocator, p: Picture, px: f32) ?Drawn {
    const src = png_decode.decode(gpa, p.png) catch return null;
    defer src.deinit(gpa);
    const k = px / p.ppem;
    const w: u32 = @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(src.width)) * k)));
    const h: u32 = @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(src.height)) * k)));
    if (w > max_side or h > max_side) return null;
    const out = gpa.alloc(u8, @as(usize, w) * h * 4) catch return null;
    resample(src.bgra, src.width, src.height, out, w, h);
    return .{ .bgra = out, .w = w, .h = h, .left = p.left * k, .top = p.top * k };
}

/// Premultiplied pixels scaled to `w` × `h`: each pixel the average of the
/// source area it covers (smaller), or bilinear between (larger).
pub fn resample(src: []const u8, sw: u32, sh: u32, out: []u8, w: u32, h: u32) void {
    const fx = @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(w));
    const fy = @as(f32, @floatFromInt(sh)) / @as(f32, @floatFromInt(h));
    for (0..h) |y| for (0..w) |x| {
        var acc = [4]f32{ 0, 0, 0, 0 };
        var weight: f32 = 0;
        const x0 = @as(f32, @floatFromInt(x)) * fx;
        const y0 = @as(f32, @floatFromInt(y)) * fy;
        const x1 = x0 + @max(fx, 1);
        const y1 = y0 + @max(fy, 1);
        var sy: u32 = @intFromFloat(@floor(y0));
        while (sy < sh and @as(f32, @floatFromInt(sy)) < y1) : (sy += 1) {
            const wy = @min(y1, @as(f32, @floatFromInt(sy + 1))) - @max(y0, @as(f32, @floatFromInt(sy)));
            var sx: u32 = @intFromFloat(@floor(x0));
            while (sx < sw and @as(f32, @floatFromInt(sx)) < x1) : (sx += 1) {
                const wx = @min(x1, @as(f32, @floatFromInt(sx + 1))) - @max(x0, @as(f32, @floatFromInt(sx)));
                const wgt = wx * wy;
                if (wgt <= 0) continue;
                const s = src[(@as(usize, sy) * sw + sx) * 4 ..][0..4];
                inline for (0..4) |ch| acc[ch] += @as(f32, @floatFromInt(s[ch])) * wgt;
                weight += wgt;
            }
        }
        const o = out[(y * w + x) * 4 ..][0..4];
        inline for (0..4) |ch| o[ch] = if (weight > 0) @intFromFloat(@min(255, @round(acc[ch] / weight))) else 0;
    };
}

fn drawLayers(gpa: std.mem.Allocator, f: *const font.Font, ls: []const Layer, px: f32) ?Drawn {
    var b: [4]f32 = .{ std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
    for (ls) |l| if (f.bounds(l.glyph)) |lb| {
        b = .{ @min(b[0], lb[0]), @min(b[1], lb[1]), @max(b[2], lb[2]), @max(b[3], lb[3]) };
    };
    if (b[2] <= b[0] or b[3] <= b[1]) return null;
    const ps = px / f.units_per_em;
    const x0 = @floor(b[0] * ps);
    const x1 = @ceil(b[2] * ps);
    const top = @ceil(b[3] * ps);
    const bottom = @floor(b[1] * ps);
    const w: u32 = @as(u32, @intFromFloat(x1 - x0)) + 2 * pad;
    const h: u32 = @as(u32, @intFromFloat(top - bottom)) + 2 * pad;
    if (w > max_side or h > max_side) return null;
    const out = gpa.alloc(u8, @as(usize, w) * h * 4) catch return null;
    @memset(out, 0);
    const cov = gpa.alloc(u8, @as(usize, w) * h) catch {
        gpa.free(out);
        return null;
    };
    defer gpa.free(cov);
    const p: f32 = @floatFromInt(pad);
    for (ls) |l| {
        var r = tt_raster.Raster.init(gpa, w, h) catch continue;
        defer r.deinit(gpa);
        f.outline(l.glyph, .{ ps, 0, 0, -ps, -x0 + p, top + p }, r.sink());
        r.coverage(cov);
        // The text's own color isn't known here: such layers draw black.
        const c = l.bgra orelse [4]u8{ 0, 0, 0, 255 };
        for (cov, 0..) |a, i| {
            if (a == 0) continue;
            const o = out[i * 4 ..][0..4];
            inline for (0..4) |ch| {
                const s: u32 = @as(u32, c[ch]) * a / 255;
                const sa: u32 = @as(u32, c[3]) * a / 255;
                o[ch] = @intCast(s + @as(u32, o[ch]) * (255 - sa) / 255);
            }
        }
    }
    return .{ .bgra = out, .w = w, .h = h, .left = x0 - p, .top = top + p };
}

const testing = std.testing;

test "a strike: the smallest at least as large, else the largest" {
    try testing.expect(better(null, 20, 40));
    try testing.expect(better(20, 48, 40));
    try testing.expect(!better(48, 64, 40));
    try testing.expect(better(64, 48, 40));
    try testing.expect(better(20, 32, 400));
}

test "resampling keeps a flat color and halves exactly" {
    var src: [4 * 4 * 4]u8 = undefined;
    for (0..16) |i| src[i * 4 ..][0..4].* = .{ 10, 200, 30, 255 };
    var out: [2 * 2 * 4]u8 = undefined;
    resample(&src, 4, 4, &out, 2, 2);
    for (0..4) |i| try testing.expectEqualSlices(u8, &.{ 10, 200, 30, 255 }, out[i * 4 ..][0..4]);
    // A checker of opaque and clear averages to half.
    for (0..16) |i| src[i * 4 ..][0..4].* = if ((i % 4 + i / 4) % 2 == 0) .{ 255, 255, 255, 255 } else .{ 0, 0, 0, 0 };
    resample(&src, 4, 4, &out, 2, 2);
    try testing.expectEqual(@as(u8, 128), out[3]);
}

test "COLR layers come bottom first in their palette colors, the text's for 0xFFFF" {
    // Four bytes before the tables (an offset of 0 means none), COLR at 4
    // and CPAL at 32, as a font file would hold them.
    const bytes = [_]u8{ 0, 0, 0, 0 } ++
        // COLR v0: 1 base record at +14, 2 layer records at +20.
        [_]u8{ 0, 0, 0, 1, 0, 0, 0, 14, 0, 0, 0, 20, 0, 2 } ++
        [_]u8{ 0, 5, 0, 0, 0, 2 } ++ // glyph 5: layers 0 and 1
        [_]u8{ 0, 7, 0, 0, 0, 8, 0xff, 0xff } ++ // glyph 7 in color 0, glyph 8 in the text's
        // CPAL v0: 1 entry, 1 palette, 1 record at +14, palette 0 from 0.
        [_]u8{ 0, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 14, 0, 0 } ++
        [_]u8{ 0x20, 0x80, 0xf0, 0x80 }; // BGRA, half opaque
    var f: font.Font = undefined;
    f.data = &bytes;
    f.t = .{ .colr = 4, .cpal = 32 };
    var buf: [4]Layer = undefined;
    const ls = layers(&f, 5, &buf);
    try testing.expectEqual(@as(usize, 2), ls.len);
    try testing.expectEqual(@as(u16, 7), ls[0].glyph);
    // Premultiplied: each channel times 128/255.
    try testing.expectEqual([4]u8{ 0x10, 0x40, 0x78, 0x80 }, ls[0].bgra.?);
    try testing.expectEqual(@as(u16, 8), ls[1].glyph);
    try testing.expectEqual(@as(?[4]u8, null), ls[1].bgra);
    try testing.expectEqual(@as(usize, 0), layers(&f, 6, &buf).len);
}
