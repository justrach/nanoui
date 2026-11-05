//! A font an app brings comes before an installed face of the same family.
//! There's no font to ship here, so the tests take a system font's file and
//! change one glyph's advance: only that copy measures so.
const std = @import("std");
const testing = std.testing;
const cf = @import("cf.zig");
const fonts = @import("fonts.zig");

extern "c" fn CTFontGetGlyphsForCharacters(font: cf.CTFontRef, chars: [*]const u16, glyphs: [*]u16, count: cf.CFIndex) bool;
extern "c" fn CTFontGetAdvancesForGlyphs(font: cf.CTFontRef, orientation: u32, glyphs: [*]const u16, advances: ?*anyopaque, count: cf.CFIndex) f64;
extern "c" fn CTFontGetUnitsPerEm(font: cf.CTFontRef) u32;

const path = "/System/Library/Fonts/Supplemental/Georgia.ttf";

fn readBE(comptime T: type, b: []const u8, at: usize) T {
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .big);
}

fn table(b: []const u8, tag: []const u8) usize {
    for (0..readBE(u16, b, 4)) |i| {
        const e = 12 + 16 * i;
        if (std.mem.eql(u8, b[e..][0..4], tag)) return readBE(u32, b, e + 8);
    }
    unreachable;
}

/// The advance of `ch` in points at `size`.
fn advance(f: cf.CTFontRef, ch: u16) f64 {
    var c = [_]u16{ch};
    var g = [_]u16{0};
    _ = CTFontGetGlyphsForCharacters(f, &c, &g, 1);
    return CTFontGetAdvancesForGlyphs(f, 0, &g, null, 1);
}

/// A copy of the file with every horizontal advance set to `units`.
fn patched(gpa: std.mem.Allocator, b: []const u8, units: u16) ![]u8 {
    const out = try gpa.dupe(u8, b);
    const n = readBE(u16, b, table(b, "hhea") + 34);
    const hmtx = table(b, "hmtx");
    for (0..n) |i| std.mem.writeInt(u16, out[hmtx + 4 * i ..][0..2], units, .big);
    return out;
}

test "a registered font wins over an installed face of its family" {
    const gpa = std.heap.c_allocator;
    const file = std.c.fopen(path, "rb") orelse return error.SkipZigTest;
    defer _ = std.c.fclose(file);
    const b = try gpa.alloc(u8, 2 * 1024 * 1024);
    const len = std.c.fread(b.ptr, 1, b.len, file);
    try testing.expect(len > 0 and len < b.len);

    const installed = fonts.create("Georgia", 100, .regular, false, false);
    defer cf.CFRelease(installed);
    const upem: f64 = @floatFromInt(CTFontGetUnitsPerEm(installed));
    const units: u16 = @intCast(@divTrunc(@as(u32, @intFromFloat(upem)) * 3, 2));
    try testing.expect(@abs(advance(installed, 'H') - 150) > 1);

    // Kept for the process, as a registered font's bytes must be.
    const copy = try patched(gpa, b[0..len], units);
    try testing.expect(fonts.registerData(copy));

    const f = fonts.create("Georgia", 100, .regular, false, false);
    defer cf.CFRelease(f);
    try testing.expectApproxEqAbs(@as(f64, 150), advance(f, 'H'), 0.01);
}

/// How wide CoreText sets `s`: features apply in shaping, not in the font's
/// character map.
fn shaped(f: cf.CTFontRef, s: []const u8) f64 {
    const attr = cf.attributed(s, f);
    defer cf.CFRelease(attr);
    const line = cf.CTLineCreateWithAttributedString(attr).?;
    defer cf.CFRelease(line);
    return cf.CTLineGetTypographicBounds(line, null, null, null);
}

test "tabular digits all take one width" {
    const sys = fonts.create(null, 40, .regular, false, false);
    defer cf.CFRelease(sys);
    // The system's own 1 is narrower than its 0 until asked otherwise.
    try testing.expect(shaped(sys, "111") < shaped(sys, "000") - 1);
    const even = fonts.tabular(@ptrCast(cf.CFRetain(sys)));
    defer cf.CFRelease(even);
    try testing.expectApproxEqAbs(shaped(even, "000"), shaped(even, "111"), 0.01);
    try testing.expectApproxEqAbs(shaped(even, "000"), shaped(even, "789"), 0.01);
}
