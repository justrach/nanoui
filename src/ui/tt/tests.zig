//! The TrueType reader and rasterizer on a real font file, where one is
//! installed (Arial on macOS, DejaVu Sans on Linux, Arial on Windows);
//! skipped elsewhere.
const std = @import("std");
const builtin = @import("builtin");
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

test "font reads and heap fonts render byte-identical coverage" {
    const gpa = std.testing.allocator;
    const path = fontPath() orelse return error.SkipZigTest;
    var loaded = try fontmap.readFile(std.testing.io, gpa, path);
    defer fontmap.freeBytes(std.testing.io, gpa, &loaded);
    var heap = try fontmap.readFile(std.testing.io, gpa, path);
    defer fontmap.freeBytes(std.testing.io, gpa, &heap);
    try std.testing.expectEqualSlices(u8, heap.data, loaded.data);
    const a = try glyphCoverage(gpa, heap.data);
    defer gpa.free(a);
    const b = try glyphCoverage(gpa, loaded.data);
    defer gpa.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
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
    // Outside the indexed folder and below cache, never backed-up app data.
    const cache_dir = try std.fs.path.join(gpa, &.{ root, "cache" });
    defer gpa.free(cache_dir);
    const cache_path = try std.fs.path.join(gpa, &.{ cache_dir, "font-index-v2.bin" });
    defer gpa.free(cache_path);

    var faces: usize = 0;
    {
        var db = fontdb.Db.init(gpa, std.testing.io);
        defer db.deinit();
        db.fonts_dir = fonts_dir;
        db.enableCache(cache_dir);
        try std.testing.expectEqualStrings(cache_path, db.cache_path.?);
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

    // Rewriting the file in place leaves its directory's fingerprint alone.
    // The per-file size+mtime must nevertheless reject the warm index.
    const font_path = try std.fs.path.join(gpa, &.{ fonts_dir, "one.ttf" });
    defer gpa.free(font_path);
    const dir_before = try std.Io.Dir.cwd().statFile(std.testing.io, fonts_dir, .{});
    const file_before = try std.Io.Dir.cwd().statFile(std.testing.io, font_path, .{});
    std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake) catch {};
    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, font_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, &.{data[data.len - 1] ^ 1}, data.len - 1);
    }
    const dir_after = try std.Io.Dir.cwd().statFile(std.testing.io, fonts_dir, .{});
    const file_after = try std.Io.Dir.cwd().statFile(std.testing.io, font_path, .{});
    try std.testing.expectEqual(dir_before.size, dir_after.size);
    try std.testing.expectEqual(dir_before.mtime.nanoseconds, dir_after.mtime.nanoseconds);
    try std.testing.expectEqual(file_before.size, file_after.size);
    try std.testing.expect(file_before.mtime.nanoseconds != file_after.mtime.nanoseconds);
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

    // A face that fails after a cache hit drops the persistent entry's index;
    // the next process must scan rather than trusting that face again.
    {
        var db = fontdb.Db.init(gpa, std.testing.io);
        defer db.deinit();
        db.fonts_dir = fonts_dir;
        db.cache_path = cache_path;
        db.scan();
        try std.testing.expectEqual(@import("fontindex.zig").State.hit, db.cache.state);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fonts/one.ttf", .data = "broken" });
        try std.testing.expect(db.load(@intCast(db.disk_start)) == null);
        try std.testing.expectEqual(@import("fontindex.zig").State.stale, db.cache.state);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, cache_path, .{}));
    }
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fonts/one.ttf", .data = data });
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

test "an unsupported cmap does not invalidate other warm font faces" {
    const gpa = std.testing.allocator;
    const data = load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(data);
    const unsupported = try gpa.dupe(u8, data);
    defer gpa.free(unsupported);
    const tables = try font.Tables.read(unsupported, 0);
    const count = std.mem.readInt(u16, unsupported[tables.cmap + 2 ..][0..2], .big);
    try std.testing.expect(count > 0);
    for (0..count) |i| {
        const record = tables.cmap + 4 + 8 * i;
        const at = tables.cmap + std.mem.readInt(u32, unsupported[record + 4 ..][0..4], .big);
        std.mem.writeInt(u16, unsupported[at..][0..2], 0, .big);
    }
    try std.testing.expectError(error.Unsupported, font.Font.init(unsupported, 0));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "fonts", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fonts/valid.ttf", .data = data });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fonts/unsupported.ttf", .data = unsupported });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    const fonts_dir = try std.fs.path.join(gpa, &.{ root, "fonts" });
    defer gpa.free(fonts_dir);
    const cache_dir = try std.fs.path.join(gpa, &.{ root, "cache" });
    defer gpa.free(cache_dir);
    const cache_path = try std.fs.path.join(gpa, &.{ cache_dir, "font-index-v2.bin" });
    defer gpa.free(cache_path);

    for (0..3) |run| {
        var db = fontdb.Db.init(gpa, std.testing.io);
        defer db.deinit();
        db.fonts_dir = fonts_dir;
        db.cache_path = cache_path;
        db.scan();
        const expected: @import("fontindex.zig").State = if (run == 0) .written else .hit;
        try std.testing.expectEqual(expected, db.cache.state);
        try std.testing.expectEqual(@as(usize, if (run == 0) 2 else 0), db.scan_files);
        var valid: ?u32 = null;
        var bad: ?u32 = null;
        for (db.faces.items, 0..) |face, i| {
            if (std.mem.endsWith(u8, face.path, "valid.ttf")) valid = @intCast(i);
            if (std.mem.endsWith(u8, face.path, "unsupported.ttf")) bad = @intCast(i);
        }
        try std.testing.expect(db.load(valid.?).?.glyphIndex('A') != 0);
        try std.testing.expect(db.load(bad.?) == null);
        try std.testing.expectEqual(expected, db.cache.state);
        try std.Io.Dir.cwd().access(std.testing.io, cache_path, .{});
    }
}

test "Windows' per-user font folder is named from LOCALAPPDATA" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var buf: [1024]u8 = undefined;
    const dir = fontdb.userFontDir(&buf) orelse return error.SkipZigTest;
    try std.testing.expect(std.fs.path.isAbsolute(dir));
    try std.testing.expect(std.mem.endsWith(u8, dir, "\\Microsoft\\Windows\\Fonts"));
}

test "a font folder that isn't there leaves the font index written and then hit" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    // As a per-user font folder is until the user installs a font.
    const missing = try std.fs.path.join(gpa, &.{ root, "no-fonts-yet" });
    defer gpa.free(missing);
    const cache_path = try std.fs.path.join(gpa, &.{ root, "font-index-v2.bin" });
    defer gpa.free(cache_path);
    for ([_]@import("fontindex.zig").State{ .written, .hit }) |expected| {
        var db = fontdb.Db.init(gpa, std.testing.io);
        defer db.deinit();
        db.fonts_dir = missing;
        db.cache_path = cache_path;
        db.scan();
        try std.testing.expectEqual(expected, db.cache.state);
    }
}

test "a variable font is known as one" {
    const gpa = std.testing.allocator;
    // Windows 11's Cascadia Mono is variable; elsewhere none is known to be installed.
    const path = if (builtin.os.tag == .windows) "C:\\Windows\\Fonts\\CascadiaMono.ttf" else return error.SkipZigTest;
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(64 << 20)) catch return error.SkipZigTest;
    defer gpa.free(data);
    try std.testing.expect((try font.Font.init(data, 0)).style.variable);
    const plain = load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(plain);
    try std.testing.expect(!(try font.Font.init(plain, 0)).style.variable);
}

/// A monospaced face of `family` for the matching tests: a style, never loaded.
fn styled(db: *fontdb.Db, family: []const u8, weight: u16, variable: bool) !void {
    var style: font.Style = .{ .weight = weight, .mono = true, .variable = variable };
    @memcpy(style.family[0..family.len], family);
    style.family_len = @intCast(family.len);
    try db.faces.append(db.gpa, .{ .path = try db.gpa.dupe(u8, family), .index = 0, .style = style });
}

test "the default fonts take a family with faces of its own over a variable one" {
    const gpa = std.testing.allocator;
    var db = fontdb.Db.init(gpa, std.testing.io);
    defer db.deinit();
    db.scanned = true;
    try styled(&db, "Cascadia Mono", 400, true);
    // Alone, the variable family is the default.
    try std.testing.expectEqualStrings("Cascadia Mono", db.faces.items[db.match(null, 700, false, true).?].style.name());
    try styled(&db, "Consolas", 400, false);
    try styled(&db, "Consolas", 700, false);
    // With a family of real faces after it in the defaults, that one, for every weight.
    const bold = db.faces.items[db.match(null, 700, false, true).?];
    try std.testing.expectEqualStrings("Consolas", bold.style.name());
    try std.testing.expectEqual(@as(u16, 700), bold.style.weight);
    try std.testing.expectEqualStrings("Consolas", db.faces.items[db.match(null, 400, false, true).?].style.name());
    // Named by the app, the variable family is still the one it gets.
    try std.testing.expectEqualStrings("Cascadia Mono", db.faces.items[db.match("Cascadia Mono", 700, false, true).?].style.name());
}

test "a default family with faces of its own beside its variable font keeps them" {
    const gpa = std.testing.allocator;
    for ([_]bool{ true, false }) |static_regular| {
        var db = fontdb.Db.init(gpa, std.testing.io);
        defer db.deinit();
        db.scanned = true;
        // The system's variable Cascadia Mono found first, faces of its own a
        // user installed after it, and Consolas.
        try styled(&db, "Cascadia Mono", 400, true);
        if (static_regular) try styled(&db, "Cascadia Mono", 400, false);
        try styled(&db, "Cascadia Mono", 700, false);
        try styled(&db, "Consolas", 400, false);
        try styled(&db, "Consolas", 700, false);
        // One family for every weight; a real face over the variable one
        // where there is one, the variable one's own regular where not.
        for ([_]u16{ 400, 700 }) |weight| {
            const face = db.faces.items[db.match(null, weight, false, true).?];
            try std.testing.expectEqualStrings("Cascadia Mono", face.style.name());
            try std.testing.expectEqual(weight, face.style.weight);
            try std.testing.expectEqual(weight == 400 and !static_regular, face.style.variable);
        }
    }
}

test "the font index keeps whether a face is variable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const fontindex = @import("fontindex.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "face.ttf", .data = "only stat'ed" });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const face_path = try std.fs.path.join(gpa, &.{ root, "face.ttf" });
    defer gpa.free(face_path);
    const index_path = try std.fs.path.join(gpa, &.{ root, "index.bin" });
    defer gpa.free(index_path);
    const stat = try std.Io.Dir.cwd().statFile(io, face_path, .{});
    var style: font.Style = .{ .variable = true };
    @memcpy(style.family[0..5], "Fixed");
    style.family_len = 5;
    const faces = [_]fontdb.Face{.{ .path = face_path, .index = 0, .style = style, .mtime = stat.mtime.nanoseconds, .size = stat.size }};
    const directories = [_]fontindex.Directory{};
    _ = fontindex.write(gpa, io, index_path, "test", &directories, &faces) orelse return error.IndexNotWritten;
    const entries = try fontindex.read(gpa, io, index_path, "test");
    defer {
        for (entries) |entry| gpa.free(entry.path);
        gpa.free(entries);
    }
    try std.testing.expect(entries.len == 1 and entries[0].style.variable);
}

const CreateFileW = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn CreateFileW(
        path: [*:0]const u16,
        access: u32,
        share: u32,
        security: ?*anyopaque,
        creation: u32,
        attributes: u32,
        template: ?*anyopaque,
    ) callconv(.winapi) ?*anyopaque;
    pub extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) i32;
} else struct {};

fn dupeZ(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    const z = try allocator.alloc(u8, path.len + 1);
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    return z[0..path.len :0];
}

fn denyRead(path: []const u8) !?*anyopaque {
    switch (builtin.os.tag) {
        .windows => {
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, path);
            defer std.testing.allocator.free(wide);
            const handle = CreateFileW.CreateFileW(wide.ptr, 0x80000000, 0, null, 3, 0x80, null);
            if (handle == null) return error.SkipZigTest;
            if (std.Io.Dir.cwd().openFile(std.testing.io, path, .{})) |probe| {
                probe.close(std.testing.io);
                _ = CreateFileW.CloseHandle(handle.?);
                return error.SkipZigTest;
            } else |_| {}
            return handle;
        },
        .linux => {
            const z = try dupeZ(std.testing.allocator, path);
            defer std.testing.allocator.free(z);
            if (std.os.linux.chmod(z.ptr, 0) != 0) return error.SkipZigTest;
            if (std.Io.Dir.cwd().openFile(std.testing.io, path, .{})) |probe| {
                probe.close(std.testing.io);
                _ = std.os.linux.chmod(z.ptr, 0o644);
                return error.SkipZigTest;
            } else |_| {}
            return null;
        },
        else => return error.SkipZigTest,
    }
}

fn restoreRead(handle: ?*anyopaque, path: []const u8) void {
    switch (builtin.os.tag) {
        .windows => {
            if (handle) |h| _ = CreateFileW.CloseHandle(h);
        },
        .linux => {
            const z = dupeZ(std.testing.allocator, path) catch return;
            defer std.testing.allocator.free(z);
            _ = std.os.linux.chmod(z.ptr, 0o644);
        },
        else => {},
    }
}

test "an unreadable font during a cold scan does not stay missing after access is restored" {
    const gpa = std.testing.allocator;
    const data = load(gpa) orelse return error.SkipZigTest;
    defer gpa.free(data);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "fonts", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fonts/a.ttf", .data = data });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fonts/b.ttf", .data = data });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    const fonts_dir = try std.fs.path.join(gpa, &.{ root, "fonts" });
    defer gpa.free(fonts_dir);
    const cache_dir = try std.fs.path.join(gpa, &.{ root, "cache" });
    defer gpa.free(cache_dir);
    const cache_path = try std.fs.path.join(gpa, &.{ cache_dir, "font-index-v2.bin" });
    defer gpa.free(cache_path);
    const blocked = try std.fs.path.join(gpa, &.{ fonts_dir, "b.ttf" });
    defer gpa.free(blocked);

    const lock = try denyRead(blocked);
    {
        var db = fontdb.Db.init(gpa, std.testing.io);
        defer db.deinit();
        db.fonts_dir = fonts_dir;
        db.enableCache(cache_dir);
        db.scan();
        try std.testing.expect(db.cache_broken);
        try std.testing.expectEqual(@import("fontindex.zig").State.write_failed, db.cache.state);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, cache_path, .{}));
    }
    restoreRead(lock, blocked);
    {
        var db = fontdb.Db.init(gpa, std.testing.io);
        defer db.deinit();
        db.fonts_dir = fonts_dir;
        db.cache_path = cache_path;
        db.scan();
        try std.testing.expectEqual(@import("fontindex.zig").State.written, db.cache.state);
        try std.testing.expectEqual(@as(usize, 2), db.faces.items.len);
    }
}

test "a second scan preserves the disk face start and failed loads still invalidate" {
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
    const cache_dir = try std.fs.path.join(gpa, &.{ root, "cache" });
    defer gpa.free(cache_dir);
    const cache_path = try std.fs.path.join(gpa, &.{ cache_dir, "font-index-v2.bin" });
    defer gpa.free(cache_path);

    var db = fontdb.Db.init(gpa, std.testing.io);
    defer db.deinit();
    db.fonts_dir = fonts_dir;
    db.cache_path = cache_path;
    db.scan();
    const start = db.disk_start;
    try std.testing.expect(db.faces.items.len > start);
    db.scan();
    try std.testing.expectEqual(start, db.disk_start);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fonts/one.ttf", .data = "broken" });
    try std.testing.expect(db.load(@intCast(start)) == null);
    try std.testing.expectEqual(@import("fontindex.zig").State.stale, db.cache.state);
}
