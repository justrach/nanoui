//! Where a call goes. By default into one app: the one it names, else the
//! one the agent last read, and never nanocua itself. The whole screen (the
//! real pointer and keyboard) only when the call asks and the user allows.
const std = @import("std");

pub const Ask = struct {
    /// The call passed whole_screen.
    whole_screen: bool = false,
    /// The user's switch, as it is when the call runs.
    allowed: bool = false,
    /// The app the call names, by pid or name, or the one its ref is in.
    pid: ?i32 = null,
    /// The app the agent last read or opened.
    last: ?i32 = null,
    self: i32,
};

pub const Route = union(enum) {
    whole_screen,
    app: i32,
    refused: []const u8,
};

pub fn route(a: Ask) Route {
    if (a.whole_screen) {
        if (!a.allowed) return .{ .refused = "The whole screen is off in nanocua: work inside one app (leave out whole_screen), or ask the user to turn it on." };
        return .whole_screen;
    }
    const pid = a.pid orelse a.last orelse return .{ .refused = "Which app? Pass app or pid, or read one first with get_ui_tree (see list_apps)." };
    if (pid == a.self) return .{ .refused = "That is nanocua itself: agents can't act on it." };
    return .{ .app = pid };
}

test "a call goes into the app it names, else the last one read" {
    try std.testing.expectEqual(Route{ .app = 7 }, route(.{ .pid = 7, .last = 9, .self = 1 }));
    try std.testing.expectEqual(Route{ .app = 9 }, route(.{ .last = 9, .self = 1 }));
    try std.testing.expect(route(.{ .self = 1 }) == .refused);
}

test "never nanocua, and the whole screen only when allowed" {
    try std.testing.expect(route(.{ .pid = 1, .self = 1 }) == .refused);
    try std.testing.expect(route(.{ .last = 1, .self = 1 }) == .refused);
    try std.testing.expect(route(.{ .whole_screen = true, .pid = 7, .self = 1 }) == .refused);
    try std.testing.expect(route(.{ .whole_screen = true, .allowed = true, .self = 1 }) == .whole_screen);
    // Allowed isn't asked for: agents stay in the app unless they say otherwise.
    try std.testing.expectEqual(Route{ .app = 7 }, route(.{ .allowed = true, .pid = 7, .self = 1 }));
}
