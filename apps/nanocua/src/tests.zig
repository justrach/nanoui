//! nanocua's tests: the tools' catalog, the policy and log, MCP sessions,
//! keys, the tree's text, the socket's framing and path, the panel through
//! the Tester, and the socket end to end. Nothing here moves the pointer,
//! types, or captures the screen; the macOS backend is compiled (every
//! declaration analyzed) but not run.
const std = @import("std");
const builtin = @import("builtin");

test {
    _ = @import("tools.zig");
    _ = @import("policy.zig");
    _ = @import("mcp.zig");
    _ = @import("keys.zig");
    _ = @import("tree.zig");
    _ = @import("target.zig");
    _ = @import("control.zig");
    _ = @import("server.zig");
    _ = @import("sockpath.zig");
    _ = @import("tests_app.zig");
    if (comptime @import("server.zig").supported) {
        _ = @import("proxy.zig");
        _ = @import("ctl.zig");
    }
    std.testing.refAllDecls(@import("server.zig").Server);
    std.testing.refAllDecls(@import("app.zig").App);
    std.testing.refAllDecls(@import("app.zig").Platform);
    if (builtin.os.tag == .macos) {
        _ = @import("mac/cf.zig");
        _ = @import("mac/windows.zig");
        _ = @import("mac/input.zig");
        _ = @import("mac/skylight.zig");
        _ = @import("mac/hit.zig");
        _ = @import("mac/pointer.zig");
        _ = @import("mac/backend.zig");
        inline for (.{ @import("mac/backend.zig"), @import("mac/ax.zig"), @import("mac/input.zig"), @import("mac/capture.zig"), @import("mac/apps.zig"), @import("mac/windows.zig"), @import("mac/hotkey.zig"), @import("proxy.zig") }) |m| std.testing.refAllDecls(m);
        std.testing.refAllDecls(@import("mac/backend.zig").Mac);
        std.testing.refAllDecls(@import("mac/hotkey.zig").HotKey);
    }
}
