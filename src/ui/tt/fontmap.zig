//! A font file's bytes, mapped read-only only on Windows. Linux and Android
//! always take the heap copy: replacing a mapped font in place can otherwise
//! invalidate its pages and raise SIGBUS. Both own their storage until freed.
const std = @import("std");
const builtin = @import("builtin");

pub const Bytes = struct {
    data: []const u8,
    mapping: ?std.Io.File.MemoryMap = null,
    heap: bool = false,
    mapped: bool = false,
};

var test_live_mappings: usize = 0;

/// The live OS mappings, checked by the repeated open/close test.
pub fn testLiveMappings() usize {
    return if (builtin.is_test) test_live_mappings else 0;
}

/// Reads `path`, mapping only on Windows. Elsewhere the allocator-owned copy
/// stays valid when another process rewrites or replaces the font file.
pub fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Bytes {
    if (builtin.os.tag == .windows) if (mapFile(io, path)) |bytes| return bytes;
    return readHeap(io, gpa, path);
}

/// The fallback, also used by the byte-for-byte rendering regression test.
pub fn readHeap(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Bytes {
    return .{
        .data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20)),
        .heap = true,
    };
}

/// A Windows read-only, non-populated mapping, or null when unavailable.
/// `MemoryMap` may itself fall back to a buffered read; that is not called a
/// mapping here, and the caller uses its heap fallback instead. Other targets
/// never map: font replacement must not be able to invalidate live pages.
pub fn mapFile(io: std.Io, path: []const u8) ?Bytes {
    if (builtin.os.tag != .windows) return null;
    if (path.len == 0) return null;
    // Zig's Windows open shares read/write/delete: font uninstall/reinstall
    // does not wait for this mapping, whose old pages remain valid meanwhile.
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    const len = file.length(io) catch {
        file.close(io);
        return null;
    };
    if (len == 0 or len > 256 << 20) {
        file.close(io);
        return null;
    }
    var mapping = std.Io.File.MemoryMap.create(io, file, .{
        .len = @intCast(len),
        .protection = .{ .read = true, .write = false },
        .populate = false,
    }) catch {
        file.close(io);
        return null;
    };
    if (mapping.section == null) {
        mapping.destroy(io);
        file.close(io);
        return null;
    }
    if (builtin.is_test) test_live_mappings += 1;
    return .{ .data = mapping.memory, .mapping = mapping, .mapped = true };
}

/// Releases a mapping (and its file handle) or a heap copy. DirectWrite faces
/// are released before the font database reaches this, by TextSystem.deinit.
pub fn freeBytes(io: std.Io, gpa: std.mem.Allocator, bytes: *Bytes) void {
    if (bytes.mapping) |*mapping| {
        const file = mapping.file;
        mapping.destroy(io);
        file.close(io);
        if (builtin.is_test and bytes.mapped) {
            std.debug.assert(test_live_mappings > 0);
            test_live_mappings -= 1;
        }
    } else if (bytes.heap) gpa.free(@constCast(bytes.data));
    bytes.* = undefined;
}

const MemoryInformation = extern struct {
    base: ?*anyopaque,
    allocation_base: ?*anyopaque,
    allocation_protect: u32,
    partition: u16,
    region_size: usize,
    state: u32,
    protect: u32,
    kind: u32,
};
extern "kernel32" fn VirtualQuery(address: *const anyopaque, info: *MemoryInformation, len: usize) callconv(.winapi) usize;

test "font mappings are read-only, exact, and release twenty times" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = "read-only font mapping bytes";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plain.ttf", .data = text });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const path = try std.fs.path.join(gpa, &.{ root_buf[0..root_len], "plain.ttf" });
    defer gpa.free(path);

    for (0..20) |_| {
        var bytes = readFile(std.testing.io, gpa, path) catch return error.MappingFailed;
        defer freeBytes(std.testing.io, gpa, &bytes);
        try std.testing.expectEqualStrings(text, bytes.data);
        if (builtin.os.tag == .windows) {
            try std.testing.expect(bytes.mapped);
            // The public slice is const, and Windows also proves the OS page
            // protection: a write faults instead of changing the file or a copy.
            var info: MemoryInformation = undefined;
            try std.testing.expect(VirtualQuery(bytes.data.ptr, &info, @sizeOf(MemoryInformation)) != 0);
            try std.testing.expectEqual(@as(u32, 0x1000), info.state); // MEM_COMMIT
            try std.testing.expectEqual(@as(u32, 0x02), info.protect & 0xff); // PAGE_READONLY
        } else {
            try std.testing.expect(!bytes.mapped and bytes.heap);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), testLiveMappings());

    var heap = try readHeap(std.testing.io, gpa, path);
    defer freeBytes(std.testing.io, gpa, &heap);
    try std.testing.expect(!heap.mapped);
    try std.testing.expectEqualStrings(text, heap.data);
    try std.testing.expect(mapFile(std.testing.io, "no such font anywhere.ttf") == null);
}

test "heap fonts survive an in-place replacement on non-Windows targets" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
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
    try std.testing.expect(bytes.heap and !bytes.mapped);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "same.ttf", .data = "tiny" });
    // Heap ownership, rather than a file-backed page, is what prevents SIGBUS.
    try std.testing.expectEqualStrings("the original font bytes", bytes.data);
}

test "Windows can uninstall and replace a font while its mapping is live" {
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
    try std.testing.expect(old.mapped);

    // Zig opens files with read/write/delete sharing. Delete uses POSIX
    // semantics on supported Windows, so Settings can remove and reinstall
    // the same path without waiting for this app's mapping to close.
    try std.Io.Dir.cwd().deleteFile(std.testing.io, path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, path, .{}));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "same.ttf", .data = "new installed font" });
    try std.testing.expectEqualStrings("old installed font", old.data);
    var new = try readFile(std.testing.io, gpa, path);
    defer freeBytes(std.testing.io, gpa, &new);
    try std.testing.expectEqualStrings("new installed font", new.data);
}
