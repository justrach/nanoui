//! Font collections whose later faces sit far into the file.
const std = @import("std");
const fontdb = @import("fontdb.zig");
const testfont = @import("testfont.zig");

fn be32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .big);
}

/// Copies a single-face font to `base` in `out`, moving its table offsets.
fn place(out: []u8, base: usize, face: []const u8) void {
    @memcpy(out[base..][0..face.len], face);
    const tables = std.mem.readInt(u16, face[4..6], .big);
    for (0..tables) |i| {
        const at = base + 12 + 16 * i + 8;
        std.mem.writeInt(u32, out[at..][0..4], be32(out, at) + @as(u32, @intCast(base)), .big);
    }
}

test "every face of a collection is found when its directory is far in" {
    const gpa = std.testing.allocator;
    const near = try testfont.build(gpa, .{ .family = "Collection Near" });
    defer gpa.free(near);
    const far = try testfont.build(gpa, .{ .family = "Collection Far", .ranges = &.{.{ 0x65e5, 0x65e5 }} });
    defer gpa.free(far);
    // The second face starts past fontdb's 64 KB first read.
    const far_at = 128 * 1024;
    const data = try gpa.alloc(u8, far_at + far.len);
    defer gpa.free(data);
    @memset(data, 0);
    @memcpy(data[0..4], "ttcf");
    std.mem.writeInt(u32, data[4..8], 0x00010000, .big);
    std.mem.writeInt(u32, data[8..12], 2, .big);
    std.mem.writeInt(u32, data[12..16], 20, .big);
    std.mem.writeInt(u32, data[16..20], far_at, .big);
    place(data, 20, near);
    place(data, far_at, far);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pair.ttc", .data = data });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &buf);
    const path = try std.fs.path.join(gpa, &.{ buf[0..len], "pair.ttc" });
    defer gpa.free(path);

    var db = fontdb.Db.init(gpa, std.testing.io);
    defer db.deinit();
    db.addFile(path);
    try std.testing.expectEqual(@as(usize, 2), db.faces.items.len);
    const face = db.family("Collection Far", 400, false) orelse return error.FarFaceMissing;
    const loaded = db.load(face) orelse return error.FarFaceUnreadable;
    try std.testing.expect(loaded.glyphIndex(0x65e5) != 0);
}
