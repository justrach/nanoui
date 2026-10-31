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
//!   wait:SECONDS  pause
//!
//! For example: `--nanoui-play="wait:1;tap:Tasks;tap:Something to do;type:Hello;key:enter"`.
const std = @import("std");
const objc = @import("objc.zig");
const types = @import("ui/types.zig");
const gpu = @import("ui/gpu.zig");
const Key = @import("ui/input.zig").Key;

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
            _ = s.ctx.applyScroll(to - p.scroll_done);
            s.ctx.input.mouse = away;
            p.scroll_done = to;
            if (dot) |*d| d.at = .{ .x = p.scroll_at.x, .y = p.scroll_at.y + to };
            s.frame();
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
