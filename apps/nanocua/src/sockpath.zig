//! Where the app listens and `nanocua mcp` connects: a Unix socket only
//! this user can open, in nanocua's Application Support folder on macOS,
//! the user's runtime folder on Linux; NANOCUA_SOCKET overrides it.
const std = @import("std");
const builtin = @import("builtin");

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn getuid() c_uint;

pub fn path(buf: []u8, env: *const std.process.Environ.Map) ![:0]const u8 {
    if (env.get("NANOCUA_SOCKET")) |p| return std.fmt.bufPrintSentinel(buf, "{s}", .{p}, 0);
    if (builtin.os.tag == .macos) {
        const home = env.get("HOME") orelse return error.NoHome;
        return std.fmt.bufPrintSentinel(buf, "{s}/Library/Application Support/nanocua/mcp.sock", .{home}, 0);
    }
    if (env.get("XDG_RUNTIME_DIR")) |d| return std.fmt.bufPrintSentinel(buf, "{s}/nanocua.sock", .{d}, 0);
    if (builtin.os.tag == .windows) return error.Unsupported;
    return std.fmt.bufPrintSentinel(buf, "/tmp/nanocua-{d}.sock", .{getuid()}, 0);
}

/// Makes the socket's folder (readable by this user only) if it is missing.
pub fn makeDir(p: []const u8) void {
    const dir = std.fs.path.dirname(p) orelse return;
    var buf: [512]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{dir}, 0) catch return;
    _ = mkdir(z, 0o700);
}

test "the path: overridden, or the platform's" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var buf: [256]u8 = undefined;
    try env.put("HOME", "/Users/ada");
    try env.put("XDG_RUNTIME_DIR", "/run/user/501");
    const p = try path(&buf, &env);
    if (builtin.os.tag == .macos)
        try std.testing.expectEqualStrings("/Users/ada/Library/Application Support/nanocua/mcp.sock", p)
    else
        try std.testing.expectEqualStrings("/run/user/501/nanocua.sock", p);
    try env.put("NANOCUA_SOCKET", "/tmp/x.sock");
    try std.testing.expectEqualStrings("/tmp/x.sock", try path(&buf, &env));
}
