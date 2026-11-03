//! A reel of the to-do list's animations, played by the app itself: run
//! it with `TODO_PROMO=1` (in the Simulator, `SIMCTL_CHILD_TODO_PROMO=1
//! xcrun simctl launch ...`) and record the screen. Every frame is the
//! real app drawn by nanoui, and every tap is a real one: the script
//! presses and releases the pointer where a finger would, so the app's
//! own controls answer it as they answer a touch.
//!
//! About eleven seconds, from launch:
//!
//!   0.35  The list comes in, card after card.
//!   1.5   Two tasks checked: each pops green, greys, slides under the rest,
//!         and the rings fill.
//!   3.0   The filter: Done, then All, the cards gliding to their places.
//!   4.6   The glass menu: Check all. Everything greens, All done.
//!   6.5   The +: the sheet comes up, Meeting, Urgent, Add task, and the new
//!         card drops into the list.
//!   9.4   The glass tab bar: Calendar, back to Tasks.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const todo = @import("todo.zig");

const ink = todo.ink;
/// The list waits this long after launch, then comes in.
const list_at: f64 = 0.35;
/// When the finger leaves, and when the reel holds still.
const done_at: f64 = 10.4;
const press_for: f64 = 0.09;
/// Where the pointer goes between touches.
const away: ui.Point = .{ .x = -1e4, .y = -1e4 };

/// What a tap lands on.
const Aim = union(enum) {
    /// The first task still to do: its checkbox.
    check,
    /// The last text drawn that reads so (the sheet's over the cards').
    text: []const u8,
    /// The round glass menu button.
    menu,
    /// The + button.
    plus,
    /// The sheet's Urgent switch.
    urgent,
};

const Tap = struct { at: f64, aim: Aim };

const script = [_]Tap{
    .{ .at = 1.5, .aim = .check },
    .{ .at = 2.25, .aim = .check },
    .{ .at = 3.0, .aim = .{ .text = "Done" } },
    .{ .at = 3.8, .aim = .{ .text = "All" } },
    .{ .at = 4.6, .aim = .menu },
    .{ .at = 5.3, .aim = .{ .text = "Check all" } },
    .{ .at = 6.5, .aim = .plus },
    .{ .at = 7.2, .aim = .{ .text = "Meeting" } },
    .{ .at = 7.75, .aim = .urgent },
    .{ .at = 8.5, .aim = .{ .text = "Add task" } },
    .{ .at = 9.4, .aim = .{ .text = "Calendar" } },
    .{ .at = 10.0, .aim = .{ .text = "Tasks" } },
};

pub const Promo = struct {
    on: bool = false,
    t0: f64 = -1,
    /// The list is drawn (before `list_at` it isn't, so it enters fresh).
    list: bool = false,
    list_since: f64 = 0,
    /// Where the next task's checkbox is, and which task that is.
    target: ?ui.Rect = null,
    next: ?usize = null,
    /// The next tap in the script, where it lands, and the last press.
    tap: usize = 0,
    aim: ?ui.Point = null,
    last: ?ui.Point = null,
    phase: enum { idle, down, up } = .idle,
    down_since: f64 = 0,
    /// The frame whose input was set: a rebuilt frame doesn't set it twice.
    frame: u64 = std.math.maxInt(u64),

    fn now(p: *const Promo, c: *ui.Context) f64 {
        return c.time - p.t0;
    }

    /// The script: the time, and the pointer as a finger would move it.
    /// Called first thing in the view, before any box asks what it got.
    pub fn step(p: *Promo, c: *ui.Context) void {
        if (p.t0 < 0) p.t0 = c.time;
        const s = p.now(c);
        if (s >= list_at and !p.list) p.list_since = c.time;
        p.list = s >= list_at;
        // Film: every frame, not just the ones something asked for.
        if (s < done_at + 1) c.animationFrame();
        if (p.frame == c.frame) return;
        p.frame = c.frame;
        const in = &c.input;
        switch (p.phase) {
            .down => if (s >= p.down_since + press_for) {
                in.mouse = p.last.?;
                c.updateHot();
                c.pointerUp();
                p.phase = .up;
            },
            .up => {
                in.mouse = away;
                c.updateHot();
                p.phase = .idle;
            },
            .idle => if (p.tap < script.len and s >= script[p.tap].at) {
                p.tap += 1;
                if (p.aim) |at| {
                    in.mouse = at;
                    in.click_count = 1;
                    c.updateHot();
                    c.pointerDown();
                    p.last = at;
                    p.down_since = s;
                    p.phase = .down;
                }
            },
        }
    }

    /// Whether the list is still coming in, so its cards stagger.
    pub fn entering(p: *const Promo, c: *ui.Context) bool {
        return p.on and c.time - p.list_since < 0.6;
    }

    /// A box of the list coming in: up and in, `delay` after the others.
    pub fn enter(p: *const Promo, c: *ui.Context, delay: f32) motion.Frame {
        if (!p.on) return .{};
        return motion.frame(c, .{
            .initial = .{ .y = 28, .opacity = 0 },
            .delay = delay,
            .transition = .{ .spring = motion.Spring.visual(0.55, 0) },
        });
    }

    /// Last in the view: where the next tap lands, from what was laid out
    /// last frame, and the finger over everything.
    pub fn draw(p: *Promo, c: *ui.Context, plus: ui.Rect, menu: ?ui.Rect) void {
        p.aim = if (p.tap < script.len) switch (script[p.tap].aim) {
            .check => mid(p.target),
            .text => |str| mid(textRect(c, str)),
            .menu => mid(menu),
            .plus => mid(plus),
            .urgent => if (textRect(c, "Urgent")) |r| .{ .x = c.size.w - 60, .y = r.y + r.h / 2 } else null,
        } else null;
        p.finger(c, p.now(c));
    }

    /// A touch, as the Simulator shows one: a soft round disc that dips as
    /// it presses. It rests where it pressed, then heads for the next tap
    /// half a second before it; it comes in from the bottom and leaves so.
    fn finger(p: *Promo, c: *ui.Context, s: f64) void {
        const off: ui.Point = .{ .x = c.size.w * 0.7, .y = c.size.h + 60 };
        var to = p.last orelse off;
        if (p.tap < script.len and s >= script[p.tap].at - 0.5) if (p.aim) |a| {
            to = a;
        };
        if (s < script[0].at - 0.6 or s > done_at) to = off;
        const glide: motion.Transition = .{ .spring = motion.Spring.visual(0.42, 0) };
        const x = motion.number(c, "promo-fx", to.x, glide);
        const y = motion.number(c, "promo-fy", to.y, glide);
        const press = motion.number(c, "promo-fp", if (p.phase == .down) 1 else 0, .{ .spring = motion.Spring.snappy });
        const d: f32 = 46;
        const dot = ui.div(c).absolute().offset(x - d / 2, y - d / 2).w(d).h(d).roundedFull().circular()
            .bg(ink.alpha(0.14 + 0.14 * press)).border(ui.Color.white.alpha(0.9)).borderW(2)
            .shadow(.{ .color = .{ .a = 0.16 }, .blur = 18, .y = 6 }).scale(1 - 0.14 * press);
        dot.end();
    }
};

fn mid(r: ?ui.Rect) ?ui.Point {
    const b = r orelse return null;
    return .{ .x = b.x + b.w / 2, .y = b.y + b.h / 2 };
}

/// Where the last text that reads `str` was laid out, last frame.
fn textRect(c: *ui.Context, str: []const u8) ?ui.Rect {
    var found: ?ui.Rect = null;
    for (c.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, str)) {
            if (c.rects.get(n.id)) |r| found = r;
        },
        else => {},
    };
    return found;
}
