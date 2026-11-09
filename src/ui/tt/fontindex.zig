//! The installed-font index kept between processes. A cache is valid only for
//! the same nanoui version, scope, every scanned directory's mtime+size, and
//! every font file's mtime+size. Validation stats those paths but never walks
//! a directory or opens a font, so an in-place rewrite stale-proofs the index.
//! Missing optional directories are records too. Damage or a write failure
//! only loses the optimization: the caller scans with the same font matching.
const std = @import("std");
const font = @import("font.zig");

/// 3: a face's flags say whether it is variable.
pub const format_version: u32 = 3;
const nanoui_version = @import("build_options").version;
const magic = "NUFI";
const seed: u64 = 0x4e554649;
const max_cache_bytes: usize = 16 << 20;
const max_entries: usize = 1 << 16;
const max_directories: usize = 4096;
const max_path_bytes: usize = 4096;

pub const Directory = struct {
    path: []const u8,
    mtime: i128 = 0,
    size: u64 = 0,
    present: bool = true,
};

pub const Entry = struct {
    path: []u8,
    index: u32,
    style: font.Style,
    mtime: i128,
    size: u64,
};

pub const State = enum { off, hit, miss, stale, damaged, unreadable, written, write_failed };
pub const Stats = struct {
    state: State = .off,
    faces: usize = 0,
    directories: usize = 0,
    bytes: usize = 0,
};

pub const ReadError = error{ NotFound, Damaged, Stale, Unreadable, OutOfMemory };

/// Reads and validates a whole index. Every directory and every font file
/// must still have its recorded mtime and size before any face is returned.
pub fn read(gpa: std.mem.Allocator, io: std.Io, cache_path: []const u8, scope: []const u8) ReadError![]Entry {
    const data = std.Io.Dir.cwd().readFileAlloc(io, cache_path, gpa, .limited(max_cache_bytes)) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        error.StreamTooLong => return error.Damaged,
        else => return error.Unreadable,
    };
    defer gpa.free(data);
    if (data.len < 8) return error.Damaged;
    const body = data[0 .. data.len - 8];
    if (std.hash.Wyhash.hash(seed, body) != std.mem.readInt(u64, data[data.len - 8 ..][0..8], .little)) return error.Damaged;
    var r: Reader = .{ .data = body };
    if (!std.mem.eql(u8, try r.take(4), magic)) return error.Damaged;
    if (try r.u32v() != format_version) return error.Stale;
    if (!std.mem.eql(u8, try r.take(try r.u8v()), nanoui_version)) return error.Stale;
    if (!std.mem.eql(u8, try r.take(try r.u16v()), scope)) return error.Stale;
    const dir_count = try r.u32v();
    const face_count = try r.u32v();
    if (dir_count > max_directories or face_count > max_entries) return error.Damaged;

    for (0..dir_count) |_| {
        const path = try r.take(try r.u16v());
        if (path.len == 0 or path.len > max_path_bytes) return error.Damaged;
        const flags = try r.u8v();
        if (flags & ~@as(u8, 1) != 0) return error.Damaged;
        const present = flags & 1 != 0;
        const mtime = try r.i128v();
        const size = try r.u64v();
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
            if (!present and err == error.FileNotFound) continue;
            if (present and err == error.FileNotFound) return error.Stale;
            return error.Unreadable;
        };
        if (!present or stat.kind != .directory) return error.Stale;
        if (stat.size != size or stat.mtime.nanoseconds != mtime) return error.Stale;
    }

    const entries = try gpa.alloc(Entry, face_count);
    var made: usize = 0;
    errdefer {
        for (entries[0..made]) |entry| gpa.free(entry.path);
        gpa.free(entries);
    }
    while (made < face_count) : (made += 1) {
        const path_len = try r.u16v();
        if (path_len == 0 or path_len > max_path_bytes) return error.Damaged;
        const path = try gpa.dupe(u8, try r.take(path_len));
        errdefer gpa.free(path);
        const index = try r.u32v();
        const family_len = try r.u8v();
        if (family_len > 64) return error.Damaged;
        var style: font.Style = .{};
        @memcpy(style.family[0..family_len], try r.take(family_len));
        style.family_len = family_len;
        style.weight = try r.u16v();
        const flags = try r.u8v();
        if (flags & ~@as(u8, 7) != 0) return error.Damaged;
        style.italic = flags & 1 != 0;
        style.mono = flags & 2 != 0;
        style.variable = flags & 4 != 0;
        const mtime = try r.i128v();
        const size = try r.u64v();
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
            if (err == error.FileNotFound) return error.Stale;
            return error.Unreadable;
        };
        if (stat.kind != .file or stat.size != size or stat.mtime.nanoseconds != mtime) return error.Stale;
        entries[made] = .{ .path = path, .index = index, .style = style, .mtime = mtime, .size = size };
    }
    if (r.at != body.len) return error.Damaged;
    return entries;
}

/// Atomically writes one complete index. The cache lives in the app's cache
/// directory, never in a font directory (which would invalidate its key).
pub fn write(gpa: std.mem.Allocator, io: std.Io, cache_path: []const u8, scope: []const u8, directories: anytype, faces: anytype) ?usize {
    if (scope.len > std.math.maxInt(u16) or nanoui_version.len > std.math.maxInt(u8)) return null;
    var body: usize = 4 + 4 + 1 + nanoui_version.len + 2 + scope.len + 4 + 4;
    for (directories) |dir| {
        if (dir.path.len == 0 or dir.path.len > max_path_bytes) return null;
        if (!grow(&body, 2 + dir.path.len + 1 + 16 + 8)) return null;
    }
    for (faces) |face| {
        if (face.path.len == 0 or face.path.len > max_path_bytes or face.style.family_len > 64) return null;
        if (!grow(&body, 2 + face.path.len + 4 + 1 + face.style.family_len + 2 + 1 + 16 + 8)) return null;
    }
    if (directories.len > max_directories or faces.len > max_entries or body + 8 > max_cache_bytes) return null;
    const data = gpa.alloc(u8, body + 8) catch return null;
    defer gpa.free(data);
    var c: Cursor = .{ .data = data };
    c.bytes(magic);
    c.u32v(format_version);
    c.u8v(@intCast(nanoui_version.len));
    c.bytes(nanoui_version);
    c.u16v(@intCast(scope.len));
    c.bytes(scope);
    c.u32v(@intCast(directories.len));
    c.u32v(@intCast(faces.len));
    for (directories) |dir| {
        c.u16v(@intCast(dir.path.len));
        c.bytes(dir.path);
        c.u8v(@intFromBool(dir.present));
        c.i128v(dir.mtime);
        c.u64v(dir.size);
    }
    for (faces) |face| {
        c.u16v(@intCast(face.path.len));
        c.bytes(face.path);
        c.u32v(face.index);
        c.u8v(face.style.family_len);
        c.bytes(face.style.family[0..face.style.family_len]);
        c.u16v(face.style.weight);
        c.u8v(@as(u8, @intFromBool(face.style.italic)) | @as(u8, @intFromBool(face.style.mono)) << 1 | @as(u8, @intFromBool(face.style.variable)) << 2);
        c.i128v(face.mtime);
        c.u64v(face.size);
    }
    std.debug.assert(c.at == body);
    std.mem.writeInt(u64, data[body..][0..8], std.hash.Wyhash.hash(seed, data[0..body]), .little);
    writeAtomic(io, cache_path, data) catch return null;
    return data.len;
}

fn grow(body: *usize, bytes: usize) bool {
    if (bytes > max_cache_bytes -| body.*) return false;
    body.* += bytes;
    return true;
}

fn writeAtomic(io: std.Io, path: []const u8, data: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .make_path = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, data);
    try atomic.replace(io);
}

const Cursor = struct {
    data: []u8,
    at: usize = 0,
    fn bytes(c: *Cursor, value: []const u8) void {
        @memcpy(c.data[c.at..][0..value.len], value);
        c.at += value.len;
    }
    fn u8v(c: *Cursor, value: u8) void {
        c.data[c.at] = value;
        c.at += 1;
    }
    fn u16v(c: *Cursor, value: u16) void {
        std.mem.writeInt(u16, c.data[c.at..][0..2], value, .little);
        c.at += 2;
    }
    fn u32v(c: *Cursor, value: u32) void {
        std.mem.writeInt(u32, c.data[c.at..][0..4], value, .little);
        c.at += 4;
    }
    fn u64v(c: *Cursor, value: u64) void {
        std.mem.writeInt(u64, c.data[c.at..][0..8], value, .little);
        c.at += 8;
    }
    fn i128v(c: *Cursor, value: i128) void {
        std.mem.writeInt(i128, c.data[c.at..][0..16], value, .little);
        c.at += 16;
    }
};

const Reader = struct {
    data: []const u8,
    at: usize = 0,
    fn take(r: *Reader, len: usize) error{Damaged}![]const u8 {
        if (r.at > r.data.len or len > r.data.len - r.at) return error.Damaged;
        const value = r.data[r.at..][0..len];
        r.at += len;
        return value;
    }
    fn u8v(r: *Reader) error{Damaged}!u8 {
        return (try r.take(1))[0];
    }
    fn u16v(r: *Reader) error{Damaged}!u16 {
        return std.mem.readInt(u16, (try r.take(2))[0..2], .little);
    }
    fn u32v(r: *Reader) error{Damaged}!u32 {
        return std.mem.readInt(u32, (try r.take(4))[0..4], .little);
    }
    fn u64v(r: *Reader) error{Damaged}!u64 {
        return std.mem.readInt(u64, (try r.take(8))[0..8], .little);
    }
    fn i128v(r: *Reader) error{Damaged}!i128 {
        return std.mem.readInt(i128, (try r.take(16))[0..16], .little);
    }
};
