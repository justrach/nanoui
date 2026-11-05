//! Applying a property's value to a `Style`: the dispatch, and the simple
//! keyword properties. `apply` returns false for a value it cannot read, and
//! then changes nothing, which is what lets a later fallback declaration fail
//! harmlessly and `@supports` ask. CSS-wide keywords are handled by the cascade.
const std = @import("std");
const style = @import("style.zig");
const prop = @import("prop.zig");
const values = @import("values.zig");
const box = @import("properties_box.zig");
const text = @import("properties_text.zig");
const paint = @import("properties_paint.zig");
const layout = @import("properties_layout.zig");
const effects = @import("properties_effects.zig");
const motion = @import("properties_motion.zig");
const svg = @import("properties_svg.zig");
const flow = @import("properties_flow.zig");

const Prop = prop.Prop;
const Ctx = values.Ctx;
const Cur = values.Cur;
const Token = values.Token;
const Style = style.Style;

/// Sets `field` when the value is one keyword of its enum.
fn setKw(comptime T: type, field: *T, t: []const Token) bool {
    field.* = values.keywordOf(T, t) orelse return false;
    return true;
}

pub fn apply(ctx: *Ctx, p: Prop, t: []const Token) bool {
    if (t.len == 0) return false;
    const s = ctx.style;
    if (svg.apply(ctx, p, t)) |r| return r;
    if (box.apply(ctx, p, t)) |r| return r;
    if (text.apply(ctx, p, t)) |r| return r;
    if (paint.apply(ctx, p, t)) |r| return r;
    if (effects.apply(ctx, p, t)) |r| return r;
    if (motion.apply(ctx, p, t)) |r| return r;
    if (layout.apply(ctx, p, t)) |r| return r;
    if (flow.apply(ctx, p, t)) |r| return r;
    return switch (p) {
        .custom, .all => false,
        .display => display(s, t),
        .position => setKw(style.Position, &s.position, t),
        .float => setKw(style.Float, &s.float, inlineSide(t)),
        .clear => setKw(style.Clear, &s.clear, inlineSide(t)),
        .box_sizing => setKw(style.BoxSizing, &s.box_sizing, t),
        .visibility => setKw(style.Visibility, &s.visibility, t),
        .opacity => opacity(ctx, t),
        .z_index => zIndex(ctx, t),
        .overflow => overflow(s, t),
        .overflow_x => overflowOne(&s.overflow_x, t),
        .overflow_y => overflowOne(&s.overflow_y, t),
        .cursor => cursor(s, t),
        .pointer_events => {
            const w = values.ident(t) orelse return false;
            s.pointer_events = !std.ascii.eqlIgnoreCase(w, "none");
            return true;
        },
        .aspect_ratio => aspectRatio(ctx, t),
        .object_fit => setKw(style.ObjectFit, &s.object_fit, t),
        .object_position => objectPosition(ctx, t),
        .color_scheme => colorScheme(ctx, t),
        // Known, with no effect on a `Style`.
        else => @backingInt(p) >= @backingInt(Prop.accent_color) or p == .text_decoration_style or p == .text_decoration_thickness,
    };
}

/// `float: inline-start` and kin, as if the text ran left to right.
fn inlineSide(t: []const Token) []const Token {
    const w = values.ident(t) orelse return t;
    if (std.ascii.eqlIgnoreCase(w, "inline-start")) return &left_tok;
    if (std.ascii.eqlIgnoreCase(w, "inline-end")) return &right_tok;
    return t;
}

const left_tok = [_]Token{.{ .kind = .ident, .text = "left" }};
const right_tok = [_]Token{.{ .kind = .ident, .text = "right" }};

fn display(s: *Style, t: []const Token) bool {
    var c = Cur.of(t);
    const a = c.next() orelse return false;
    if (a.kind != .ident) return false;
    const b = c.next();
    if (b) |second| {
        if (second.kind != .ident or !c.atEnd()) return false;
        return displayPair(s, a.text, second.text);
    }
    const w = a.text;
    if (std.ascii.eqlIgnoreCase(w, "flow-root")) {
        s.display = .block;
        s.flow_root = true;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(w, "ruby") or std.ascii.eqlIgnoreCase(w, "ruby-text") or std.ascii.eqlIgnoreCase(w, "ruby-base")) {
        s.display = .inline_;
        s.flow_root = false;
        return true;
    }
    const d = values.keyword(style.Display, w) orelse return false;
    s.display = d;
    s.flow_root = false;
    return true;
}

/// The two-value forms: `inline flex`, `block flow-root`, `list-item block`.
fn displayPair(s: *Style, a: []const u8, b: []const u8) bool {
    const eq = std.ascii.eqlIgnoreCase;
    var outer = a;
    var inner = b;
    if (eq(a, "flow") or eq(a, "flow-root") or eq(a, "flex") or eq(a, "grid") or eq(a, "table")) {
        outer = b;
        inner = a;
    }
    if (eq(outer, "list-item") or eq(inner, "list-item")) {
        s.display = .list_item;
        s.flow_root = false;
        return true;
    }
    const is_inline = eq(outer, "inline");
    if (!is_inline and !eq(outer, "block")) return false;
    s.flow_root = false;
    if (eq(inner, "flow")) {
        s.display = if (is_inline) .inline_ else .block;
    } else if (eq(inner, "flow-root")) {
        s.display = if (is_inline) .inline_block else .block;
        s.flow_root = true;
    } else if (eq(inner, "flex")) {
        s.display = if (is_inline) .inline_flex else .flex;
    } else if (eq(inner, "grid")) {
        s.display = if (is_inline) .inline_grid else .grid;
    } else if (eq(inner, "table")) {
        s.display = if (is_inline) .inline_table else .table;
    } else return false;
    return true;
}

fn opacity(ctx: *Ctx, t: []const Token) bool {
    if (values.single(t)) |a| if (a.kind == .percentage) {
        ctx.style.opacity = std.math.clamp(a.num / 100, 0, 1);
        return true;
    };
    const n = values.numberOf(ctx, t) orelse return false;
    ctx.style.opacity = std.math.clamp(n, 0, 1);
    return true;
}

fn zIndex(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| {
        if (!std.ascii.eqlIgnoreCase(w, "auto")) return false;
        ctx.style.z_index = null;
        return true;
    }
    const n = values.numberOf(ctx, t) orelse return false;
    const z: i32 = @intFromFloat(std.math.clamp(n, -2e9, 2e9));
    ctx.style.z_index = z;
    return true;
}

fn overflowWord(w: []const u8) ?style.Overflow {
    if (std.ascii.eqlIgnoreCase(w, "overlay")) return .auto;
    return values.keyword(style.Overflow, w);
}

fn overflow(s: *Style, t: []const Token) bool {
    var c = Cur.of(t);
    const a = c.next() orelse return false;
    if (a.kind != .ident) return false;
    const x = overflowWord(a.text) orelse return false;
    var y = x;
    if (c.next()) |b| {
        if (b.kind != .ident or !c.atEnd()) return false;
        y = overflowWord(b.text) orelse return false;
    }
    s.overflow_x = x;
    s.overflow_y = y;
    return true;
}

fn overflowOne(field: *style.Overflow, t: []const Token) bool {
    const w = values.ident(t) orelse return false;
    field.* = overflowWord(w) orelse return false;
    return true;
}

fn cursor(s: *Style, t: []const Token) bool {
    // `url(x) 2 2, pointer`: the keyword is last.
    var c = Cur.of(t);
    var last: ?Token = null;
    while (c.next()) |k| last = k;
    const k = last orelse return false;
    if (k.kind != .ident) return false;
    const w = k.text;
    const eq = std.ascii.eqlIgnoreCase;
    s.cursor = if (values.keyword(style.Cursor, w)) |v| v else if (eq(w, "grabbing") or eq(w, "move") or eq(w, "all-scroll"))
        .grab
    else if (eq(w, "ew-resize") or eq(w, "e-resize") or eq(w, "w-resize") or eq(w, "col-resize"))
        .col_resize
    else if (eq(w, "ns-resize") or eq(w, "n-resize") or eq(w, "s-resize"))
        .row_resize
    else if (eq(w, "vertical-text"))
        .text
    else if (eq(w, "no-drop"))
        .not_allowed
    else if (eq(w, "none") or eq(w, "wait") or eq(w, "progress") or eq(w, "help") or eq(w, "crosshair") or eq(w, "cell") or eq(w, "copy") or eq(w, "alias") or eq(w, "context-menu") or eq(w, "zoom-in") or eq(w, "zoom-out") or eq(w, "nesw-resize") or eq(w, "nwse-resize") or eq(w, "ne-resize") or eq(w, "nw-resize") or eq(w, "se-resize") or eq(w, "sw-resize"))
        .default
    else
        return false;
    return true;
}

fn aspectRatio(ctx: *Ctx, t: []const Token) bool {
    var c = Cur.of(t);
    var auto_seen = c.takeIdent("auto");
    if (c.atEnd()) {
        if (!auto_seen) return false;
        ctx.style.aspect_ratio = 0;
        return true;
    }
    const a = values.numberAt(ctx, &c) orelse return false;
    var ratio = a;
    if (c.takeDelim('/')) {
        const b = values.numberAt(ctx, &c) orelse return false;
        if (b == 0) return false;
        ratio = a / b;
    }
    if (c.takeIdent("auto")) auto_seen = true;
    ctx.style.aspect_auto = auto_seen;
    if (!c.atEnd()) return false;
    ctx.style.aspect_ratio = ratio;
    return true;
}

/// Written as `background-position` is, and read the same way.
fn objectPosition(ctx: *Ctx, t: []const Token) bool {
    const s = ctx.style;
    const saved = [4]f32{ s.background_x, s.background_y, s.background_x_px, s.background_y_px };
    defer {
        s.background_x = saved[0];
        s.background_y = saved[1];
        s.background_x_px = saved[2];
        s.background_y_px = saved[3];
    }
    if (!paint.position(ctx, t)) return false;
    s.object_x = s.background_x;
    s.object_y = s.background_y;
    s.object_x_px = s.background_x_px;
    s.object_y_px = s.background_y_px;
    return true;
}

fn colorScheme(ctx: *Ctx, t: []const Token) bool {
    var c = Cur.of(t);
    var light = false;
    var dark = false;
    var any = false;
    while (c.next()) |k| {
        if (k.kind != .ident) return false;
        any = true;
        if (k.isIdent("light")) light = true;
        if (k.isIdent("dark")) dark = true;
    }
    if (!any) return false;
    // Not asking for dark (`normal`, `light`, `only light`) is light.
    ctx.style.dark_scheme = dark and (!light or ctx.viewport_dark);
    return true;
}
