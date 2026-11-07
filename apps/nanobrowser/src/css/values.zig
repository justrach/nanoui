//! Reading property values from tokens: the cursor, lengths, numbers and the
//! context a value is computed in. Colors are in `colors.zig`, `calc()` in
//! `calc.zig`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../dom.zig");
const style = @import("style.zig");
const tk = @import("tokenizer.zig");
const calc = @import("calc.zig");

pub const Token = tk.Token;
const Len = style.Len;
const Style = style.Style;

/// What a value is computed against.
pub const Ctx = struct {
    style: *Style,
    parent: *const Style,
    /// The element's starting point: initial values, with inherited ones taken
    /// from the parent. What `unset` falls back to.
    base: *const Style,
    root_font: f32 = 16,
    vw: f32 = 1024,
    vh: f32 = 768,
    /// Told when anything reads the viewport's size: a new size then has to restyle.
    viewport_read: ?*bool = null,
    viewport_dark: bool = false,
    node: ?*dom.Node = null,
    arena: Allocator,
    /// Set by `content` when it gives a pseudo-element something to be.
    has_content: bool = false,
    font_size_set: bool = false,
    /// It was set by a keyword (`small`), which the bare `monospace` has its own sizes of.
    font_size_keyword: bool = false,
    /// `font-size` is being read: `em` means the parent's size.
    in_font_size: bool = false,
    /// `line-height: 2em` in a font shorthand, whose size is already known.
    em_override: f32 = 0,
    /// The engine's knowledge of fonts; null outside one.
    fonts: ?*@import("font_family.zig").Names = null,
    gpa: ?Allocator = null,

    pub fn em(c: *const Ctx) f32 {
        if (c.em_override > 0) return c.em_override;
        return if (c.in_font_size) c.parent.font_size else c.style.font_size;
    }
};

/// A cursor over a value's tokens.
pub const Cur = struct {
    t: []const Token,
    i: usize = 0,

    pub fn of(t: []const Token) Cur {
        return .{ .t = t };
    }

    pub fn skipWs(c: *Cur) void {
        while (c.i < c.t.len and c.t[c.i].kind == .whitespace) c.i += 1;
    }

    pub fn atEnd(c: *Cur) bool {
        c.skipWs();
        return c.i >= c.t.len;
    }

    pub fn peek(c: *Cur) ?Token {
        c.skipWs();
        return if (c.i < c.t.len) c.t[c.i] else null;
    }

    pub fn next(c: *Cur) ?Token {
        const t = c.peek() orelse return null;
        c.i += 1;
        return t;
    }

    pub fn takeIdent(c: *Cur, name: []const u8) bool {
        const t = c.peek() orelse return false;
        if (!t.isIdent(name)) return false;
        c.i += 1;
        return true;
    }

    pub fn takeComma(c: *Cur) bool {
        const t = c.peek() orelse return false;
        if (t.kind != .comma) return false;
        c.i += 1;
        return true;
    }

    pub fn takeColon(c: *Cur) bool {
        const t = c.peek() orelse return false;
        if (t.kind != .colon) return false;
        c.i += 1;
        return true;
    }

    pub fn takeDelim(c: *Cur, d: u8) bool {
        const t = c.peek() orelse return false;
        if (!t.isDelim(d)) return false;
        c.i += 1;
        return true;
    }

    /// After a function token or `(`: its contents; the cursor moves past
    /// the close.
    pub fn body(c: *Cur) []const Token {
        const start = c.i;
        var depth: u32 = 1;
        while (c.i < c.t.len) : (c.i += 1) {
            switch (c.t[c.i].kind) {
                .function, .lparen => depth += 1,
                .rparen => {
                    depth -= 1;
                    if (depth == 0) {
                        const b = c.t[start..c.i];
                        c.i += 1;
                        return b;
                    }
                },
                else => {},
            }
        }
        return c.t[start..c.i];
    }

    /// Up to the next comma at this level, or the end; moves past the comma.
    pub fn untilComma(c: *Cur) []const Token {
        const start = c.i;
        var depth: u32 = 0;
        while (c.i < c.t.len) : (c.i += 1) {
            switch (c.t[c.i].kind) {
                .function, .lparen, .lbracket => depth += 1,
                .rparen, .rbracket => depth -|= 1,
                .comma => if (depth == 0) {
                    const b = c.t[start..c.i];
                    c.i += 1;
                    return b;
                },
                else => {},
            }
        }
        return c.t[start..c.i];
    }
};

/// The token if `t` holds exactly one (apart from whitespace).
pub fn single(t: []const Token) ?Token {
    var c = Cur.of(t);
    const a = c.next() orelse return null;
    return if (c.atEnd()) a else null;
}

/// The ident if `t` is one ident.
pub fn ident(t: []const Token) ?[]const u8 {
    const a = single(t) orelse return null;
    return if (a.kind == .ident) a.text else null;
}

/// Whether `text` names `field`, an enum tag whose `_` stand for `-` and whose
/// trailing `_` is for Zig's keywords.
fn nameMatches(field: []const u8, text: []const u8) bool {
    var f = field;
    if (f.len > 0 and f[f.len - 1] == '_') f = f[0 .. f.len - 1];
    if (f.len != text.len) return false;
    for (f, text) |a, b| {
        const x: u8 = if (a == '_') '-' else a;
        if (x != std.ascii.toLower(b)) return false;
    }
    return true;
}

/// The member of enum `T` that an ident names.
pub fn keyword(comptime T: type, text: []const u8) ?T {
    const names = @typeInfo(T).@"enum".field_names;
    inline for (names) |n| if (nameMatches(n, text)) return @field(T, n);
    return null;
}

/// `keyword` on a one-ident value.
pub fn keywordOf(comptime T: type, t: []const Token) ?T {
    return keyword(T, ident(t) orelse return null);
}

/// What the font's own measures give `ex`, `ch` and `cap`, when there's a font
/// system to ask.
fn fontUnits(ctx: *const Ctx) ?@import("font_family.zig").Units {
    const n = ctx.fonts orelse return null;
    const probe = n.probe orelse return null;
    const m = probe(n.ctx orelse return null, ctx.style.font_family, ctx.em(), ctx.style.font_weight, ctx.style.italic) orelse return null;
    if (m.ch <= 0 or m.ex <= 0) return null;
    return m;
}

/// CSS pixels per unit, against the context; null for an unknown unit.
pub fn unitPx(ctx: *const Ctx, unit: []const u8) ?f32 {
    var buf: [8]u8 = undefined;
    if (unit.len > buf.len) return null;
    const u = std.ascii.lowerString(&buf, unit);
    const eql = std.mem.eql;
    if (eql(u8, u, "px")) return 1;
    if (eql(u8, u, "em")) return ctx.em();
    if (eql(u8, u, "rem")) return ctx.root_font;
    if (u.len > 1 and (u[0] == 'v' or u[1] == 'v')) if (ctx.viewport_read) |r| {
        r.* = true;
    };
    if (eql(u8, u, "vw") or eql(u8, u, "dvw") or eql(u8, u, "svw") or eql(u8, u, "lvw") or eql(u8, u, "vi")) return ctx.vw / 100;
    if (eql(u8, u, "vh") or eql(u8, u, "dvh") or eql(u8, u, "svh") or eql(u8, u, "lvh") or eql(u8, u, "vb")) return ctx.vh / 100;
    if (eql(u8, u, "vmin") or eql(u8, u, "dvmin") or eql(u8, u, "svmin") or eql(u8, u, "lvmin")) return @min(ctx.vw, ctx.vh) / 100;
    if (eql(u8, u, "vmax") or eql(u8, u, "dvmax") or eql(u8, u, "svmax") or eql(u8, u, "lvmax")) return @max(ctx.vw, ctx.vh) / 100;
    if (eql(u8, u, "cqw") or eql(u8, u, "cqi")) return cqSize(ctx, true) / 100;
    if (eql(u8, u, "cqh") or eql(u8, u, "cqb")) return cqSize(ctx, false) / 100;
    if (eql(u8, u, "cqmin")) return @min(cqSize(ctx, true), cqSize(ctx, false)) / 100;
    if (eql(u8, u, "cqmax")) return @max(cqSize(ctx, true), cqSize(ctx, false)) / 100;
    if (eql(u8, u, "ch")) return if (fontUnits(ctx)) |m| m.ch else ctx.em() * (if (ctx.style.mono) @as(f32, 0.6) else 0.5);
    if (eql(u8, u, "ex")) return if (fontUnits(ctx)) |m| m.ex else ctx.em() * 0.5;
    if (eql(u8, u, "cap")) return if (fontUnits(ctx)) |m| m.cap else ctx.em() * 0.7;
    if (eql(u8, u, "ic")) return ctx.em();
    if (eql(u8, u, "lh")) {
        const lh = ctx.style.line_height;
        return if (lh > 0) lh else ctx.em() * 1.2;
    }
    if (eql(u8, u, "rlh")) return ctx.root_font * 1.2;
    if (eql(u8, u, "pt")) return 96.0 / 72.0;
    if (eql(u8, u, "pc")) return 16;
    if (eql(u8, u, "in")) return 96;
    if (eql(u8, u, "cm")) return 96.0 / 2.54;
    if (eql(u8, u, "mm")) return 96.0 / 25.4;
    if (eql(u8, u, "q")) return 96.0 / 101.6;
    return null;
}

/// A container's content box on one axis, for cq units: the nearest that contains
/// that axis, and the viewport when there's none, or none laid out yet.
fn cqSize(ctx: *const Ctx, inline_axis: bool) f32 {
    if (ctx.viewport_read) |r| r.* = true;
    const viewport = if (inline_axis) ctx.vw else ctx.vh;
    var at = if (ctx.node) |n| n.parent else null;
    while (at) |a| : (at = a.parent) {
        const st = a.computed orelse continue;
        if (st.container_type == .size or (st.container_type == .inline_size and inline_axis)) {
            const v = if (inline_axis) a.container_w else a.container_h;
            return if (v >= 0) v else viewport;
        }
    }
    return viewport;
}

/// One length or percentage token or math function at the cursor.
pub fn lengthAt(ctx: *const Ctx, c: *Cur) ?Len {
    const t = c.peek() orelse return null;
    switch (t.kind) {
        .number => {
            if (t.num != 0) return null;
            c.i += 1;
            return Len.of(0);
        },
        .dimension => {
            const per = unitPx(ctx, t.text) orelse return null;
            c.i += 1;
            return Len.of(bounded(t.num * per));
        },
        .percentage => {
            c.i += 1;
            return .{ .pct = bounded(t.num) };
        },
        .function => {
            if (!calc.isMathFunction(t.text)) return null;
            const save = c.i;
            c.i += 1;
            const v = calc.evalFunction(ctx, t.text, c.body()) orelse {
                c.i = save;
                return null;
            };
            if (v.kind == .number) {
                if (v.num != 0) {
                    c.i = save;
                    return null;
                }
                return Len.of(0);
            }
            return .{ .px = bounded(v.px), .pct = bounded(v.pct), .math = v.math };
        },
        else => return null,
    }
}

/// Lengths past what any page means, kept where layout's arithmetic is safe.
fn bounded(v: f32) f32 {
    return std.math.clamp(v, -3.3e7, 3.3e7);
}

/// A whole value that is one length.
pub fn lengthOf(ctx: *const Ctx, t: []const Token) ?Len {
    var c = Cur.of(t);
    const l = lengthAt(ctx, &c) orelse return null;
    return if (c.atEnd()) l else null;
}

/// A length in pixels: percentages refuse. For borders, spacing, shadows.
pub fn pxAt(ctx: *const Ctx, c: *Cur) ?f32 {
    const save = c.i;
    const l = lengthAt(ctx, c) orelse return null;
    if (l.pct != 0) {
        c.i = save;
        return null;
    }
    return l.px;
}

/// A number or a math function giving one.
pub fn numberAt(ctx: *const Ctx, c: *Cur) ?f32 {
    const t = c.peek() orelse return null;
    if (t.kind == .number) {
        c.i += 1;
        return t.num;
    }
    if (t.kind == .function and calc.isMathFunction(t.text)) {
        const save = c.i;
        c.i += 1;
        const v = calc.evalFunction(ctx, t.text, c.body()) orelse {
            c.i = save;
            return null;
        };
        if (v.kind == .number) return v.num;
        c.i = save;
    }
    return null;
}

pub fn numberOf(ctx: *const Ctx, t: []const Token) ?f32 {
    var c = Cur.of(t);
    const v = numberAt(ctx, &c) orelse return null;
    return if (c.atEnd()) v else null;
}

/// A sizing keyword or length: `width`, `min-width`, `flex-basis` and kin.
pub fn sizeAt(ctx: *const Ctx, c: *Cur) ?Len {
    const t = c.peek() orelse return null;
    if (t.kind == .ident) {
        const kind: Len.Kind = keyword(Len.Kind, t.text) orelse blk: {
            if (t.isIdent("-webkit-fit-content") or t.isIdent("-moz-fit-content")) break :blk .fit_content;
            if (t.isIdent("-webkit-fill-available") or t.isIdent("-moz-available")) break :blk .stretch;
            if (t.isIdent("-moz-max-content") or t.isIdent("-webkit-max-content")) break :blk .max_content;
            if (t.isIdent("-moz-min-content") or t.isIdent("-webkit-min-content")) break :blk .min_content;
            return null;
        };
        if (kind == .length) return null;
        c.i += 1;
        return .{ .kind = kind };
    }
    return lengthAt(ctx, c);
}

/// An angle in degrees, with `c` at it.
pub fn angleAt(c: *Cur) ?f32 {
    const t = c.peek() orelse return null;
    if (t.kind == .number and t.num == 0) {
        c.i += 1;
        return 0;
    }
    if (t.kind != .dimension) return null;
    const d = angleUnit(t.text) orelse return null;
    c.i += 1;
    return t.num * d;
}

pub fn angleUnit(u: []const u8) ?f32 {
    if (std.ascii.eqlIgnoreCase(u, "deg")) return 1;
    if (std.ascii.eqlIgnoreCase(u, "rad")) return 180.0 / std.math.pi;
    if (std.ascii.eqlIgnoreCase(u, "grad")) return 0.9;
    if (std.ascii.eqlIgnoreCase(u, "turn")) return 360;
    return null;
}
