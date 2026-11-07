//! HTML's presentational attributes the style sheets do not cover: read here,
//! applied under whatever the cascade decided. `bgcolor` is paint's.
const std = @import("std");
const css = @import("../css/style.zig");
const dom = @import("../dom.zig");
const ctx = @import("ctx.zig");
const replaced = @import("replaced.zig");
const gen = @import("gen.zig");
const Ctx = ctx.Ctx;
const Error = ctx.Error;
const Style = css.Style;
const Len = css.Len;

fn dimLen(n: *const dom.Node, name: []const u8) ?Len {
    const d = replaced.dimAttr(n, name) orelse return null;
    return if (d.pct) .{ .pct = d.px } else .{ .px = d.px };
}

fn eqAttr(n: *const dom.Node, name: []const u8, value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(n.attr(name) orelse return false, value);
}

fn tableOf(n: *const dom.Node) ?*dom.Node {
    var at = n.parent;
    var hops: u8 = 0;
    while (at) |p| : (at = p.parent) {
        hops += 1;
        if (hops > 8) return null;
        if (p.isTag("table")) return p;
    }
    return null;
}

const gray: css.Color = .{ .r = 0.5, .g = 0.5, .b = 0.5 };

fn solid(width: f32, color: css.Color) css.Border {
    return .{ .width = width, .style = .solid, .color = color };
}

fn valignOf(raw: []const u8) ?css.VerticalAlign {
    if (std.ascii.eqlIgnoreCase(raw, "top")) return .top;
    if (std.ascii.eqlIgnoreCase(raw, "middle") or std.ascii.eqlIgnoreCase(raw, "center")) return .middle;
    if (std.ascii.eqlIgnoreCase(raw, "bottom")) return .bottom;
    if (std.ascii.eqlIgnoreCase(raw, "baseline")) return .baseline;
    return null;
}

/// The style the element lays out with: `s` itself unless an attribute adds to
/// it. The cascade applies most of these too, in which case nothing changes here.
pub fn apply(c: *Ctx, n: *dom.Node, s: *const Style) Error!*const Style {
    if (n.ns != .html) return s;
    var out = s.*;
    var changed = false;
    if (n.isTag("td") or n.isTag("th")) {
        changed = cellHints(n, &out);
    } else if (n.attrs.items.len == 0) {
        return s;
    } else if (n.isTag("table")) {
        changed = tableHints(n, &out);
    } else if (n.isTag("tr")) {
        if (s.height.kind == .auto) if (dimLen(n, "height")) |h| {
            out.height = h;
            changed = true;
        };
    } else if (n.isTag("img")) {
        changed = imageHints(n, &out);
    }
    if (!changed) return s;
    const copy = try c.arena.create(Style);
    copy.* = out;
    return copy;
}

fn imageHints(n: *const dom.Node, s: *Style) bool {
    if (s.float != .none) return false;
    if (eqAttr(n, "align", "left")) s.float = .left else if (eqAttr(n, "align", "right")) s.float = .right else return false;
    if (s.display == .inline_) s.display = .block;
    return true;
}

fn allBorders(s: *Style, b: css.Border) void {
    s.border_top = b;
    s.border_right = b;
    s.border_bottom = b;
    s.border_left = b;
}

fn tableHints(n: *const dom.Node, s: *Style) bool {
    var changed = false;
    if (s.width.kind == .auto) if (dimLen(n, "width")) |v| {
        s.width = v;
        changed = true;
    };
    if (s.height.kind == .auto) if (dimLen(n, "height")) |v| {
        s.height = v;
        changed = true;
    };
    if (replaced.dimAttr(n, "cellspacing")) |d| if (!d.pct and s.border_spacing == 2 and d.px != 2) {
        s.border_spacing = d.px;
        s.border_spacing_y = d.px;
        changed = true;
    };
    if (replaced.dimAttr(n, "border")) |d| if (!d.pct and d.px > 0 and s.border_top.style == .none) {
        allBorders(s, solid(d.px, gray));
        changed = true;
    };
    if (s.float == .none) {
        if (eqAttr(n, "align", "left")) {
            s.float = .left;
            changed = true;
        } else if (eqAttr(n, "align", "right")) {
            s.float = .right;
            changed = true;
        }
    }
    if (eqAttr(n, "align", "center") and s.margin_left.kind != .auto) {
        s.margin_left = .auto;
        s.margin_right = .auto;
        changed = true;
    }
    return changed;
}

/// `cellpadding` only beats the UA sheet's default padding, not an author's.
fn cellHints(n: *const dom.Node, s: *Style) bool {
    var changed = false;
    if (n.attrs.items.len > 0) {
        if (s.width.kind == .auto) if (dimLen(n, "width")) |v| if (v.px != 0 or v.pct != 0) {
            s.width = v;
            changed = true;
        };
        if (s.height.kind == .auto) if (dimLen(n, "height")) |v| if (v.pct == 0 and v.px != 0) {
            s.height = v;
            changed = true;
        };
    }
    if (n.attr("valign") orelse rowAttr(n, "valign")) |raw| if (valignOf(raw)) |v| if (s.vertical_align != v) {
        s.vertical_align = v;
        changed = true;
    };
    const table = tableOf(n) orelse return changed;
    if (table.attrs.items.len == 0) return changed;
    if (replaced.dimAttr(table, "cellpadding")) |d| if (defaultPadding(s) and !(d.px == s.padding_top.px and !d.pct)) {
        const v: Len = if (d.pct) .{ .pct = d.px } else .{ .px = d.px };
        s.padding_top = v;
        s.padding_right = v;
        s.padding_bottom = v;
        s.padding_left = v;
        changed = true;
    };
    if (replaced.dimAttr(table, "border")) |d| if (!d.pct and d.px > 0 and s.border_top.style == .none) {
        allBorders(s, solid(1, gray));
        changed = true;
    };
    return changed;
}

fn rowAttr(n: *const dom.Node, name: []const u8) ?[]const u8 {
    const p = n.parent orelse return null;
    if (p.isTag("tr")) {
        if (p.attr(name)) |v| return v;
        if (p.parent) |g| return g.attr(name);
    }
    return null;
}

fn defaultPadding(s: *const Style) bool {
    const t = s.padding_top;
    if (t.pct != 0 or t.px > 1) return false;
    return s.padding_right.px == t.px and s.padding_bottom.px == t.px and s.padding_left.px == t.px;
}

/// What the attributes pass on to what is inside, and a list's counter.
pub fn descend(g: *gen.Gen, n: *dom.Node) void {
    if (n.ns != .html) return;
    if (n.isTag("table")) {
        g.text_align = null;
        g.nowrap = false;
    } else if (n.isTag("center")) {
        g.text_align = .center;
    } else if (n.attr("align")) |a| {
        if (!n.isTag("img") and !n.isTag("input") and !n.isTag("caption")) {
            if (std.ascii.eqlIgnoreCase(a, "center") or std.ascii.eqlIgnoreCase(a, "middle")) g.text_align = .center;
            if (std.ascii.eqlIgnoreCase(a, "right")) g.text_align = .right;
            if (std.ascii.eqlIgnoreCase(a, "left")) g.text_align = .left;
            if (std.ascii.eqlIgnoreCase(a, "justify")) g.text_align = .justify;
        }
    }
    if ((n.isTag("td") or n.isTag("th")) and n.hasAttr("nowrap")) g.nowrap = true;
    if (n.isTag("ol") or n.isTag("ul") or n.isTag("menu") or n.isTag("dir")) {
        g.counter_step = 1;
        g.counter = 1;
        const reversed = n.hasAttr("reversed");
        if (reversed) {
            g.counter_step = -1;
            var count: i64 = 0;
            var k = n.first_child;
            while (k) |x| : (k = x.next) {
                if (x.isTag("li")) count += 1;
            }
            g.counter = count;
        }
        if (n.attr("start")) |v| {
            g.counter = std.fmt.parseInt(i64, std.mem.trim(u8, v, " \t\r\n"), 10) catch g.counter;
        }
    }
}

/// `hidden=until-found` and `content-visibility: hidden`: it has a box, and shows
/// nothing that is in it.
pub fn isContentHidden(n: *const dom.Node, s: *const Style) bool {
    if (s.content_hidden) return true;
    const v = n.attr("hidden") orelse return false;
    return std.ascii.eqlIgnoreCase(v, "until-found");
}
