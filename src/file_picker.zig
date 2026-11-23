//! Read a single user-selected file as bounded bytes. Paths stay at the host.
const std = @import("std");
const builtin = @import("builtin");

pub const Options = struct {
    /// File extensions without dots. Filters guide the picker only.
    extensions: []const []const u8 = &.{},
    max_bytes: usize = 16 * 1024 * 1024,
};

pub const File = struct {
    name: []const u8,
    bytes: []const u8,
};

pub const Owned = struct {
    file: File,

    pub fn deinit(self: Owned, allocator: std.mem.Allocator) void {
        allocator.free(self.file.name);
        allocator.free(self.file.bytes);
    }
};

pub const Failure = enum(u32) { io = 2, too_large = 3, out_of_memory = 4, busy = 5, unavailable = 6 };
pub const Result = union(enum) { picked: File, cancelled, failed: Failure };
pub const Callback = *const fn (?*anyopaque, Result) void;

pub fn validate(options: Options) error{InvalidFilter}!void {
    for (options.extensions) |extension| {
        if (extension.len == 0) return error.InvalidFilter;
        for (extension) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_')
                return error.InvalidFilter;
        }
    }
}

/// Native synchronous dialog. Call on the UI thread outside view building.
/// Free both the name and bytes with Owned.deinit. Null means cancellation.
pub fn open(allocator: std.mem.Allocator, io: std.Io, options: Options) !?Owned {
    if (comptime builtin.os.tag == .wasi or builtin.abi.isAndroid()) return error.Unsupported;
    try validate(options);
    const dialog = @import("nanoui.zig").dialog;
    const paths = (try dialog.open(allocator, .{ .extensions = options.extensions })) orelse return null;
    defer dialog.freePaths(allocator, paths);
    if (paths.len == 0) return null;
    return try readPath(allocator, io, paths[0], options.max_bytes);
}

fn readPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_bytes: usize) !Owned {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes +| 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.FileTooLarge,
        else => return err,
    };
    errdefer allocator.free(bytes);
    const name = try allocator.dupe(u8, std.fs.path.basename(path));
    return .{ .file = .{ .name = name, .bytes = bytes } };
}

/// Browser only. Bind the current semantic button to one request. The DOM
/// host opens the dialog during the browser gesture, before the next Zig frame.
pub const bind = if (builtin.os.tag == .wasi) @import("web/file_bridge.zig").bind else {};

test "file picker owns the basename and refuses an oversized read" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "chosen.txt", .data = "hello" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const path = try std.fs.path.join(a, &.{ buf[0..n], "chosen.txt" });
    defer a.free(path);
    try std.testing.expectError(error.FileTooLarge, readPath(a, io, path, 4));
    const chosen = try readPath(a, io, path, 5);
    defer chosen.deinit(a);
    try std.testing.expectEqualStrings("chosen.txt", chosen.file.name);
    try std.testing.expectEqualStrings("hello", chosen.file.bytes);
    try std.testing.expectError(error.InvalidFilter, validate(.{ .extensions = &.{"txt,image/*"} }));
}
