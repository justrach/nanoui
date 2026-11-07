//! A font file's owned heap bytes on every target. File-backed pages are not
//! immutable while a font is updated in place; on Windows a live mapping also
//! blocks truncation with ERROR_USER_MAPPED_FILE. A private copy avoids both.
const std = @import("std");
const builtin = @import("builtin");

pub const Bytes = struct {
    data: []const u8,
};

/// Reads `path` into storage owned until `freeBytes`.
pub fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Bytes {
    return .{
        .data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20)),
    };
}

pub fn freeBytes(io: std.Io, gpa: std.mem.Allocator, bytes: *Bytes) void {
    _ = io;
    gpa.free(@constCast(bytes.data));
    bytes.* = undefined;
}

test "font reads are exact and release twenty times" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = "read-only font mapping bytes";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plain.ttf", .data = text });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const path = try std.fs.path.join(gpa, &.{ root_buf[0..root_len], "plain.ttf" });
    defer gpa.free(path);

    // The testing allocator also proves that every iteration releases its copy.
    for (0..20) |_| {
        var bytes = try readFile(std.testing.io, gpa, path);
        defer freeBytes(std.testing.io, gpa, &bytes);
        try std.testing.expectEqualStrings(text, bytes.data);
    }
    var heap = try readFile(std.testing.io, gpa, path);
    defer freeBytes(std.testing.io, gpa, &heap);
    try std.testing.expectEqualStrings(text, heap.data);
    try std.testing.expectError(error.FileNotFound, readFile(std.testing.io, gpa, "no such font anywhere.ttf"));
}

test "heap fonts survive an in-place replacement" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "same.ttf", .data = "the original font bytes" });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const path = try std.fs.path.join(gpa, &.{ root_buf[0..root_len], "same.ttf" });
    defer gpa.free(path);
    var bytes = try readFile(std.testing.io, gpa, path);
    defer freeBytes(std.testing.io, gpa, &bytes);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "same.ttf", .data = "tiny" });
    try std.testing.expectEqualStrings("the original font bytes", bytes.data);
}

test "Windows can uninstall and replace a font while its bytes are live" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "same.ttf", .data = "old installed font" });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const path = try std.fs.path.join(gpa, &.{ root_buf[0..root_len], "same.ttf" });
    defer gpa.free(path);
    var old = try readFile(std.testing.io, gpa, path);
    defer freeBytes(std.testing.io, gpa, &old);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, path, .{}));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "same.ttf", .data = "new installed font" });
    try std.testing.expectEqualStrings("old installed font", old.data);
    var new = try readFile(std.testing.io, gpa, path);
    defer freeBytes(std.testing.io, gpa, &new);
    try std.testing.expectEqualStrings("new installed font", new.data);
}

test "font reads survive direct in-place replacement twenty times" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old_text = "old installed font";
    const new_text = "new installed font";
    try std.testing.expectEqual(old_text.len, new_text.len);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "same.ttf", .data = old_text });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const path = try std.fs.path.join(gpa, &.{ root_buf[0..root_len], "same.ttf" });
    defer gpa.free(path);

    for (0..20) |i| {
        const before = if (i % 2 == 0) old_text else new_text;
        const after = if (i % 2 == 0) new_text else old_text;
        var old = try readFile(std.testing.io, gpa, path);
        defer freeBytes(std.testing.io, gpa, &old);
        try std.testing.expectEqualStrings(before, old.data);

        // No unlink or rename: this is the same truncation a font update uses.
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = after });
        try std.testing.expectEqualStrings(before, old.data);
        var new = try readFile(std.testing.io, gpa, path);
        defer freeBytes(std.testing.io, gpa, &new);
        try std.testing.expectEqualStrings(after, new.data);
    }
}
