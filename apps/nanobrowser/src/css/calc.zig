//! `calc()`, `min()`, `max()` and `clamp()`. A value is linear in pixels and
//! percent where it can be, which is what a `Len` holds. `min(100%, 500px)` is
//! not: it stays an expression (`style.Math`) that layout evaluates once the
//! percentage's reference is known, with the viewport's answer alongside for
//! whatever has no reference.
const std = @import("std");
const values = @import("values.zig");
const style = @import("style.zig");

const Ctx = values.Ctx;
const Cur = values.Cur;

pub const Value = struct {
    kind: enum { number, length } = .number,
    num: f32 = 0,
    px: f32 = 0,
    pct: f32 = 0,
    /// Open until the reference is known; `px` and `pct` are the estimate.
    math: ?*const style.Math = null,

    fn scaled(v: Value, ctx: *const Ctx, f: f32) Value {
        var out: Value = .{ .kind = v.kind, .num = v.num * f, .px = v.px * f, .pct = v.pct * f };
        if (v.math != null) out.math = node(ctx, .add, &.{v.len()}, f);
        return out;
    }

    /// As a `Len`.
    fn len(v: Value) style.Len {
        return .{ .px = v.px, .pct = v.pct, .math = v.math };
    }

    fn mixes(v: Value) bool {
        return v.math != null or (v.pct != 0 and v.px != 0);
    }

    /// The value as a plain number, for comparing.
    fn estimate(v: Value, ctx: *const Ctx) f32 {
        if (v.kind == .number) return v.num;
        if (ctx.viewport_read) |r| r.* = true;
        return v.px + v.pct * ctx.vw / 100;
    }
};

/// An expression node in the arena; null when memory ran out, which leaves the estimate.
fn node(ctx: *const Ctx, op: style.Math.Op, args: []const style.Len, scale: f32) ?*const style.Math {
    const list = ctx.arena.dupe(style.Len, args) catch return null;
    const m = ctx.arena.create(style.Math) catch return null;
    m.* = .{ .op = op, .args = list, .scale = scale };
    return m;
}

/// Whether a comparison among these needs the reference to be decided: lengths
/// with percentages that aren't all alike. Percentages alone keep their order.
fn staysOpen(list: []const Value) bool {
    var any_pct = false;
    var any_px = false;
    for (list) |v| {
        if (v.kind != .length) return false;
        if (v.mixes()) return true;
        if (v.pct != 0) any_pct = true else if (v.px != 0) any_px = true;
    }
    return any_pct and any_px;
}

/// The chosen estimate, kept open when the choice depends on the reference.
fn opened(ctx: *const Ctx, chosen: Value, op: style.Math.Op, list: []const Value) Value {
    var out = chosen;
    out.math = null;
    if (!staysOpen(list)) return out;
    var args: [8]style.Len = undefined;
    if (list.len > args.len) return out;
    for (list, 0..) |v, i| args[i] = v.len();
    out.math = node(ctx, op, args[0..list.len], 1);
    return out;
}

pub fn isMathFunction(name: []const u8) bool {
    const l = [_][]const u8{ "calc", "-webkit-calc", "-moz-calc", "min", "max", "clamp", "abs", "round" };
    for (l) |x| if (std.ascii.eqlIgnoreCase(name, x)) return true;
    return false;
}

/// Evaluates the named function over its arguments.
pub fn evalFunction(ctx: *const Ctx, name: []const u8, args: []const values.Token) ?Value {
    const v = evalFn(ctx, name, args, 0) orelse return null;
    // `calc(1e30 * 1e30 * 0)`: not a number means not valid.
    if (!std.math.isFinite(v.num) or !std.math.isFinite(v.px) or !std.math.isFinite(v.pct)) return null;
    return v;
}

fn evalFn(ctx: *const Ctx, name: []const u8, args: []const values.Token, depth: u32) ?Value {
    if (depth > 32) return null;
    if (std.ascii.eqlIgnoreCase(name, "calc") or std.ascii.eqlIgnoreCase(name, "-webkit-calc") or std.ascii.eqlIgnoreCase(name, "-moz-calc")) {
        var c = Cur.of(args);
        const v = sum(ctx, &c, depth) orelse return null;
        return if (c.atEnd()) v else null;
    }
    if (std.ascii.eqlIgnoreCase(name, "min")) return minMax(ctx, args, true, depth);
    if (std.ascii.eqlIgnoreCase(name, "max")) return minMax(ctx, args, false, depth);
    if (std.ascii.eqlIgnoreCase(name, "abs")) {
        var c = Cur.of(args);
        const v = sum(ctx, &c, depth) orelse return null;
        return if (v.estimate(ctx) < 0) v.scaled(ctx, -1) else v;
    }
    if (std.ascii.eqlIgnoreCase(name, "round")) return round(ctx, args, depth);
    if (std.ascii.eqlIgnoreCase(name, "clamp")) {
        var c = Cur.of(args);
        const lo = operand(ctx, c.untilComma(), depth) orelse return null;
        const mid = operand(ctx, c.untilComma(), depth) orelse return null;
        const hi = operand(ctx, c.untilComma(), depth) orelse return null;
        if (lo.kind != mid.kind or mid.kind != hi.kind) return null;
        var v = mid;
        if (v.estimate(ctx) > hi.estimate(ctx)) v = hi;
        if (v.estimate(ctx) < lo.estimate(ctx)) v = lo;
        // max(lo, min(mid, hi)).
        if (!staysOpen(&.{ lo, mid, hi })) {
            v.math = null;
            return v;
        }
        const inner = opened(ctx, mid, .min, &.{ mid, hi });
        return opened(ctx, v, .max, &.{ lo, inner });
    }
    return null;
}

fn operand(ctx: *const Ctx, t: []const values.Token, depth: u32) ?Value {
    var c = Cur.of(t);
    const v = sum(ctx, &c, depth) orelse return null;
    return if (c.atEnd()) v else null;
}

fn minMax(ctx: *const Ctx, args: []const values.Token, is_min: bool, depth: u32) ?Value {
    var c = Cur.of(args);
    var best: ?Value = null;
    var all: [8]Value = undefined;
    var n: usize = 0;
    while (!c.atEnd()) {
        const v = operand(ctx, c.untilComma(), depth) orelse return null;
        if (n < all.len) all[n] = v;
        n += 1;
        if (best) |b| {
            if (b.kind != v.kind) return null;
            const smaller = v.estimate(ctx) < b.estimate(ctx);
            if (smaller == is_min) best = v;
        } else best = v;
    }
    const b = best orelse return null;
    if (n > all.len) return b;
    return opened(ctx, b, if (is_min) .min else .max, all[0..n]);
}

fn round(ctx: *const Ctx, args: []const values.Token, depth: u32) ?Value {
    var c = Cur.of(args);
    var how: enum { nearest, up, down, to_zero } = .nearest;
    if (c.takeIdent("nearest")) {
        _ = c.takeComma();
    } else if (c.takeIdent("up")) {
        how = .up;
        _ = c.takeComma();
    } else if (c.takeIdent("down")) {
        how = .down;
        _ = c.takeComma();
    } else if (c.takeIdent("to-zero")) {
        how = .to_zero;
        _ = c.takeComma();
    }
    const v = operand(ctx, c.untilComma(), depth) orelse return null;
    const step = operand(ctx, c.untilComma(), depth) orelse return null;
    const s = step.estimate(ctx);
    if (s == 0) return null;
    const q = v.estimate(ctx) / s;
    const r = switch (how) {
        .nearest => @round(q),
        .up => @ceil(q),
        .down => @floor(q),
        .to_zero => @trunc(q),
    };
    return if (v.kind == .number) .{ .num = r * s } else .{ .kind = .length, .px = r * s };
}

fn sum(ctx: *const Ctx, c: *Cur, depth: u32) ?Value {
    var v = product(ctx, c, depth) orelse return null;
    while (true) {
        const t = c.peek() orelse return v;
        var sign: f32 = 1;
        if (t.isDelim('-')) {
            sign = -1;
            c.i += 1;
        } else if (t.isDelim('+')) {
            c.i += 1;
        } else if ((t.kind == .number or t.kind == .dimension or t.kind == .percentage) and t.signed) {
            // `1px +2px` tokenizes the sign into the number; browsers call it
            // invalid only for want of whitespace, which is a nicety.
        } else return v;
        const r = product(ctx, c, depth) orelse return null;
        if (r.kind != v.kind) return null;
        const open = v.math != null or r.math != null;
        const whole: ?*const style.Math = if (open) node(ctx, .add, &.{ v.len(), r.scaled(ctx, sign).len() }, 1) else null;
        v.num += r.num * sign;
        v.px += r.px * sign;
        v.pct += r.pct * sign;
        v.math = whole;
    }
}

fn product(ctx: *const Ctx, c: *Cur, depth: u32) ?Value {
    var v = primary(ctx, c, depth) orelse return null;
    while (true) {
        const t = c.peek() orelse return v;
        if (t.isDelim('*')) {
            c.i += 1;
            const r = primary(ctx, c, depth) orelse return null;
            if (r.kind == .number) {
                v = v.scaled(ctx, r.num);
            } else if (v.kind == .number) {
                v = r.scaled(ctx, v.num);
            } else return null;
        } else if (t.isDelim('/')) {
            c.i += 1;
            const r = primary(ctx, c, depth) orelse return null;
            if (r.kind != .number or r.num == 0) return null;
            v = v.scaled(ctx, 1 / r.num);
        } else return v;
    }
}

fn primary(ctx: *const Ctx, c: *Cur, depth: u32) ?Value {
    const t = c.next() orelse return null;
    switch (t.kind) {
        .number => return .{ .num = t.num },
        .percentage => return .{ .kind = .length, .pct = t.num },
        .dimension => {
            const per = values.unitPx(ctx, t.text) orelse return null;
            return .{ .kind = .length, .px = t.num * per };
        },
        .lparen => return operand(ctx, c.body(), depth + 1),
        .function => {
            if (!isMathFunction(t.text)) return null;
            return evalFn(ctx, t.text, c.body(), depth + 1);
        },
        .ident => {
            if (t.isIdent("pi")) return .{ .num = std.math.pi };
            if (t.isIdent("e")) return .{ .num = std.math.e };
            return null;
        },
        else => return null,
    }
}
