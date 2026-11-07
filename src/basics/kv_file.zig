//! `kv.standard()` where there are no NSUserDefaults (Linux, Windows): the
//! values in memory, kept in `<data dir>/kv.json` (one JSON object of
//! strings). The app's `App.create` attaches it; each change rewrites the
//! file, through a temporary one renamed over it, so a crash leaves the old
//! file or the new one, never half of one. Main thread only.
const std = @import("std");
const Memory = @import("kv.zig").Memory;

pub const File = struct {
    mem: Memory,
    io: std.Io,
    /// `<dir>/kv.json`, and the temporary file beside it.
    path: []u8,
    tmp: []u8,

    /// Reads `<dir>/kv.json` if it is there; a file that doesn't parse is
    /// left alone and the store starts empty (the next change replaces it).
    pub fn open(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !File {
        const path = try std.fs.path.join(gpa, &.{ dir, "kv.json" });
        errdefer gpa.free(path);
        const tmp = try std.fs.path.join(gpa, &.{ dir, ".kv.json.tmp" });
        errdefer gpa.free(tmp);
        var f: File = .{ .mem = .{ .gpa = gpa }, .io = io, .path = path, .tmp = tmp };
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20)) catch return f;
        defer gpa.free(bytes);
        f.load(bytes) catch |e| std.log.info("nanoui: {s} unread: {t}", .{ path, e });
        return f;
    }

    fn load(f: *File, bytes: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, f.mem.gpa, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.NotAnObject;
        var it = parsed.value.object.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .string) try f.mem.put(e.key_ptr.*, e.value_ptr.string);
    }

    pub fn deinit(f: *File) void {
        f.mem.deinit();
        f.mem.gpa.free(f.path);
        f.mem.gpa.free(f.tmp);
    }

    pub fn set(f: *File, key: []const u8, value: []const u8) !void {
        try f.mem.put(key, value);
        try f.save();
    }

    pub fn remove(f: *File, key: []const u8) void {
        if (!f.mem.map.contains(key)) return;
        f.mem.drop(key);
        f.save() catch |e| std.log.info("nanoui: {s} not written: {t}", .{ f.path, e });
    }

    /// The whole store, as JSON, over the old file.
    fn save(f: *File) !void {
        const gpa = f.mem.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_1 } };
        try s.beginObject();
        var it = f.mem.map.iterator();
        while (it.next()) |e| {
            try s.objectField(e.key_ptr.*);
            try s.write(e.value_ptr.*);
        }
        try s.endObject();
        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(f.io, .{ .sub_path = f.tmp, .data = out.written() });
        cwd.rename(f.tmp, cwd, f.path, f.io) catch |e| {
            cwd.deleteFile(f.io, f.tmp) catch {};
            return e;
        };
    }
};

test "a file store keeps values across opens, and ignores a broken file" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "/tmp/nanoui-test-kv-file";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    defer cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    {
        var f = try File.open(gpa, io, dir);
        defer f.deinit();
        try f.set("hotkey", "ctrl_space");
        try f.set("quote", "a \"b\"\n\tc");
        try f.set("gone", "x");
        f.remove("gone");
    }
    {
        var f = try File.open(gpa, io, dir);
        defer f.deinit();
        try std.testing.expectEqualStrings("ctrl_space", f.mem.map.get("hotkey").?);
        try std.testing.expectEqualStrings("a \"b\"\n\tc", f.mem.map.get("quote").?);
        try std.testing.expect(!f.mem.map.contains("gone"));
    }
    try cwd.writeFile(io, .{ .sub_path = dir ++ "/kv.json", .data = "{not json" });
    var f = try File.open(gpa, io, dir);
    defer f.deinit();
    try std.testing.expectEqual(@as(u32, 0), f.mem.map.count());
}
