//! What is done to a box after it is laid out: shadows, transforms, clips,
//! filters, and how a form control leaves its drawing to the author.
const std = @import("std");
const style = @import("style.zig");
const prop = @import("prop.zig");
const values = @import("values.zig");
const colors = @import("colors.zig");

const fx = style.fx;
const Prop = prop.Prop;
const Ctx = values.Ctx;
const Cur = values.Cur;
const Token = values.Token;
const Len = style.Len;
const Shadow = style.Shadow;
const Op = fx.Op;

pub fn apply(ctx: *Ctx, p: Prop, t: []const Token) ?bool {
    const s = ctx.style;
    return switch (p) {
        .box_shadow => boxShadow(ctx, t),
        .text_shadow => textShadow(ctx, t),
        .transform => transform(ctx, t),
        .translate => translateProp(ctx, t),
        .rotate => rotateProp(ctx, t),
        .scale => scaleProp(ctx, t),
        .transform_origin => transformOrigin(ctx, t),
        .clip => clipRect(ctx, t),
        .clip_path => clipPath(ctx, t),
        .filter => filter(ctx, t),
        .backdrop_filter => backdropFilter(ctx, t),
        .outline_offset => {
            var c = Cur.of(t);
            s.outline_offset = values.pxAt(ctx, &c) orelse return false;
            return c.atEnd();
        },
        .isolation, .mix_blend_mode, .will_change => {
            s.makes_context = makesContext(p, t);
            return true;
        },
        // `properties_flow.zig` takes what it does to sizes.
        .contain => {
            s.makes_context = makesContext(p, t);
            return null;
        },
        .appearance => {
            const w = values.ident(t) orelse return false;
            s.appearance_none = std.ascii.eqlIgnoreCase(w, "none");
            return true;
        },
        .accent_color => {
            if (values.ident(t)) |w| if (std.ascii.eqlIgnoreCase(w, "auto")) {
                s.accent = null;
                return true;
            };
            s.accent = colors.of(ctx, t) orelse return false;
            return true;
        },
        .text_fill_color => {
            s.text_fill = colors.of(ctx, t) orelse return false;
            return true;
        },
        else => null,
    };
}

/// Blending itself is not done (what's under shows as if `normal`); the
/// stacking context it makes is, since what paints over what depends on it.
fn makesContext(p: Prop, t: []const Token) bool {
    var c = Cur.of(t);
    while (c.next()) |k| {
        if (k.kind != .ident) continue;
        switch (p) {
            .isolation => if (k.isIdent("isolate")) return true,
            .mix_blend_mode => if (!k.isIdent("normal")) return true,
            .will_change => if (k.isIdent("opacity") or k.isIdent("transform") or k.isIdent("filter") or k.isIdent("clip-path") or k.isIdent("translate") or k.isIdent("rotate") or k.isIdent("scale")) return true,
            else => if (k.isIdent("paint") or k.isIdent("layout") or k.isIdent("strict") or k.isIdent("content")) return true,
        }
    }
    return false;
}

/// One shadow of `box-shadow` or `text-shadow`.
fn shadowOf(ctx: *Ctx, part: []const Token, inset_ok: bool) ?Shadow {
    var c = Cur.of(part);
    var nums: [4]f32 = .{ 0, 0, 0, 0 };
    var n: usize = 0;
    var inset = false;
    var color: ?style.Color = null;
    while (!c.atEnd()) {
        if (inset_ok and c.takeIdent("inset")) {
            inset = true;
            continue;
        }
        if (n < 4) if (values.pxAt(ctx, &c)) |v| {
            nums[n] = v;
            n += 1;
            continue;
        };
        if (color == null) if (colors.at(ctx, &c)) |v| {
            color = v;
            continue;
        };
        return null;
    }
    if (n < 2) return null;
    return .{ .x = nums[0], .y = nums[1], .blur = @max(nums[2], 0), .spread = nums[3], .color = color orelse ctx.style.color, .inset = inset };
}

fn shadowList(ctx: *Ctx, t: []const Token, inset_ok: bool) ?[]const Shadow {
    var outer = Cur.of(t);
    var out: std.ArrayList(Shadow) = .empty;
    while (!outer.atEnd()) {
        const sh = shadowOf(ctx, outer.untilComma(), inset_ok) orelse return null;
        // Tailwind's empty layers: `0 0 #0000`.
        if (sh.color.a > 0) out.append(ctx.arena, sh) catch return null;
    }
    return out.items;
}

fn boxShadow(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| {
        if (!std.ascii.eqlIgnoreCase(w, "none")) return false;
        ctx.style.shadow = null;
        ctx.style.shadows = &.{};
        return true;
    }
    const list = shadowList(ctx, t, true) orelse return false;
    ctx.style.shadows = list;
    ctx.style.shadow = null;
    for (list) |sh| if (!sh.inset) {
        ctx.style.shadow = sh;
        break;
    };
    return true;
}

fn textShadow(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| {
        if (!std.ascii.eqlIgnoreCase(w, "none")) return false;
        ctx.style.text_shadows = &.{};
        return true;
    }
    ctx.style.text_shadows = shadowList(ctx, t, false) orelse return false;
    return true;
}

/// A number, or a percentage of one, for `scale`.
fn scaleAt(ctx: *Ctx, c: *Cur) ?f32 {
    if (c.peek()) |k| if (k.kind == .percentage) {
        c.i += 1;
        return k.num / 100;
    };
    return values.numberAt(ctx, c);
}

fn lenArg(ctx: *Ctx, a: *Cur) ?Len {
    return values.lengthAt(ctx, a);
}

/// `transform`'s function `name`, its arguments in `a`.
fn opOf(ctx: *Ctx, name: []const u8, a: *Cur) ?Op {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "translate")) {
        const x = lenArg(ctx, a) orelse return null;
        var y = Len.zero;
        if (a.takeComma()) y = lenArg(ctx, a) orelse return null;
        return .{ .translate = .{ .x = x, .y = y } };
    }
    if (eq(name, "translate3d")) {
        const x = lenArg(ctx, a) orelse return null;
        if (!a.takeComma()) return null;
        const y = lenArg(ctx, a) orelse return null;
        return .{ .translate = .{ .x = x, .y = y } };
    }
    if (eq(name, "translateX")) return .{ .translate = .{ .x = lenArg(ctx, a) orelse return null, .y = Len.zero } };
    if (eq(name, "translateY")) return .{ .translate = .{ .x = Len.zero, .y = lenArg(ctx, a) orelse return null } };
    if (eq(name, "translateZ") or eq(name, "perspective")) return .{ .scale = .{ 1, 1 } };
    if (eq(name, "scale") or eq(name, "scale3d")) {
        const x = scaleAt(ctx, a) orelse return null;
        var y = x;
        if (a.takeComma()) y = scaleAt(ctx, a) orelse return null;
        return .{ .scale = .{ x, y } };
    }
    if (eq(name, "scaleX")) return .{ .scale = .{ scaleAt(ctx, a) orelse return null, 1 } };
    if (eq(name, "scaleY")) return .{ .scale = .{ 1, scaleAt(ctx, a) orelse return null } };
    if (eq(name, "scaleZ")) return .{ .scale = .{ 1, 1 } };
    if (eq(name, "rotate") or eq(name, "rotateZ")) return .{ .rotate = values.angleAt(a) orelse return null };
    // Turned out of the plane and flattened: what is left is its shadow on it.
    if (eq(name, "rotateX")) return .{ .scale = .{ 1, @cos((values.angleAt(a) orelse return null) * std.math.pi / 180) } };
    if (eq(name, "rotateY")) return .{ .scale = .{ @cos((values.angleAt(a) orelse return null) * std.math.pi / 180), 1 } };
    if (eq(name, "rotate3d")) {
        var v: [3]f32 = undefined;
        for (&v) |*x| {
            x.* = values.numberAt(ctx, a) orelse return null;
            if (!a.takeComma()) return null;
        }
        const deg = values.angleAt(a) orelse return null;
        const cos = @cos(deg * std.math.pi / 180);
        if (@abs(v[2]) >= @abs(v[0]) and @abs(v[2]) >= @abs(v[1])) return .{ .rotate = if (v[2] < 0) -deg else deg };
        if (@abs(v[0]) >= @abs(v[1])) return .{ .scale = .{ 1, cos } };
        return .{ .scale = .{ cos, 1 } };
    }
    if (eq(name, "skew")) {
        const x = values.angleAt(a) orelse return null;
        var y: f32 = 0;
        if (a.takeComma()) y = values.angleAt(a) orelse return null;
        return .{ .skew = .{ x, y } };
    }
    if (eq(name, "skewX")) return .{ .skew = .{ values.angleAt(a) orelse return null, 0 } };
    if (eq(name, "skewY")) return .{ .skew = .{ 0, values.angleAt(a) orelse return null } };
    if (eq(name, "matrix")) {
        var v: [6]f32 = undefined;
        for (&v, 0..) |*x, i| {
            x.* = values.numberAt(ctx, a) orelse return null;
            if (i < 5 and !a.takeComma()) return null;
        }
        return .{ .matrix = .{ .a = v[0], .b = v[1], .c = v[2], .d = v[3], .e = v[4], .f = v[5] } };
    }
    if (eq(name, "matrix3d")) {
        var v: [16]f32 = undefined;
        for (&v, 0..) |*x, i| {
            x.* = values.numberAt(ctx, a) orelse return null;
            if (i < 15 and !a.takeComma()) return null;
        }
        return .{ .matrix = .{ .a = v[0], .b = v[1], .c = v[4], .d = v[5], .e = v[12], .f = v[13] } };
    }
    return null;
}

fn transform(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| {
        if (!std.ascii.eqlIgnoreCase(w, "none")) return false;
        ctx.style.transform = null;
        return true;
    }
    var c = Cur.of(t);
    var ops: std.ArrayList(Op) = .empty;
    while (c.next()) |f| {
        if (f.kind != .function) return false;
        var a = Cur.of(c.body());
        const op = opOf(ctx, f.text, &a) orelse return false;
        ops.append(ctx.arena, op) catch return false;
    }
    if (ops.items.len == 0) return false;
    ctx.style.transform = .{ .ops = ops.items };
    return true;
}

fn translateProp(ctx: *Ctx, t: []const Token) bool {
    const s = ctx.style;
    if (values.ident(t)) |w| {
        if (!std.ascii.eqlIgnoreCase(w, "none")) return false;
        s.translate_x = Len.zero;
        s.translate_y = Len.zero;
        return true;
    }
    var c = Cur.of(t);
    s.translate_x = values.lengthAt(ctx, &c) orelse return false;
    s.translate_y = values.lengthAt(ctx, &c) orelse Len.zero;
    return true;
}

fn rotateProp(ctx: *Ctx, t: []const Token) bool {
    const s = ctx.style;
    if (values.ident(t)) |w| {
        if (!std.ascii.eqlIgnoreCase(w, "none")) return false;
        s.rotate = 0;
        return true;
    }
    var c = Cur.of(t);
    if (values.angleAt(&c)) |d| {
        s.rotate = d;
        return true;
    }
    if (c.takeIdent("z")) {
        s.rotate = values.angleAt(&c) orelse return false;
        return true;
    }
    // Round another axis: flat, and only its squash shows.
    if (c.takeIdent("x") or c.takeIdent("y")) return true;
    var v: [3]f32 = undefined;
    for (&v) |*x| x.* = values.numberAt(ctx, &c) orelse return false;
    const d = values.angleAt(&c) orelse return false;
    s.rotate = if (@abs(v[2]) >= @abs(v[0]) and @abs(v[2]) >= @abs(v[1])) (if (v[2] < 0) -d else d) else 0;
    return true;
}

fn scaleProp(ctx: *Ctx, t: []const Token) bool {
    const s = ctx.style;
    if (values.ident(t)) |w| {
        if (!std.ascii.eqlIgnoreCase(w, "none")) return false;
        s.scale_x = 1;
        s.scale_y = 1;
        return true;
    }
    var c = Cur.of(t);
    const x = scaleAt(ctx, &c) orelse return false;
    s.scale_x = x;
    s.scale_y = scaleAt(ctx, &c) orelse x;
    return true;
}

/// An axis of a position: a keyword or a length; `y` says which one it set.
const Axis = struct { len: Len, y_only: bool = false, x_only: bool = false };

fn axisAt(ctx: *Ctx, c: *Cur) ?Axis {
    const pct = struct {
        fn of(v: f32) Len {
            return .{ .pct = v };
        }
    }.of;
    if (c.takeIdent("left")) return .{ .len = pct(0), .x_only = true };
    if (c.takeIdent("right")) return .{ .len = pct(100), .x_only = true };
    if (c.takeIdent("top")) return .{ .len = pct(0), .y_only = true };
    if (c.takeIdent("bottom")) return .{ .len = pct(100), .y_only = true };
    if (c.takeIdent("center")) return .{ .len = pct(50) };
    return .{ .len = values.lengthAt(ctx, c) orelse return null };
}

/// A place in a box: one value's other axis is its middle.
fn positionAt(ctx: *Ctx, c: *Cur) ?[2]Len {
    const a = axisAt(ctx, c) orelse return null;
    const b = axisAt(ctx, c) orelse {
        if (a.y_only) return .{ .{ .pct = 50 }, a.len };
        return .{ a.len, .{ .pct = 50 } };
    };
    if (a.y_only or b.x_only) return .{ b.len, a.len };
    return .{ a.len, b.len };
}

fn transformOrigin(ctx: *Ctx, t: []const Token) bool {
    var c = Cur.of(t);
    const p = positionAt(ctx, &c) orelse return false;
    _ = values.lengthAt(ctx, &c);
    if (!c.atEnd()) return false;
    ctx.style.transform_origin_x = p[0];
    ctx.style.transform_origin_y = p[1];
    return true;
}

fn clipRect(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| {
        if (!std.ascii.eqlIgnoreCase(w, "auto")) return false;
        ctx.style.clip_rect = null;
        return true;
    }
    var c = Cur.of(t);
    const f = c.next() orelse return false;
    if (!f.isFunction("rect")) return false;
    var a = Cur.of(c.body());
    var v: [4]?f32 = .{ null, null, null, null };
    for (&v, 0..) |*x, i| {
        if (i > 0) _ = a.takeComma();
        if (a.takeIdent("auto")) continue;
        x.* = values.pxAt(ctx, &a) orelse return false;
    }
    ctx.style.clip_rect = .{ .top = v[0], .right = v[1], .bottom = v[2], .left = v[3] };
    return true;
}

fn insetOf(ctx: *Ctx, a: *Cur) ?fx.ClipPath {
    var v: [4]Len = undefined;
    var n: usize = 0;
    while (n < 4) : (n += 1) v[n] = values.lengthAt(ctx, a) orelse break;
    if (n == 0) return null;
    var radius = Len.zero;
    if (a.takeIdent("round")) {
        radius = values.lengthAt(ctx, a) orelse return null;
        // Different corners: the first says enough for a rectangle's clip.
        while (!a.atEnd()) _ = a.next();
    }
    const r = if (n > 1) v[1] else v[0];
    return .{ .inset = .{ .t = v[0], .r = r, .b = if (n > 2) v[2] else v[0], .l = if (n > 3) v[3] else r, .radius = radius } };
}

fn circleOf(ctx: *Ctx, a: *Cur) ?fx.ClipPath {
    var r: Len = .{ .pct = 0 };
    var closest = true;
    var farthest = false;
    if (a.takeIdent("closest-side")) {
        // The default.
    } else if (a.takeIdent("farthest-side")) {
        closest = false;
        farthest = true;
    } else if (values.lengthAt(ctx, a)) |l| {
        r = l;
        closest = false;
    }
    var p: [2]Len = .{ .{ .pct = 50 }, .{ .pct = 50 } };
    if (a.takeIdent("at")) p = positionAt(ctx, a) orelse return null;
    return .{ .circle = .{ .r = r, .cx = p[0], .cy = p[1], .closest = closest, .farthest = farthest } };
}

fn ellipseOf(ctx: *Ctx, a: *Cur) ?fx.ClipPath {
    var rx: Len = .{ .pct = 0 };
    var ry: Len = .{ .pct = 0 };
    var closest = true;
    if (values.lengthAt(ctx, a)) |l| {
        rx = l;
        ry = values.lengthAt(ctx, a) orelse return null;
        closest = false;
    }
    var p: [2]Len = .{ .{ .pct = 50 }, .{ .pct = 50 } };
    if (a.takeIdent("at")) p = positionAt(ctx, a) orelse return null;
    return .{ .ellipse = .{ .rx = rx, .ry = ry, .cx = p[0], .cy = p[1], .closest = closest } };
}

fn polygonOf(ctx: *Ctx, a: *Cur) ?fx.ClipPath {
    if (a.takeIdent("evenodd") or a.takeIdent("nonzero")) _ = a.takeComma();
    var pts: std.ArrayList([2]Len) = .empty;
    while (!a.atEnd()) {
        const x = values.lengthAt(ctx, a) orelse return null;
        const y = values.lengthAt(ctx, a) orelse return null;
        pts.append(ctx.arena, .{ x, y }) catch return null;
        if (!a.takeComma()) break;
    }
    return .{ .polygon = pts.items };
}

fn clipPath(ctx: *Ctx, t: []const Token) bool {
    const s = ctx.style;
    var c = Cur.of(t);
    s.clip_path = null;
    while (c.next()) |k| {
        if (k.isIdent("none")) return true;
        // A reference to an SVG `<clipPath>`: not followed.
        if (k.kind == .url) return true;
        if (k.kind == .ident) continue; // border-box and kin
        if (k.kind != .function) return false;
        const eq = std.ascii.eqlIgnoreCase;
        var a = Cur.of(c.body());
        if (eq(k.text, "inset")) {
            s.clip_path = insetOf(ctx, &a) orelse return false;
        } else if (eq(k.text, "circle")) {
            s.clip_path = circleOf(ctx, &a) orelse return false;
        } else if (eq(k.text, "ellipse")) {
            s.clip_path = ellipseOf(ctx, &a) orelse return false;
        } else if (eq(k.text, "polygon")) {
            s.clip_path = polygonOf(ctx, &a) orelse return false;
        } else if (eq(k.text, "path") or eq(k.text, "url") or eq(k.text, "shape") or eq(k.text, "rect") or eq(k.text, "xywh")) {
            // Understood as a shape; no clip is drawn for it.
        } else return false;
    }
    return true;
}

fn amountAt(ctx: *Ctx, a: *Cur) ?f32 {
    if (a.atEnd()) return 1;
    if (a.peek()) |k| if (k.kind == .percentage) {
        a.i += 1;
        return k.num / 100;
    };
    return values.numberAt(ctx, a);
}

fn filterList(ctx: *Ctx, t: []const Token) ?[]const fx.Filter {
    var c = Cur.of(t);
    var out: std.ArrayList(fx.Filter) = .empty;
    const eq = std.ascii.eqlIgnoreCase;
    while (c.next()) |k| {
        if (k.kind == .url) continue;
        if (k.kind != .function) return null;
        var a = Cur.of(c.body());
        var f: fx.Filter = .{ .kind = .opacity };
        if (eq(k.text, "blur")) {
            f = .{ .kind = .blur, .amount = if (a.atEnd()) 0 else values.pxAt(ctx, &a) orelse return null };
        } else if (eq(k.text, "hue-rotate")) {
            f = .{ .kind = .hue_rotate, .amount = if (a.atEnd()) 0 else values.angleAt(&a) orelse return null };
        } else if (eq(k.text, "drop-shadow")) {
            f = .{ .kind = .drop_shadow, .shadow = shadowOf(ctx, a.t, false) orelse return null };
        } else if (eq(k.text, "url")) {
            continue;
        } else {
            const kind: fx.FilterKind = if (eq(k.text, "brightness")) .brightness else if (eq(k.text, "contrast")) .contrast else if (eq(k.text, "grayscale")) .grayscale else if (eq(k.text, "invert")) .invert else if (eq(k.text, "opacity")) .opacity else if (eq(k.text, "saturate")) .saturate else if (eq(k.text, "sepia")) .sepia else return null;
            f = .{ .kind = kind, .amount = amountAt(ctx, &a) orelse return null };
        }
        out.append(ctx.arena, f) catch return null;
    }
    return out.items;
}

fn filter(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| {
        if (!std.ascii.eqlIgnoreCase(w, "none")) return false;
        ctx.style.filters = &.{};
        return true;
    }
    ctx.style.filters = filterList(ctx, t) orelse return false;
    return true;
}

/// The blur of a backdrop's filters; the others have nothing to work on.
fn backdropFilter(ctx: *Ctx, t: []const Token) bool {
    ctx.style.backdrop_blur = 0;
    if (values.ident(t)) |w| return std.ascii.eqlIgnoreCase(w, "none");
    const list = filterList(ctx, t) orelse return false;
    for (list) |f| if (f.kind == .blur) {
        ctx.style.backdrop_blur = f.amount;
    };
    return true;
}
