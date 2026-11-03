//! The TrueType reader and rasterizer on a real font file, where one is
//! installed (Arial on macOS, DejaVu Sans on Linux, Arial on Windows);
//! skipped elsewhere.
const std = @import("std");
const font = @import("font.zig");
const fontdb = @import("fontdb.zig");
const fontmap = @import("fontmap.zig");
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
    var db = fontdb.Db.init(gpa, std.testing.io);
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

fn fontPath() ?[]const u8 {
    for (candidates) |path| {
        const file = std.Io.Dir.cwd().openFile(std.testing.io, path, .{}) catch continue;
        file.close(std.testing.io);
        return path;
    }
    return null;
}

fn glyphCoverage(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    const f = try font.Font.init(data, 0);
    const glyph = f.glyphIndex('A');
    const bounds = f.bounds(glyph).?;
    const scale = 40 / f.units_per_em;
    var r = try raster.Raster.init(gpa, 64, 64);
    defer r.deinit(gpa);
    f.outline(glyph, .{ scale, 0, 0, -scale, 2 - bounds[0] * scale, 50 + bounds[3] * scale }, r.sink());
    const pixels = try gpa.alloc(u8, 64 * 64);
    r.coverage(pixels);
    return pixels;
}

test "mapped and heap fonts render byte-identical coverage" {
    const gpa = std.testing.allocator;
    const path = fontPath() orelse return error.SkipZigTest;
    var mapped = try fontmap.readFile(std.testing.io, gpa, path);
    defer fontmap.freeBytes(std.testing.io, gpa, &mapped);
    var heap = try fontmap.readHeap(std.testing.io, gpa, path);
    defer fontmap.freeBytes(std.testing.io, gpa, &heap);
    try std.testing.expectEqualSlices(u8, heap.data, mapped.data);
    const a = try glyphCoverage(gpa, heap.data);
    defer gpa.free(a);
    const b = try glyphCoverage(gpa, mapped.data);
    defer gpa.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
    if (!mapped.mapped) return error.SkipZigTest;
}

test "font index hits without scanning and directory changes rebuild it" {
    const gpa = std.testing.allocator;
    const data = load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(data);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "fonts", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fonts/one.ttf", .data = data });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    const fonts_dir = try std.fs.path.join(gpa, &.{ root, "fonts" });
    defer gpa.free(fonts_dir);
    // Outside the indexed folder: the cache write must not change its key.
    const cache_path = try std.fs.path.join(gpa, &.{ root, "data", "fonts.idx" });
    defer gpa.free(cache_path);

    var faces: usize = 0;
    {
        var db = fontdb.Db.init(gpa, std.testing.io);
        defer db.deinit();
        db.fonts_dir = fonts_dir;
        db.cache_path = cache_path;
        db.scan();
        try std.testing.expectEqual(@import("fontindex.zig").State.written, db.cache.state);
        try std.testing.expect(db.scan_files > 0 and db.scan_directories > 0);
        faces = db.faces.items.len;
        try std.testing.expect(faces > 0);
    }
    {
        var db = fontdb.Db.init(gpa, std.testing.io);
        defer db.deinit();
        db.fonts_dir = fonts_dir;
        db.cache_path = cache_path;
        db.scan();
        try std.testing.expectEqual(@import("fontindex.zig").State.hit, db.cache.state);
        try std.testing.expectEqual(@as(usize, 0), db.scan_files);
        try std.testing.expectEqual(@as(usize, 0), db.scan_directories);
        try std.testing.expectEqual(faces, db.faces.items.len);
    }

    // A non-font file is enough: the key belongs to the directory, not to a
    // fresh enumeration of font files. Give coarse timestamp filesystems a tick.
    const before = try std.Io.Dir.cwd().statFile(std.testing.io, fonts_dir, .{});
    std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake) catch {};
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fonts/marker.txt", .data = "changed" });
    const after = try std.Io.Dir.cwd().statFile(std.testing.io, fonts_dir, .{});
    try std.testing.expect(before.size != after.size or before.mtime.nanoseconds != after.mtime.nanoseconds);
    {
        var db = fontdb.Db.init(gpa, std.testing.io);
        defer db.deinit();
        db.fonts_dir = fonts_dir;
        db.cache_path = cache_path;
        db.scan();
        try std.testing.expectEqual(@import("fontindex.zig").State.written, db.cache.state);
        try std.testing.expect(db.scan_files > 0);
        try std.testing.expectEqual(faces, db.faces.items.len);
    }

    // A damaged index is ignored and rewritten, never partially trusted.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = cache_path, .data = "not a font index" });
    {
        var db = fontdb.Db.init(gpa, std.testing.io);
        defer db.deinit();
        db.fonts_dir = fonts_dir;
        db.cache_path = cache_path;
        db.scan();
        try std.testing.expectEqual(@import("fontindex.zig").State.written, db.cache.state);
        try std.testing.expect(db.scan_files > 0);
        try std.testing.expectEqual(faces, db.faces.items.len);
    }
}
