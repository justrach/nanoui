//! The font's properties. A font is what `Style` holds: size, weight, italic, width
//! and the family list, with what the list means (sans, serif, mono) for the
//! few places that care.
const std = @import("std");
const font_family = @import("font_family.zig");
const values = @import("values.zig");

const Ctx = values.Ctx;
const Cur = values.Cur;
const Token = values.Token;
const Style = @import("style.zig").Style;

fn fontSizeKeyword(w: []const u8, parent: f32) ?f32 {
    const m = std.StaticStringMap(f32).initComptime(.{
        .{ "xx-small", 9 },           .{ "x-small", 10 }, .{ "small", 13 },    .{ "medium", 16 },
        .{ "large", 18 },             .{ "x-large", 24 }, .{ "xx-large", 32 }, .{ "xxx-large", 48 },
        .{ "-webkit-xxx-large", 48 },
    });
    var buf: [20]u8 = undefined;
    if (w.len > buf.len) return null;
    const low = std.ascii.lowerString(&buf, w);
    if (m.get(low)) |v| return v;
    if (std.mem.eql(u8, low, "smaller")) return parent / 1.2;
    if (std.mem.eql(u8, low, "larger")) return parent * 1.2;
    return null;
}

/// Whether a size stays what it says when the family changes, as Blink's
/// `is_absolute_size`: lengths, and what's relative to a size that does.
fn isAbsolute(ctx: *const Ctx, t: []const Token) bool {
    const k = values.single(t) orelse return true;
    switch (k.kind) {
        .percentage => return ctx.parent.font_size_abs,
        .dimension => {
            const relative = [_][]const u8{ "em", "rem", "ex", "ch", "cap", "ic", "lh", "rlh" };
            for (relative) |u| if (std.ascii.eqlIgnoreCase(k.text, u)) return ctx.parent.font_size_abs;
            return true;
        },
        .ident => {
            if (k.isIdent("larger") or k.isIdent("smaller")) return ctx.parent.font_size_abs;
            return false;
        },
        else => return true,
    }
}

/// Notes what kind of size a value is.
fn noteSize(ctx: *Ctx, t: []const Token) void {
    ctx.style.font_size_abs = isAbsolute(ctx, t);
    ctx.font_size_keyword = if (values.ident(t)) |w| !std.ascii.eqlIgnoreCase(w, "larger") and !std.ascii.eqlIgnoreCase(w, "smaller") else false;
}

/// The size a value gives, relative to the parent's.
fn sizeValue(ctx: *Ctx, t: []const Token) ?f32 {
    const parent = ctx.parent.font_size;
    if (values.ident(t)) |w| return fontSizeKeyword(w, parent);
    ctx.in_font_size = true;
    defer ctx.in_font_size = false;
    const l = values.lengthOf(ctx, t) orelse return null;
    const v = l.px + l.pct * parent / 100;
    return if (v < 0) null else v;
}

pub fn fontSize(ctx: *Ctx, t: []const Token) bool {
    ctx.style.font_size = sizeValue(ctx, t) orelse return false;
    noteSize(ctx, t);
    ctx.font_size_set = true;
    return true;
}

fn weightValue(ctx: *Ctx, t: Token) ?u16 {
    if (t.kind == .number) {
        if (t.num < 1 or t.num > 1000) return null;
        return @intFromFloat(t.num);
    }
    if (t.kind != .ident) return null;
    if (t.isIdent("normal")) return 400;
    if (t.isIdent("bold")) return 700;
    const p = ctx.parent.font_weight;
    if (t.isIdent("bolder")) return if (p < 350) 400 else if (p < 550) 700 else if (p < 900) 900 else p;
    if (t.isIdent("lighter")) return if (p < 550) 100 else if (p < 750) 400 else 700;
    return null;
}

pub fn fontWeight(ctx: *Ctx, t: []const Token) bool {
    if (values.numberOf(ctx, t)) |n| {
        if (n < 1 or n > 1000) return false;
        ctx.style.font_weight = @intFromFloat(n);
        return true;
    }
    const a = values.single(t) orelse return false;
    ctx.style.font_weight = weightValue(ctx, a) orelse return false;
    return true;
}

pub fn fontStyle(s: *Style, t: []const Token) bool {
    var c = Cur.of(t);
    const a = c.next() orelse return false;
    if (a.isIdent("normal")) {
        s.italic = false;
    } else if (a.isIdent("italic") or a.isIdent("oblique")) {
        s.italic = true;
    } else return false;
    return true;
}

fn containsCi(hay: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(hay, needle) != null;
}

const Family = enum { sans, serif, mono };

/// What a family name means, when it is one known to mean anything.
fn familyKind(name: []const u8) ?Family {
    if (containsCi(name, "mono") or containsCi(name, "consol") or containsCi(name, "courier") or containsCi(name, "menlo") or containsCi(name, "monaco") or containsCi(name, " code") or containsCi(name, "inconsolata") or containsCi(name, "terminal") or containsCi(name, "lucida console")) return .mono;
    if (containsCi(name, "sans") or containsCi(name, "arial") or containsCi(name, "helvetica") or containsCi(name, "verdana") or containsCi(name, "tahoma") or containsCi(name, "segoe") or containsCi(name, "roboto") or containsCi(name, "system-ui") or containsCi(name, "-apple-system") or containsCi(name, "blinkmacsystemfont") or containsCi(name, "inter") or containsCi(name, "geneva") or containsCi(name, "trebuchet") or containsCi(name, "calibri")) return .sans;
    if (containsCi(name, "serif") or containsCi(name, "georgia") or containsCi(name, "times") or containsCi(name, "cambria") or containsCi(name, "palatino") or containsCi(name, "garamond") or containsCi(name, "libertine") or containsCi(name, "baskerville") or containsCi(name, "didot") or containsCi(name, "antiqua") or containsCi(name, "merriweather") or containsCi(name, "lora") or containsCi(name, "playfair") or containsCi(name, "charter") or containsCi(name, "iowan")) return .serif;
    return null;
}

/// `font-variant` and `font-variant-numeric`: what's kept of them moves digits.
pub fn fontVariant(s: *Style, t: []const Token) bool {
    var tabular = false;
    for (t) |k| {
        if (k.isIdent("tabular-nums")) tabular = true;
    }
    s.tabular = tabular;
    return true;
}

fn stretchKeyword(k: Token) ?u16 {
    const m = std.StaticStringMap(u16).initComptime(.{
        .{ "ultra-condensed", 50 }, .{ "extra-condensed", 62 }, .{ "condensed", 75 },       .{ "semi-condensed", 87 }, .{ "normal", 100 },
        .{ "semi-expanded", 112 },  .{ "expanded", 125 },       .{ "extra-expanded", 150 }, .{ "ultra-expanded", 200 },
    });
    if (k.kind != .ident) return null;
    var buf: [16]u8 = undefined;
    if (k.text.len > buf.len) return null;
    return m.get(std.ascii.lowerString(&buf, k.text));
}

pub fn fontStretch(s: *Style, t: []const Token) bool {
    const k = values.single(t) orelse return false;
    if (k.kind == .percentage and k.num >= 0) {
        s.font_stretch = @intFromFloat(@min(k.num, 1000));
        return true;
    }
    s.font_stretch = stretchKeyword(k) orelse return false;
    return true;
}

/// Reads a family list; `false` when it is not one.
pub fn fontFamily(ctx: *Ctx, t: []const Token) bool {
    const s = ctx.style;
    const list = (font_family.resolve(ctx.arena, ctx.fonts, ctx.gpa orelse ctx.arena, t) catch return false) orelse return false;
    s.font_family = list;
    var c = Cur.of(t);
    var kind: ?Family = null;
    var count: usize = 0;
    var bare_monospace = false;
    while (!c.atEnd()) {
        const part = c.untilComma();
        var pc = Cur.of(part);
        var buf: [96]u8 = undefined;
        var n: usize = 0;
        var parts: usize = 0;
        while (pc.next()) |k| {
            if (k.kind != .ident and k.kind != .string) return false;
            parts += 1;
            if (n > 0 and n < buf.len) {
                buf[n] = ' ';
                n += 1;
            }
            const m = @min(k.text.len, buf.len - n);
            @memcpy(buf[n .. n + m], k.text[0..m]);
            n += m;
        }
        if (parts == 0) return false;
        count += 1;
        const name = buf[0..n];
        if (count == 1 and std.ascii.eqlIgnoreCase(name, "monospace")) bare_monospace = true;
        if (kind == null) kind = familyKind(name);
    }
    if (count == 0) return false;
    const k = kind orelse .sans;
    s.mono = k == .mono;
    s.serif = k == .serif;
    s.mono_generic = bare_monospace and count == 1;
    return true;
}

pub fn font(ctx: *Ctx, t: []const Token) bool {
    const s = ctx.style;
    var c = Cur.of(t);
    if (values.ident(t)) |w| {
        const sys = [_][]const u8{ "caption", "icon", "menu", "message-box", "small-caption", "status-bar" };
        for (sys) |x| if (std.ascii.eqlIgnoreCase(w, x)) {
            s.font_size = 13;
            s.font_size_abs = true;
            s.font_weight = 400;
            s.italic = false;
            s.mono = false;
            s.serif = false;
            s.mono_generic = false;
            s.font_family = "system-ui," ++ font_family.standard;
            s.font_stretch = 100;
            s.line_height = 0;
            s.line_height_factor = 0;
            ctx.font_size_set = true;
            return true;
        };
    }
    var weight: u16 = 400;
    var italic = false;
    var stretch: u16 = 100;
    // The optional words before the size.
    while (true) {
        const k = c.peek() orelse return false;
        if (k.isIdent("normal") or k.isIdent("small-caps")) {
            c.i += 1;
            continue;
        }
        if (isStretch(k)) {
            stretch = stretchKeyword(k) orelse 100;
            c.i += 1;
            continue;
        }
        if (k.isIdent("italic") or k.isIdent("oblique")) {
            italic = true;
            c.i += 1;
            continue;
        }
        if (k.kind == .number and k.num != 0) {
            weight = weightValue(ctx, k) orelse return false;
            c.i += 1;
            continue;
        }
        if (k.kind == .ident) if (weightValue(ctx, k)) |w| {
            weight = w;
            c.i += 1;
            continue;
        };
        break;
    }
    // The size token.
    const size_at = c.i;
    const k = c.peek() orelse return false;
    if (k.kind == .ident and fontSizeKeyword(k.text, 16) != null) {
        c.i += 1;
    } else if (values.lengthAt(ctx, &c) == null) {
        return false;
    }
    const after_size = c.i;
    c.i = size_at;
    c.skipWs();
    const size = sizeValue(ctx, c.t[c.i..after_size]) orelse return false;
    c.i = after_size;
    // `/line-height`.
    var factor: f32 = 0;
    var line: f32 = 0;
    if (c.takeDelim('/')) {
        const lh = c.peek() orelse return false;
        if (lh.isIdent("normal")) {
            c.i += 1;
        } else if (lh.kind == .number) {
            c.i += 1;
            factor = lh.num;
            line = lh.num * size;
        } else {
            ctx.em_override = size;
            defer ctx.em_override = 0;
            const l = values.lengthAt(ctx, &c) orelse return false;
            line = l.px + l.pct * size / 100;
        }
    }
    if (c.atEnd()) return false;
    if (!fontFamily(ctx, c.t[c.i..])) return false;
    noteSize(ctx, c.t[size_at..after_size]);
    s.font_size = size;
    s.font_weight = weight;
    s.italic = italic;
    s.font_stretch = stretch;
    s.line_height = line;
    s.line_height_factor = factor;
    ctx.font_size_set = true;
    return true;
}

fn isStretch(t: Token) bool {
    const l = [_][]const u8{ "ultra-condensed", "extra-condensed", "condensed", "semi-condensed", "semi-expanded", "expanded", "extra-expanded", "ultra-expanded" };
    for (l) |x| if (t.isIdent(x)) return true;
    return false;
}
