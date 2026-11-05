//! Web font files back to fonts: WOFF, WOFF2 with and without its transforms, a
//! real subset from Google Fonts, and what hostile copies of each do.
const std = @import("std");
const sfnt = @import("sfnt.zig");
const font = @import("font.zig");
const testfont = @import("testfont.zig");
const wrap = @import("testfont_wrap.zig");

/// Lato (SIL OFL, `third_party/licenses/Lato-OFL.txt`): the few glyphs of
/// "Hamburgefonstiv 12", as Google Fonts serves them.
const lato = @embedFile("data/lato-subset.woff2");

const NullSink = struct {
    points: u32 = 0,
    fn move(c: *anyopaque, _: f32, _: f32) void {
        bump(c);
    }
    fn line(c: *anyopaque, _: f32, _: f32) void {
        bump(c);
    }
    fn quad(c: *anyopaque, _: f32, _: f32, _: f32, _: f32) void {
        bump(c);
    }
    fn close(_: *anyopaque) void {}
    fn bump(c: *anyopaque) void {
        const s: *NullSink = @ptrCast(@alignCast(c));
        s.points += 1;
    }
    fn sink(s: *NullSink) font.Sink {
        return .{ .ctx = s, .move = move, .line = line, .quad = quad, .close = close };
    }
};

fn outlinePoints(f: *const font.Font, g: u16) u32 {
    var s: NullSink = .{};
    f.outline(g, .{ 1, 0, 0, 1, 0, 0 }, s.sink());
    return s.points;
}

/// Reads whatever came out as a font, as the text system would.
fn exercise(data: []const u8) void {
    const f = font.Font.init(data, 0) catch return;
    var i: u16 = 0;
    while (i < @min(f.num_glyphs, 64)) : (i += 1) {
        _ = f.advance(i);
        _ = f.bounds(i);
        _ = outlinePoints(&f, i);
        _ = f.kerning(i, i +% 1);
    }
    for ("Hamburgefonstiv 12") |c| _ = f.glyphIndex(c);
    _ = f.xHeight();
    _ = f.capHeight();
}

test "a real WOFF2 file decodes to the font it holds" {
    const gpa = std.testing.allocator;
    const data = try sfnt.decode(gpa, lato);
    defer gpa.free(data);
    try sfnt.validate(data);
    const f = try font.Font.init(data, 0);
    try std.testing.expectEqualStrings("Lato", f.style.name());
    // Letters it has, each with an outline and an advance; one it doesn't.
    for ("Hamburgefonstiv12") |c| {
        const g = f.glyphIndex(c);
        try std.testing.expect(g != 0);
        try std.testing.expect(outlinePoints(&f, g) > 3);
        try std.testing.expect(f.advance(g) > 0);
    }
    try std.testing.expectEqual(@as(u16, 0), f.glyphIndex('Q'));
}

test "a real WOFF2 file survives every changed byte and every truncation" {
    const gpa = std.testing.allocator;
    const buf = try gpa.dupe(u8, lato);
    defer gpa.free(buf);
    for (0..lato.len) |i| {
        for ([_]u8{ 0, 0xff, lato[i] ^ 0x41 }) |v| {
            buf[i] = v;
            if (sfnt.decode(gpa, buf)) |out| {
                exercise(out);
                gpa.free(out);
            } else |_| {}
        }
        buf[i] = lato[i];
        if (sfnt.decode(gpa, lato[0..i])) |out| {
            gpa.free(out);
        } else |_| {}
    }
}

fn sameFont(a: []const u8, b: []const u8) !void {
    const fa = try font.Font.init(a, 0);
    const fb = try font.Font.init(b, 0);
    try std.testing.expectEqual(fa.num_glyphs, fb.num_glyphs);
    try std.testing.expectEqual(fa.units_per_em, fb.units_per_em);
    try std.testing.expectEqualStrings(fa.style.name(), fb.style.name());
    var g: u16 = 0;
    while (g < fa.num_glyphs) : (g += 1) {
        try std.testing.expectEqual(fa.advance(g), fb.advance(g));
        try std.testing.expectEqual(fa.bounds(g), fb.bounds(g));
        try std.testing.expectEqual(outlinePoints(&fa, g), outlinePoints(&fb, g));
    }
    try std.testing.expectEqual(fa.glyphIndex('a'), fb.glyphIndex('a'));
}

test "WOFF decodes stored and zlib tables, and refuses bad ones" {
    const gpa = std.testing.allocator;
    const plain = try testfont.build(gpa, .{ .family = "Woff One", .ranges = &.{.{ 0x20, 0x30 }} });
    defer gpa.free(plain);
    const stored = try wrap.woff(gpa, plain, false);
    defer gpa.free(stored);
    const zipped = try wrap.woff(gpa, plain, true);
    defer gpa.free(zipped);
    try std.testing.expect(zipped.len != stored.len);
    for ([_][]const u8{ stored, zipped }) |file| {
        const out = try sfnt.decode(gpa, file);
        defer gpa.free(out);
        try sameFont(plain, out);
    }
    const buf = try gpa.dupe(u8, zipped);
    defer gpa.free(buf);
    for (0..zipped.len) |i| {
        for ([_]u8{ 0, 0xff, zipped[i] ^ 0x41 }) |v| {
            buf[i] = v;
            if (sfnt.decode(gpa, buf)) |out| {
                exercise(out);
                gpa.free(out);
            } else |_| {}
        }
        buf[i] = zipped[i];
        if (sfnt.decode(gpa, zipped[0..i])) |out| {
            gpa.free(out);
        } else |_| {}
    }
}

test "WOFF2 rebuilds glyf, loca and hmtx from their transforms" {
    const gpa = std.testing.allocator;
    const plain = try testfont.build(gpa, .{ .family = "Woff Two", .ranges = &.{.{ 0x20, 0x28 }}, .advance = 620 });
    defer gpa.free(plain);
    const untransformed = try wrap.woff2(gpa, plain, false);
    defer gpa.free(untransformed);
    const transformed = try wrap.woff2(gpa, plain, true);
    defer gpa.free(transformed);
    for ([_][]const u8{ untransformed, transformed }) |file| {
        const out = try sfnt.decode(gpa, file);
        defer gpa.free(out);
        try sameFont(plain, out);
        const f = try font.Font.init(out, 0);
        const b = f.bounds(f.glyphIndex('!')).?;
        try std.testing.expectEqual(@as(f32, 570), b[2]);
        try std.testing.expectEqual(@as(f32, 620), f.advance(f.glyphIndex('!')));
    }
    const buf = try gpa.dupe(u8, transformed);
    defer gpa.free(buf);
    for (0..transformed.len) |i| {
        for ([_]u8{ 0, 0xff, transformed[i] ^ 0x41 }) |v| {
            buf[i] = v;
            if (sfnt.decode(gpa, buf)) |out| {
                exercise(out);
                gpa.free(out);
            } else |_| {}
        }
        buf[i] = transformed[i];
        if (sfnt.decode(gpa, transformed[0..i])) |out| {
            gpa.free(out);
        } else |_| {}
    }
}

test "an OpenType font's CFF outlines read as TrueType's do, and survive any change" {
    const gpa = std.testing.allocator;
    const plain = try testfont.build(gpa, .{ .family = "Otf", .cff = true, .ranges = &.{.{ 0x20, 0x30 }}, .advance = 620 });
    defer gpa.free(plain);
    try sfnt.validate(plain);
    const f = try font.Font.init(plain, 0);
    const g = f.glyphIndex('!');
    try std.testing.expect(g != 0);
    try std.testing.expectEqual(@as(f32, 620), f.advance(g));
    const b = f.bounds(g).?;
    try std.testing.expectEqual(@as(f32, 50), b[0]);
    try std.testing.expectEqual(@as(f32, 570), b[2]);
    try std.testing.expectEqual(@as(f32, 700), b[3]);
    try std.testing.expectEqual(@as(u32, 4), outlinePoints(&f, g));
    const w2 = try wrap.woff2(gpa, plain, false);
    defer gpa.free(w2);
    const back = try sfnt.decode(gpa, w2);
    defer gpa.free(back);
    const f2 = try font.Font.init(back, 0);
    try std.testing.expectEqual(@as(u32, 4), outlinePoints(&f2, g));
    const buf = try gpa.dupe(u8, plain);
    defer gpa.free(buf);
    for (0..plain.len) |i| {
        for ([_]u8{ 0, 0xff, plain[i] ^ 0x41, 12, 10, 29 }) |v| {
            buf[i] = v;
            exercise(buf);
        }
        buf[i] = plain[i];
    }
}

test "what isn't a font says so" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NotAFont, sfnt.decode(gpa, "<!doctype html><title>404</title>"));
    try std.testing.expectError(error.NotAFont, sfnt.decode(gpa, ""));
    // A table past the end of the file.
    const plain = try testfont.build(gpa, .{});
    defer gpa.free(plain);
    const bad = try gpa.dupe(u8, plain);
    defer gpa.free(bad);
    std.mem.writeInt(u32, bad[12 + 8..][0..4], 0xfffffff0, .big);
    try std.testing.expectError(error.Corrupt, sfnt.validate(bad));
}

test "a glyph of a hostile font can't nest or repeat components without end" {
    const gpa = std.testing.allocator;
    const plain = try testfont.build(gpa, .{ .ranges = &.{.{ 0x20, 0x21 }} });
    defer gpa.free(plain);
    const data = try gpa.dupe(u8, plain);
    defer gpa.free(data);
    const f = try font.Font.init(data, 0);
    // Every glyph one composite whose component is itself, many times over.
    const at = f.t.glyf;
    std.mem.writeInt(i16, data[at..][0..2], -1, .big);
    var p: usize = at + 10;
    for (0..8) |_| {
        std.mem.writeInt(u16, data[p..][0..2], 0x0020, .big); // more follow, byte args
        std.mem.writeInt(u16, data[p + 2..][0..2], 0, .big);
        p += 6;
    }
    _ = outlinePoints(&f, 0);
}
