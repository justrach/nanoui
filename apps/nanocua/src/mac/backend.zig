//! The tools on macOS. Calls run one at a time on a serial queue of their
//! own, so a slow app's accessibility (or a screenshot) never holds the
//! panel; each answers on the main thread. Calls work inside one app in the
//! background (target.zig) unless they ask for the whole screen and the user
//! allows it. Acting re-checks both switches on the queue (Stop wins over calls
//! already waiting) and refuses to touch nanocua's own windows.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const mcp = @import("../mcp.zig");
const tools = @import("../tools.zig");
const keys = @import("../keys.zig");
const cf = @import("cf.zig");
const ax = @import("ax.zig");
const input = @import("input.zig");
const capture = @import("capture.zig");
const apps = @import("apps.zig");
const windows = @import("windows.zig");
const hit = @import("hit.zig");
const target = @import("../target.zig");

extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) objc.dispatch_queue_t;
extern "c" fn dispatch_async_f(queue: objc.dispatch_queue_t, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn getpid() c_int;
extern "c" fn usleep(us: c_uint) c_int;

const off_this_space = "That app's window isn't on the user's current Space, or is minimized, so macOS shows nanocua neither its picture nor its elements. Tell the user once; don't retry.";

/// What one agent is working on. Agents connect one socket each: refs from
/// one's tree mean nothing to another, and neither moves the other's target.
pub const Session = struct {
    refs: ax.Refs,
    /// The app it last read or opened.
    last: ?i32 = null,
};

pub const Sessions = struct {
    gpa: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(u64, *Session) = .empty,

    pub fn get(s: *Sessions, conn: u64) !*Session {
        const gop = try s.map.getOrPut(s.gpa, conn);
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = s.map.remove(conn);
        const session = try s.gpa.create(Session);
        session.* = .{ .refs = .{ .gpa = s.gpa } };
        gop.value_ptr.* = session;
        return session;
    }

    pub fn remove(s: *Sessions, conn: u64) void {
        const kv = s.map.fetchRemove(conn) orelse return;
        kv.value.refs.deinit();
        s.gpa.destroy(kv.value);
    }

    pub fn deinit(s: *Sessions) void {
        var it = s.map.valueIterator();
        while (it.next()) |v| {
            v.*.refs.deinit();
            s.gpa.destroy(v.*);
        }
        s.map.deinit(s.gpa);
    }
};

pub const Mac = struct {
    gpa: std.mem.Allocator,
    queue: objc.dispatch_queue_t,
    /// Each agent's refs and target: the queue's alone.
    sessions: Sessions,
    /// The kill switch as the queue sees it.
    stopped: std.atomic.Value(bool) = .init(false),
    /// The whole-screen switch as the queue sees it.
    whole_screen: std.atomic.Value(bool) = .init(false),
    self_pid: i32,

    pub fn init(gpa: std.mem.Allocator) Mac {
        ax.setTimeout(2.0);
        return .{ .gpa = gpa, .queue = dispatch_queue_create("nanocua.tools", null), .sessions = .{ .gpa = gpa }, .self_pid = getpid() };
    }

    pub fn backend(m: *Mac) mcp.Backend {
        return .{ .ptr = m, .call = call, .closed = closed };
    }

    fn call(ptr: *anyopaque, tool: tools.Tool, args: tools.Args, reply: *mcp.Reply) void {
        const m: *Mac = @ptrCast(@alignCast(ptr));
        const job = Job.create(m, tool, args, reply) catch return reply.fail("nanocua is out of memory");
        dispatch_async_f(m.queue, job, Job.run);
    }

    const Closed = struct {
        mac: *Mac,
        conn: u64,

        fn run(ctx: ?*anyopaque) callconv(.c) void {
            const c: *Closed = @ptrCast(@alignCast(ctx));
            c.mac.sessions.remove(c.conn);
            c.mac.gpa.destroy(c);
        }
    };

    /// After any calls of its still waiting on the queue.
    fn closed(ptr: *anyopaque, conn: u64) void {
        const m: *Mac = @ptrCast(@alignCast(ptr));
        const c = m.gpa.create(Closed) catch return;
        c.* = .{ .mac = m, .conn = conn };
        dispatch_async_f(m.queue, c, Closed.run);
    }
};

/// Permissions, as the panel shows them.
pub fn accessibility() bool {
    return cf.trusted(false);
}

pub fn screenRecording() bool {
    return capture.allowed();
}

/// Puts nanocua's window where the user is, above other apps', until `on` is
/// false. macOS may refuse to activate an app nobody clicked, and the window can
/// be on another Space, while the user's app is full screen on its own.
pub fn raise(window: *nanoui.Window, on: bool) void {
    const floating: objc.NSInteger = 3;
    const move_to_active_space: usize = 1 << 1;
    const full_screen_auxiliary: usize = 1 << 8;
    objc.msg(void, window.nswindow, "setLevel:", .{if (on) floating else @as(objc.NSInteger, 0)});
    // Only an accessory app's window can appear over another app's full screen.
    const regular: objc.NSInteger = 0;
    const accessory: objc.NSInteger = 1;
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    _ = objc.msg(objc.BOOL, nsapp, "setActivationPolicy:", .{if (on) accessory else regular});
    if (!on) return;
    objc.msg(void, window.nswindow, "setCollectionBehavior:", .{move_to_active_space | full_screen_auxiliary});
    // Moving to the active Space happens as a window is shown, not while it's up.
    objc.msg(void, window.nswindow, "orderOut:", .{@as(?objc.Object, null)});
    objc.msg(void, window.nswindow, "orderFrontRegardless", .{});
}

pub const Permission = enum(usize) { accessibility = 1, screen = 2 };

/// Asks for a permission: the system's prompt, then its Settings pane. After
/// this frame, not during it: some of these calls run the event loop while they
/// wait, and a frame started inside a frame leaves its boxes open.
pub fn request(which: Permission) void {
    objc.dispatchMain(@ptrFromInt(@backingInt(which)), asked);
}

fn asked(ctx: ?*anyopaque) callconv(.c) void {
    const which: Permission = @fromBackingInt(@intCast(@intFromPtr(ctx)));
    switch (which) {
        .accessibility => if (!cf.trusted(true)) openSettings("Privacy_Accessibility"),
        .screen => if (!cf.CGRequestScreenCaptureAccess()) {
            capture.register();
            openSettings("Privacy_ScreenCapture");
            // macOS may not list the app even so, and only a person can add it.
            revealApp();
        },
    }
}

/// Shows this app in Finder, ready to drag into a System Settings list.
fn revealApp() void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const bundle = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    const path = objc.fromNSString(objc.msg(?objc.Object, bundle, "bundlePath", .{}));
    if (std.mem.endsWith(u8, path, ".app")) nanoui.shell.showInFolder(path);
}

fn openSettings(pane: []const u8) void {
    var buf: [128]u8 = undefined;
    const url = std.fmt.bufPrint(&buf, "x-apple.systempreferences:com.apple.preference.security?{s}", .{pane}) catch return;
    _ = nanoui.shell.openUrl(url);
}

const Job = struct {
    mac: *Mac,
    session: *Session = undefined,
    tool: tools.Tool,
    reply: *mcp.Reply,
    arena: std.heap.ArenaAllocator,
    // The arguments, copied off the request.
    x: ?f64,
    y: ?f64,
    width: ?f64,
    height: ?f64,
    dx: ?f64,
    dy: ?f64,
    ref: ?i64,
    pid: ?i64,
    count: ?i64,
    max_nodes: ?i64,
    max_size: ?i64,
    whole_screen: bool,
    text: ?[]const u8,
    name: ?[]const u8,
    app: ?[]const u8,
    button: ?[]const u8,
    // The answer.
    out: std.Io.Writer.Allocating,
    shot: ?capture.Shot = null,
    failed: bool = false,

    fn create(m: *Mac, tool: tools.Tool, a: tools.Args, reply: *mcp.Reply) !*Job {
        const j = try m.gpa.create(Job);
        j.* = .{
            .mac = m,
            .tool = tool,
            .reply = reply,
            .arena = .init(m.gpa),
            .out = .init(m.gpa),
            .x = a.number("x"),
            .y = a.number("y"),
            .width = a.number("width"),
            .height = a.number("height"),
            .dx = a.number("dx"),
            .dy = a.number("dy"),
            .ref = a.int("ref"),
            .pid = a.int("pid"),
            .count = a.int("count"),
            .max_nodes = a.int("max_nodes"),
            .max_size = a.int("max_size"),
            .whole_screen = a.boolean("whole_screen") orelse false,
            .text = null,
            .name = null,
            .app = null,
            .button = null,
        };
        const al = j.arena.allocator();
        // Whichever string the tool takes, under one name.
        const t = a.string("text") orelse a.string("keys") orelse a.string("value");
        if (t) |s| j.text = try al.dupe(u8, s);
        if (a.string("name")) |s| j.name = try al.dupe(u8, s);
        if (a.string("app")) |s| j.app = try al.dupe(u8, s);
        if (a.string("button")) |s| j.button = try al.dupe(u8, s);
        return j;
    }

    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const j: *Job = @ptrCast(@alignCast(ctx));
        const pool = objc.Pool.push();
        if (j.mac.sessions.get(j.reply.conn)) |session| {
            j.session = session;
            j.perform() catch |e| j.fail("{s}", .{@errorName(e)});
        } else |e| j.fail("{s}", .{@errorName(e)});
        pool.pop();
        objc.dispatchMain(j, deliver);
    }

    fn deliver(ctx: ?*anyopaque) callconv(.c) void {
        const j: *Job = @ptrCast(@alignCast(ctx));
        const gpa = j.mac.gpa;
        defer {
            if (j.shot) |s| gpa.free(s.data);
            j.out.deinit();
            j.arena.deinit();
            gpa.destroy(j);
        }
        const text = j.out.written();
        if (j.shot) |s| {
            j.reply.finish(&.{ .{ .image = .{ .data = s.data, .mime = "image/jpeg" } }, .{ .text = text } }, false, .ok);
        } else j.reply.finish(&.{.{ .text = if (text.len > 0) text else "done" }}, j.failed, if (j.failed) .failed else .ok);
    }

    fn fail(j: *Job, comptime fmt: []const u8, args: anytype) void {
        j.failed = true;
        j.out.clearRetainingCapacity();
        j.out.writer.print(fmt, args) catch {};
    }

    fn perform(j: *Job) !void {
        const w = &j.out.writer;
        const m = j.mac;
        if (j.tool.kind() == .act) {
            if (m.stopped.load(.acquire)) return j.fail("nanocua is stopped: the user pressed Stop.", .{});
            if (!accessibility()) return j.fail("nanocua has no Accessibility permission, which input needs: ask the user to grant it in nanocua's window.", .{});
        }
        switch (j.tool) {
            .list_apps => apps.each(j, writeApp),
            .get_ui_tree => {
                if (!accessibility()) return j.fail("nanocua has no Accessibility permission: ask the user to grant it in nanocua's window.", .{});
                const named = j.namedPid() orelse return;
                const pid = named orelse j.session.last orelse
                    ax.focusedPid() orelse return j.fail("No app has the keyboard focus: pass pid or app.", .{});
                if (pid == m.self_pid) return j.fail("That is nanocua itself, which agents don't see. Pass pid or app (see list_apps).", .{});
                const max: usize = @intCast(std.math.clamp(j.max_nodes orelse 400, 1, 2000));
                try ax.writeTree(&j.session.refs, w, pid, .{ .max_nodes = max });
                if (windows.main(pid)) |win| if (!win.onscreen) try w.print("\n{s}\n", .{off_this_space});
                j.session.last = pid;
            },
            .screenshot => try j.screenshot(),
            .click => {
                const button: input.Button = if (j.button != null and std.mem.eql(u8, j.button.?, "right")) .right else .left;
                const count: u32 = @intCast(std.math.clamp(j.count orelse 1, 1, 3));
                if (j.ref) |r| {
                    const el = j.element(r) orelse return;
                    const t = j.events(ax.pidOf(el)) orelse return;
                    if (button == .left and count == 1 and !hit.inWebPage(el) and ax.perform(el, "AXPress")) return w.print("Pressed [{d}].", .{r});
                    const f = ax.frame(el) orelse return j.fail("[{d}] has no frame to click.", .{r});
                    const c = j.inWindow(t, f) orelse return j.fail("[{d}] is out of sight in its window: scroll to it first.", .{r});
                    const aimed = j.aim(t, c[0], c[1]) orelse return;
                    input.click(aimed, c[0], c[1], button, count);
                    return j.sent(aimed, "a click to", c);
                }
                const t = j.events(null) orelse return;
                const p = j.point(t) orelse return;
                const aimed = j.aim(t, p[0], p[1]) orelse return;
                if (aimed == .app and button == .left and count == 1) {
                    var buf: [64]u8 = undefined;
                    if (hit.press(&buf, aimed.app.pid, p[0], p[1])) |what|
                        return w.print("Pressed the {s} at {d:.0},{d:.0}.", .{ what, p[0], p[1] });
                }
                input.click(aimed, p[0], p[1], button, count);
                try j.sent(aimed, "a click to", p);
            },
            .type_text => {
                const text = j.text orelse return j.fail("type_text needs text.", .{});
                var el_pid: ?i32 = null;
                const el = if (j.ref) |r| blk: {
                    const e = j.element(r) orelse return;
                    el_pid = ax.pidOf(e);
                    break :blk e;
                } else null;
                const t = j.events(el_pid) orelse return;
                if (el) |e| {
                    if (!ax.focus(e)) if (ax.center(e)) |c| if (j.aim(t, c[0], c[1])) |aimed| input.click(aimed, c[0], c[1], .left, 1);
                    _ = usleep(60_000);
                }
                if (!j.keyboardIsOthers(t)) return;
                const typed = input.typeText(t, text, &m.stopped);
                try w.print("Typed {d} characters.", .{typed});
            },
            .press_key => {
                var buf: [32]u8 = undefined;
                const combo = keys.parse(&buf, j.text orelse "") catch
                    return j.fail("Write keys like \"cmd+s\", \"shift+tab\", \"enter\", \"escape\", \"left\", \"f5\".", .{});
                const t = j.events(null) orelse return;
                if (!j.keyboardIsOthers(t)) return;
                if (!input.press(t, combo)) return j.fail("No key code for that key.", .{});
                try w.print("Pressed {s}.", .{j.text.?});
            },
            .scroll => {
                var el_pid: ?i32 = null;
                var el_frame: ?[4]f64 = null;
                if (j.ref) |r| {
                    const el = j.element(r) orelse return;
                    el_pid = ax.pidOf(el);
                    el_frame = ax.frame(el) orelse return j.fail("[{d}] has no frame.", .{r});
                }
                const t = j.events(el_pid) orelse return;
                const p = if (el_frame) |f|
                    j.inWindow(t, f) orelse return j.fail("[{d}] is out of sight in its window.", .{j.ref.?})
                else
                    j.point(t) orelse return;
                const aimed = j.aim(t, p[0], p[1]) orelse return;
                const dx = j.dx orelse 0;
                const dy: f64 = j.dy orelse if (dx == 0) 3 else 0;
                try j.scrollAt(aimed, p, dx, dy);
            },
            .move_mouse => {
                const t = j.events(null) orelse return;
                const p = j.point(t) orelse return;
                const aimed = j.aim(t, p[0], p[1]) orelse return;
                input.move(aimed, p[0], p[1]);
                try if (aimed == .hid) w.print("Moved the pointer to {d:.0},{d:.0}.", .{ p[0], p[1] }) else j.sent(aimed, "a hover to", p);
            },
            .set_value => {
                const r = j.ref orelse return j.fail("set_value needs ref.", .{});
                const el = j.element(r) orelse return;
                const err = ax.setText(el, j.text orelse "");
                if (err != 0) return j.fail("[{d}] refused the value (AXError {d}): it may not be editable; try type_text.", .{ r, err });
                try w.print("Set [{d}].", .{r});
            },
            .open_app => {
                const n = j.name orelse return j.fail("open_app needs name.", .{});
                if (j.whole_screen and !m.whole_screen.load(.acquire)) return j.fail("The whole screen is off in nanocua: open it behind the user's work (leave out whole_screen).", .{});
                switch (apps.open(n, j.whole_screen)) {
                    .running => try w.print("{s} is running, behind what the user is doing. Read it with get_ui_tree.", .{n}),
                    .activated => try w.print("Brought {s} forward.", .{n}),
                    .launched => try w.print("Opening {s} in the background. Read it with get_ui_tree once it has started.", .{n}),
                    .not_found => return j.fail("Found no app named \"{s}\".", .{n}),
                }
                // A later get_ui_tree without app reads this one. (One just
                // launching isn't in the running list yet.)
                if (apps.pidNamed(n)) |pid| if (pid != m.self_pid) {
                    j.session.last = pid;
                };
            },
        }
        // Let what was done show before the agent looks again.
        if (j.tool.kind() == .act) _ = usleep(120_000);
    }

    fn writeApp(j: *Job, a: apps.App) void {
        const w = &j.out.writer;
        w.print("{s} — {s} pid {d}", .{ a.name, a.bundle, a.pid }) catch return;
        if (a.active) w.writeAll(" (frontmost)") catch return;
        if (a.pid == j.mac.self_pid) w.writeAll(" (nanocua: off limits)") catch return;
        w.writeByte('\n') catch return;
    }

    /// The element behind ref `r`, unless it is missing or nanocua's.
    fn element(j: *Job, r: i64) ?cf.AXUIElementRef {
        const el = j.session.refs.get(r) orelse {
            j.fail("No element [{d}]: refs come from the last get_ui_tree.", .{r});
            return null;
        };
        if (ax.pidOf(el)) |pid| if (pid == j.mac.self_pid) {
            j.fail("[{d}] is nanocua's own: agents can't act on it.", .{r});
            return null;
        };
        return el;
    }

    /// The pid the call names, which may be none. Null if it names an app
    /// that isn't running (it says so).
    fn namedPid(j: *Job) ??i32 {
        if (j.pid) |p| return @as(?i32, @intCast(std.math.clamp(p, 0, std.math.maxInt(i32))));
        const n = j.app orelse return @as(?i32, null);
        if (apps.pidNamed(n)) |pid| return @as(?i32, pid);
        j.fail("No running app is named \"{s}\" (see list_apps).", .{n});
        return null;
    }

    /// Where this call's events go, or null if it may not send any (it says
    /// why). `el_pid`: the app of the element it acts on.
    fn events(j: *Job, el_pid: ?i32) ?input.Target {
        const m = j.mac;
        const named = j.namedPid() orelse return null;
        const r = target.route(.{
            .whole_screen = j.whole_screen,
            .allowed = m.whole_screen.load(.acquire),
            .pid = named orelse el_pid,
            .last = j.session.last,
            .self = m.self_pid,
        });
        switch (r) {
            .refused => |why| {
                j.fail("{s}", .{why});
                return null;
            },
            .whole_screen => return .hid,
            .app => |pid| {
                j.session.last = pid;
                return .{ .app = .{ .pid = pid, .window = if (windows.main(pid)) |w| w.id else 0 } };
            },
        }
    }

    /// Where to aim at an element so that the event lands in its window: on the
    /// real pointer its middle, in an app the middle of what shows.
    fn inWindow(j: *Job, t: input.Target, f: [4]f64) ?[2]f64 {
        _ = j;
        const middle: [2]f64 = .{ f[0] + f[2] / 2, f[1] + f[3] / 2 };
        if (t == .hid) return middle;
        const w = windows.at(t.app.pid, middle[0], middle[1]) orelse windows.main(t.app.pid) orelse return null;
        return target.visiblePoint(f, windows.box(w));
    }

    /// `t` aimed at the window under x, y. An app's window must be there: an
    /// event anywhere else goes nowhere, and saying so beats pretending.
    fn aim(j: *Job, t: input.Target, x: f64, y: f64) ?input.Target {
        if (t == .hid) return t;
        const w = windows.at(t.app.pid, x, y) orelse {
            if (windows.main(t.app.pid)) |m| {
                const b = windows.box(m);
                j.fail("{d:.0},{d:.0} isn't in a window of that app. Its main window is at {d:.0},{d:.0} sized {d:.0}x{d:.0}.", .{ x, y, b[0], b[1], b[2], b[3] });
            } else j.fail("That app has no window to act in.", .{});
            return null;
        };
        return .{ .app = .{ .pid = t.app.pid, .window = w.id, .origin = .{ w.frame.origin.x, w.frame.origin.y } } };
    }

    /// Reports events that can't be confirmed, which is every event sent into
    /// an app: macOS doesn't say whether it acted on them.
    fn sent(j: *Job, t: input.Target, what: []const u8, p: [2]f64) !void {
        const w = &j.out.writer;
        if (t == .hid) return w.print("Sent {s} the screen at {d:.0},{d:.0}.", .{ what, p[0], p[1] });
        try w.print("Sent {s} the app at {d:.0},{d:.0}. Not confirmed: apps can ignore events in the background, so check with get_ui_tree or screenshot.", .{ what, p[0], p[1] });
    }

    /// Scrolls and says what really happened: with a scroll bar to read, it knows.
    fn scrollAt(j: *Job, t: input.Target, p: [2]f64, dx: f64, dy: f64) !void {
        const w = &j.out.writer;
        if (t == .hid) {
            input.scroll(t, p[0], p[1], dx, dy);
            return w.print("Scrolled the screen {d} down, {d} right at {d:.0},{d:.0}.", .{ dy, dx, p[0], p[1] });
        }
        const pid = t.app.pid;
        const before = hit.position(pid, p[0], p[1]);
        input.scroll(t, p[0], p[1], dx, dy);
        if (!before.known()) return j.sent(t, "a scroll to", p);
        // Scrolling can animate.
        _ = usleep(200_000);
        if (hit.position(pid, p[0], p[1]).moved(before))
            return w.print("Scrolled {d} down, {d} right at {d:.0},{d:.0}.", .{ dy, dx, p[0], p[1] });
        if (before.atEnd(dx, dy)) return w.print("Nothing moved: it's already at the end that way.", .{});
        hit.scrollBars(pid, p[0], p[1], dx, dy);
        _ = usleep(50_000);
        if (hit.position(pid, p[0], p[1]).moved(before))
            return w.print("Scrolled at {d:.0},{d:.0} through its scroll bars: about {d} down, {d} right.", .{ p[0], p[1], dy, dx });
        j.fail("Nothing scrolled at {d:.0},{d:.0}: the app ignored it. It may not be scrollable there, or need whole_screen.", .{ p[0], p[1] });
    }

    /// x and y. On the real pointer, not over nanocua's own windows.
    fn point(j: *Job, t: input.Target) ?[2]f64 {
        const x = j.x orelse {
            j.fail("{s} needs ref, or x and y.", .{@tagName(j.tool)});
            return null;
        };
        const y = j.y orelse {
            j.fail("{s} needs y too.", .{@tagName(j.tool)});
            return null;
        };
        if (t == .hid) if (ax.pidAt(x, y)) |pid| if (pid == j.mac.self_pid) {
            j.fail("{d:.0},{d:.0} is over nanocua's own window: agents can't act on it.", .{ x, y });
            return null;
        };
        return .{ x, y };
    }

    /// Whether keys can go where `t` sends them: into an app they always can.
    fn keyboardIsOthers(j: *Job, t: input.Target) bool {
        if (t != .hid) return true;
        if (ax.focusedPid()) |pid| if (pid == j.mac.self_pid) {
            j.fail("nanocua has the keyboard: keys would go to its own window. Bring another app forward first (open_app).", .{});
            return false;
        };
        return true;
    }

    fn screenshot(j: *Job) !void {
        const m = j.mac;
        const named = j.namedPid() orelse return;
        const route = target.route(.{
            .whole_screen = j.whole_screen,
            .allowed = m.whole_screen.load(.acquire),
            .pid = named,
            .last = j.session.last,
            .self = m.self_pid,
        });
        const max: u32 = @intCast(std.math.clamp(j.max_size orelse 1280, 64, 2560));
        var rect = capture.screen();
        const result: capture.Error!capture.Shot = switch (route) {
            .refused => |why| return j.fail("{s}", .{why}),
            .whole_screen => blk: {
                if (j.x != null or j.y != null or j.width != null or j.height != null) {
                    const x = j.x orelse 0;
                    const y = j.y orelse 0;
                    rect = .{ .origin = .{ .x = x, .y = y }, .size = .{
                        .width = j.width orelse rect.size.width - x,
                        .height = j.height orelse rect.size.height - y,
                    } };
                    if (rect.size.width < 1 or rect.size.height < 1) return j.fail("The region is empty.", .{});
                }
                break :blk capture.capture(m.gpa, rect, max);
            },
            .app => |pid| blk: {
                const w = windows.main(pid) orelse return j.fail("App {d} has no window to capture.", .{pid});
                rect = w.frame;
                j.session.last = pid;
                // macOS refuses these (SCStream error -3811), with no better reason to pass on.
                if (!w.onscreen) return j.fail("{s}", .{off_this_space});
                break :blk capture.window(m.gpa, w.id, w.frame, max);
            },
        };
        const shot = result catch |e| return switch (e) {
            error.NoPermission => j.fail("nanocua has no Screen Recording permission: ask the user to grant it in nanocua's window, or use get_ui_tree.", .{}),
            else => j.fail("The screenshot failed ({s}).", .{@errorName(e)}),
        };
        j.shot = shot;
        const sx = rect.size.width / @as(f64, @floatFromInt(shot.width));
        const sy = rect.size.height / @as(f64, @floatFromInt(shot.height));
        try j.out.writer.print("The image is {d}x{d} px of the region at {d:.0},{d:.0} sized {d:.0}x{d:.0} points: pixel (px, py) is the point ({d:.0} + px*{d:.4}, {d:.0} + py*{d:.4}).", .{ shot.width, shot.height, rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, rect.origin.x, sx, rect.origin.y, sy });
    }
};

test "agents don't share refs or a target; a closed agent's are freed" {
    var s: Sessions = .{ .gpa = std.testing.allocator };
    defer s.deinit();
    const a = try s.get(1);
    const b = try s.get(2);
    try std.testing.expect(a != b);
    a.last = 42;
    try std.testing.expectEqual(@as(?i32, null), b.last);
    try std.testing.expectEqual(a, try s.get(1));
    s.remove(1);
    s.remove(1);
    try std.testing.expectEqual(@as(?i32, null), (try s.get(1)).last);
}
