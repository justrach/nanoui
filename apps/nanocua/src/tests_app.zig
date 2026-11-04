//! The panel through the Tester (Stop and Resume, input, the log, the
//! command's Copy) and the socket end to end over a socket pair, with a
//! backend that only records: nothing here touches the real screen.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const mcp = @import("mcp.zig");
const tools = @import("tools.zig");
const App = @import("app.zig").App;
const view = @import("view.zig");
const theme = @import("theme.zig");
const server = @import("server.zig");

const Recorder = struct {
    calls: usize = 0,
    fn call(ptr: *anyopaque, tool: tools.Tool, _: tools.Args, reply: *mcp.Reply) void {
        const r: *Recorder = @ptrCast(@alignCast(ptr));
        r.calls += 1;
        if (tool == .get_ui_tree) reply.text("app \"Notes\" pid 42\n[1] Window \"Notes\"") else reply.fail("No element [9]");
    }
};

fn call(a: *App, id: u32, name: []const u8, args: []const u8) void {
    var buf: [256]u8 = undefined;
    a.hub.handle(1, std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ id, name, args }) catch unreachable);
}

fn perms() @import("app.zig").Perms {
    return .{ .accessibility = true, .screen = false };
}

test "the panel: stop and resume, input, the log, copying the command" {
    const gpa = std.testing.allocator;
    var rec: Recorder = .{};
    var a: App = undefined;
    a.init(gpa, .{ .ptr = &rec, .call = Recorder.call });
    defer a.deinit();
    a.dark = false;
    a.read_perms = perms;
    a.setCommand("/Applications/nanocua.app/Contents/MacOS/nanocua");
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 560, .height = 720, .theme = theme.ui(false) });
    defer t.deinit();

    try std.testing.expect(t.hasText("Looking only"));
    try std.testing.expect(t.hasText("No agent connected"));
    try std.testing.expect(t.hasText("Nothing yet. Every call an agent makes shows here."));
    if (comptime builtin.os.tag == .macos) {
        try std.testing.expect(t.hasText("Allowed"));
        try std.testing.expect(t.hasText("Allow…"));
    }

    // Looking works; acting is refused until input is on.
    call(&a, 1, "get_ui_tree", "{\"app\":\"Notes\"}");
    call(&a, 2, "click", "{\"ref\":9}");
    t.settle(0.5);
    try std.testing.expectEqual(@as(usize, 1), rec.calls);
    try std.testing.expect(t.hasText("refused"));
    try std.testing.expect(t.hasText("done"));
    try std.testing.expect(t.hasText("2 calls, 1 refused"));
    try t.screenshot("/tmp/nanocua-panel.png");

    try t.clickText("Allow input: clicks, typing, keys, opening apps");
    t.settle(0.5);
    try std.testing.expect(a.hub.policy.allow_input);
    try std.testing.expect(t.hasText("Acting"));
    call(&a, 3, "click", "{\"ref\":9}");
    t.settle(0.5);
    try std.testing.expectEqual(@as(usize, 2), rec.calls);
    try std.testing.expect(t.hasText("failed"));
    try std.testing.expect(t.hasText("No element [9]"));

    // The whole screen has its own switch, off until the user turns it on.
    call(&a, 30, "screenshot", "{\"whole_screen\":true}");
    t.settle(0.5);
    try std.testing.expectEqual(@as(usize, 2), rec.calls);
    try t.clickText("Allow whole screen: your pointer and keyboard, pictures of everything");
    t.settle(0.5);
    try std.testing.expect(a.hub.policy.allow_whole_screen);
    try std.testing.expect(t.hasText("Whole screen"));
    call(&a, 31, "screenshot", "{\"whole_screen\":true}");
    t.settle(0.5);
    try std.testing.expectEqual(@as(usize, 3), rec.calls);

    // Stop refuses everything, even looking; Resume undoes it.
    try t.clickText("Stop");
    t.settle(0.5);
    try std.testing.expect(a.hub.policy.stopped);
    try std.testing.expect(t.hasText("Stopped"));
    call(&a, 4, "get_ui_tree", "{}");
    try std.testing.expectEqual(@as(usize, 3), rec.calls);
    try t.clickText("Resume");
    t.settle(0.5);
    try std.testing.expect(!a.hub.policy.stopped);

    try t.clickText("Copy");
    t.settle(0.2);
    try std.testing.expectEqualStrings("/Applications/nanocua.app/Contents/MacOS/nanocua mcp", t.clipboard.items);
    try std.testing.expect(t.hasText("Copied"));

    try t.clickText("Clear");
    t.settle(0.5);
    try std.testing.expect(t.hasText("Nothing yet. Every call an agent makes shows here."));
}

extern "c" fn socketpair(domain: c_int, kind: c_int, protocol: c_int, fds: *[2]c_int) c_int;
extern "c" fn close(fd: c_int) c_int;

test "the socket: a request in, its answer out, a closed agent dropped" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var rec: Recorder = .{};
    var a: App = undefined;
    a.init(gpa, .{ .ptr = &rec, .call = Recorder.call });
    defer a.deinit();
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), socketpair(1, 1, 0, &fds));
    _ = try a.server.adopt(fds[0]);
    try std.testing.expectEqual(@as(usize, 1), a.server.clients());
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get_ui_tree\"}}\n";
    try std.testing.expect(server.writeAll(fds[1], req));
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    var tries: usize = 0;
    while (std.mem.count(u8, got.items, "\n") < 2 and tries < 50) : (tries += 1) {
        nanoui.runFor(0.02);
        var buf: [4096]u8 = undefined;
        var fds_poll = [_]std.posix.pollfd{.{ .fd = fds[1], .events = std.posix.POLL.IN, .revents = 0 }};
        if ((std.posix.poll(&fds_poll, 0) catch 0) == 0) continue;
        const n = std.c.read(fds[1], &buf, buf.len);
        if (n > 0) try got.appendSlice(gpa, buf[0..@intCast(n)]);
    }
    try std.testing.expect(std.mem.startsWith(u8, got.items, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n"));
    try std.testing.expect(std.mem.indexOf(u8, got.items, "[1] Window \\\"Notes\\\"") != null);
    _ = close(fds[1]);
    tries = 0;
    while (a.server.clients() > 0 and tries < 50) : (tries += 1) nanoui.runFor(0.02);
    try std.testing.expectEqual(@as(usize, 0), a.server.clients());
}
