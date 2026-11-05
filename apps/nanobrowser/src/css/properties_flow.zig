//! How boxes flow beyond the box model: containers and containment, multiple
//! columns, `text-wrap: balance`, counters, and where a fragment's scroll stops.
const std = @import("std");
const style = @import("style.zig");
const prop = @import("prop.zig");
const values = @import("values.zig");

const Prop = prop.Prop;
const Ctx = values.Ctx;
const Cur = values.Cur;
const Token = values.Token;

pub fn apply(ctx: *Ctx, p: Prop, t: []const Token) ?bool {
    const s = ctx.style;
    return switch (p) {
        .container => container(ctx, t),
        .container_type => containerType(s, t),
        .container_name => containerName(ctx, t),
        .contain => contain(s, t),
        .columns => columns(ctx, t),
        .column_count => columnCount(ctx, t),
        .column_width => columnWidth(ctx, t),
        .column_span => {
            const w = values.ident(t) orelse return false;
            s.column_span_all = std.ascii.eqlIgnoreCase(w, "all");
            return true;
        },
        .content_visibility => {
            const w = values.ident(t) orelse return false;
            s.content_hidden = std.ascii.eqlIgnoreCase(w, "hidden");
            if (s.content_hidden) s.contain_size = true;
            return true;
        },
        .counter_reset => counterOps(ctx, &s.counter_reset, t, 0),
        .counter_increment => counterOps(ctx, &s.counter_increment, t, 1),
        .counter_set => counterOps(ctx, &s.counter_set, t, 0),
        .scroll_margin_top, .scroll_margin_block_start => pxInto(ctx, &s.scroll_margin_top, t),
        .scroll_padding_top, .scroll_padding_block_start => pxInto(ctx, &s.scroll_padding_top, t),
        .scroll_margin, .scroll_margin_block => firstPx(ctx, &s.scroll_margin_top, t),
        .scroll_padding, .scroll_padding_block => firstPx(ctx, &s.scroll_padding_top, t),
        else => null,
    };
}

fn containerType(s: *style.Style, t: []const Token) bool {
    const w = values.ident(t) orelse return false;
    const eq = std.ascii.eqlIgnoreCase;
    s.container_type = if (eq(w, "normal")) .normal else if (eq(w, "size")) .size else if (eq(w, "inline-size")) .inline_size else return false;
    return true;
}

fn containerName(ctx: *Ctx, t: []const Token) bool {
    var names: std.ArrayList([]const u8) = .empty;
    var c = Cur.of(t);
    while (c.next()) |k| {
        if (k.kind != .ident) return false;
        if (k.isIdent("none")) continue;
        names.append(ctx.arena, k.text) catch return false;
    }
    ctx.style.container_names = names.items;
    return true;
}

/// `container: name / type`.
fn container(ctx: *Ctx, t: []const Token) bool {
    var slash: ?usize = null;
    for (t, 0..) |k, i| if (k.isDelim('/')) {
        slash = i;
    };
    const names = t[0 .. slash orelse t.len];
    if (!containerName(ctx, names)) return false;
    ctx.style.container_type = .normal;
    if (slash) |i| return containerType(ctx.style, t[i + 1 ..]);
    return true;
}

fn contain(s: *style.Style, t: []const Token) bool {
    s.contain_size = false;
    s.contain_inline_size = false;
    s.contain_flow = false;
    var c = Cur.of(t);
    while (c.next()) |k| {
        if (k.kind != .ident) return false;
        if (k.isIdent("strict")) {
            s.contain_size = true;
            s.contain_flow = true;
        } else if (k.isIdent("content")) {
            s.contain_flow = true;
        } else if (k.isIdent("size")) {
            s.contain_size = true;
        } else if (k.isIdent("inline-size")) {
            s.contain_inline_size = true;
        } else if (k.isIdent("layout") or k.isIdent("paint")) {
            s.contain_flow = true;
        }
    }
    return true;
}

fn columnCount(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| if (std.ascii.eqlIgnoreCase(w, "auto")) {
        ctx.style.column_count = 0;
        return true;
    };
    const n = values.numberOf(ctx, t) orelse return false;
    if (n < 1) return false;
    ctx.style.column_count = @intFromFloat(@min(n, 1000));
    return true;
}

fn columnWidth(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| if (std.ascii.eqlIgnoreCase(w, "auto")) {
        ctx.style.column_width = 0;
        return true;
    };
    var c = Cur.of(t);
    const v = values.pxAt(ctx, &c) orelse return false;
    if (!c.atEnd() or v < 0) return false;
    ctx.style.column_width = v;
    return true;
}

/// `columns: width count`, in either order.
fn columns(ctx: *Ctx, t: []const Token) bool {
    var count: u16 = 0;
    var width: f32 = 0;
    var c = Cur.of(t);
    while (!c.atEnd()) {
        if (c.takeIdent("auto")) continue;
        const k = c.peek().?;
        if (k.kind == .number and k.num != 0) {
            if (k.num < 1) return false;
            count = @intFromFloat(@min(k.num, 1000));
            c.i += 1;
            continue;
        }
        width = values.pxAt(ctx, &c) orelse return false;
    }
    ctx.style.column_count = count;
    ctx.style.column_width = width;
    return true;
}

/// `name 1 other`, a number after a name being its value; `none` for no steps.
fn counterOps(ctx: *Ctx, field: *[]const style.CounterOp, t: []const Token, default: i32) bool {
    var out: std.ArrayList(style.CounterOp) = .empty;
    var c = Cur.of(t);
    while (c.next()) |k| {
        if (k.kind != .ident) return false;
        if (k.isIdent("none")) continue;
        var v = default;
        if (c.peek()) |n| if (n.kind == .number) {
            v = @intFromFloat(std.math.clamp(n.num, -1e9, 1e9));
            c.i += 1;
        };
        out.append(ctx.arena, .{ .name = k.text, .value = v }) catch return false;
    }
    field.* = out.items;
    return true;
}

fn pxInto(ctx: *Ctx, field: *f32, t: []const Token) bool {
    if (values.ident(t)) |w| if (std.ascii.eqlIgnoreCase(w, "auto")) {
        field.* = 0;
        return true;
    };
    var c = Cur.of(t);
    field.* = values.pxAt(ctx, &c) orelse return false;
    return true;
}

/// A shorthand's first value: the top, for this is all a fragment's scroll reads.
fn firstPx(ctx: *Ctx, field: *f32, t: []const Token) bool {
    return pxInto(ctx, field, t);
}
