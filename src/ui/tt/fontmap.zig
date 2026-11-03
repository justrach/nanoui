//! A font file's bytes, mapped read-only where the platform supports it.
//! The mapping is demand-paged; the heap fallback is the same whole-file read
//! the font database used before. Both own their storage until `freeBytes`.
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

/// Reads `path`, preferring a read-only mapping and falling back to the
/// original allocator-owned whole-file read when mapping is unavailable.
pub fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Bytes {
    if (mapFile(io, path)) |bytes| return bytes;
    return readHeap(io, gpa, path);
}

/// The fallback, also used by the byte-for-byte rendering regression test.
pub fn readHeap(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Bytes {
    return .{
        .data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20)),
        .heap = true,
    };
}

/// A read-only, non-populated mapping, or null when this file cannot be
/// mapped. `MemoryMap` may itself fall back to a buffered read; that is not
/// called a mapping here, and the caller uses its original fallback instead.
pub fn mapFile(io: std.Io, path: []const u8) ?Bytes {
    if (path.len == 0) return null;
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
        if (!bytes.mapped) return error.SkipZigTest;
        // The public slice is const, and Windows also proves the OS page
        // protection: a write faults instead of changing the file or a copy.
        if (builtin.os.tag == .windows) {
            var info: MemoryInformation = undefined;
            try std.testing.expect(VirtualQuery(bytes.data.ptr, &info, @sizeOf(MemoryInformation)) != 0);
            try std.testing.expectEqual(@as(u32, 0x1000), info.state); // MEM_COMMIT
            try std.testing.expectEqual(@as(u32, 0x02), info.protect & 0xff); // PAGE_READONLY
        }
    }
    try std.testing.expectEqual(@as(usize, 0), testLiveMappings());

    var heap = try readHeap(std.testing.io, gpa, path);
    defer freeBytes(std.testing.io, gpa, &heap);
    try std.testing.expect(!heap.mapped);
    try std.testing.expectEqualStrings(text, heap.data);
    try std.testing.expect(mapFile(std.testing.io, "no such font anywhere.ttf") == null);
}
