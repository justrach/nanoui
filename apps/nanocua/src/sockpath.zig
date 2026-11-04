//! Where the app listens and `nanocua mcp` connects: a Unix socket only
//! this user can open, in nanocua's Application Support folder on macOS,
//! the user's runtime folder on Linux; NANOCUA_SOCKET overrides it. `nanocua
//! mcp` and `nanocua ctl` find it the same way, whoever starts them.
const std = @import("std");
const builtin = @import("builtin");

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn getuid() c_uint;

/// The user's real home, not $HOME: Harness runs graff with HOME set per account,
/// and every program on one Mac has to find the one app.
pub fn realHome() ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    const entry = std.c.getpwuid(getuid()) orelse return null;
    return std.mem.span(entry.dir orelse return null);
}

pub fn path(buf: []u8, env: *const std.process.Environ.Map, real_home: ?[]const u8) ![:0]const u8 {
    if (env.get("NANOCUA_SOCKET")) |p| return std.fmt.bufPrintSentinel(buf, "{s}", .{p}, 0);
    if (builtin.os.tag == .macos) {
        const home = real_home orelse env.get("HOME") orelse return error.NoHome;
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
    const p = try path(&buf, &env, null);
    if (builtin.os.tag == .macos)
        try std.testing.expectEqualStrings("/Users/ada/Library/Application Support/nanocua/mcp.sock", p)
    else
        try std.testing.expectEqualStrings("/run/user/501/nanocua.sock", p);
    try env.put("NANOCUA_SOCKET", "/tmp/x.sock");
    try std.testing.expectEqualStrings("/tmp/x.sock", try path(&buf, &env, null));
}

test "another $HOME doesn't move the socket" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var buf: [256]u8 = undefined;
    try env.put("HOME", "/Users/ada/.accounts/two");
    try std.testing.expectEqualStrings("/Users/ada/Library/Application Support/nanocua/mcp.sock", try path(&buf, &env, "/Users/ada"));
    try std.testing.expect(realHome() != null);
}
