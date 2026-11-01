//! A promo film of the to-do list, played by the app itself: run it with
//! `TODO_PROMO=1` (in the Simulator, `SIMCTL_CHILD_TODO_PROMO=1 xcrun
//! simctl launch ...`) and record the screen. Every frame is the real app
//! drawn by nanoui; the script only taps for you.
//!
//! Fifteen seconds, then it starts again from the same dark card:
//!
//!   0.0  "Your day, done." on ink, a letter at a time, and a check pops.
//!   2.4  The card folds into the + button, and the app comes in under it.
//!   4.4  A finger checks the tasks off, quicker each time; each one greys,
//!        slides under the rest, and the rings fill.
//!   8.4  All done: the rings turn green and the tag says so. It holds.
//!  11.6  The card opens out of the + again: built with nanoui.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const todo = @import("todo.zig");

const ink = todo.ink;
const green = todo.green;
const length: f64 = 15;
/// When each task is checked: a deliberate first tap, then quicker.
const taps = [_]f64{ 5.0, 6.15, 7.05, 7.75, 8.35 };
const fold_at: f64 = 2.4;
const open_at: f64 = 11.6;
const platforms = [_][]const u8{ "iOS", "macOS", "Windows", "Linux", "Android" };

pub const Promo = struct {
    on: bool = false,
    t0: f64 = -1,
    tapped: usize = 0,
    /// The list is drawn (under the card it isn't, so it enters fresh).
    list: bool = false,
    list_at: f64 = 0,
    /// Where the next task's checkbox is, and which task that is.
    target: ?ui.Rect = null,
    next: ?usize = null,

    fn now(p: *const Promo, c: *ui.Context) f64 {
        return c.time - p.t0;
    }

    /// The script: the time, the taps, and the loop.
    pub fn step(p: *Promo, t: *todo.Todo, c: *ui.Context) void {
        if (p.t0 < 0) p.t0 = c.time;
        if (p.now(c) >= length) {
            p.* = .{ .on = true, .t0 = c.time };
            t.restart();
        }
        const s = p.now(c);
        const show = s >= fold_at + 0.25 and s < open_at + 0.8;
        if (show and !p.list) p.list_at = c.time;
        p.list = show;
        while (p.tapped < taps.len and s >= taps[p.tapped]) : (p.tapped += 1) {
            const i = p.next orelse continue;
            t.tasks[i].done = true;
            t.tasks[i].done_at = c.time;
        }
        // Film: every frame, not just the ones something asked for.
        c.animationFrame();
    }

    /// Whether the list is still coming in, so its cards stagger.
    pub fn entering(p: *const Promo, c: *ui.Context) bool {
        return p.on and c.time - p.list_at < 0.6;
    }

    /// A box of the list coming in: up and in, `delay` after the card folds.
    pub fn enter(p: *const Promo, c: *ui.Context, delay: f32) motion.Frame {
        if (!p.on) return .{};
        return motion.frame(c, .{
            .initial = .{ .y = 28, .opacity = 0 },
            .delay = delay,
            .transition = .{ .spring = motion.Spring.visual(0.55, 0) },
        });
    }

    /// What floats over the app: the finger, and the card.
    pub fn draw(p: *Promo, c: *ui.Context, plus: ui.Rect) void {
        const s = p.now(c);
        if (s > 4.1 and s < 10.2) p.finger(c, s);
        p.card(c, s, plus);
    }

    /// A touch, as the Simulator shows one: a soft disc that dips as it
    /// presses. It comes in from the bottom and leaves the same way.
    fn finger(p: *Promo, c: *ui.Context, s: f64) void {
        const away: ui.Point = .{ .x = c.size.w * 0.72, .y = c.size.h + 60 };
        var to = away;
        if (s > 4.4 and s < 9.0) if (p.target) |r| {
            to = .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
        };
        const glide: motion.Transition = .{ .spring = motion.Spring.visual(0.42, 0) };
        const x = motion.number(c, "promo-fx", to.x, glide);
        const y = motion.number(c, "promo-fy", to.y, glide);
        var down = false;
        for (taps) |at| down = down or (s > at - 0.14 and s < at + 0.06);
        const press = motion.number(c, "promo-fp", if (down) 1 else 0, .{ .spring = motion.Spring.snappy });
        const d: f32 = 46;
        const dot = ui.div(c).absolute().offset(x - d / 2, y - d / 2).w(d).h(d).roundedFull()
            .bg(ink.alpha(0.16 + 0.14 * press)).border(ui.Color.white.alpha(0.9)).borderW(2)
            .shadow(.{ .color = .{ .a = 0.18 }, .blur = 18, .y = 6 }).scale(1 - 0.14 * press);
        dot.end();
    }

    /// The ink card: the whole screen, folded into the + button and
    /// opened out of it again, with the words of each end on it.
    fn card(p: *Promo, c: *ui.Context, s: f64, plus: ui.Rect) void {
        _ = p;
        const folded = s >= fold_at and s < open_at;
        const f = motion.number(c, "promo-fold", if (folded) 1 else 0, .{ .spring = motion.Spring.visual(0.6, 0) });
        // Folded, it fades into the glass + under it; it's back before it opens.
        const seen = motion.number(c, "promo-seen", if (s < fold_at + 0.6 or s >= open_at - 0.3) 1 else 0, .{ .tween = .{ .duration = 0.25, .ease = .ease_out } });
        if (seen <= 0.001) return;
        const lerp = struct {
            fn at(a: f32, b: f32, k: f32) f32 {
                return a + (b - a) * k;
            }
        }.at;
        const panel = ui.div(c).absolute().offset(lerp(0, plus.x, f), lerp(0, plus.y, f))
            .w(lerp(c.size.w, plus.w, f)).h(lerp(c.size.h, plus.h, f)).rounded(lerp(0, plus.w / 2, f)).bg(ink).opacity(seen);
        panel.end();
        // The words, over the panel's full size: gone before it is small,
        // and the last ones gone before the film starts again on bare ink.
        const fade_out: f32 = @floatCast(std.math.clamp((length - s) / 0.45, 0, 1));
        const words = std.math.clamp(1 - f * 3, 0, 1) * fade_out;
        if (words <= 0.001) return;
        const layer = ui.div(c).absolute().offset(0, 0).sizeFull().column().center().gap(28).opacity(words);
        defer layer.end();
        if (s < open_at) intro(c, s) else outro(c, s - open_at);
    }
};

/// A green disc with a check, popping in once `s` passes `at`.
fn check(c: *ui.Context, s: f64, at: f64) void {
    const slot = ui.div(c).w(96).h(96).center();
    defer slot.end();
    if (s < at) return;
    const f = motion.frame(c, .{ .initial = .{ .scale = 0.2, .opacity = 0 }, .transition = .{ .spring = motion.Spring.bouncy } });
    const disc = ui.div(c).w(88).h(88).roundedFull().bg(green).center()
        .shadow(.{ .color = green.alpha(0.45), .blur = 30, .y = 10 }).motion(f);
    defer disc.end();
    ui.icon(c, "checkmark", .{ .size = 40, .weight = .bold, .color = .white });
}

/// A line that comes in a letter at a time once `s` passes `at`, its
/// height kept before then so nothing below it moves.
fn line(c: *ui.Context, s: f64, at: f64, str: []const u8, style: ui.TextStyle) void {
    const slot = ui.div(c).h(style.size * 1.25).center();
    defer slot.end();
    if (s < at) return;
    motion.letters(c, str, style, .{
        .enter = .{ .y = style.size * 0.45, .opacity = 0 },
        .stagger_each = 0.035,
        .transition = .{ .spring = motion.Spring.visual(0.5, 0.12) },
    });
}

fn intro(c: *ui.Context, s: f64) void {
    // It settles back a touch as it goes.
    const out = motion.number(c, "promo-out", if (s > fold_at - 0.2) 1 else 0, .{ .spring = motion.Spring.visual(0.4, 0) });
    const box = ui.div(c).column().itemsCenter().gap(20).scale(1 - 0.06 * out);
    defer box.end();
    check(c, s, 1.15);
    const words = ui.div(c).column().itemsCenter().gap(0);
    defer words.end();
    line(c, s, 0.15, "Your day,", .{ .size = 54, .weight = .bold, .color = .white });
    line(c, s, 0.6, "done.", .{ .size = 54, .weight = .bold, .color = green });
}

fn outro(c: *ui.Context, s: f64) void {
    check(c, s, 0.35);
    {
        const words = ui.div(c).column().itemsCenter().gap(2);
        defer words.end();
        line(c, s, 0.55, "Built with", .{ .size = 22, .weight = .semibold, .color = ui.Color.white.alpha(0.6) });
        line(c, s, 0.75, "nanoui", .{ .size = 60, .weight = .bold, .color = .white });
        line(c, s, 1.2, "Native UI, in Zig", .{ .size = 17, .weight = .medium, .color = ui.Color.white.alpha(0.6) });
    }
    const row = ui.div(c).row().gap(8).h(32).itemsCenter();
    defer row.end();
    if (s < 1.55) return;
    for (platforms, 0..) |name, i| {
        ui.key(c, c.print("promo-os-{d}", .{i}));
        const f = motion.frame(c, .{
            .initial = .{ .y = 10, .opacity = 0 },
            .delay = motion.stagger(i, 0.07),
            .transition = .{ .spring = motion.Spring.visual(0.45, 0) },
        });
        const pill = ui.div(c).h(32).px(14).roundedFull().bg(ui.Color.white.alpha(0.1)).center().motion(f);
        defer pill.end();
        ui.text(c, name, .{ .size = 13, .weight = .semibold, .color = .white });
    }
}
