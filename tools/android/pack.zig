//! Puts an app's native libraries in its APK, for `apk.zig`: aapt2's APK
//! (the manifest, the resources) copied entry by entry, then each library
//! stored at `lib/<abi>/` uncompressed, its data aligned to 16 KiB so
//! Android maps it from the APK as it is (`extractNativeLibs="false"`, on
//! devices with 4 or 16 KiB pages); every other stored entry aligned to 4
//! bytes, as zipalign does. The result is for apksigner to sign.
//!
//!     pack OUT.apk IN.apk ABI LIB.so...
const std = @import("std");

const local_sig = 0x04034b50;
const central_sig = 0x02014b50;
const end_sig = 0x06054b50;
/// zipalign's extra field: the alignment, then padding.
const align_id = 0xd935;

const Entry = struct {
    name: []const u8,
    method: u16,
    flags: u16,
    time: u16,
    date: u16,
    crc: u32,
    size: u32,
    raw_size: u32,
    external: u32,
    /// The data as stored (compressed or not).
    data: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 5) {
        std.debug.print("usage: pack OUT.apk IN.apk ABI LIB.so...\n", .{});
        return error.Usage;
    }
    const cwd = std.Io.Dir.cwd();
    const in = try cwd.readFileAlloc(io, args[2], gpa, .limited(1 << 30));
    defer gpa.free(in);
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);
    try read(gpa, in, &entries);
    var libs: std.ArrayList([]u8) = .empty;
    defer {
        for (libs.items) |l| gpa.free(l);
        libs.deinit(gpa);
    }
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    for (args[4..]) |path| {
        const data = try cwd.readFileAlloc(io, path, gpa, .limited(1 << 30));
        try libs.append(gpa, data);
        const name = try std.fmt.allocPrint(gpa, "lib/{s}/{s}", .{ args[3], std.fs.path.basename(path) });
        try names.append(gpa, name);
        try entries.append(gpa, .{
            .name = name,
            .method = 0,
            .flags = 0,
            // 1 January 1980, as aapt2 dates its entries.
            .time = 0,
            .date = 0x21,
            .crc = std.hash.Crc32.hash(data),
            .size = @intCast(data.len),
            .raw_size = @intCast(data.len),
            // A regular file, rw-r--r-- (for unzip; Android reads no modes).
            .external = 0o100644 << 16,
            .data = data,
        });
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try write(gpa, &out, entries.items);
    try cwd.writeFile(io, .{ .sub_path = args[1], .data = out.items });
}

fn le16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn le32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// The entries of the zip `in`, by its central directory.
fn read(gpa: std.mem.Allocator, in: []const u8, entries: *std.ArrayList(Entry)) !void {
    if (in.len < 22) return error.NotAZip;
    var end = in.len - 22;
    while (le32(in, end) != end_sig) {
        if (end == 0 or in.len - end > 22 + 0xffff) return error.NotAZip;
        end -= 1;
    }
    const count = le16(in, end + 10);
    var at: usize = le32(in, end + 16);
    for (0..count) |_| {
        if (at + 46 > in.len or le32(in, at) != central_sig) return error.BadCentralDirectory;
        const name_len = le16(in, at + 28);
        const extra_len = le16(in, at + 30);
        const comment_len = le16(in, at + 32);
        const local = le32(in, at + 42);
        const raw_size = le32(in, at + 20);
        if (local + 30 > in.len or le32(in, local) != local_sig) return error.BadLocalHeader;
        const data_at = local + 30 + le16(in, local + 26) + le16(in, local + 28);
        if (data_at + raw_size > in.len) return error.BadLocalHeader;
        try entries.append(gpa, .{
            .name = in[at + 46 ..][0..name_len],
            .method = le16(in, at + 10),
            // Sizes go in the local header: no data descriptor follows.
            .flags = le16(in, at + 8) & ~@as(u16, 0x8),
            .time = le16(in, at + 12),
            .date = le16(in, at + 14),
            .crc = le32(in, at + 16),
            .size = le32(in, at + 24),
            .raw_size = raw_size,
            // Files of no mode (aapt2's) as regular ones, for unzip.
            .external = if (le32(in, at + 38) == 0) 0o100644 << 16 else le32(in, at + 38),
            .data = in[data_at..][0..raw_size],
        });
        at += 46 + name_len + extra_len + comment_len;
    }
}

fn put16(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u16) !void {
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
}

fn put32(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
}

/// What a stored entry's data aligns to: a library's to 16 KiB.
fn alignmentOf(e: Entry) usize {
    if (e.method != 0) return 1;
    return if (std.mem.endsWith(u8, e.name, ".so")) 16384 else 4;
}

fn write(gpa: std.mem.Allocator, out: *std.ArrayList(u8), entries: []const Entry) !void {
    var offsets = try gpa.alloc(u32, entries.len);
    defer gpa.free(offsets);
    for (entries, 0..) |e, i| {
        offsets[i] = @intCast(out.items.len);
        const a = alignmentOf(e);
        // Padding in an extra field of zipalign's, at least its header.
        var extra: usize = 0;
        if (a > 1) {
            const data_at = out.items.len + 30 + e.name.len;
            extra = 6;
            while ((data_at + extra) % a != 0) extra += 1;
        }
        try put32(out, gpa, local_sig);
        try put16(out, gpa, if (e.method == 0) 10 else 20);
        try put16(out, gpa, e.flags);
        try put16(out, gpa, e.method);
        try put16(out, gpa, e.time);
        try put16(out, gpa, e.date);
        try put32(out, gpa, e.crc);
        try put32(out, gpa, e.raw_size);
        try put32(out, gpa, e.size);
        try put16(out, gpa, @intCast(e.name.len));
        try put16(out, gpa, @intCast(extra));
        try out.appendSlice(gpa, e.name);
        if (extra > 0) {
            try put16(out, gpa, align_id);
            try put16(out, gpa, @intCast(extra - 4));
            try put16(out, gpa, @intCast(a));
            try out.appendNTimes(gpa, 0, extra - 6);
        }
        try out.appendSlice(gpa, e.data);
    }
    const central: u32 = @intCast(out.items.len);
    for (entries, offsets) |e, offset| {
        try put32(out, gpa, central_sig);
        try put16(out, gpa, 0x0314); // made by: version 2.0, Unix
        try put16(out, gpa, if (e.method == 0) 10 else 20);
        try put16(out, gpa, e.flags);
        try put16(out, gpa, e.method);
        try put16(out, gpa, e.time);
        try put16(out, gpa, e.date);
        try put32(out, gpa, e.crc);
        try put32(out, gpa, e.raw_size);
        try put32(out, gpa, e.size);
        try put16(out, gpa, @intCast(e.name.len));
        try put16(out, gpa, 0);
        try put16(out, gpa, 0);
        try put16(out, gpa, 0);
        try put16(out, gpa, 0);
        try put32(out, gpa, e.external);
        try put32(out, gpa, offset);
        try out.appendSlice(gpa, e.name);
    }
    const size: u32 = @intCast(out.items.len - central);
    try put32(out, gpa, end_sig);
    try put16(out, gpa, 0);
    try put16(out, gpa, 0);
    try put16(out, gpa, @intCast(entries.len));
    try put16(out, gpa, @intCast(entries.len));
    try put32(out, gpa, size);
    try put32(out, gpa, central);
    try put16(out, gpa, 0);
}

test "entries come back as written, stored data aligned" {
    const gpa = std.testing.allocator;
    const lib = "\x7fELF library";
    const entries = [_]Entry{
        .{ .name = "AndroidManifest.xml", .method = 8, .flags = 0, .time = 0, .date = 0x21, .crc = 1, .size = 9, .raw_size = 3, .external = 0, .data = "abc" },
        .{ .name = "resources.arsc", .method = 0, .flags = 0, .time = 0, .date = 0x21, .crc = std.hash.Crc32.hash("res"), .size = 3, .raw_size = 3, .external = 0, .data = "res" },
        .{ .name = "lib/arm64-v8a/libapp.so", .method = 0, .flags = 0, .time = 0, .date = 0x21, .crc = std.hash.Crc32.hash(lib), .size = lib.len, .raw_size = lib.len, .external = 0, .data = lib },
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try write(gpa, &out, &entries);
    var back: std.ArrayList(Entry) = .empty;
    defer back.deinit(gpa);
    try read(gpa, out.items, &back);
    try std.testing.expectEqual(entries.len, back.items.len);
    for (entries, back.items) |a, b| {
        try std.testing.expectEqualStrings(a.name, b.name);
        try std.testing.expectEqualStrings(a.data, b.data);
        try std.testing.expectEqual(a.crc, b.crc);
        const at = @intFromPtr(b.data.ptr) - @intFromPtr(out.items.ptr);
        try std.testing.expectEqual(0, at % alignmentOf(a));
    }
}
