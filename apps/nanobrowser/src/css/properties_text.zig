//! Fonts, color and text. A font is reduced to what `Style` holds: size,
//! weight, italic, and which of three families (sans, serif, mono) it means.
const std = @import("std");
const style = @import("style.zig");
const prop = @import("prop.zig");
const values = @import("values.zig");
const colors = @import("colors.zig");

const Prop = prop.Prop;
const Ctx = values.Ctx;
const Cur = values.Cur;
const Token = values.Token;
const Style = style.Style;

pub fn apply(ctx: *Ctx, p: Prop, t: []const Token) ?bool {
    const s = ctx.style;
    return switch (p) {
        .color => {
            s.color = colors.of(ctx, t) orelse return false;
            return true;
        },
        .font => font(ctx, t),
        .font_size => fontSize(ctx, t),
        .font_family => fontFamily(s, t),
        .font_weight => fontWeight(ctx, t),
        .font_style => fontStyle(s, t),
        .font_variant, .font_stretch => true,
        .line_height => lineHeight(ctx, t),
        .direction => {
            const w = values.ident(t) orelse return false;
            if (std.ascii.eqlIgnoreCase(w, "rtl")) {
                s.rtl = true;
            } else if (std.ascii.eqlIgnoreCase(w, "ltr")) {
                s.rtl = false;
            } else return false;
            return true;
        },
        .letter_spacing => spacing(ctx, &s.letter_spacing, t),
        .word_spacing => spacing(ctx, &s.word_spacing, t),
        .text_align => textAlign(s, t),
        .text_indent => {
            s.text_indent = values.lengthOf(ctx, t) orelse return false;
            return true;
        },
        .white_space => whiteSpace(s, t),
        .white_space_collapse => whiteSpaceCollapse(s, t),
        .text_wrap, .text_wrap_mode => textWrap(s, t),
        .text_transform => {
            // `full-width` and the rest have no effect here.
            const w = values.ident(t) orelse return false;
            s.text_transform = values.keyword(style.TextTransform, w) orelse .none;
            return true;
        },
        .list_style => listStyle(s, t),
        .list_style_type => listType(s, t),
        .list_style_position => listPosition(s, t),
        .list_style_image => true,
        .text_decoration => textDecoration(ctx, t),
        .text_decoration_line => decorationLine(s, t),
        .text_decoration_color => {
            s.text_decoration_color = colors.of(ctx, t) orelse return false;
            return true;
        },
        .vertical_align => verticalAlign(ctx, t),
        .text_overflow => {
            const w = values.single(t) orelse return true; // the two-value form is not honoured
            s.text_overflow_ellipsis = w.isIdent("ellipsis");
            return true;
        },
        .border_collapse => {
            const w = values.ident(t) orelse return false;
            s.border_collapse = std.ascii.eqlIgnoreCase(w, "collapse");
            return true;
        },
        .border_spacing => borderSpacing(ctx, t),
        .table_layout => {
            const w = values.ident(t) orelse return false;
            s.table_fixed = std.ascii.eqlIgnoreCase(w, "fixed");
            return true;
        },
        .caption_side => {
            const w = values.ident(t) orelse return false;
            s.caption_bottom = std.ascii.eqlIgnoreCase(w, "bottom") or std.ascii.eqlIgnoreCase(w, "block-end");
            return true;
        },
        .word_break => wordBreak(s, t),
        .overflow_wrap, .word_wrap => overflowWrap(s, t),
        .tab_size => tabSize(ctx, t),
        else => null,
    };
}

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

fn fontSize(ctx: *Ctx, t: []const Token) bool {
    ctx.style.font_size = sizeValue(ctx, t) orelse return false;
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

fn fontWeight(ctx: *Ctx, t: []const Token) bool {
    if (values.numberOf(ctx, t)) |n| {
        if (n < 1 or n > 1000) return false;
        ctx.style.font_weight = @intFromFloat(n);
        return true;
    }
    const a = values.single(t) orelse return false;
    ctx.style.font_weight = weightValue(ctx, a) orelse return false;
    return true;
}

fn fontStyle(s: *Style, t: []const Token) bool {
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

/// Reads a family list; `false` when it is not one.
fn fontFamily(s: *Style, t: []const Token) bool {
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

fn lineHeight(ctx: *Ctx, t: []const Token) bool {
    const s = ctx.style;
    if (values.ident(t)) |w| {
        if (!std.ascii.eqlIgnoreCase(w, "normal")) return false;
        s.line_height = 0;
        s.line_height_factor = 0;
        return true;
    }
    if (values.numberOf(ctx, t)) |n| {
        if (n < 0) return false;
        s.line_height_factor = n;
        s.line_height = n * s.font_size;
        // `line-height: 0` means a zero line box, not `normal`.
        if (n == 0) s.line_height = 0.0001;
        return true;
    }
    const l = values.lengthOf(ctx, t) orelse return false;
    const v = l.px + l.pct * s.font_size / 100;
    if (v < 0) return false;
    s.line_height_factor = 0;
    s.line_height = if (v == 0) 0.0001 else v;
    return true;
}

fn font(ctx: *Ctx, t: []const Token) bool {
    const s = ctx.style;
    var c = Cur.of(t);
    if (values.ident(t)) |w| {
        const sys = [_][]const u8{ "caption", "icon", "menu", "message-box", "small-caption", "status-bar" };
        for (sys) |x| if (std.ascii.eqlIgnoreCase(w, x)) {
            s.font_size = 13;
            s.font_weight = 400;
            s.italic = false;
            s.mono = false;
            s.serif = false;
            s.mono_generic = false;
            s.line_height = 0;
            s.line_height_factor = 0;
            ctx.font_size_set = true;
            return true;
        };
    }
    var weight: u16 = 400;
    var italic = false;
    // The optional words before the size.
    while (true) {
        const k = c.peek() orelse return false;
        if (k.isIdent("normal") or k.isIdent("small-caps") or isStretch(k)) {
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
    if (!fontFamily(s, c.t[c.i..])) return false;
    s.font_size = size;
    s.font_weight = weight;
    s.italic = italic;
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

fn spacing(ctx: *Ctx, field: *f32, t: []const Token) bool {
    if (values.ident(t)) |w| {
        if (!std.ascii.eqlIgnoreCase(w, "normal")) return false;
        field.* = 0;
        return true;
    }
    const l = values.lengthOf(ctx, t) orelse return false;
    field.* = l.px;
    return true;
}

fn textAlign(s: *Style, t: []const Token) bool {
    const w = values.ident(t) orelse return false;
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(w, "match-parent") or eq(w, "justify-all")) return true; // inherited already
    if (eq(w, "-webkit-center") or eq(w, "-moz-center") or eq(w, "-khtml-center")) {
        s.text_align = .center;
        s.center_children = true;
        return true;
    }
    if (eq(w, "-webkit-left") or eq(w, "-moz-left")) {
        s.text_align = .left;
    } else if (eq(w, "-webkit-right") or eq(w, "-moz-right")) {
        s.text_align = .right;
    } else {
        s.text_align = values.keyword(style.TextAlign, w) orelse return false;
    }
    s.center_children = false;
    return true;
}

fn whiteSpace(s: *Style, t: []const Token) bool {
    const w = values.ident(t) orelse {
        // `pre-wrap` as `collapse wrap` pairs.
        var c = Cur.of(t);
        const a = c.next() orelse return false;
        const b = c.next() orelse return false;
        if (a.isIdent("preserve") and b.isIdent("nowrap")) {
            s.white_space = .pre;
            return true;
        }
        if (a.isIdent("preserve") and b.isIdent("wrap")) {
            s.white_space = .pre_wrap;
            return true;
        }
        return false;
    };
    if (std.ascii.eqlIgnoreCase(w, "break-spaces")) {
        s.white_space = .pre_wrap;
        return true;
    }
    s.white_space = values.keyword(style.WhiteSpace, w) orelse return false;
    return true;
}

fn whiteSpaceCollapse(s: *Style, t: []const Token) bool {
    const w = values.ident(t) orelse return false;
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(w, "preserve") or eq(w, "break-spaces")) {
        s.white_space = if (s.white_space == .nowrap or s.white_space == .pre) .pre else .pre_wrap;
    } else if (eq(w, "collapse")) {
        s.white_space = if (s.white_space == .nowrap or s.white_space == .pre) .nowrap else .normal;
    } else if (eq(w, "preserve-breaks")) {
        s.white_space = .pre_line;
    } else return false;
    return true;
}

fn textWrap(s: *Style, t: []const Token) bool {
    var c = Cur.of(t);
    const w = c.next() orelse return false;
    if (w.kind != .ident) return false;
    if (w.isIdent("nowrap")) {
        s.white_space = if (s.white_space == .pre or s.white_space == .pre_wrap) .pre else .nowrap;
        s.text_balance = false;
    } else if (w.isIdent("wrap") or w.isIdent("balance") or w.isIdent("pretty") or w.isIdent("stable")) {
        s.white_space = if (s.white_space == .pre) .pre_wrap else if (s.white_space == .nowrap) .normal else s.white_space;
        s.text_balance = w.isIdent("balance");
    } else return false;
    return true;
}

fn listWord(w: []const u8) ?style.ListStyle {
    if (values.keyword(style.ListStyle, w)) |v| return v;
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(w, "lower-latin")) return .lower_alpha;
    if (eq(w, "upper-latin")) return .upper_alpha;
    if (eq(w, "arabic-indic") or eq(w, "armenian") or eq(w, "georgian") or eq(w, "hebrew") or eq(w, "cjk-decimal")) return .decimal;
    if (eq(w, "disclosure-open") or eq(w, "disclosure-closed")) return .disc;
    return null;
}

fn listType(s: *Style, t: []const Token) bool {
    const a = values.single(t) orelse return false;
    if (a.kind == .string) {
        s.list_style = .none;
        return true;
    }
    if (a.kind != .ident) return false;
    s.list_style = listWord(a.text) orelse return false;
    return true;
}

fn listPosition(s: *Style, t: []const Token) bool {
    const w = values.ident(t) orelse return false;
    if (std.ascii.eqlIgnoreCase(w, "inside")) {
        s.list_inside = true;
    } else if (std.ascii.eqlIgnoreCase(w, "outside")) {
        s.list_inside = false;
    } else return false;
    return true;
}

fn listStyle(s: *Style, t: []const Token) bool {
    var c = Cur.of(t);
    var ty: style.ListStyle = .disc;
    var inside = false;
    var saw_none = false;
    var saw_type = false;
    while (c.next()) |k| {
        if (k.kind == .url) continue;
        if (k.kind == .function) {
            _ = c.body();
            continue;
        }
        if (k.kind == .string) {
            ty = .none;
            saw_type = true;
            continue;
        }
        if (k.kind != .ident) return false;
        if (k.isIdent("inside")) {
            inside = true;
        } else if (k.isIdent("outside")) {
            inside = false;
        } else if (k.isIdent("none")) {
            saw_none = true;
        } else {
            ty = listWord(k.text) orelse return false;
            saw_type = true;
        }
    }
    s.list_style = if (saw_none and !saw_type) .none else ty;
    s.list_inside = inside;
    return true;
}

/// Reads the `text-decoration-line` words at `c`; null if there are none.
fn lines(c: *Cur, out: *[3]bool) bool {
    var any = false;
    while (true) {
        if (c.takeIdent("underline")) {
            out[0] = true;
        } else if (c.takeIdent("line-through")) {
            out[1] = true;
        } else if (c.takeIdent("overline")) {
            out[2] = true;
        } else if (c.takeIdent("blink")) {
            // Nobody misses it.
        } else if (c.takeIdent("none")) {
            // Sets nothing.
        } else return any;
        any = true;
    }
}

fn decorationLine(s: *Style, t: []const Token) bool {
    var c = Cur.of(t);
    var l = [3]bool{ false, false, false };
    if (!lines(&c, &l) or !c.atEnd()) return false;
    s.underline = l[0];
    s.line_through = l[1];
    s.overline = l[2];
    return true;
}

fn textDecoration(ctx: *Ctx, t: []const Token) bool {
    var c = Cur.of(t);
    var l = [3]bool{ false, false, false };
    var color: ?style.Color = null;
    var any = false;
    while (!c.atEnd()) {
        if (lines(&c, &l)) {
            any = true;
            continue;
        }
        const k = c.peek().?;
        if (k.isIdent("solid") or k.isIdent("double") or k.isIdent("dotted") or k.isIdent("dashed") or k.isIdent("wavy") or k.isIdent("auto") or k.isIdent("from-font")) {
            c.i += 1;
            any = true;
            continue;
        }
        if (colors.at(ctx, &c)) |v| {
            color = v;
            any = true;
            continue;
        }
        if (values.lengthAt(ctx, &c) != null) {
            any = true;
            continue;
        }
        return false;
    }
    if (!any) return false;
    const s = ctx.style;
    s.underline = l[0];
    s.line_through = l[1];
    s.overline = l[2];
    s.text_decoration_color = color;
    return true;
}

fn verticalAlign(ctx: *Ctx, t: []const Token) bool {
    if (values.ident(t)) |w| {
        ctx.style.vertical_align = values.keyword(style.VerticalAlign, w) orelse return false;
        return true;
    }
    // A length has no place in the enum: it reads as `baseline`.
    if (values.lengthOf(ctx, t) == null) return false;
    ctx.style.vertical_align = .baseline;
    return true;
}

fn borderSpacing(ctx: *Ctx, t: []const Token) bool {
    var c = Cur.of(t);
    const a = values.pxAt(ctx, &c) orelse return false;
    var b = a;
    if (!c.atEnd()) b = values.pxAt(ctx, &c) orelse return false;
    if (!c.atEnd()) return false;
    ctx.style.border_spacing = a;
    ctx.style.border_spacing_y = b;
    return true;
}

fn wordBreak(s: *Style, t: []const Token) bool {
    const w = values.ident(t) orelse return false;
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(w, "break-all")) {
        s.word_break_all = true;
    } else if (eq(w, "normal") or eq(w, "keep-all") or eq(w, "auto-phrase")) {
        s.word_break_all = false;
    } else if (eq(w, "break-word")) {
        s.word_break_all = false;
        s.overflow_wrap_anywhere = true;
    } else return false;
    return true;
}

fn overflowWrap(s: *Style, t: []const Token) bool {
    const w = values.ident(t) orelse return false;
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(w, "anywhere") or eq(w, "break-word")) {
        s.overflow_wrap_anywhere = true;
    } else if (eq(w, "normal")) {
        s.overflow_wrap_anywhere = false;
    } else return false;
    return true;
}

fn tabSize(ctx: *Ctx, t: []const Token) bool {
    if (values.numberOf(ctx, t)) |n| {
        if (n < 0) return false;
        ctx.style.tab_size = n;
        return true;
    }
    const l = values.lengthOf(ctx, t) orelse return false;
    // In spaces, at a typical advance of half an em.
    ctx.style.tab_size = l.px / (ctx.style.font_size * 0.5);
    return true;
}
