//! `--nanoui-play=STEPS`: steps in the manner of `--nanoui-script`, played
//! in the app's first window while it runs, at a person's pace, with a dot
//! where each finger lands: for demo videos and screen recordings (iOS's
//! Simulator records its screen but has no way to tap). macOS and iOS.
//!
//!   tap:TEXT      press the text drawn as TEXT, and let go (click:TEXT too)
//!   tap:@X,Y      press the point X, Y (points; negative from the right or bottom edge)
//!   move:TEXT     put the finger on it, for the scroll that follows
//!   type:TEXT     type it, a character at a time
//!   key:NAME      a key: enter, backspace, escape, tab, …
//!   scroll:DY     drag DY points under the finger (negative: up, to what's below);
//!                 held past an end it rubber-bands, so `scroll:200` at the top pulls to refresh
//!   wheel:DY      (macOS) a trackpad's scroll, as an event through the view's own handler;
//!                 never posted to the system, so nothing else hears it
//!   notch:LINES   (macOS) a mouse wheel's notches, the same way
//!   menukey:K     (macOS) ⌘K, as an event offered to the menu bar first, as AppKit does
//!   drag:WxH      (macOS) drag the window's size there, as a person does, a change a
//!                 frame through AppKit's live resize; says on stderr what each change cost
//!   wait:SECONDS  pause
//!   ax:PATH       (macOS) write what VoiceOver reads to PATH; axpress:LABEL press it
//!
//! For example: `--nanoui-play="wait:1;tap:Tasks;tap:Something to do;type:Hello;key:enter"`.
const std = @import("std");
const objc = @import("objc.zig");
const types = @import("ui/types.zig");
const gpu = @import("ui/gpu.zig");
const Key = @import("ui/input.zig").Key;
const mac = @import("builtin").os.tag == .macos;

/// The finger's dot: where it is, and how far it has faded once lifted.
const Dot = struct { at: types.Point, fade: f32 = 0, lifted: bool = false };
var dot: ?Dot = null;

const away: types.Point = .{ .x = -1e6, .y = -1e6 };

/// Plays `steps` in `app`'s first window once it has drawn.
pub fn start(app: anytype, steps: []const u8) void {
    const P = Player(@TypeOf(app.*));
    const p = app.gpa.create(P) catch return;
    p.* = .{ .app = app, .steps = std.mem.splitScalar(u8, steps, ';') };
    after(0.5, p, P.begin);
}

/// The dot over a frame's instances, while there is one.
pub fn paint(gpa: std.mem.Allocator, out: *std.ArrayList(gpu.Instance)) void {
    const d = dot orelse return;
    const r: f32 = 22 * (1 + 0.35 * d.fade);
    const a = 1 - d.fade;
    out.append(gpa, .{
        .rect = .{ d.at.x - r, d.at.y - r, 2 * r, 2 * r },
        .color = gpu.color4(.{ .r = 0.55, .g = 0.55, .b = 0.6, .a = 0.35 * a }),
        .border_color = gpu.color4(.{ .r = 1, .g = 1, .b = 1, .a = 0.8 * a }),
        .border_width = 2,
        .radius = r,
        .kind = gpu.Kind.quad,
    }) catch {};
}

extern "c" fn CGEventCreateScrollWheelEvent2(source: ?*anyopaque, units: u32, count: u32, y: i32, x: i32, z: i32) ?*anyopaque;
extern "c" fn CGEventSetIntegerValueField(event: *anyopaque, field: u32, value: i64) void;
extern "c" fn CGEventSetLocation(event: *anyopaque, at: objc.CGPoint) void;
extern "c" fn CFRelease(o: *anyopaque) void;

/// A trackpad's scroll over the middle of `s`, through the view's `scrollWheel:` as
/// AppKit calls it. The event is made here and never posted.
fn wheelEvent(s: anytype, dy: f32, precise: bool) void {
    const pixels = 0;
    const lines = 1;
    const continuous = 88;
    const phase = 99;
    const phase_changed = 2;
    const ev = CGEventCreateScrollWheelEvent2(null, if (precise) pixels else lines, 1, @intFromFloat(dy), 0, 0) orelse return;
    defer CFRelease(ev);
    if (precise) {
        CGEventSetIntegerValueField(ev, continuous, 1);
        CGEventSetIntegerValueField(ev, phase, phase_changed);
    }
    const middle: objc.CGPoint = .{ .x = s.size.w / 2, .y = s.size.h * 0.6 };
    const base = objc.msg(objc.CGPoint, s.nsview, "convertPoint:toView:", .{ middle, @as(?objc.Object, null) });
    // A location in the system's coordinates: from the top of the first screen.
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const first = objc.msg(objc.Object, screens, "firstObject", .{});
    const top = objc.msg(objc.CGRect, first, "frame", .{}).size.height;
    CGEventSetLocation(ev, .{ .x = base.x, .y = top - base.y });
    const event = objc.msg(objc.Object, objc.class("NSEvent"), "eventWithCGEvent:", .{ev});
    objc.msg(void, s.nsview, "scrollWheel:", .{event});
}

/// Thirty changes of size between where it is and `w` × `h`, one after another as a
/// drag gives them, each one timed.
fn dragWindow(s: anytype, w: f32, h: f32) void {
    const from = s.size;
    var ms: [30]f64 = undefined;
    objc.msg(void, s.nsview, "viewWillStartLiveResize", .{});
    for (&ms, 0..) |*m, i| {
        const k = @as(f32, @floatFromInt(i + 1)) / ms.len;
        const size: objc.CGSize = .{ .width = from.w + (w - from.w) * k, .height = from.h + (h - from.h) * k };
        const t0 = CACurrentMediaTime();
        objc.msg(void, s.window.nswindow, "setContentSize:", .{size});
        m.* = (CACurrentMediaTime() - t0) * 1000;
    }
    objc.msg(void, s.nsview, "viewDidEndLiveResize", .{});
    std.mem.sort(f64, &ms, {}, std.sort.asc(f64));
    var total: f64 = 0;
    for (ms) |m| total += m;
    std.debug.print("nanoui-play: drag of {d} changes took {d:.0} ms: median {d:.1}, slowest {d:.1}\n", .{ ms.len, total, ms[ms.len / 2], ms[ms.len - 1] });
}

extern "c" fn CACurrentMediaTime() f64;

/// ⌘ and a key as AppKit first offers it: to the menu bar. Not posted either.
fn menuKey(key: []const u8) void {
    const keyDown: objc.NSUInteger = 10;
    const command: objc.NSUInteger = 1 << 20;
    const chars = objc.nsString(key);
    const ev = objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{ keyDown, objc.CGPoint{ .x = 0, .y = 0 }, command, @as(f64, 0), @as(objc.NSInteger, 0), @as(?objc.Object, null), chars, chars, objc.NO, @as(u16, 0) });
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const menu = objc.msg(?objc.Object, app, "mainMenu", .{}) orelse return;
    _ = objc.msg(objc.BOOL, menu, "performKeyEquivalent:", .{ev});
}

fn after(seconds: f64, p: anytype, comptime f: fn (@TypeOf(p)) void) void {
    const Wrap = struct {
        fn run(ctx: ?*anyopaque) callconv(.c) void {
            f(@ptrCast(@alignCast(ctx)));
        }
    };
    objc.dispatchAfter(@intFromFloat(seconds * std.time.ns_per_s), p, Wrap.run);
}

fn Player(comptime App: type) type {
    return struct {
        const P = @This();

        app: *App,
        steps: std.mem.SplitIterator(u8, .scalar),
        /// Where the finger is: a scroll starts there.
        finger: ?types.Point = null,
        /// What `type` has left to type.
        typing: []const u8 = "",
        /// A scroll's distance, how much of it is done, and where it began.
        scroll_dy: f32 = 0,
        scroll_t: f32 = 0,
        scroll_done: f32 = 0,
        scroll_at: types.Point = .{},

        /// The first window's surface, once it has drawn a frame.
        fn surface(p: *P) ?*SurfaceOf(App) {
            if (p.app.windows.items.len == 0) return null;
            const s = p.app.windows.items[0].surface orelse return null;
            return if (s.ctx.frame > 0) s else null;
        }

        fn begin(p: *P) void {
            if (p.surface() == null) return after(0.25, p, begin);
            p.next();
        }

        fn next(p: *P) void {
            const s = p.surface() orelse return after(0.25, p, next);
            const raw = p.steps.next() orelse return;
            const step = std.mem.trim(u8, raw, " ");
            const colon = std.mem.indexOfScalar(u8, step, ':') orelse step.len;
            const op = step[0..colon];
            const arg = if (colon < step.len) step[colon + 1 ..] else "";
            if (std.mem.eql(u8, op, "tap") or std.mem.eql(u8, op, "click")) {
                const at = find(s, arg) orelse return p.missing(step);
                p.finger = at;
                dot = .{ .at = at };
                s.ctx.input.mouse = at;
                s.ctx.updateHot();
                s.ctx.input.click_count = 1;
                s.ctx.pointerDown();
                s.frame();
                after(0.14, p, release);
            } else if (std.mem.eql(u8, op, "move")) {
                p.finger = find(s, arg) orelse return p.missing(step);
                p.next();
            } else if (std.mem.eql(u8, op, "type")) {
                p.typing = arg;
                p.typeOne();
            } else if (std.mem.eql(u8, op, "key")) {
                s.ctx.input.key = std.meta.stringToEnum(Key, arg) orelse return p.missing(step);
                s.frame();
                after(0.5, p, next);
            } else if (std.mem.eql(u8, op, "scroll")) {
                p.scroll_dy = std.fmt.parseFloat(f32, arg) catch return p.missing(step);
                p.scroll_t = 0;
                p.scroll_done = 0;
                p.scroll_at = p.finger orelse .{ .x = s.ctx.size.w / 2, .y = s.ctx.size.h * 0.6 };
                dot = .{ .at = p.scroll_at };
                p.scrollStep();
            } else if (mac and std.mem.eql(u8, op, "drag")) {
                const x = std.mem.indexOfScalar(u8, arg, 'x') orelse return p.missing(step);
                const w = std.fmt.parseFloat(f32, arg[0..x]) catch return p.missing(step);
                const h = std.fmt.parseFloat(f32, arg[x + 1 ..]) catch return p.missing(step);
                dragWindow(s, w, h);
                after(0.2, p, next);
            } else if (mac and std.mem.eql(u8, op, "wheel")) {
                wheelEvent(s, std.fmt.parseFloat(f32, arg) catch return p.missing(step), true);
                after(0.05, p, next);
            } else if (mac and std.mem.eql(u8, op, "notch")) {
                wheelEvent(s, std.fmt.parseFloat(f32, arg) catch return p.missing(step), false);
                after(0.05, p, next);
            } else if (mac and std.mem.eql(u8, op, "menukey")) {
                menuKey(arg);
                after(0.5, p, next);
            } else if (mac and (std.mem.eql(u8, op, "ax") or std.mem.eql(u8, op, "axpress"))) {
                const ax = @import("ui/axdump.zig");
                const ok = if (op.len == 2) ax.dump(s.nsview, arg) else ax.press(s.nsview, arg);
                if (!ok) return p.missing(step);
                after(0.5, p, next);
            } else if (std.mem.eql(u8, op, "wait")) {
                after(std.fmt.parseFloat(f64, arg) catch 0, p, next);
            } else p.missing(step);
        }

        /// A step that can't be played: said, and skipped.
        fn missing(p: *P, step: []const u8) void {
            std.log.warn("nanoui: --nanoui-play: can't play \"{s}\"", .{step});
            after(0.1, p, next);
        }

        fn release(p: *P) void {
            const s = p.surface() orelse return;
            s.ctx.input.mouse = p.finger.?;
            s.ctx.updateHot();
            s.ctx.pointerUp();
            s.frame();
            // The finger is up: nothing stays hovered.
            s.ctx.input.mouse = away;
            s.ctx.updateHot();
            p.lift();
            after(0.7, p, next);
        }

        fn typeOne(p: *P) void {
            const s = p.surface() orelse return;
            if (p.typing.len == 0) return after(0.4, p, next);
            const n = @min(p.typing.len, std.unicode.utf8ByteSequenceLength(p.typing[0]) catch 1);
            s.ctx.input.chars = p.typing[0..n];
            p.typing = p.typing[n..];
            s.frame();
            after(0.07, p, typeOne);
        }

        fn scrollStep(p: *P) void {
            const s = p.surface() orelse return;
            p.scroll_t = @min(1, p.scroll_t + 1.0 / 30.0);
            // Eased in and out over half a second.
            const t = p.scroll_t;
            const eased = if (t < 0.5) 2 * t * t else 1 - std.math.pow(f32, -2 * t + 2, 2) / 2;
            const to = p.scroll_dy * eased;
            s.ctx.input.mouse = p.scroll_at;
            // Held as a finger holds: past an end it rubber-bands.
            s.ctx.scroll_holding = true;
            // A view with no scrolling box takes the wheel itself, as a surface gives it.
            const moved_box = s.ctx.applyScroll(to - p.scroll_done);
            const wheel = !moved_box and s.ctx.wants_wheel;
            if (wheel) s.ctx.input.scroll.y += to - p.scroll_done;
            p.scroll_done = to;
            if (dot) |*d| d.at = .{ .x = p.scroll_at.x, .y = p.scroll_at.y + to };
            s.frame();
            // A wheel's pointer stays where it is; only a finger lifts.
            if (!wheel) s.ctx.input.mouse = away;
            if (p.scroll_t < 1) return after(1.0 / 60.0, p, scrollStep);
            // Let go: it springs back (and a pull past its threshold refreshes).
            s.ctx.scroll_holding = false;
            s.frame();
            p.lift();
            after(0.5, p, next);
        }

        /// The dot fades away, a frame at a time.
        fn lift(p: *P) void {
            if (dot) |*d| d.lifted = true;
            fadeStep(p);
        }

        fn fadeStep(p: *P) void {
            const d = if (dot) |*d| d else return;
            // Pressed again meanwhile: that dot isn't fading.
            if (!d.lifted) return;
            d.fade += 1.0 / 15.0;
            if (d.fade >= 1) dot = null;
            if (p.surface()) |s| s.frame();
            if (dot != null) after(1.0 / 60.0, p, fadeStep);
        }
    };
}

/// The surface type of `App`'s windows.
fn SurfaceOf(comptime App: type) type {
    const Window = std.meta.Child(std.meta.Child(@FieldType(@FieldType(App, "windows"), "items")));
    return std.meta.Child(std.meta.Child(@FieldType(Window, "surface")));
}

/// The center of the text drawn as `str` in the last frame, or the point
/// `@X,Y` (an icon, a map).
fn find(s: anytype, str: []const u8) ?types.Point {
    if (str.len > 1 and str[0] == '@') {
        const comma = std.mem.indexOfScalar(u8, str, ',') orelse return null;
        const x = std.fmt.parseFloat(f32, str[1..comma]) catch return null;
        const y = std.fmt.parseFloat(f32, str[comma + 1 ..]) catch return null;
        return .{ .x = if (x < 0) s.ctx.size.w + x else x, .y = if (y < 0) s.ctx.size.h + y else y };
    }
    for (s.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, str)) return .{ .x = n.rect.x + n.rect.w / 2, .y = n.rect.y + n.rect.h / 2 },
        else => {},
    };
    return null;
}
