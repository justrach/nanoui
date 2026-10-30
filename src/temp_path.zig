//! Where a test writes a file it does not keep.
//!
//! Tests used to spell `/tmp/...`, which is where a temporary file goes on Linux
//! and macOS and nowhere at all on Windows. Two attempts at a "portable" fix
//! were both wrong: `C:\Windows\Temp` needs administrator rights, and the
//! system's `%TEMP%` is refused by the test binary here even though the same
//! path writes fine from a normal program (something about the token the test
//! runner has). A path under the project's own `.zig-cache/tmp` has neither
//! problem — the project directory is writable by whoever runs the tests, which
//! is the only property that matters here.
//!
//! `std.testing.tmpDir` is the sanctioned way to get a scratch *directory*; this
//! is the same idea for a scratch *file*, with a name the test chooses, so a
//! test that wants `nanoui-kit.png` beside the others gets it.

const std = @import("std");
const builtin = @import("builtin");

/// A scratch path, `name` under the project's `.zig-cache/tmp`, written into a
/// buffer the caller owns for as long as it needs the path.
///
///     var buf: [256]u8 = undefined;
///     const path = try tempPath(&buf, "nanoui-kit.png");
///
/// The directory is made if it is not there. Callers are tests; nobody reads
/// these files afterwards, and `.zig-cache` is not committed.
pub fn tempPath(buf: []u8, name: []const u8) ![]const u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const parent = std.Io.Dir.cwd().createDirPathOpen(io, ".zig-cache/tmp", .{}) catch return error.NoTempDir;
    parent.close(io);
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ ".zig-cache/tmp", std.fs.path.sep_str, name });
}

test "a scratch path is under the project's cache, which is writable" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;
    const p = try tempPath(&buf, "x.png");
    try testing.expect(std.mem.startsWith(u8, p, ".zig-cache/tmp"));
    try testing.expect(std.mem.endsWith(u8, p, "x.png"));
    // The two directories that were tried first, and are not usable: one needs
    // administrator rights, the other is refused in this process.
    try testing.expect(std.mem.indexOf(u8, p, "Windows\\Temp") == null);
}

test "a scratch path can be written to and read back" {
    const testing = std.testing;
    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [256]u8 = undefined;
    const p = try tempPath(&buf, "nanoui-temp-path-test.txt");
    defer std.Io.Dir.cwd().deleteFile(io, p) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "ok" });
    var got: [8]u8 = undefined;
    const back = try std.Io.Dir.cwd().readFile(io, p, &got);
    try testing.expectEqualStrings("ok", back);
}
