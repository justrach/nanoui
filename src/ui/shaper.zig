//! A fast path for shaping printable ASCII: each character's glyph and
//! advance, and each pair's kerning, are learned once from CoreText and
//! cached, so laying out "1234" again with other digits costs lookups,
//! not a CoreText line. A pair CoreText turns into one glyph (a ligature),
//! or anything outside printable ASCII, falls back to CoreText; the test
//! below checks the fast path places glyphs exactly as CoreText does.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");

extern "c" fn CTLineGetGlyphRuns(line: cf.CTLineRef) *anyopaque;
extern "c" fn CFArrayGetCount(arr: *anyopaque) cf.CFIndex;
extern "c" fn CFArrayGetValueAtIndex(arr: *anyopaque, i: cf.CFIndex) *anyopaque;
extern "c" fn CTRunGetGlyphCount(run: *anyopaque) cf.CFIndex;
extern "c" fn CTRunGetGlyphs(run: *anyopaque, range: cf.CFRange, out: [*]u16) void;
extern "c" fn CTRunGetPositions(run: *anyopaque, range: cf.CFRange, out: [*]objc.CGPoint) void;
extern "c" fn CTRunGetAttributes(run: *anyopaque) *anyopaque;
extern "c" fn CFDictionaryGetValue(dict: *anyopaque, key: *const anyopaque) ?*anyopaque;

const first: u8 = 0x20;
const count = 0x7f - 0x20;

pub fn isSimpleAscii(s: []const u8) bool {
    for (s) |c| if (c < first or c >= 0x7f) return false;
    return true;
}
/// What CoreText makes of a short string: its glyphs and their x positions.
const Shaped = struct {
    n: usize = 0,
    /// The font CoreText drew with (a variant of the one asked for).
    font: ?*anyopaque = null,
    glyphs: [2]u16 = .{ 0, 0 },
    x: [2]f32 = .{ 0, 0 },
    width: f32 = 0,
};

fn shapeShort(font: cf.CTFontRef, s: []const u8) Shaped {
    const attr = cf.attributed(s, font);
    defer cf.CFRelease(attr);
    const line = cf.CTLineCreateWithAttributedString(attr).?;
    defer cf.CFRelease(line);
    var out: Shaped = .{ .width = @floatCast(cf.CTLineGetTypographicBounds(line, null, null, null)) };
    const runs = CTLineGetGlyphRuns(line);
    var r: cf.CFIndex = 0;
    while (r < CFArrayGetCount(runs)) : (r += 1) {
        const run = CFArrayGetValueAtIndex(runs, r);
        const n: usize = @intCast(CTRunGetGlyphCount(run));
        if (out.n + n > 2) {
            out.n = 3; // more than the pair: not simple
            return out;
        }
        out.font = CFDictionaryGetValue(CTRunGetAttributes(run), cf.kCTFontAttributeName);
        var g: [2]u16 = undefined;
        var p: [2]objc.CGPoint = undefined;
        CTRunGetGlyphs(run, .{ .location = 0, .length = 0 }, &g);
        CTRunGetPositions(run, .{ .location = 0, .length = 0 }, &p);
        for (0..n) |i| {
            out.glyphs[out.n] = g[i];
            out.x[out.n] = @floatCast(p[i].x);
            out.n += 1;
        }
    }
    return out;
}

const Pair = struct {
    /// The second glyph's x minus the first's advance.
    kern: f32,
    /// CoreText does not shape this pair as two glyphs.
    complex: bool,
};

/// The cached shaping of one font's printable ASCII.
pub const Table = struct {
    font: cf.CTFontRef,
    /// The font CoreText's runs of this text use; null until learned, and
    /// the fast path holds only while every character uses this one.
    run_font: ?*anyopaque = null,
    glyph: [count]u16 = @splat(0),
    advance: [count]f32 = @splat(0),
    known: [count]bool = @splat(false),
    pairs: std.AutoHashMapUnmanaged(u16, Pair) = .empty,

    pub fn deinit(t: *Table, gpa: std.mem.Allocator) void {
        t.pairs.deinit(gpa);
    }

    fn char(t: *Table, c: u8) ?usize {
        const i = c - first;
        if (!t.known[i]) {
            const s = shapeShort(t.font, &.{c});
            if (s.n != 1) return null;
            if (t.run_font == null) t.run_font = s.font;
            if (s.font != t.run_font) return null;
            t.glyph[i] = s.glyphs[0];
            t.advance[i] = s.width;
            t.known[i] = true;
        }
        return i;
    }

    fn pair(t: *Table, gpa: std.mem.Allocator, a: u8, b: u8) ?Pair {
        const key = @as(u16, a) << 8 | b;
        if (t.pairs.get(key)) |p| return p;
        const ia = t.char(a) orelse return null;
        _ = t.char(b) orelse return null;
        const s = shapeShort(t.font, &.{ a, b });
        const p: Pair = if (s.n == 2) .{ .kern = s.x[1] - t.advance[ia], .complex = false } else .{ .kern = 0, .complex = true };
        t.pairs.put(gpa, key, p) catch {};
        return p;
    }

    /// Lays out `s` as CoreText would, writing its glyphs and pen
    /// positions; null when `s` needs CoreText itself.
    pub fn layout(t: *Table, gpa: std.mem.Allocator, s: []const u8, glyphs: []u16, xs: []f32) ?f32 {
        var x: f32 = 0;
        for (s, 0..) |c, i| {
            if (c < first or c >= 0x7f) return null;
            const ci = t.char(c) orelse return null;
            if (i > 0) {
                const p = t.pair(gpa, s[i - 1], c) orelse return null;
                if (p.complex) return null;
                x += p.kern;
            }
            glyphs[i] = t.glyph[ci];
            xs[i] = x;
            x += t.advance[ci];
        }
        return x;
    }
};

test "the fast path places glyphs as CoreText does" {
    const gpa = std.testing.allocator;
    const nsfont = objc.msg(objc.Object, objc.class(objc.font_class), "systemFontOfSize:weight:", .{ @as(f64, 13), @as(f64, 0) });
    var t: Table = .{ .font = @ptrCast(nsfont) };
    defer t.deinit(gpa);
    const samples = [_][]const u8{ "1234", "9876", "Hello, World!", "AVATAR To Ty", "fi fl ffi", "Row 42 - a line", "(x) = [y]", "WAVE", "Typography" };
    var compared: usize = 0;
    defer std.testing.expect(compared >= samples.len - 1) catch @panic("the fast path declined too many samples");
    for (samples) |s| {
        var g: [64]u16 = undefined;
        var xs: [64]f32 = undefined;
        const w = t.layout(gpa, s, &g, &xs) orelse continue; // a ligature: CoreText's own
        compared += 1;
        const attr = cf.attributed(s, @ptrCast(nsfont));
        defer cf.CFRelease(attr);
        const line = cf.CTLineCreateWithAttributedString(attr).?;
        defer cf.CFRelease(line);
        const ref_w: f32 = @floatCast(cf.CTLineGetTypographicBounds(line, null, null, null));
        try std.testing.expectApproxEqAbs(ref_w, w, 0.01);
        const run = CFArrayGetValueAtIndex(CTLineGetGlyphRuns(line), 0);
        var rg: [64]u16 = undefined;
        var rp: [64]objc.CGPoint = undefined;
        CTRunGetGlyphs(run, .{ .location = 0, .length = 0 }, &rg);
        CTRunGetPositions(run, .{ .location = 0, .length = 0 }, &rp);
        for (0..s.len) |i| {
            try std.testing.expectEqual(rg[i], g[i]);
            try std.testing.expectApproxEqAbs(@as(f32, @floatCast(rp[i].x)), xs[i], 0.01);
        }
    }
}
