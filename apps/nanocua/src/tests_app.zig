//! The panel through the Tester (Stop and Resume, input, the log, the
//! command's Copy), the switches from outside, and the socket end to end over
//! a socket pair, with a
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

    // Asking for Screen Recording says what's left to do, which is the user's.
    if (comptime builtin.os.tag == .macos) {
        try std.testing.expect(!t.hasText(view.screen_hint));
        try t.clickText("Allow…");
        t.settle(0.2);
        try std.testing.expect(a.asked_screen);
        try std.testing.expect(t.hasText(view.screen_hint));
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
    try std.testing.expect(!a.hub.policy.allow_whole_screen);
    a.gate.request.?.at -= 1;
    t.frame();
    try t.clickText("Allow");
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

test "the switches stay as the user left them: calls and redraws don't flip them" {
    const gpa = std.testing.allocator;
    var rec: Recorder = .{};
    var a: App = undefined;
    a.init(gpa, .{ .ptr = &rec, .call = Recorder.call });
    defer a.deinit();
    a.dark = false;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 560, .height = 720, .theme = theme.ui(false) });
    defer t.deinit();
    const whole = "Allow whole screen: your pointer and keyboard, pictures of everything";

    // Turning input on leaves the whole screen off, whatever comes after.
    try t.clickText("Allow input: clicks, typing, keys, opening apps");
    t.settle(0.5);
    try std.testing.expect(a.hub.policy.allow_input);
    try std.testing.expect(!a.hub.policy.allow_whole_screen);
    call(&a, 1, "screenshot", "{\"whole_screen\":true}");
    t.settle(0.5);
    try std.testing.expect(!a.hub.policy.allow_whole_screen);

    // A click on the switch only asks: it may have been meant to focus the
    // window. Allow turns it on, and nobody's waiting to be told.
    try t.clickText(whole);
    t.settle(0.5);
    try std.testing.expect(!a.hub.policy.allow_whole_screen);
    try std.testing.expect(t.hasText("A request from this window"));
    a.gate.request.?.at -= 1;
    t.frame();
    try t.clickText("Allow");
    t.settle(0.5);
    try std.testing.expect(a.hub.policy.allow_whole_screen);
    try std.testing.expect(!t.hasText("A request from this window"));

    // Off takes one click; off stays off through calls, redraws and the pointer.
    try t.clickText(whole);
    t.settle(0.5);
    try std.testing.expect(!a.hub.policy.allow_whole_screen);
    try std.testing.expect(!t.hasText("Whole screen"));
    for (0..5) |i| {
        call(&a, @intCast(i + 2), "get_ui_tree", "{}");
        t.frame();
        t.moveTo(300, @floatFromInt(300 + i * 10));
        t.settle(0.2);
        try std.testing.expect(!a.hub.policy.allow_whole_screen);
        try std.testing.expect(a.hub.policy.allow_input);
    }
}

/// The hub's clock and what it sends, for the control tests.
const Wire = struct {
    gpa: std.mem.Allocator,
    sent: std.ArrayList(u8) = .empty,
    var now: f64 = 0;
    fn clock() f64 {
        return now;
    }
    fn send(ptr: *anyopaque, conn: u64, line: []const u8) void {
        const w: *Wire = @ptrCast(@alignCast(ptr));
        w.sent.print(w.gpa, "{d}:{s}\n", .{ conn, line }) catch {};
    }
    fn saw(w: *Wire, text: []const u8) bool {
        return std.mem.indexOf(u8, w.sent.items, text) != null;
    }
};

fn control(a: *App, id: u32, method: []const u8, params: []const u8) void {
    var buf: [256]u8 = undefined;
    a.hub.handle(9, std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"nanocua/{s}\",\"params\":{s}}}", .{ id, method, params }) catch unreachable);
}

fn notReal() bool {
    return false;
}

test "from outside: off at once, on only by a click in the window" {
    const gpa = std.testing.allocator;
    var rec: Recorder = .{};
    var wire: Wire = .{ .gpa = gpa };
    defer wire.sent.deinit(gpa);
    var a: App = undefined;
    a.init(gpa, .{ .ptr = &rec, .call = Recorder.call });
    defer a.deinit();
    a.dark = false;
    Wire.now = 100;
    a.hub.clock = Wire.clock;
    a.hub.sink = .{ .ptr = &wire, .send = Wire.send };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 560, .height = 720, .theme = theme.ui(false) });
    defer t.deinit();

    // Asking changes nothing, answers nothing yet, and shows the question.
    control(&a, 1, "ask", "{\"what\":\"input\",\"from\":\"graff\"}");
    try std.testing.expect(!a.hub.policy.allow_input);
    try std.testing.expectEqual(@as(usize, 0), wire.sent.items.len);
    t.settle(0.2);
    try std.testing.expect(t.hasText("A request from graff"));
    try std.testing.expect(t.hasText(@import("control.zig").Want.input.question()));

    // A click right away can't answer: it may have been meant for something else.
    try t.clickText("Allow");
    t.settle(0.2);
    try std.testing.expect(!a.hub.policy.allow_input);

    // The status says what's waiting; a second question has to wait its turn.
    control(&a, 2, "status", "{}");
    try std.testing.expect(wire.saw("9:{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{"));
    try std.testing.expect(wire.saw("\"pending\":\"input\""));
    control(&a, 3, "ask", "{\"what\":\"whole_screen\"}");
    try std.testing.expect(wire.saw("\"outcome\":\"busy\""));

    // A program's click, once it's armed, is ignored, and the panel says so.
    Wire.now += 1;
    a.real_pointer = notReal;
    t.frame();
    try t.clickText("Allow");
    t.settle(0.2);
    try std.testing.expect(!a.hub.policy.allow_input);
    try std.testing.expect(a.gate.request != null);
    try std.testing.expect(t.hasText(view.ignored_click));

    // So are the panel's own switches, on the way on...
    try t.clickText("Allow input: clicks, typing, keys, opening apps");
    t.settle(0.2);
    try std.testing.expect(!a.hub.policy.allow_input);

    // A person's click answers it, and whoever asked hears.
    a.real_pointer = null;
    wire.sent.clearRetainingCapacity();
    try t.clickText("Allow");
    t.settle(0.2);
    try std.testing.expect(a.hub.policy.allow_input);
    try std.testing.expect(a.gate.request == null);
    try std.testing.expect(wire.saw("9:{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{"));
    try std.testing.expect(wire.saw("\"outcome\":\"allowed\""));
    try std.testing.expect(!t.hasText("A request from graff"));

    // ...but a program can turn things off, here and from outside.
    a.real_pointer = notReal;
    try t.clickText("Allow input: clicks, typing, keys, opening apps");
    t.settle(0.2);
    try std.testing.expect(!a.hub.policy.allow_input);
    a.real_pointer = null;
    a.setInput(true);
    a.setWholeScreen(true);
    control(&a, 4, "off", "{\"what\":\"whole_screen\"}");
    try std.testing.expect(!a.hub.policy.allow_whole_screen and a.hub.policy.allow_input);
    control(&a, 5, "off", "{\"what\":\"input\"}");
    try std.testing.expect(!a.hub.policy.allow_input);
    wire.sent.clearRetainingCapacity();
    control(&a, 6, "off", "{\"what\":\"resume\"}");
    try std.testing.expect(wire.saw("-32602"));

    // Stop works from outside; Resume is a question like the rest.
    control(&a, 7, "stop", "{}");
    try std.testing.expect(a.hub.policy.stopped);
    control(&a, 8, "ask", "{\"what\":\"resume\",\"from\":\"Harness\"}");
    try std.testing.expect(a.hub.policy.stopped);
    t.settle(0.2);
    try std.testing.expect(t.hasText("A request from Harness"));

    // Deny: whoever asked hears, and asking again is refused for a while.
    wire.sent.clearRetainingCapacity();
    try t.clickText("Deny");
    t.settle(0.2);
    try std.testing.expect(a.hub.policy.stopped);
    try std.testing.expect(wire.saw("\"outcome\":\"denied\""));
    wire.sent.clearRetainingCapacity();
    control(&a, 10, "ask", "{\"what\":\"resume\"}");
    try std.testing.expect(wire.saw("\"outcome\":\"quiet\""));

    // Unanswered, it goes away and says so. Already on needs no question.
    Wire.now += 20;
    a.setStopped(false);
    wire.sent.clearRetainingCapacity();
    control(&a, 11, "ask", "{\"what\":\"resume\"}");
    try std.testing.expect(wire.saw("\"outcome\":\"already_on\""));
    control(&a, 12, "ask", "{\"what\":\"input\",\"from\":\"graff\"}");
    Wire.now += 61;
    wire.sent.clearRetainingCapacity();
    t.frame();
    t.settle(0.2);
    try std.testing.expect(a.gate.request == null);
    try std.testing.expect(!a.hub.policy.allow_input);
    try std.testing.expect(wire.saw("9:{\"jsonrpc\":\"2.0\",\"id\":12,\"result\":{"));
    try std.testing.expect(wire.saw("\"outcome\":\"expired\""));
}

test "an agent's own connection can't reach the switches through MCP" {
    // `nanocua mcp` has a hub of its own with no control behind it.
    const gpa = std.testing.allocator;
    var wire: Wire = .{ .gpa = gpa };
    defer wire.sent.deinit(gpa);
    var rec: Recorder = .{};
    var h: mcp.Hub = .{ .gpa = gpa, .clock = Wire.clock, .sink = .{ .ptr = &wire, .send = Wire.send }, .backend = .{ .ptr = &rec, .call = Recorder.call } };
    h.handle(1, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"nanocua/ask\",\"params\":{\"what\":\"input\"}}");
    try std.testing.expect(wire.saw("-32601"));
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
