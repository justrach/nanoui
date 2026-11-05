//! Color and text; the font's own properties are in `properties_font.zig`.
const std = @import("std");
const fonts = @import("properties_font.zig");
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
        .font => fonts.font(ctx, t),
        .font_size => fonts.fontSize(ctx, t),
        .font_family => fonts.fontFamily(ctx, t),
        .font_weight => fonts.fontWeight(ctx, t),
        .font_style => fonts.fontStyle(s, t),
        .font_variant, .font_variant_numeric => fonts.fontVariant(s, t),
        .font_stretch => fonts.fontStretch(s, t),
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
        .line_break => lineBreak(s, t),
        .overflow_wrap, .word_wrap => overflowWrap(s, t),
        .tab_size => tabSize(ctx, t),
        else => null,
    };
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

/// Only `anywhere` changes where text here breaks; the others are about CJK rules.
fn lineBreak(s: *Style, t: []const Token) bool {
    const w = values.ident(t) orelse return false;
    s.line_break_anywhere = std.ascii.eqlIgnoreCase(w, "anywhere");
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
