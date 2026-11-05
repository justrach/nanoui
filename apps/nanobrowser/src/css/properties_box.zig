//! The box: sizes, margins, padding, offsets, borders, radii and outline, with
//! their shorthands and logical forms (written as if vertical text did not
//! exist: block is top to bottom, inline follows `direction`).
const std = @import("std");
const style = @import("style.zig");
const prop = @import("prop.zig");
const values = @import("values.zig");
const colors = @import("colors.zig");

const Prop = prop.Prop;
const Ctx = values.Ctx;
const Cur = values.Cur;
const Token = values.Token;
const Len = style.Len;
const Style = style.Style;
const Border = style.Border;

/// What a null from `apply` means: not one of this file's properties.
pub fn apply(ctx: *Ctx, p: Prop, t: []const Token) ?bool {
    const s = ctx.style;
    const rtl = s.rtl;
    return switch (p) {
        .width, .inline_size => size(ctx, &s.width, t, false),
        .height, .block_size => size(ctx, &s.height, t, false),
        .min_width, .min_inline_size => size(ctx, &s.min_width, t, false),
        .min_height, .min_block_size => size(ctx, &s.min_height, t, false),
        .max_width, .max_inline_size => size(ctx, &s.max_width, t, true),
        .max_height, .max_block_size => size(ctx, &s.max_height, t, true),

        .margin => four(ctx, .{ &s.margin_top, &s.margin_right, &s.margin_bottom, &s.margin_left }, t, true),
        .margin_top, .margin_block_start => one(ctx, &s.margin_top, t, true),
        .margin_right => one(ctx, &s.margin_right, t, true),
        .margin_bottom, .margin_block_end => one(ctx, &s.margin_bottom, t, true),
        .margin_left => one(ctx, &s.margin_left, t, true),
        .margin_inline => pair(ctx, &s.margin_left, &s.margin_right, t, true, rtl),
        .margin_block => pair(ctx, &s.margin_top, &s.margin_bottom, t, true, false),
        .margin_inline_start => one(ctx, if (rtl) &s.margin_right else &s.margin_left, t, true),
        .margin_inline_end => one(ctx, if (rtl) &s.margin_left else &s.margin_right, t, true),

        .padding => four(ctx, .{ &s.padding_top, &s.padding_right, &s.padding_bottom, &s.padding_left }, t, false),
        .padding_top, .padding_block_start => one(ctx, &s.padding_top, t, false),
        .padding_right => one(ctx, &s.padding_right, t, false),
        .padding_bottom, .padding_block_end => one(ctx, &s.padding_bottom, t, false),
        .padding_left => one(ctx, &s.padding_left, t, false),
        .padding_inline => pair(ctx, &s.padding_left, &s.padding_right, t, false, rtl),
        .padding_block => pair(ctx, &s.padding_top, &s.padding_bottom, t, false, false),
        .padding_inline_start => one(ctx, if (rtl) &s.padding_right else &s.padding_left, t, false),
        .padding_inline_end => one(ctx, if (rtl) &s.padding_left else &s.padding_right, t, false),

        .top, .inset_block_start => one(ctx, &s.top, t, true),
        .right => one(ctx, &s.right, t, true),
        .bottom, .inset_block_end => one(ctx, &s.bottom, t, true),
        .left => one(ctx, &s.left, t, true),
        .inset => four(ctx, .{ &s.top, &s.right, &s.bottom, &s.left }, t, true),
        .inset_inline => pair(ctx, &s.left, &s.right, t, true, rtl),
        .inset_block => pair(ctx, &s.top, &s.bottom, t, true, false),
        .inset_inline_start => one(ctx, if (rtl) &s.right else &s.left, t, true),
        .inset_inline_end => one(ctx, if (rtl) &s.left else &s.right, t, true),

        .border => borderAll(ctx, t),
        .border_top, .border_block_start => borderSide(ctx, &.{&s.border_top}, t),
        .border_right => borderSide(ctx, &.{&s.border_right}, t),
        .border_bottom, .border_block_end => borderSide(ctx, &.{&s.border_bottom}, t),
        .border_left => borderSide(ctx, &.{&s.border_left}, t),
        .border_inline => borderSide(ctx, &.{ &s.border_left, &s.border_right }, t),
        .border_block => borderSide(ctx, &.{ &s.border_top, &s.border_bottom }, t),
        .border_inline_start => borderSide(ctx, &.{if (rtl) &s.border_right else &s.border_left}, t),
        .border_inline_end => borderSide(ctx, &.{if (rtl) &s.border_left else &s.border_right}, t),
        .border_width => widths(ctx, .{ &s.border_top, &s.border_right, &s.border_bottom, &s.border_left }, t),
        .border_style => styles(.{ &s.border_top, &s.border_right, &s.border_bottom, &s.border_left }, t),
        .border_color => borderColors(ctx, .{ &s.border_top, &s.border_right, &s.border_bottom, &s.border_left }, t),
        .border_top_width => width1(ctx, &s.border_top, t),
        .border_right_width => width1(ctx, &s.border_right, t),
        .border_bottom_width => width1(ctx, &s.border_bottom, t),
        .border_left_width => width1(ctx, &s.border_left, t),
        .border_top_style => style1(&s.border_top, t),
        .border_right_style => style1(&s.border_right, t),
        .border_bottom_style => style1(&s.border_bottom, t),
        .border_left_style => style1(&s.border_left, t),
        .border_top_color => color1(ctx, &s.border_top, t),
        .border_right_color => color1(ctx, &s.border_right, t),
        .border_bottom_color => color1(ctx, &s.border_bottom, t),
        .border_left_color => color1(ctx, &s.border_left, t),
        .border_inline_width => widths(ctx, .{ &s.border_left, &s.border_right, &s.border_left, &s.border_right }, t),
        .border_block_width => widths(ctx, .{ &s.border_top, &s.border_bottom, &s.border_top, &s.border_bottom }, t),
        .border_inline_style => styles(.{ &s.border_left, &s.border_right, &s.border_left, &s.border_right }, t),
        .border_block_style => styles(.{ &s.border_top, &s.border_bottom, &s.border_top, &s.border_bottom }, t),
        .border_inline_color => borderColors(ctx, .{ &s.border_left, &s.border_right, &s.border_left, &s.border_right }, t),
        .border_block_color => borderColors(ctx, .{ &s.border_top, &s.border_bottom, &s.border_top, &s.border_bottom }, t),

        .border_radius => radiusAll(ctx, t),
        .border_top_left_radius, .border_start_start_radius => radius1(ctx, 0, t),
        .border_top_right_radius, .border_start_end_radius => radius1(ctx, 1, t),
        .border_bottom_right_radius, .border_end_end_radius => radius1(ctx, 2, t),
        .border_bottom_left_radius, .border_end_start_radius => radius1(ctx, 3, t),

        .outline => outline(ctx, t),
        .outline_width => width1(ctx, &s.outline, t),
        .outline_style => outlineStyle(s, t),
        .outline_color => outlineColor(ctx, t),
        else => null,
    };
}

fn size(ctx: *Ctx, field: *Len, t: []const Token, is_max: bool) bool {
    var c = Cur.of(t);
    const l = values.sizeAt(ctx, &c) orelse return false;
    if (!c.atEnd()) return false;
    // `none` is for the maxima, `auto` for the rest.
    if (is_max and l.kind == .auto) return false;
    if (!is_max and l.kind == .none) return false;
    field.* = l;
    return true;
}

fn lenOrAuto(ctx: *Ctx, c: *Cur, allow_auto: bool) ?Len {
    if (allow_auto and c.takeIdent("auto")) return Len.auto;
    return values.lengthAt(ctx, c);
}

fn one(ctx: *Ctx, field: *Len, t: []const Token, allow_auto: bool) bool {
    var c = Cur.of(t);
    const l = lenOrAuto(ctx, &c, allow_auto) orelse return false;
    if (!c.atEnd()) return false;
    field.* = l;
    return true;
}

/// The 1 to 4 value rule: top, right, bottom, left.
fn four(ctx: *Ctx, fields: [4]*Len, t: []const Token, allow_auto: bool) bool {
    var c = Cur.of(t);
    var v: [4]Len = undefined;
    var n: usize = 0;
    while (n < 4 and !c.atEnd()) : (n += 1) v[n] = lenOrAuto(ctx, &c, allow_auto) orelse return false;
    if (n == 0 or !c.atEnd()) return false;
    fields[0].* = v[0];
    fields[1].* = if (n > 1) v[1] else v[0];
    fields[2].* = if (n > 2) v[2] else v[0];
    fields[3].* = if (n > 3) v[3] else fields[1].*;
    return true;
}

/// The 1 or 2 value rule of a logical pair; `flip` for right-to-left text.
fn pair(ctx: *Ctx, a: *Len, b: *Len, t: []const Token, allow_auto: bool, flip: bool) bool {
    var c = Cur.of(t);
    const first = lenOrAuto(ctx, &c, allow_auto) orelse return false;
    var second = first;
    if (!c.atEnd()) second = lenOrAuto(ctx, &c, allow_auto) orelse return false;
    if (!c.atEnd()) return false;
    (if (flip) b else a).* = first;
    (if (flip) a else b).* = second;
    return true;
}

fn widthAt(ctx: *Ctx, c: *Cur) ?f32 {
    if (c.takeIdent("thin")) return 1;
    if (c.takeIdent("medium")) return 3;
    if (c.takeIdent("thick")) return 5;
    const v = values.pxAt(ctx, c) orelse return null;
    if (v < 0) return null;
    // A hairline stays visible rather than rounding to nothing.
    return if (v > 0 and v < 1) 1 else @floor(v);
}

fn styleAt(c: *Cur) ?style.BorderStyle {
    const t = c.peek() orelse return null;
    if (t.kind != .ident) return null;
    const v = values.keyword(style.BorderStyle, t.text) orelse return null;
    c.i += 1;
    return v;
}

/// `<width> || <style> || <color>`, each optional, reset when missing.
fn borderValue(ctx: *Ctx, t: []const Token) ?Border {
    var c = Cur.of(t);
    var b: Border = .{ .width = 3, .style = .none, .color = ctx.style.color };
    var seen_w = false;
    var seen_s = false;
    var seen_c = false;
    while (!c.atEnd()) {
        if (!seen_s) if (styleAt(&c)) |v| {
            b.style = v;
            seen_s = true;
            continue;
        };
        if (!seen_w) if (widthAt(ctx, &c)) |v| {
            b.width = v;
            seen_w = true;
            continue;
        };
        if (!seen_c) if (colors.at(ctx, &c)) |v| {
            b.color = v;
            seen_c = true;
            continue;
        };
        return null;
    }
    if (!seen_s and !seen_w and !seen_c) return null;
    return b;
}

fn borderAll(ctx: *Ctx, t: []const Token) bool {
    const b = borderValue(ctx, t) orelse return false;
    const s = ctx.style;
    s.border_top = b;
    s.border_right = b;
    s.border_bottom = b;
    s.border_left = b;
    return true;
}

fn borderSide(ctx: *Ctx, sides: []const *Border, t: []const Token) bool {
    const b = borderValue(ctx, t) orelse return false;
    for (sides) |x| x.* = b;
    return true;
}

fn widths(ctx: *Ctx, sides: [4]*Border, t: []const Token) bool {
    var c = Cur.of(t);
    var v: [4]f32 = undefined;
    var n: usize = 0;
    while (n < 4 and !c.atEnd()) : (n += 1) v[n] = widthAt(ctx, &c) orelse return false;
    if (n == 0 or !c.atEnd()) return false;
    sides[0].width = v[0];
    sides[1].width = if (n > 1) v[1] else v[0];
    sides[2].width = if (n > 2) v[2] else v[0];
    sides[3].width = if (n > 3) v[3] else sides[1].width;
    return true;
}

fn styles(sides: [4]*Border, t: []const Token) bool {
    var c = Cur.of(t);
    var v: [4]style.BorderStyle = undefined;
    var n: usize = 0;
    while (n < 4 and !c.atEnd()) : (n += 1) v[n] = styleAt(&c) orelse return false;
    if (n == 0 or !c.atEnd()) return false;
    sides[0].style = v[0];
    sides[1].style = if (n > 1) v[1] else v[0];
    sides[2].style = if (n > 2) v[2] else v[0];
    sides[3].style = if (n > 3) v[3] else sides[1].style;
    return true;
}

fn borderColors(ctx: *Ctx, sides: [4]*Border, t: []const Token) bool {
    var c = Cur.of(t);
    var v: [4]style.Color = undefined;
    var n: usize = 0;
    while (n < 4 and !c.atEnd()) : (n += 1) v[n] = colors.at(ctx, &c) orelse return false;
    if (n == 0 or !c.atEnd()) return false;
    sides[0].color = v[0];
    sides[1].color = if (n > 1) v[1] else v[0];
    sides[2].color = if (n > 2) v[2] else v[0];
    sides[3].color = if (n > 3) v[3] else sides[1].color;
    return true;
}

fn width1(ctx: *Ctx, b: *Border, t: []const Token) bool {
    var c = Cur.of(t);
    const v = widthAt(ctx, &c) orelse return false;
    if (!c.atEnd()) return false;
    b.width = v;
    return true;
}

fn style1(b: *Border, t: []const Token) bool {
    var c = Cur.of(t);
    const v = styleAt(&c) orelse return false;
    if (!c.atEnd()) return false;
    b.style = v;
    return true;
}

fn color1(ctx: *Ctx, b: *Border, t: []const Token) bool {
    b.color = colors.of(ctx, t) orelse return false;
    return true;
}

fn radiusAll(ctx: *Ctx, t: []const Token) bool {
    // The horizontal radii, then after any `/` the vertical ones.
    var c = Cur.of(t);
    var v: [4]Len = undefined;
    var n: usize = 0;
    while (n < 4 and !c.atEnd()) {
        if (c.peek().?.isDelim('/')) break;
        v[n] = values.lengthAt(ctx, &c) orelse return false;
        n += 1;
    }
    if (n == 0) return false;
    var h: [4]Len = v;
    var m = n;
    if (c.takeDelim('/')) {
        m = 0;
        while (m < 4 and !c.atEnd()) {
            h[m] = values.lengthAt(ctx, &c) orelse return false;
            m += 1;
        }
        if (m == 0) return false;
    }
    if (!c.atEnd()) return false;
    const pick = struct {
        fn at(l: *const [4]Len, count: usize, i: usize) Len {
            return switch (i) {
                0 => l[0],
                1 => if (count > 1) l[1] else l[0],
                2 => if (count > 2) l[2] else l[0],
                else => if (count > 3) l[3] else if (count > 1) l[1] else l[0],
            };
        }
    }.at;
    const s = ctx.style;
    for (0..4) |i| {
        const x = pick(&v, n, i);
        const y = pick(&h, m, i);
        s.radius[i] = x.px;
        s.radius_pct[i] = x.pct;
        s.radius_y[i] = y.px;
        s.radius_y_pct[i] = y.pct;
    }
    return true;
}

fn radius1(ctx: *Ctx, i: usize, t: []const Token) bool {
    var c = Cur.of(t);
    const x = values.lengthAt(ctx, &c) orelse return false;
    const y = if (c.atEnd()) x else values.lengthAt(ctx, &c) orelse return false;
    const s = ctx.style;
    s.radius[i] = x.px;
    s.radius_pct[i] = x.pct;
    s.radius_y[i] = y.px;
    s.radius_y_pct[i] = y.pct;
    return true;
}

fn outlineStyle(s: *Style, t: []const Token) bool {
    const w = values.ident(t) orelse return false;
    if (std.ascii.eqlIgnoreCase(w, "auto")) {
        s.outline.style = .solid;
        return true;
    }
    s.outline.style = values.keyword(style.BorderStyle, w) orelse return false;
    return true;
}

fn outlineColor(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| if (std.ascii.eqlIgnoreCase(w, "invert")) {
        ctx.style.outline.color = ctx.style.color;
        return true;
    };
    ctx.style.outline.color = colors.of(ctx, t) orelse return false;
    return true;
}

fn outline(ctx: *Ctx, t: []const Token) bool {
    // `auto` as a style, `invert` as a color.
    var c = Cur.of(t);
    var buf: [8]Token = undefined;
    var n: usize = 0;
    while (c.i < c.t.len and n < buf.len) : (c.i += 1) {
        var k = c.t[c.i];
        if (k.isIdent("auto")) k.text = "solid";
        if (k.isIdent("invert")) k.text = "currentcolor";
        buf[n] = k;
        n += 1;
    }
    ctx.style.outline = borderValue(ctx, buf[0..n]) orelse return false;
    return true;
}
