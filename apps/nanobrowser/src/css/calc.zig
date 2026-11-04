//! `calc()`, `min()`, `max()` and `clamp()`. A value is linear in pixels and
//! percent, which is what a `Len` holds; `min(100%, 500px)` is not, so a
//! comparison mixing them is decided as if the percentage were of the viewport's
//! width, the usual reference in practice.
const std = @import("std");
const values = @import("values.zig");

const Ctx = values.Ctx;
const Cur = values.Cur;

pub const Value = struct {
    kind: enum { number, length } = .number,
    num: f32 = 0,
    px: f32 = 0,
    pct: f32 = 0,

    fn scaled(v: Value, f: f32) Value {
        return .{ .kind = v.kind, .num = v.num * f, .px = v.px * f, .pct = v.pct * f };
    }

    /// The value as a plain number, for comparing.
    fn estimate(v: Value, ctx: *const Ctx) f32 {
        if (v.kind == .number) return v.num;
        return v.px + v.pct * ctx.vw / 100;
    }
};

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
        return if (v.estimate(ctx) < 0) v.scaled(-1) else v;
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
        return v;
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
    while (!c.atEnd()) {
        const v = operand(ctx, c.untilComma(), depth) orelse return null;
        if (best) |b| {
            if (b.kind != v.kind) return null;
            const smaller = v.estimate(ctx) < b.estimate(ctx);
            if (smaller == is_min) best = v;
        } else best = v;
    }
    return best;
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
        v.num += r.num * sign;
        v.px += r.px * sign;
        v.pct += r.pct * sign;
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
                v = v.scaled(r.num);
            } else if (v.kind == .number) {
                v = r.scaled(v.num);
            } else return null;
        } else if (t.isDelim('/')) {
            c.i += 1;
            const r = primary(ctx, c, depth) orelse return null;
            if (r.kind != .number or r.num == 0) return null;
            v = v.scaled(1 / r.num);
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
