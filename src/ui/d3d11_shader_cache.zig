//! Compiled D3D11 shader bytecode kept between runs: `D3DCompile` costs over
//! 100 ms for `quad_ps` and returns the same bytes every time. One file per
//! entry point under the app's cache folder (`shader-cache\{entry}.dxbc`),
//! rewritten whenever the shader source changes. Anything unusable is a miss,
//! never an error.
const std = @import("std");
const builtin = @import("builtin");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// 1: bytecode of `D3DCompile` with no flags, as `shaderFrom` asks for it.
const format_version: u32 = 1;
const magic = "NUDX";
/// `quad_ps`, the largest shader, is 18 KiB.
pub const max_bytes: usize = 64 * 1024;
/// magic, format version, and the hash of the source it was compiled from.
const header_len = 16;

pub const Key = struct {
    source: []const u8,
    entry: []const u8,
};

fn sourceHash(key: Key) u64 {
    return std.hash.Wyhash.hash(0x4e554458, key.source);
}

/// The bytecode of `key`'s shader as a previous run compiled it.
pub const Blob = struct {
    /// The whole file, header and all: on the page allocator.
    file: []u8,

    pub fn code(b: Blob) []const u8 {
        return b.file[header_len..];
    }

    pub fn deinit(b: Blob) void {
        std.heap.page_allocator.free(b.file);
    }
};

fn path(entry: []const u8, root: ?[]const u8, buf: *[512]u8) ?[]const u8 {
    const base = root orelse return null;
    return std.fmt.bufPrint(buf, "{s}\\shader-cache\\{s}.dxbc", .{ base, entry }) catch null;
}

/// `NANOUI_SHADER_CACHE=0` runs without the cache.
fn enabled() bool {
    const value = std.mem.span(getenv("NANOUI_SHADER_CACHE") orelse return true);
    return !std.mem.eql(u8, value, "0");
}

pub fn load(key: Key, root: ?[]const u8) ?Blob {
    // A test keeps no cache: it compiles, and reads nothing of the user's.
    if (builtin.is_test or !enabled()) return null;
    var path_buf: [512]u8 = undefined;
    const file = path(key.entry, root, &path_buf) orelse return null;
    return loadIn(key, std.Io.Dir.cwd(), std.Io.Threaded.global_single_threaded.io(), file);
}

fn loadIn(key: Key, dir: std.Io.Dir, io: std.Io, file: []const u8) ?Blob {
    const bytes = dir.readFileAlloc(io, file, std.heap.page_allocator, .limited(max_bytes + header_len)) catch return null;
    if (!valid(bytes, key)) {
        std.heap.page_allocator.free(bytes);
        return null;
    }
    return .{ .file = bytes };
}

/// Keeps `code` as `key`'s shader for the next run, replacing what was there.
pub fn store(key: Key, root: ?[]const u8, code: []const u8) void {
    if (builtin.is_test or !enabled()) return;
    var path_buf: [512]u8 = undefined;
    const file = path(key.entry, root, &path_buf) orelse return;
    storeIn(key, std.Io.Dir.cwd(), std.Io.Threaded.global_single_threaded.io(), file, code);
}

fn storeIn(key: Key, dir: std.Io.Dir, io: std.Io, file: []const u8, code: []const u8) void {
    if (code.len < 32 or code.len > max_bytes) return;
    dir.createDirPath(io, std.fs.path.dirname(file) orelse return) catch return;
    const bytes = std.heap.page_allocator.alloc(u8, header_len + code.len) catch return;
    defer std.heap.page_allocator.free(bytes);
    @memcpy(bytes[0..4], magic);
    std.mem.writeInt(u32, bytes[4..8], format_version, .little);
    std.mem.writeInt(u64, bytes[8..16], sourceHash(key), .little);
    @memcpy(bytes[header_len..], code);
    dir.writeFile(io, .{ .sub_path = file, .data = bytes }) catch {};
}

/// Our header, for this source, and the device's own: a file from another
/// source version or a half-written one is a miss.
fn valid(bytes: []const u8, key: Key) bool {
    if (bytes.len < header_len + 32) return false;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return false;
    if (std.mem.readInt(u32, bytes[4..8], .little) != format_version) return false;
    if (std.mem.readInt(u64, bytes[8..16], .little) != sourceHash(key)) return false;
    const code = bytes[header_len..];
    if (!std.mem.eql(u8, code[0..4], "DXBC")) return false;
    return std.mem.readInt(u32, code[24..28], .little) == code.len;
}

test "shader cache: cold miss, warm hit, source invalidation and replacement in a temporary directory" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = "shader-cache/quad_ps.dxbc";
    const key: Key = .{ .source = "first shader", .entry = "quad_ps" };
    var code: [32]u8 = @splat(0);
    @memcpy(code[0..4], "DXBC");
    std.mem.writeInt(u32, code[24..28], code.len, .little);
    try testing.expect(loadIn(key, tmp.dir, testing.io, file) == null);
    storeIn(key, tmp.dir, testing.io, file, &code);
    const first = loadIn(key, tmp.dir, testing.io, file) orelse return error.CacheMiss;
    defer first.deinit();
    try testing.expectEqualSlices(u8, &code, first.code());
    const changed: Key = .{ .source = "changed shader", .entry = "quad_ps" };
    try testing.expect(loadIn(changed, tmp.dir, testing.io, file) == null);
    code[31] = 42;
    storeIn(changed, tmp.dir, testing.io, file, &code);
    const replaced = loadIn(changed, tmp.dir, testing.io, file) orelse return error.CacheMiss;
    defer replaced.deinit();
    try testing.expectEqualSlices(u8, &code, replaced.code());
    try testing.expect(loadIn(key, tmp.dir, testing.io, file) == null);
}

test "shader cache: corrupt and truncated cache files are misses" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const key: Key = .{ .source = "shader", .entry = "quad_ps" };
    const file = "shader-cache/quad_ps.dxbc";
    var code: [32]u8 = @splat(0);
    @memcpy(code[0..4], "DXBC");
    std.mem.writeInt(u32, code[24..28], code.len, .little);
    storeIn(key, tmp.dir, testing.io, file, &code);
    const original = loadIn(key, tmp.dir, testing.io, file) orelse return error.CacheMiss;
    defer original.deinit();
    for ([_]usize{ 0, 4, 8, header_len, header_len + 24 }) |at| {
        original.file[at] ^= 1;
        try tmp.dir.writeFile(testing.io, .{ .sub_path = file, .data = original.file });
        try testing.expect(loadIn(key, tmp.dir, testing.io, file) == null);
        original.file[at] ^= 1;
    }
    for ([_]usize{ 0, header_len - 1, original.file.len - 1 }) |len| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = file, .data = original.file[0..len] });
        try testing.expect(loadIn(key, tmp.dir, testing.io, file) == null);
    }
}
