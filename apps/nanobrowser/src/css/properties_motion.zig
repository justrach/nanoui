//! `animation-*` and `transition-*`: each longhand's comma list, kept until the
//! element's style is finished, when the names decide how many there are and
//! the other lists are repeated to fit (`zip`).
const std = @import("std");
const style = @import("style.zig");
const prop = @import("prop.zig");
const values = @import("values.zig");

const fx = style.fx;
const Prop = prop.Prop;
const Ctx = values.Ctx;
const Cur = values.Cur;
const Token = values.Token;
const Timing = fx.Timing;

/// What was written, before the names say how many there are.
pub const AnimRaw = struct {
    names: []const []const u8 = &.{},
    durations: []const f32 = &.{},
    delays: []const f32 = &.{},
    timings: []const Timing = &.{},
    iterations: []const f32 = &.{},
    directions: []const fx.Direction = &.{},
    fills: []const fx.FillMode = &.{},
    paused: []const bool = &.{},
};

pub const TransRaw = struct {
    names: []const []const u8 = &.{},
    durations: []const f32 = &.{},
    delays: []const f32 = &.{},
    timings: []const Timing = &.{},
};

pub fn apply(ctx: *Ctx, p: Prop, t: []const Token) ?bool {
    return switch (p) {
        .animation => animation(ctx, t),
        .animation_name => setAnim(ctx, "names", list([]const u8, ctx, t, nameAt)),
        .animation_duration => setAnim(ctx, "durations", list(f32, ctx, t, timeAt)),
        .animation_delay => setAnim(ctx, "delays", list(f32, ctx, t, timeAt)),
        .animation_timing_function => setAnim(ctx, "timings", list(Timing, ctx, t, timingAt)),
        .animation_iteration_count => setAnim(ctx, "iterations", list(f32, ctx, t, iterationAt)),
        .animation_direction => setAnim(ctx, "directions", list(fx.Direction, ctx, t, directionAt)),
        .animation_fill_mode => setAnim(ctx, "fills", list(fx.FillMode, ctx, t, fillAt)),
        .animation_play_state => setAnim(ctx, "paused", list(bool, ctx, t, pausedAt)),
        .transition => transition(ctx, t),
        .transition_property => setTrans(ctx, "names", list([]const u8, ctx, t, nameAt)),
        .transition_duration => setTrans(ctx, "durations", list(f32, ctx, t, timeAt)),
        .transition_delay => setTrans(ctx, "delays", list(f32, ctx, t, timeAt)),
        .transition_timing_function => setTrans(ctx, "timings", list(Timing, ctx, t, timingAt)),
        .transition_behavior => true,
        else => null,
    };
}

fn list(comptime T: type, ctx: *Ctx, t: []const Token, comptime at: fn (*Ctx, *Cur) ?T) ?[]const T {
    var outer = Cur.of(t);
    var out: std.ArrayList(T) = .empty;
    while (!outer.atEnd()) {
        var c = Cur.of(outer.untilComma());
        const v = at(ctx, &c) orelse return null;
        if (!c.atEnd()) return null;
        out.append(ctx.arena, v) catch return null;
    }
    return out.items;
}

fn setAnim(ctx: *Ctx, comptime field: []const u8, v: anytype) bool {
    const value = v orelse return false;
    const r = ctx.arena.create(AnimRaw) catch return false;
    r.* = if (ctx.style.anim_raw) |o| o.* else .{};
    @field(r, field) = value;
    ctx.style.anim_raw = r;
    return true;
}

fn setTrans(ctx: *Ctx, comptime field: []const u8, v: anytype) bool {
    const value = v orelse return false;
    const r = ctx.arena.create(TransRaw) catch return false;
    r.* = if (ctx.style.trans_raw) |o| o.* else .{};
    @field(r, field) = value;
    ctx.style.trans_raw = r;
    return true;
}

fn nameAt(_: *Ctx, c: *Cur) ?[]const u8 {
    const k = c.next() orelse return null;
    if (k.kind == .ident or k.kind == .string) return k.text;
    return null;
}

fn timeAt(_: *Ctx, c: *Cur) ?f32 {
    const k = c.peek() orelse return null;
    if (k.kind == .number and k.num == 0) {
        c.i += 1;
        return 0;
    }
    if (k.kind != .dimension) return null;
    const per: f32 = if (std.ascii.eqlIgnoreCase(k.text, "s")) 1 else if (std.ascii.eqlIgnoreCase(k.text, "ms")) 0.001 else return null;
    c.i += 1;
    return k.num * per;
}

pub fn timingAt(ctx: *Ctx, c: *Cur) ?Timing {
    const k = c.peek() orelse return null;
    const eq = std.ascii.eqlIgnoreCase;
    if (k.kind == .ident) {
        const named: ?Timing = if (eq(k.text, "ease")) Timing.ease else if (eq(k.text, "linear")) .linear else if (eq(k.text, "ease-in")) Timing.ease_in else if (eq(k.text, "ease-out")) Timing.ease_out else if (eq(k.text, "ease-in-out")) Timing.ease_in_out else if (eq(k.text, "step-start")) Timing{ .steps = .{ .n = 1, .jump_start = true, .jump_end = false } } else if (eq(k.text, "step-end")) Timing{ .steps = .{ .n = 1, .jump_start = false, .jump_end = true } } else null;
        if (named != null) c.i += 1;
        return named;
    }
    if (k.kind != .function) return null;
    if (eq(k.text, "linear")) {
        c.i += 1;
        _ = c.body();
        return .linear;
    }
    if (eq(k.text, "cubic-bezier")) {
        c.i += 1;
        var a = Cur.of(c.body());
        var v: [4]f32 = undefined;
        for (&v, 0..) |*x, i| {
            x.* = values.numberAt(ctx, &a) orelse return null;
            if (i < 3 and !a.takeComma()) return null;
        }
        return .{ .bezier = v };
    }
    if (eq(k.text, "steps")) {
        c.i += 1;
        var a = Cur.of(c.body());
        const n = values.numberAt(ctx, &a) orelse return null;
        var start = false;
        var end = true;
        if (a.takeComma()) {
            const w = a.next() orelse return null;
            if (w.isIdent("start") or w.isIdent("jump-start")) {
                start = true;
                end = false;
            } else if (w.isIdent("jump-both")) {
                start = true;
            } else if (w.isIdent("jump-none")) {
                end = false;
            }
        }
        return .{ .steps = .{ .n = @intFromFloat(std.math.clamp(n, 1, 10000)), .jump_start = start, .jump_end = end } };
    }
    return null;
}

fn iterationAt(ctx: *Ctx, c: *Cur) ?f32 {
    if (c.takeIdent("infinite")) return std.math.inf(f32);
    const n = values.numberAt(ctx, c) orelse return null;
    return if (n < 0) null else n;
}

fn directionAt(_: *Ctx, c: *Cur) ?fx.Direction {
    if (c.takeIdent("normal")) return .normal;
    if (c.takeIdent("reverse")) return .reverse;
    if (c.takeIdent("alternate-reverse")) return .alternate_reverse;
    if (c.takeIdent("alternate")) return .alternate;
    return null;
}

fn fillAt(_: *Ctx, c: *Cur) ?fx.FillMode {
    if (c.takeIdent("none")) return FillNone;
    if (c.takeIdent("forwards")) return .forwards;
    if (c.takeIdent("backwards")) return .backwards;
    if (c.takeIdent("both")) return .both;
    return null;
}
const FillNone: fx.FillMode = .none;

fn pausedAt(_: *Ctx, c: *Cur) ?bool {
    if (c.takeIdent("running")) return false;
    if (c.takeIdent("paused")) return true;
    return null;
}

fn animation(ctx: *Ctx, t: []const Token) bool {
    var outer = Cur.of(t);
    var names: std.ArrayList([]const u8) = .empty;
    var durations: std.ArrayList(f32) = .empty;
    var delays: std.ArrayList(f32) = .empty;
    var timings: std.ArrayList(Timing) = .empty;
    var iterations: std.ArrayList(f32) = .empty;
    var directions: std.ArrayList(fx.Direction) = .empty;
    var fills: std.ArrayList(fx.FillMode) = .empty;
    var paused: std.ArrayList(bool) = .empty;
    const a = ctx.arena;
    while (!outer.atEnd()) {
        var c = Cur.of(outer.untilComma());
        var name: ?[]const u8 = null;
        var duration: ?f32 = null;
        var delay: ?f32 = null;
        var timing: ?Timing = null;
        var iteration: ?f32 = null;
        var direction: ?fx.Direction = null;
        var fill: ?fx.FillMode = null;
        var pause: ?bool = null;
        while (!c.atEnd()) {
            if (timeAt(ctx, &c)) |v| {
                if (duration == null) duration = v else delay = v;
                continue;
            }
            if (timing == null) if (timingAt(ctx, &c)) |v| {
                timing = v;
                continue;
            };
            if (iteration == null) if (iterationAt(ctx, &c)) |v| {
                iteration = v;
                continue;
            };
            if (direction == null) if (directionAt(ctx, &c)) |v| {
                direction = v;
                continue;
            };
            if (fill == null) if (fillAt(ctx, &c)) |v| {
                fill = v;
                continue;
            };
            if (pause == null) if (pausedAt(ctx, &c)) |v| {
                pause = v;
                continue;
            };
            if (name == null) if (nameAt(ctx, &c)) |v| {
                name = v;
                continue;
            };
            return false;
        }
        names.append(a, name orelse "none") catch return false;
        durations.append(a, duration orelse 0) catch return false;
        delays.append(a, delay orelse 0) catch return false;
        timings.append(a, timing orelse Timing.ease) catch return false;
        iterations.append(a, iteration orelse 1) catch return false;
        directions.append(a, direction orelse .normal) catch return false;
        fills.append(a, fill orelse .none) catch return false;
        paused.append(a, pause orelse false) catch return false;
    }
    const r = a.create(AnimRaw) catch return false;
    r.* = .{ .names = names.items, .durations = durations.items, .delays = delays.items, .timings = timings.items, .iterations = iterations.items, .directions = directions.items, .fills = fills.items, .paused = paused.items };
    ctx.style.anim_raw = r;
    return true;
}

fn transition(ctx: *Ctx, t: []const Token) bool {
    var outer = Cur.of(t);
    var names: std.ArrayList([]const u8) = .empty;
    var durations: std.ArrayList(f32) = .empty;
    var delays: std.ArrayList(f32) = .empty;
    var timings: std.ArrayList(Timing) = .empty;
    const a = ctx.arena;
    while (!outer.atEnd()) {
        var c = Cur.of(outer.untilComma());
        var name: ?[]const u8 = null;
        var duration: ?f32 = null;
        var delay: ?f32 = null;
        var timing: ?Timing = null;
        while (!c.atEnd()) {
            if (timeAt(ctx, &c)) |v| {
                if (duration == null) duration = v else delay = v;
                continue;
            }
            if (timing == null) if (timingAt(ctx, &c)) |v| {
                timing = v;
                continue;
            };
            // `transition-behavior`'s words.
            if (c.takeIdent("allow-discrete") or c.takeIdent("normal")) continue;
            if (name == null) if (nameAt(ctx, &c)) |v| {
                name = v;
                continue;
            };
            return false;
        }
        names.append(a, name orelse "all") catch return false;
        durations.append(a, duration orelse 0) catch return false;
        delays.append(a, delay orelse 0) catch return false;
        timings.append(a, timing orelse Timing.ease) catch return false;
    }
    const r = a.create(TransRaw) catch return false;
    r.* = .{ .names = names.items, .durations = durations.items, .delays = delays.items, .timings = timings.items };
    ctx.style.trans_raw = r;
    return true;
}

fn nth(comptime T: type, l: []const T, i: usize, or_else: T) T {
    return if (l.len == 0) or_else else l[i % l.len];
}

/// The lists made one, into the style's `animations` and `transitions`.
/// What can't show (no name, or no time at all) is left out, so an element with
/// nothing that could run costs nothing.
pub fn zip(ctx_arena: std.mem.Allocator, s: *style.Style) void {
    s.animations = &.{};
    s.transitions = &.{};
    if (s.anim_raw) |r| {
        var out: std.ArrayList(fx.Animation) = .empty;
        for (r.names, 0..) |name, i| {
            if (std.ascii.eqlIgnoreCase(name, "none")) continue;
            out.append(ctx_arena, .{
                .name = name,
                .duration = @max(nth(f32, r.durations, i, 0), 0),
                .delay = nth(f32, r.delays, i, 0),
                .timing = nth(Timing, r.timings, i, Timing.ease),
                .iterations = nth(f32, r.iterations, i, 1),
                .direction = nth(fx.Direction, r.directions, i, .normal),
                .fill = nth(fx.FillMode, r.fills, i, .none),
                .paused = nth(bool, r.paused, i, false),
            }) catch return;
        }
        s.animations = out.items;
    }
    if (s.trans_raw) |r| {
        const names = if (r.names.len > 0) r.names else &[_][]const u8{"all"};
        var out: std.ArrayList(fx.Transition) = .empty;
        for (names, 0..) |name, i| {
            const duration = @max(nth(f32, r.durations, i, 0), 0);
            const delay = nth(f32, r.delays, i, 0);
            if (std.ascii.eqlIgnoreCase(name, "none") or duration + delay <= 0) continue;
            out.append(ctx_arena, .{ .name = name, .duration = duration, .delay = delay, .timing = nth(Timing, r.timings, i, Timing.ease) }) catch return;
        }
        s.transitions = out.items;
    }
}
