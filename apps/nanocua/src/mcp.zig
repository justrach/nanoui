//! MCP over newline-delimited JSON-RPC: initialize, ping, tools/list and
//! tools/call. The hub checks each call against the policy, logs it, and
//! hands it to the backend with a Reply, which the backend completes now
//! or later (a screenshot finishes on another queue), on the main thread.
//! Connections are numbers: a reply to one that closed is dropped.
const std = @import("std");
const tools = @import("tools.zig");
const policy = @import("policy.zig");

pub const protocol_version = "2025-06-18";
pub const version = "0.1.0";

/// Where replies go: the server's connection `conn`, one line each.
pub const Sink = struct {
    ptr: *anyopaque,
    send: *const fn (ptr: *anyopaque, conn: u64, line: []const u8) void,
};

/// What runs the tools. `call` copies what it needs from `args` before
/// returning; it completes `reply` exactly once, now or later.
pub const Backend = struct {
    ptr: *anyopaque,
    call: *const fn (ptr: *anyopaque, tool: tools.Tool, args: tools.Args, reply: *Reply) void,
    /// A connection went away: what it held can go too.
    closed: ?*const fn (ptr: *anyopaque, conn: u64) void = null,
};

/// The switches, for `nanocua/*` calls (control.zig). `id` lasts only the call.
pub const Control = struct {
    ptr: *anyopaque,
    func: *const fn (ptr: *anyopaque, conn: u64, id: []const u8, method: []const u8, params: ?std.json.Value) void,
};

pub const Content = union(enum) {
    text: []const u8,
    /// Base64 already.
    image: struct { data: []const u8, mime: []const u8 },
};

pub const Callback = struct {
    ptr: *anyopaque,
    func: *const fn (ptr: *anyopaque) void,
};

pub const Hub = struct {
    gpa: std.mem.Allocator,
    sink: Sink,
    backend: Backend,
    policy: policy.Policy = .{},
    log: policy.Log = .{},
    /// Seconds, for the log.
    clock: *const fn () f64,
    /// Something changed for the panel (a call came or finished).
    changed: ?Callback = null,
    /// Calls not yet answered.
    pending: usize = 0,
    /// Null where nothing can answer them (`nanocua mcp`'s own hub): agents
    /// reach the switches only by opening the socket themselves.
    control: ?Control = null,

    pub fn closed(h: *Hub, conn: u64) void {
        if (h.backend.closed) |f| f(h.backend.ptr, conn);
    }

    /// Handles one line from connection `conn`.
    pub fn handle(h: *Hub, conn: u64, line: []const u8) void {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) return;
        var arena: std.heap.ArenaAllocator = .init(h.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const msg = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch
            return h.sendError(conn, "null", -32700, "Parse error");
        if (msg != .object) return h.sendError(conn, "null", -32600, "Invalid request");
        const id_v = msg.object.get("id");
        const method_v = msg.object.get("method") orelse return; // a response: nothing asked
        if (method_v != .string) return h.sendError(conn, "null", -32600, "Invalid request");
        // Notifications (initialized, cancelled) need no answer.
        const id_val = id_v orelse return;
        const id = std.json.Stringify.valueAlloc(a, id_val, .{}) catch return;
        const method = method_v.string;
        const params = msg.object.get("params");
        if (std.mem.eql(u8, method, "initialize")) {
            h.sendResult(conn, id, initResult(a, params) catch return);
        } else if (std.mem.eql(u8, method, "ping")) {
            h.sendResult(conn, id, "{}");
        } else if (std.mem.eql(u8, method, "tools/list")) {
            var aw: std.Io.Writer.Allocating = .init(a);
            tools.writeList(&aw.writer) catch return;
            h.sendResult(conn, id, aw.written());
        } else if (std.mem.eql(u8, method, "tools/call")) {
            h.call(conn, id, params);
        } else if (std.mem.startsWith(u8, method, "nanocua/") and h.control != null) {
            h.control.?.func(h.control.?.ptr, conn, id, method, params);
        } else h.sendError(conn, id, -32601, "Method not found");
    }

    fn call(h: *Hub, conn: u64, id: []const u8, params: ?std.json.Value) void {
        const p = tools.Args.of(params);
        const name = p.string("name") orelse return h.sendError(conn, id, -32602, "tools/call needs a name");
        const tool = tools.Tool.parse(name) orelse return h.sendError(conn, id, -32602, "Unknown tool");
        const args_v: ?std.json.Value = if (p.obj) |o| o.get("arguments") else null;
        var sum_buf: [256]u8 = undefined;
        const sum = summarize(&sum_buf, args_v);
        const seq = h.log.add(tool, sum, h.clock());
        const reply = h.gpa.create(Reply) catch return;
        reply.* = .{ .hub = h, .conn = conn, .seq = seq, .id = h.gpa.dupe(u8, id) catch {
            h.gpa.destroy(reply);
            return;
        } };
        h.pending += 1;
        h.notify();
        const whole_screen = tools.Args.of(args_v).boolean("whole_screen") orelse false;
        if (h.policy.denial(tool, whole_screen)) |why| return reply.finish(&.{.{ .text = why }}, true, .denied);
        h.backend.call(h.backend.ptr, tool, tools.Args.of(args_v), reply);
    }

    fn notify(h: *Hub) void {
        if (h.changed) |c| c.func(c.ptr);
    }

    pub fn sendResult(h: *Hub, conn: u64, id: []const u8, result: []const u8) void {
        var aw: std.Io.Writer.Allocating = .init(h.gpa);
        defer aw.deinit();
        aw.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id, result }) catch return;
        h.sink.send(h.sink.ptr, conn, aw.written());
    }

    pub fn sendError(h: *Hub, conn: u64, id: []const u8, code: i32, message: []const u8) void {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ id, code, message }) catch return;
        h.sink.send(h.sink.ptr, conn, line);
    }
};

/// An unanswered tools/call; frees itself once finished.
pub const Reply = struct {
    hub: *Hub,
    conn: u64,
    id: []u8,
    seq: u64,

    pub fn text(r: *Reply, s: []const u8) void {
        r.finish(&.{.{ .text = s }}, false, .ok);
    }

    /// A failure the model should read (no permission, no such element).
    pub fn fail(r: *Reply, s: []const u8) void {
        r.finish(&.{.{ .text = s }}, true, .failed);
    }

    pub fn failf(r: *Reply, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        r.fail(std.fmt.bufPrint(&buf, fmt, args) catch fmt);
    }

    pub fn textf(r: *Reply, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        r.text(std.fmt.bufPrint(&buf, fmt, args) catch fmt);
    }

    pub fn finish(r: *Reply, content: []const Content, is_error: bool, status: policy.Status) void {
        const h = r.hub;
        defer {
            h.pending -= 1;
            h.gpa.free(r.id);
            h.gpa.destroy(r);
            h.notify();
        }
        var detail: []const u8 = "";
        for (content) |c| if (c == .text) {
            detail = c.text;
            break;
        } else {
            detail = "image";
        };
        h.log.finish(r.seq, status, detail, h.clock());
        var aw: std.Io.Writer.Allocating = .init(h.gpa);
        defer aw.deinit();
        writeResult(&aw.writer, r.id, content, is_error) catch return;
        h.sink.send(h.sink.ptr, r.conn, aw.written());
    }
};

/// One tools/call result as a JSON-RPC line, without a Reply.
pub fn writeResult(w: *std.Io.Writer, id: []const u8, content: []const Content, is_error: bool) !void {
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[", .{id});
    for (content, 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        switch (c) {
            .text => |t| {
                try w.writeAll("{\"type\":\"text\",\"text\":");
                try std.json.Stringify.encodeJsonString(t, .{}, w);
                try w.writeByte('}');
            },
            .image => |img| try w.print("{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"{s}\"}}", .{ img.data, img.mime }),
        }
    }
    try w.print("],\"isError\":{}}}}}", .{is_error});
}

fn initResult(a: std.mem.Allocator, params: ?std.json.Value) ![]const u8 {
    // Answer in the client's version when it asks for one we know.
    const known = [_][]const u8{ "2024-11-05", "2025-03-26", "2025-06-18" };
    var ver: []const u8 = protocol_version;
    if (tools.Args.of(params).string("protocolVersion")) |v| for (known) |k| {
        if (std.mem.eql(u8, v, k)) ver = k;
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    try aw.writer.print("{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{\"listChanged\":false}}}},\"serverInfo\":{{\"name\":\"nanocua\",\"version\":\"{s}\"}},\"instructions\":", .{ ver, version });
    try std.json.Stringify.encodeJsonString(instructions, .{}, &aw.writer);
    try aw.writer.writeByte('}');
    return aw.written();
}

pub const instructions =
    \\nanocua lets you use apps on this computer, within what its user allows in the nanocua window.
    \\Use it for another app's real UI; to show or test your own work, prefer the project's own commands.
    \\You work inside one app in the background: the user's pointer and keyboard stay theirs. Look first:
    \\get_ui_tree gives exact elements with refs and makes that app the one you act in; act on refs (click,
    \\type_text, set_value). Use screenshot when the tree is not enough. Coordinates are screen points from
    \\the top-left. If a call says nanocua is stopped, or input or the whole screen is off, tell the user
    \\once and carry on without it; do not retry in a loop, and permissions are the user's to give.
;

/// The arguments as one short line for the log.
fn summarize(buf: []u8, args: ?std.json.Value) []const u8 {
    const v = args orelse return "";
    var w: std.Io.Writer = .fixed(buf);
    std.json.Stringify.value(v, .{}, &w) catch {};
    const s = w.buffered();
    if (std.mem.eql(u8, s, "{}")) return "";
    return s;
}

const testing = std.testing;

/// Lines sent, for the tests.
const Lines = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,
    fn send(ptr: *anyopaque, conn: u64, line: []const u8) void {
        const l: *Lines = @ptrCast(@alignCast(ptr));
        l.list.print(l.gpa, "{d}:{s}\n", .{ conn, line }) catch {};
    }
};

/// Answers clicks at once and keeps screenshots waiting, as the real one.
const Fake = struct {
    held: ?*Reply = null,
    fn call(ptr: *anyopaque, tool: tools.Tool, args: tools.Args, reply: *Reply) void {
        const f: *Fake = @ptrCast(@alignCast(ptr));
        switch (tool) {
            .screenshot => f.held = reply,
            .click => if (args.point()) |p| reply.textf("clicked {d},{d}", .{ p[0], p[1] }) else reply.fail("no target"),
            else => reply.text("ok"),
        }
    }
};

fn zero() f64 {
    return 0;
}

test "a session: initialize, list, calls answered now and later, the policy" {
    var lines: Lines = .{ .gpa = testing.allocator };
    defer lines.list.deinit(testing.allocator);
    var fake: Fake = .{};
    var h: Hub = .{ .gpa = testing.allocator, .clock = zero, .sink = .{ .ptr = &lines, .send = Lines.send }, .backend = .{ .ptr = &fake, .call = Fake.call } };
    h.handle(1, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\"}}");
    h.handle(1, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    h.handle(1, "{\"jsonrpc\":\"2.0\",\"id\":\"two\",\"method\":\"tools/list\"}");
    try testing.expect(std.mem.indexOf(u8, lines.list.items, "\"protocolVersion\":\"2025-03-26\"") != null);
    try testing.expect(std.mem.indexOf(u8, lines.list.items, "1:{\"jsonrpc\":\"2.0\",\"id\":\"two\",\"result\":{\"tools\":[") != null);
    lines.list.clearRetainingCapacity();

    // Input is off: the click is refused, and logged as such.
    h.handle(2, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"click\",\"arguments\":{\"x\":5,\"y\":6}}}");
    try testing.expect(std.mem.indexOf(u8, lines.list.items, "\"isError\":true") != null);
    try testing.expectEqual(policy.Status.denied, h.log.newest(0).?.status);
    try testing.expectEqualStrings("{\"x\":5,\"y\":6}", h.log.newest(0).?.summary());
    h.policy.allow_input = true;
    lines.list.clearRetainingCapacity();
    h.handle(2, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"click\",\"arguments\":{\"x\":5,\"y\":6}}}");
    try testing.expectEqualStrings("2:{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"clicked 5,6\"}],\"isError\":false}}\n", lines.list.items);

    // A screenshot answers later; the hub counts it until then.
    lines.list.clearRetainingCapacity();
    h.handle(2, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\"}}");
    try testing.expectEqual(@as(usize, 1), h.pending);
    try testing.expectEqual(@as(usize, 0), lines.list.items.len);
    fake.held.?.finish(&.{ .{ .image = .{ .data = "QUJD", .mime = "image/jpeg" } }, .{ .text = "1:1" } }, false, .ok);
    try testing.expectEqual(@as(usize, 0), h.pending);
    try testing.expect(std.mem.indexOf(u8, lines.list.items, "{\"type\":\"image\",\"data\":\"QUJD\",\"mimeType\":\"image/jpeg\"}") != null);

    // Errors: bad JSON, unknown methods and tools.
    lines.list.clearRetainingCapacity();
    h.handle(3, "{nope");
    h.handle(3, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"resources/list\"}");
    h.handle(3, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"rm_rf\"}}");
    try testing.expect(std.mem.indexOf(u8, lines.list.items, "-32700") != null);
    try testing.expect(std.mem.indexOf(u8, lines.list.items, "-32601") != null);
    try testing.expect(std.mem.indexOf(u8, lines.list.items, "-32602") != null);

    // Stopped: even looking is refused.
    h.policy.stopped = true;
    lines.list.clearRetainingCapacity();
    h.handle(3, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"list_apps\"}}");
    try testing.expect(std.mem.indexOf(u8, lines.list.items, "stopped") != null);
}
