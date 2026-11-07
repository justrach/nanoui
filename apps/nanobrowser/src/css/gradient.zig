//! Gradients: linear (an angle), radial (a center and radii across the box)
//! and conic (a center and a start), and their stops.
const std = @import("std");
const style = @import("style.zig");
const values = @import("values.zig");
const colors = @import("colors.zig");

const Ctx = values.Ctx;
const Cur = values.Cur;
const Token = values.Token;

fn sideAngle(c: *Cur, legacy: bool, g: *style.Gradient) ?f32 {
    var dx: f32 = 0;
    var dy: f32 = 0;
    var any = false;
    while (true) {
        if (c.takeIdent("left")) {
            dx = -1;
        } else if (c.takeIdent("right")) {
            dx = 1;
        } else if (c.takeIdent("top")) {
            dy = -1;
        } else if (c.takeIdent("bottom")) {
            dy = 1;
        } else break;
        any = true;
    }
    if (!any) return null;
    // Old prefixed gradients name where they start, not where they go.
    if (legacy) {
        dx = -dx;
        dy = -dy;
    }
    // A corner: its angle depends on the box's shape.
    if (dx != 0 and dy != 0) {
        g.to_x = @intFromFloat(dx);
        g.to_y = @intFromFloat(dy);
    }
    const rad = std.math.atan2(dx, -dy);
    return std.math.radiansToDegrees(rad);
}

/// A gradient function by name; null when its arguments cannot be read.
pub fn parse(ctx: *Ctx, name: []const u8, args: []const Token) ?style.Gradient {
    var c = Cur.of(args);
    var g: style.Gradient = .{};
    const is_linear = std.ascii.findIgnoreCase(name, "linear") != null;
    const legacy = std.ascii.startsWithIgnoreCase(name, "-webkit-") or std.ascii.startsWithIgnoreCase(name, "-moz-");
    g.repeating = std.ascii.findIgnoreCase(name, "repeating") != null;
    if (is_linear) {
        if (values.angleAt(&c)) |a| {
            // The prefixed syntax counts from the right, against the clock.
            g.angle = if (legacy) 90 - a else a;
            _ = c.takeComma();
        } else if (c.takeIdent("to")) {
            g.angle = sideAngle(&c, false, &g) orelse return null;
            _ = c.takeComma();
        } else if (legacy) {
            if (sideAngle(&c, true, &g)) |a| {
                g.angle = a;
                _ = c.takeComma();
            }
        }
    } else {
        g.shape = if (std.ascii.findIgnoreCase(name, "conic") != null) .conic else .radial;
        if (g.shape == .conic) g.angle = 0;
        // Their shape prelude has no color in it, so stops start after it.
        const save = c.i;
        const first = c.untilComma();
        if (firstIsStop(ctx, first)) c.i = save else prelude(ctx, &g, first);
    }
    var stops: std.ArrayList(RawStop) = .empty;
    while (!c.atEnd()) {
        const part = c.untilComma();
        readStop(ctx, part, &stops) catch return null;
    }
    if (stops.items.len < 1) return null;
    const out = ctx.arena.alloc(style.GradientStop, stops.items.len) catch return null;
    var pixels = false;
    for (stops.items) |r| {
        if (r.px != 0) pixels = true;
    }
    if (pixels) {
        // Only the box can say where its stops without a place fall.
        g.has_px = true;
        for (stops.items, out) |r, *o| o.* = .{ .color = r.color, .at = r.at orelse 0, .px = r.px, .known = r.at != null };
    } else spreadStops(stops.items, out);
    g.stops = out;
    return g;
}

/// Radial's `circle closest-side at 50% 0`, conic's `from 90deg at 50% 50%`.
fn prelude(ctx: *Ctx, g: *style.Gradient, part: []const Token) void {
    var c = Cur.of(part);
    var closest = false;
    var corner = true;
    var size: [2]?f32 = .{ null, null };
    var sizes: usize = 0;
    while (!c.atEnd()) {
        if (c.takeIdent("circle")) {
            g.circle = true;
            continue;
        }
        if (c.takeIdent("ellipse")) continue;
        if (c.takeIdent("closest-side")) {
            closest = true;
            corner = false;
            g.extent = .closest_side;
        } else if (c.takeIdent("closest-corner")) {
            closest = true;
            g.extent = .closest_corner;
        } else if (c.takeIdent("farthest-side")) {
            corner = false;
            g.extent = .farthest_side;
        } else if (c.takeIdent("farthest-corner")) {
            g.extent = .farthest_corner;
        } else if (c.takeIdent("from")) {
            if (values.angleAt(&c)) |a| g.angle = a;
        } else if (c.takeIdent("at")) {
            center(ctx, g, &c);
        } else if (values.lengthAt(ctx, &c)) |l| {
            if (sizes == 0) {
                g.size_x = l;
                g.size_y = l;
            }
            if (sizes == 1) g.size_y = l;
            if (sizes < 2 and l.px == 0) size[sizes] = l.pct / 100;
            sizes += 1;
        } else c.i += 1;
    }
    const pick = struct {
        fn f(at: f32, near: bool) f32 {
            return if (near) @min(at, 1 - at) else @max(at, 1 - at);
        }
    }.f;
    const k: f32 = if (corner) std.math.sqrt2 else 1;
    g.rx = @max(0.001, size[0] orelse pick(g.cx, closest) * k);
    g.ry = @max(0.001, size[1] orelse size[0] orelse pick(g.cy, closest) * k);
}

fn center(ctx: *Ctx, g: *style.Gradient, c: *Cur) void {
    var n: usize = 0;
    while (n < 2 and !c.atEnd()) : (n += 1) {
        if (c.takeIdent("left")) {
            g.cx = 0;
        } else if (c.takeIdent("right")) {
            g.cx = 1;
        } else if (c.takeIdent("top")) {
            g.cy = 0;
        } else if (c.takeIdent("bottom")) {
            g.cy = 1;
        } else if (c.takeIdent("center")) {
            // The default.
        } else if (values.lengthAt(ctx, c)) |l| {
            if (n == 0) {
                g.cx = l.pct / 100;
                g.cx_px = l.px;
            } else {
                g.cy = l.pct / 100;
                g.cy_px = l.px;
            }
        } else return;
    }
}

fn firstIsStop(ctx: *Ctx, part: []const Token) bool {
    var c = Cur.of(part);
    if (colors.at(ctx, &c) != null) return true;
    if (c.peek()) |t| if (t.kind == .percentage) {
        c.i += 1;
        return colors.at(ctx, &c) != null;
    };
    return false;
}

const RawStop = struct { color: style.Color, at: ?f32, px: f32 = 0 };

fn readStop(ctx: *Ctx, part: []const Token, out: *std.ArrayList(RawStop)) error{Bad}!void {
    var c = Cur.of(part);
    var color: ?style.Color = null;
    var at: [2]?f32 = .{ null, null };
    var px: [2]f32 = .{ 0, 0 };
    var n_at: usize = 0;
    while (!c.atEnd()) {
        if (color == null) if (colors.at(ctx, &c)) |v| {
            color = v;
            continue;
        };
        if (n_at < 2) if (values.lengthAt(ctx, &c)) |l| {
            at[n_at] = l.pct / 100;
            px[n_at] = l.px;
            n_at += 1;
            continue;
        };
        if (values.angleAt(&c)) |a| {
            if (n_at < 2) at[n_at] = a / 360;
            n_at += 1;
            continue;
        }
        return error.Bad;
    }
    // A bare position is a midpoint hint: it has no color to show.
    const col = color orelse return;
    out.append(ctx.arena, .{ .color = col, .at = at[0], .px = px[0] }) catch return error.Bad;
    if (at[1]) |second| out.append(ctx.arena, .{ .color = col, .at = second, .px = px[1] }) catch return error.Bad;
}

/// The spec's fix-up: ends default to 0 and 1, gaps fill evenly, and positions
/// never run backwards.
fn spreadStops(raw: []const RawStop, out: []style.GradientStop) void {
    var at: [64]f32 = undefined;
    const n = @min(raw.len, at.len);
    var known: [64]bool = undefined;
    for (raw[0..n], 0..) |r, i| {
        known[i] = r.at != null;
        at[i] = r.at orelse 0;
    }
    if (!known[0]) {
        at[0] = 0;
        known[0] = true;
    }
    if (!known[n - 1]) {
        at[n - 1] = 1;
        known[n - 1] = true;
    }
    var i: usize = 1;
    var high = at[0];
    while (i < n) : (i += 1) {
        if (known[i]) {
            if (at[i] < high) at[i] = high;
            high = at[i];
        }
    }
    i = 0;
    while (i < n) : (i += 1) {
        if (known[i]) continue;
        var e = i;
        while (!known[e]) e += 1;
        const start = at[i - 1];
        const gap = (at[e] - start) / @as(f32, @floatFromInt(e - i + 1));
        var j = i;
        while (j < e) : (j += 1) {
            at[j] = start + gap * @as(f32, @floatFromInt(j - i + 1));
            known[j] = true;
        }
    }
    for (out, 0..) |*o, k| {
        const idx = @min(k, n - 1);
        o.* = .{ .color = raw[idx].color, .at = at[idx] };
    }
}
