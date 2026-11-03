//! The TrueType reader and rasterizer on a real font file, where one is
//! installed (Arial on macOS, DejaVu Sans on Linux, Arial on Windows);
//! skipped elsewhere.
const std = @import("std");
const font = @import("font.zig");
const raster = @import("raster.zig");

const candidates = [_][]const u8{
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "C:\\Windows\\Fonts\\arial.ttf",
};

fn load(gpa: std.mem.Allocator) ?[]u8 {
    const io = std.testing.io;
    for (candidates) |p| {
        return std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(64 << 20)) catch continue;
    }
    return null;
}

test "a font's metrics, characters, advances, kerning and outlines" {
    const gpa = std.testing.allocator;
    const data = load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(data);
    const f = try font.Font.init(data, 0);
    try std.testing.expect(f.units_per_em >= 1000);
    try std.testing.expect(f.ascent > 0 and f.descent > 0);
    try std.testing.expect(f.style.weight == 400 and !f.style.italic);
    try std.testing.expect(f.style.name().len > 0);
    const a = f.glyphIndex('A');
    const v = f.glyphIndex('V');
    try std.testing.expect(a != 0 and v != 0);
    try std.testing.expect(f.glyphIndex(0x10FFFF) == 0);
    // "i" is narrower than "m"; "AV" kerns closer.
    try std.testing.expect(f.advance(f.glyphIndex('i')) < f.advance(f.glyphIndex('m')));
    try std.testing.expect(f.kerning(a, v) <= 0);

    // "o" at 40 pixels: ink in its ring, none in its hole.
    const o = f.glyphIndex('o');
    const b = f.bounds(o).?;
    const s = 40 / f.units_per_em;
    const w: usize = @intFromFloat(@ceil((b[2] - b[0]) * s) + 2);
    const h: usize = @intFromFloat(@ceil((b[3] - b[1]) * s) + 2);
    var r = try raster.Raster.init(gpa, w, h);
    defer r.deinit(gpa);
    f.outline(o, .{ s, 0, 0, -s, 1 - b[0] * s, 1 + b[3] * s }, r.sink());
    const px = try gpa.alloc(u8, w * h);
    defer gpa.free(px);
    r.coverage(px);
    try std.testing.expectEqual(@as(u8, 0), px[(h / 2) * w + w / 2]);
    var ink: usize = 0;
    for (px) |p| ink += @intFromBool(p > 128);
    try std.testing.expect(ink > w * h / 5);
    try std.testing.expect(px[(h / 2) * w + 2] > 128);
}

test "a font the app brings is found by its family, from its bytes" {
    const gpa = std.testing.allocator;
    const data = load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(data);
    var db = @import("fontdb.zig").Db.init(gpa, std.testing.io);
    defer db.deinit();
    // Only this font: no folders scanned.
    db.scanned = true;
    db.addMemory(data);
    const family = db.faces.items[0].style.name();
    const face = db.family(family, 400, false).?;
    const f = db.load(face).?;
    try std.testing.expect(f.glyphIndex('A') != 0);
    try std.testing.expect(db.family("No Such Family", 400, false) == null);
}
