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
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, file, std.heap.page_allocator, .limited(max_bytes + header_len)) catch return null;
    if (!valid(bytes, key)) {
        std.heap.page_allocator.free(bytes);
        return null;
    }
    return .{ .file = bytes };
}

/// Keeps `code` as `key`'s shader for the next run, replacing what was there.
pub fn store(key: Key, root: ?[]const u8, code: []const u8) void {
    if (builtin.is_test or !enabled()) return;
    if (code.len < 32 or code.len > max_bytes) return;
    var path_buf: [512]u8 = undefined;
    const file = path(key.entry, root, &path_buf) orelse return;
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(file) orelse return) catch return;
    const bytes = std.heap.page_allocator.alloc(u8, header_len + code.len) catch return;
    defer std.heap.page_allocator.free(bytes);
    @memcpy(bytes[0..4], magic);
    std.mem.writeInt(u32, bytes[4..8], format_version, .little);
    std.mem.writeInt(u64, bytes[8..16], sourceHash(key), .little);
    @memcpy(bytes[header_len..], code);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = bytes }) catch {};
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
