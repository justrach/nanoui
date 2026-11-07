//! Presentational hints: the old HTML attributes that act as style
//! (`<td bgcolor>`, `<table width>`, `<font color>`). They sit between the UA
//! sheet and author rules. Old pages, Hacker News among them, are built on these.
const std = @import("std");
const dom = @import("../dom.zig");
const style = @import("style.zig");
const values = @import("values.zig");
const colors = @import("colors.zig");
const properties = @import("properties.zig");
const parser = @import("parser.zig");
const prop = @import("prop.zig");

const Node = dom.Node;
const Style = style.Style;
const Len = style.Len;
const Color = style.Color;

/// A dimension attribute: `100`, `100px`, `50%`.
fn dimension(raw: []const u8) ?Len {
    const s = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (s.len == 0) return null;
    var e: usize = 0;
    while (e < s.len and (std.ascii.isDigit(s[e]) or s[e] == '.')) : (e += 1) {}
    if (e == 0) return null;
    const v = std.fmt.parseFloat(f32, s[0..e]) catch return null;
    if (e < s.len and s[e] == '%') return .{ .pct = v };
    return Len.of(v);
}

/// The legacy color parser: names and `#rgb`, and bare hex digits.
fn legacyColor(ctx: *const values.Ctx, raw: []const u8) ?Color {
    const s = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (s.len == 0 or std.ascii.eqlIgnoreCase(s, "transparent")) return null;
    if (s[0] == '#') return colors.parseHex(s[1..]) orelse hexish(s[1..]);
    const tok = [_]values.Token{.{ .kind = .ident, .text = s }};
    if (colors.of(ctx, &tok)) |c| return c;
    return hexish(s);
}

/// Anything else, read digit by digit in the attribute's long-standing way.
fn hexish(s: []const u8) ?Color {
    if (s.len == 3 or s.len == 6) if (colors.parseHex(s)) |c| return c;
    var buf: [12]u8 = undefined;
    var n: usize = 0;
    for (s) |c| {
        if (n >= buf.len) break;
        buf[n] = if (std.ascii.isHex(c)) c else '0';
        n += 1;
    }
    if (n == 0) return null;
    while (n % 3 != 0) : (n += 1) buf[n] = '0';
    const third = n / 3;
    const pick = struct {
        fn at(b: []const u8) f32 {
            const hi = std.fmt.charToDigit(b[0], 16) catch 0;
            const lo = if (b.len > 1) std.fmt.charToDigit(b[1], 16) catch 0 else 0;
            return @as(f32, @floatFromInt(hi * 16 + lo)) / 255;
        }
    };
    return .{ .r = pick.at(buf[0..third]), .g = pick.at(buf[third .. 2 * third]), .b = pick.at(buf[2 * third .. n]) };
}

fn eqCi(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn alignText(s: *Style, v: []const u8) void {
    s.center_children = false;
    if (eqCi(v, "left")) s.text_align = .left;
    if (eqCi(v, "right")) s.text_align = .right;
    if (eqCi(v, "center") or eqCi(v, "middle")) {
        s.text_align = .center;
        s.center_children = true;
    }
    if (eqCi(v, "justify")) s.text_align = .justify;
}

fn fontSizeAttr(raw: []const u8) ?f32 {
    const t = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (t.len == 0) return null;
    const sizes = [_]f32{ 10, 13, 16, 18, 24, 32, 48 };
    var rel: i32 = 0;
    var d = t;
    if (t[0] == '+') {
        rel = 1;
        d = t[1..];
    } else if (t[0] == '-') {
        rel = -1;
        d = t[1..];
    }
    const n = std.fmt.parseInt(i32, d, 10) catch return null;
    const idx = if (rel == 0) n else 3 + rel * n;
    return sizes[@intCast(std.math.clamp(idx, 1, 7) - 1)];
}

/// Text style hints, applied in the cascade's early passes.
pub fn early(node: *Node, ctx: *values.Ctx, phase: u2) void {
    if (node.ns == .svg and phase == 1) if (node.attr("color")) |v| presentation(ctx, "color", v);
    if (node.ns != .html or node.attrs.items.len == 0) return;
    const s = ctx.style;
    if (phase == 0) {
        if (node.attr("dir")) |d| {
            if (eqCi(d, "rtl")) s.rtl = true;
            if (eqCi(d, "ltr")) s.rtl = false;
        }
        if (node.isTag("font")) {
            if (node.attr("size")) |v| if (fontSizeAttr(v)) |px| {
                s.font_size = px;
                ctx.font_size_set = true;
            };
            if (node.attr("face")) |face| {
                // The attribute is a list as `font-family` is, in plain text.
                var tok: [32]values.Token = undefined;
                var n: usize = 0;
                var names = std.mem.splitScalar(u8, face, ',');
                while (names.next()) |name| {
                    if (n + 2 > tok.len) break;
                    if (n > 0) {
                        tok[n] = .{ .kind = .comma };
                        n += 1;
                    }
                    tok[n] = .{ .kind = .string, .text = std.mem.trim(u8, name, " \t\r\n") };
                    n += 1;
                }
                _ = properties.apply(ctx, .font_family, tok[0..n]);
            }
        }
    } else if (phase == 1) {
        if (node.isTag("font")) if (node.attr("color")) |v| if (legacyColor(ctx, v)) |c| {
            s.color = c;
        };
        if (node.isTag("body")) if (node.attr("text")) |v| if (legacyColor(ctx, v)) |c| {
            s.color = c;
        };
    }
}

fn tableAncestor(node: *const Node) ?*const Node {
    var at = node.parent;
    while (at) |n| : (at = n.parent) if (n.isTag("table")) return n;
    return null;
}

/// Box hints, applied before author rules in the last pass.
pub fn late(node: *Node, ctx: *values.Ctx) void {
    if (node.ns == .svg) return svgAttributes(node, ctx);
    if (node.ns != .html) return;
    const s = ctx.style;
    const tag = node.tag;
    const is = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;
    const is_cell = is(tag, "td") or is(tag, "th");
    // Cell padding comes from the table, so a cell has a hint with no attribute.
    if (is_cell) if (tableAncestor(node)) |t| {
        if (t.attr("cellpadding")) |v| if (dimension(v)) |d| {
            s.padding_top = d;
            s.padding_right = d;
            s.padding_bottom = d;
            s.padding_left = d;
        };
        if (t.attr("border")) |v| if (dimension(v)) |d| if (d.px > 0) {
            const b: style.Border = .{ .width = 1, .style = .inset, .color = .{ .r = 0.5, .g = 0.5, .b = 0.5 } };
            s.border_top = b;
            s.border_right = b;
            s.border_bottom = b;
            s.border_left = b;
        };
    };
    if (node.attrs.items.len == 0) return;
    if (node.attr("bgcolor")) |v| if (legacyColor(ctx, v)) |c| {
        s.background = c;
    };
    if (node.attr("background")) |v| if (is(tag, "body") or is_cell or is(tag, "table")) {
        s.background_image = v;
    };
    if (node.attr("width")) |v| if (widthHolder(tag)) if (dimension(v)) |d| {
        s.width = d;
    };
    if (node.attr("height")) |v| if (heightHolder(tag)) if (dimension(v)) |d| {
        s.height = d;
    };
    if (node.attr("align")) |v| {
        if (is_cell or is(tag, "tr") or is(tag, "thead") or is(tag, "tbody") or is(tag, "tfoot") or is(tag, "div") or is(tag, "p") or is(tag, "h1") or is(tag, "h2") or is(tag, "h3") or is(tag, "h4") or is(tag, "h5") or is(tag, "h6") or is(tag, "caption")) {
            alignText(s, v);
        } else if (is(tag, "table")) {
            if (eqCi(v, "center")) {
                s.margin_left = Len.auto;
                s.margin_right = Len.auto;
            } else if (eqCi(v, "left")) {
                s.float = .left;
            } else if (eqCi(v, "right")) {
                s.float = .right;
            }
        } else if (is(tag, "img") or is(tag, "object") or is(tag, "embed") or is(tag, "iframe") or is(tag, "input")) {
            if (eqCi(v, "left")) s.float = .left;
            if (eqCi(v, "right")) s.float = .right;
            if (eqCi(v, "top")) s.vertical_align = .top;
            if (eqCi(v, "middle") or eqCi(v, "absmiddle")) s.vertical_align = .middle;
            if (eqCi(v, "bottom")) s.vertical_align = .baseline;
        }
    }
    if (node.attr("valign")) |v| {
        if (eqCi(v, "top")) s.vertical_align = .top;
        if (eqCi(v, "middle")) s.vertical_align = .middle;
        if (eqCi(v, "bottom")) s.vertical_align = .bottom;
        if (eqCi(v, "baseline")) s.vertical_align = .baseline;
    }
    if (is_cell and node.hasAttr("nowrap")) s.white_space = .nowrap;
    if (is(tag, "table")) tableHints(node, s);
    if (is(tag, "ol") or is(tag, "ul") or is(tag, "li")) listHints(node, s);
    if (is(tag, "img") or is(tag, "object") or is(tag, "embed")) imageHints(node, s);
    if (is(tag, "hr")) hrHints(node, ctx);
    // Whatever doesn't read as a nonzero number turns it off (`0`, `no`).
    if (is(tag, "iframe")) if (node.attr("frameborder")) |v| {
        const on = std.fmt.parseInt(i32, std.mem.trim(u8, v, " \t\r\n"), 10) catch 0;
        if (on == 0) {
            s.border_top.width = 0;
            s.border_right.width = 0;
            s.border_bottom.width = 0;
            s.border_left.width = 0;
        }
    };
}

/// SVG's attributes that are style: read as CSS, below every author rule.
fn svgAttributes(node: *Node, ctx: *values.Ctx) void {
    for (node.attrs.items) |a| {
        if (!isPresentation(a.name)) continue;
        presentation(ctx, a.name, a.value);
    }
}

fn isPresentation(name: []const u8) bool {
    const l = [_][]const u8{ "fill", "fill-opacity", "fill-rule", "clip-rule", "clip-path", "mask", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "stop-color", "stop-opacity", "opacity", "visibility", "display", "paint-order", "vector-effect" };
    for (l) |x| if (std.mem.eql(u8, name, x)) return true;
    return false;
}

fn presentation(ctx: *values.Ctx, name: []const u8, value: []const u8) void {
    const text = std.fmt.allocPrint(ctx.arena, "{s}:{s}", .{ name, value }) catch return;
    const d = parser.parseDeclarations(ctx.arena, text) catch return;
    for (d.items) |x| {
        if (x.prop == .custom or x.prop == .all) continue;
        _ = properties.apply(ctx, x.prop, x.value);
    }
}

fn widthHolder(tag: []const u8) bool {
    const l = [_][]const u8{ "table", "td", "th", "col", "colgroup", "img", "hr", "iframe", "video", "canvas", "object", "embed", "applet", "svg", "pre", "input" };
    for (l) |x| if (std.mem.eql(u8, tag, x)) return true;
    return false;
}

fn heightHolder(tag: []const u8) bool {
    const l = [_][]const u8{ "table", "td", "th", "tr", "thead", "tbody", "tfoot", "img", "iframe", "video", "canvas", "object", "embed", "applet", "svg", "input" };
    for (l) |x| if (std.mem.eql(u8, tag, x)) return true;
    return false;
}

fn tableHints(node: *Node, s: *Style) void {
    if (node.attr("cellspacing")) |v| if (dimension(v)) |d| {
        s.border_spacing = d.px;
        s.border_spacing_y = d.px;
    };
    if (node.attr("border")) |v| if (dimension(v)) |d| if (d.px > 0) {
        const b: style.Border = .{ .width = d.px, .style = .outset, .color = .{ .r = 0.5, .g = 0.5, .b = 0.5 } };
        s.border_top = b;
        s.border_right = b;
        s.border_bottom = b;
        s.border_left = b;
    };
}

fn listHints(node: *Node, s: *Style) void {
    const v = node.attr("type") orelse return;
    if (std.mem.eql(u8, v, "1")) s.list_style = .decimal;
    if (std.mem.eql(u8, v, "a")) s.list_style = .lower_alpha;
    if (std.mem.eql(u8, v, "A")) s.list_style = .upper_alpha;
    if (std.mem.eql(u8, v, "i")) s.list_style = .lower_roman;
    if (std.mem.eql(u8, v, "I")) s.list_style = .upper_roman;
    if (eqCi(v, "disc")) s.list_style = .disc;
    if (eqCi(v, "circle")) s.list_style = .circle;
    if (eqCi(v, "square")) s.list_style = .square;
}

fn imageHints(node: *Node, s: *Style) void {
    if (node.attr("hspace")) |v| if (dimension(v)) |d| {
        s.margin_left = d;
        s.margin_right = d;
    };
    if (node.attr("vspace")) |v| if (dimension(v)) |d| {
        s.margin_top = d;
        s.margin_bottom = d;
    };
    if (node.attr("border")) |v| if (dimension(v)) |d| {
        const b: style.Border = .{ .width = d.px, .style = .solid, .color = s.color };
        s.border_top = b;
        s.border_right = b;
        s.border_bottom = b;
        s.border_left = b;
    };
    // The intrinsic ratio the attributes promise, until the image arrives.
    const w = dimension(node.attr("width") orelse return) orelse return;
    const h = dimension(node.attr("height") orelse return) orelse return;
    if (w.pct == 0 and h.pct == 0 and h.px > 0) s.aspect_ratio = w.px / h.px;
}

fn hrHints(node: *Node, ctx: *values.Ctx) void {
    const s = ctx.style;
    if (node.attr("color")) |v| if (legacyColor(ctx, v)) |c| {
        s.background = c;
        s.border_top.color = c;
        s.border_right.color = c;
        s.border_bottom.color = c;
        s.border_left.color = c;
    };
    if (node.hasAttr("noshade") and !node.hasAttr("color")) {
        const gray: style.Color = .{ .r = 169.0 / 255.0, .g = 169.0 / 255.0, .b = 169.0 / 255.0 };
        for ([_]*style.Border{ &s.border_top, &s.border_right, &s.border_bottom, &s.border_left }) |e| {
            e.style = .solid;
            e.color = gray;
        }
        s.background = gray;
    }
    // `size` counts its borders; at 1 only the top one is left.
    if (node.attr("size")) |v| if (dimension(v)) |d| if (d.pct == 0) {
        if (d.px <= 1) {
            s.border_bottom.width = 0;
        } else {
            s.height = .{ .kind = .length, .px = d.px - 2 };
        }
    };
}
