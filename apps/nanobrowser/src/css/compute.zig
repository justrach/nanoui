//! Computing one element's style: the rules that match it in cascade order,
//! applied in passes so that what depends on the font size and the color sees
//! them. The tree walk is in `cascade.zig`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../dom.zig");
const style = @import("style.zig");
const sheet = @import("sheet.zig");
const rule_index = @import("rule_index.zig");
const vars = @import("vars.zig");
const values = @import("values.zig");
const properties = @import("properties.zig");
const wide = @import("properties_wide.zig");
const prop = @import("prop.zig");
const hints = @import("hints.zig");
const parser = @import("parser.zig");
const cascade = @import("cascade.zig");
const motion = @import("properties_motion.zig");

const Engine = cascade.Engine;
const Style = style.Style;
const Entry = rule_index.Entry;
const Declaration = sheet.Declaration;
const Declarations = sheet.Declarations;

/// The result for an element: its custom properties, and whether there is
/// something for `::before` and `::after` to compute.
pub const Result = struct {
    scope: ?*const vars.Scope,
    before: bool = false,
    after: bool = false,
    marker: bool = false,
    backdrop: bool = false,
};

/// A shadow root's stand-in: nothing matches it, and it adds no box.
pub fn shadowRoot(parent: *const Style, parent_scope: ?*const vars.Scope, out: *Style) Result {
    out.* = wide.inherit(parent);
    out.display = .contents;
    return .{ .scope = parent_scope };
}

fn entryLess(_: void, a: Entry, b: Entry) bool {
    return a.key < b.key;
}

/// The cached parse of a node's `style` attribute. Lives in the document's arena
/// because it must outlast style generations.
fn inlineDecls(n: *dom.Node) Allocator.Error!?*const Declarations {
    const text = n.attr("style") orelse return null;
    if (n.inline_decls != null and n.inline_src.ptr == text.ptr and n.inline_src.len == text.len) {
        return @ptrCast(@alignCast(n.inline_decls.?));
    }
    const d = try parser.parseDeclarationsBase(n.doc.arena, text, n.doc.url);
    n.inline_decls = d;
    n.inline_src = text;
    return d;
}

/// A style of `@keyframes` for `n`: `base` with the frame's declarations over it,
/// substituted as the element's own are.
pub fn frameStyle(e: *Engine, n: *dom.Node, parent: *const Style, scope: ?*const vars.Scope, base: *const Style, d: *const Declarations, out: *Style) Allocator.Error!void {
    out.* = base.*;
    var ctx: values.Ctx = .{
        .style = out,
        .parent = parent,
        .base = base,
        .root_font = e.root_font,
        .vw = e.viewport.width,
        .vh = e.viewport.height,
        .viewport_read = &e.viewport_read,
        .viewport_dark = e.viewport.dark,
        .node = n,
        .arena = e.genArena(),
    };
    for (d.items) |*x| {
        if (x.prop == .custom or x.prop == .all or x.wide != .none) continue;
        var toks = x.value;
        if (x.has_var) toks = (try vars.substitute(ctx.arena, x.value, scope)) orelse continue;
        _ = properties.apply(&ctx, x.prop, toks);
    }
    for ([_]*style.Border{ &out.border_top, &out.border_right, &out.border_bottom, &out.border_left, &out.outline }) |b| {
        if (b.style == .none or b.style == .hidden) b.width = 0;
    }
    out.inherited_visibility = out.visibility;
}

/// Computes `n`'s style into `out`.
pub fn element(e: *Engine, n: *dom.Node, parent: *const Style, parent_scope: ?*const vars.Scope, out: *Style) Allocator.Error!Result {
    const gpa = e.gpa;
    e.matched.clearRetainingCapacity();
    e.pseudo_before.clearRetainingCapacity();
    e.pseudo_after.clearRetainingCapacity();
    e.pseudo_placeholder.clearRetainingCapacity();
    e.pseudo_marker.clearRetainingCapacity();
    e.pseudo_backdrop.clearRetainingCapacity();
    e.collected.clearRetainingCapacity();
    try e.collectFor(n);
    for (e.collected.items) |m| {
        if (m.container) |c| if (!e.containerHolds(c, n)) continue;
        switch (m.sel.pseudo) {
            .none, .slotted, .part => try e.matched.append(gpa, m),
            .before => try e.pseudo_before.append(gpa, m),
            .after => try e.pseudo_after.append(gpa, m),
            .placeholder => try e.pseudo_placeholder.append(gpa, m),
            .marker => try e.pseudo_marker.append(gpa, m),
            .backdrop => try e.pseudo_backdrop.append(gpa, m),
            .other => {},
        }
    }
    std.mem.sort(Entry, e.matched.items, {}, entryLess);
    const inline_d = if (n.attrs.items.len > 0) try inlineDecls(n) else null;

    const scope = try customProperties(e, e.matched.items, inline_d, parent_scope);
    var run: Run = .{
        .e = e,
        .node = n,
        .matched = e.matched.items,
        .inline_d = inline_d,
        .parent = parent,
        .scope = scope,
        .is_element = true,
    };
    _ = try run.compute(out);
    if (e.pseudo_placeholder.items.len > 0 and (n.isTag("input") or n.isTag("textarea"))) {
        std.mem.sort(Entry, e.pseudo_placeholder.items, {}, entryLess);
        var ph: Run = .{ .e = e, .node = n, .matched = e.pseudo_placeholder.items, .inline_d = null, .parent = out, .scope = scope, .is_element = false };
        var made: Style = undefined;
        _ = try ph.compute(&made);
        out.placeholder = made.color;
    }
    return .{
        .scope = scope,
        .before = hasContent(e.pseudo_before.items),
        .after = hasContent(e.pseudo_after.items),
        .marker = e.pseudo_marker.items.len > 0,
        .backdrop = e.pseudo_backdrop.items.len > 0,
    };
}

fn hasContent(list: []const Entry) bool {
    for (list) |m| if (m.decls.has_content) return true;
    return false;
}

/// Computes a pseudo-element's style; null if it comes to nothing to show.
pub fn pseudo(e: *Engine, n: *dom.Node, list: []Entry, parent: *const Style, parent_scope: ?*const vars.Scope, out: *Style) Allocator.Error!bool {
    std.mem.sort(Entry, list, {}, entryLess);
    const scope = try customProperties(e, list, null, parent_scope);
    var run: Run = .{
        .e = e,
        .node = n,
        .matched = list,
        .inline_d = null,
        .parent = parent,
        .scope = scope,
        .is_element = false,
    };
    const shows = try run.compute(out);
    // `::marker` is there whatever its rules say; `content` only changes its words.
    const always = list.len > 0 and (list[0].sel.pseudo == .marker or list[0].sel.pseudo == .backdrop);
    return (shows or always) and out.display != .none;
}

fn customProperties(e: *Engine, list: []const Entry, inline_d: ?*const Declarations, parent: ?*const vars.Scope) Allocator.Error!?*const vars.Scope {
    var any = false;
    for (list) |m| if (m.decls.has_custom) {
        any = true;
        break;
    };
    if (inline_d) |d| if (d.has_custom) {
        any = true;
    };
    // What the parent declared and doesn't inherit stops here.
    const back = if (parent) |p| p.local else &.{};
    if (!any and back.len == 0) return parent;
    const gpa = e.gpa;
    const b = &e.custom_builder;
    b.reset();
    for (back) |x| try b.putBack(gpa, x, if (e.registered.get(x.name)) |r| r.initial else null);
    // Normal declarations, then `!important` ones over them.
    for (list) |m| if (m.decls.has_custom) {
        for (m.decls.items) |*d| if (d.prop == .custom and !d.important) try b.add(gpa, d, parent);
    };
    if (inline_d) |id| for (id.items) |*d| {
        if (d.prop == .custom and !d.important) try b.add(gpa, d, parent);
    };
    for (list) |m| if (m.decls.has_custom and m.decls.has_important) {
        for (m.decls.items) |*d| if (d.prop == .custom and d.important) try b.add(gpa, d, parent);
    };
    if (inline_d) |id| for (id.items) |*d| {
        if (d.prop == .custom and d.important) try b.add(gpa, d, parent);
    };
    return b.finish(e.genArena(), parent, &e.registered);
}

/// One computation over one list of rules. The UA-only form, for `revert`, is
/// another run over the same element.
const Run = struct {
    e: *Engine,
    node: *dom.Node,
    matched: []const Entry,
    inline_d: ?*const Declarations,
    parent: *const Style,
    scope: ?*const vars.Scope,
    is_element: bool,
    ua_only: bool = false,
    ctx: values.Ctx = undefined,
    /// Initial values, with the current color and medium borders in place once
    /// the color is known.
    initial: Style = .{},
    base: Style = .{},
    ua_style: ?Style = null,

    fn compute(r: *Run, out: *Style) Allocator.Error!bool {
        const e = r.e;
        r.base = wide.inherit(r.parent);
        if (r.parent == &e.root_parent) r.base.dark_scheme = e.meta_dark;
        out.* = r.base;
        r.ctx = .{
            .style = out,
            .parent = r.parent,
            .base = &r.base,
            .root_font = e.root_font,
            .vw = e.viewport.width,
            .vh = e.viewport.height,
            .viewport_read = &e.viewport_read,
            .viewport_dark = e.viewport.dark,
            .node = r.node,
            .arena = e.genArena(),
            .fonts = &e.fonts,
            .gpa = e.gpa,
        };

        try r.pass(0);
        fontQuirk(out, r.parent, r.ctx.font_size_set, r.ctx.font_size_keyword);
        if (out.line_height_factor > 0) out.line_height = out.line_height_factor * out.font_size;

        try r.pass(1);

        // Borders and outlines start at `medium` and the current color;
        // `finish` zeroes the ones with no style.
        for ([_]*Style{ out, &r.base, &r.initial }) |s| {
            for ([_]*style.Border{ &s.border_top, &s.border_right, &s.border_bottom, &s.border_left, &s.outline }) |b| {
                b.* = .{ .width = 3, .style = .none, .color = out.color };
            }
        }

        try r.pass(2);
        r.finish(out);
        return r.ctx.has_content;
    }

    /// Everything of one phase: the UA's rules, presentational hints, author
    /// rules, inline style, then the same in reverse for `!important`.
    fn pass(r: *Run, ph: u2) Allocator.Error!void {
        const m = r.matched;
        var ua_end: usize = 0;
        while (ua_end < m.len and m[ua_end].ua) ua_end += 1;
        for (m[0..ua_end]) |x| try r.applyList(x.decls, ph, false);
        if (r.ua_only) return;
        if (r.is_element) {
            if (ph < 2) {
                hints.early(r.node, &r.ctx, ph);
            } else {
                hints.late(r.node, &r.ctx);
                if (!r.e.scripting and r.node.isTag("noscript")) r.ctx.style.display = .inline_;
            }
        }
        for (m[ua_end..]) |x| try r.applyList(x.decls, ph, false);
        if (r.inline_d) |d| try r.applyList(d, ph, false);
        // `!important`: author rules with the layer order turned over.
        var any = false;
        for (m) |x| if (x.decls.has_important) {
            any = true;
            break;
        };
        if (r.inline_d) |d| if (d.has_important) {
            any = true;
        };
        if (!any) return;
        var layer_order: std.ArrayList(Entry) = .empty;
        defer layer_order.deinit(r.e.gpa);
        for (m[ua_end..]) |x| if (x.decls.has_important) try layer_order.append(r.e.gpa, x);
        std.mem.sort(Entry, layer_order.items, {}, importantLess);
        for (layer_order.items) |x| try r.applyList(x.decls, ph, true);
        if (r.inline_d) |d| try r.applyList(d, ph, true);
        for (m[0..ua_end]) |x| if (x.decls.has_important) try r.applyList(x.decls, ph, true);
    }

    fn importantLess(_: void, a: Entry, b: Entry) bool {
        if (a.layer != b.layer) return a.layer > b.layer;
        return a.key < b.key;
    }

    fn applyList(r: *Run, d: *const Declarations, ph: u2, important: bool) Allocator.Error!void {
        if (important and !d.has_important) return;
        for (d.items) |*x| {
            if (x.important != important) continue;
            if (x.prop == .custom) continue;
            if (x.phase != ph and x.prop != .all) continue;
            try r.apply(x, ph);
        }
    }

    fn apply(r: *Run, d: *const Declaration, ph: u2) Allocator.Error!void {
        var toks = d.value;
        var w = d.wide;
        if (d.has_var) {
            const sub = try vars.substitute(r.ctx.arena, d.value, r.scope);
            if (sub) |t| {
                toks = t;
                w = wideOf(t);
            } else {
                w = .unset;
            }
        }
        if (d.prop == .all) return r.applyAll(w, ph);
        if (w == .none) {
            if (!properties.apply(&r.ctx, d.prop, toks) and d.has_var) w = .unset;
        }
        const s = r.ctx.style;
        switch (w) {
            .none => {},
            .inherit => wide.copy(d.prop, s, r.parent),
            .initial => wide.copy(d.prop, s, &r.initial),
            .unset => wide.copy(d.prop, s, if (prop.isInherited(d.prop)) r.parent else &r.initial),
            .revert => wide.copy(d.prop, s, try r.reverted()),
        }
    }

    fn applyAll(r: *Run, w: sheet.Wide, ph: u2) Allocator.Error!void {
        const s = r.ctx.style;
        switch (w) {
            .none => {},
            .inherit => wide.copyAll(s, r.parent, ph),
            .initial => wide.copyAll(s, &r.initial, ph),
            .unset => wide.copyAll(s, &r.base, ph),
            .revert => wide.copyAll(s, try r.reverted(), ph),
        }
    }

    /// The style the UA sheet alone gives; at the UA's own level, `revert`
    /// is `unset`.
    fn reverted(r: *Run) Allocator.Error!*const Style {
        if (r.ua_only) return &r.base;
        if (r.ua_style == null) {
            var sub: Run = .{
                .e = r.e,
                .node = r.node,
                .matched = r.matched,
                .inline_d = null,
                .parent = r.parent,
                .scope = r.scope,
                .is_element = r.is_element,
                .ua_only = true,
            };
            var out: Style = undefined;
            _ = try sub.compute(&out);
            r.ua_style = out;
        }
        return &r.ua_style.?;
    }

    /// Computed-value fix-ups once everything has been applied.
    fn finish(r: *Run, s: *Style) void {
        s.inherited_visibility = s.visibility;
        motion.zip(r.ctx.arena, s);
        for ([_]*style.Border{ &s.border_top, &s.border_right, &s.border_bottom, &s.border_left, &s.outline }) |b| {
            if (b.style == .none or b.style == .hidden) b.width = 0;
        }
        const out_of_flow = s.position == .absolute or s.position == .fixed;
        if (out_of_flow) s.float = .none;
        const is_root = r.parent == &r.e.root_parent;
        s.was_block = !(s.display == .inline_ or s.display == .inline_block or s.display == .inline_flex or s.display == .inline_grid or s.display == .inline_table);
        if (r.parent.inert or (r.is_element and r.node.hasAttr("inert"))) s.inert = true;
        if (s.inert) s.pointer_events = false;
        if (s.container_type == .size) s.contain_size = true;
        if (s.container_type == .inline_size) s.contain_inline_size = true;
        if (s.float != .none or out_of_flow or is_root or r.flexParent()) s.display = blockified(s.display);
        // `-webkit-center`, `<center>`, `<td align=center>`: block children with
        // no margins of their own are centered too, not only the text.
        if (r.is_element and r.parent.center_children and !out_of_flow and s.float == .none and !s.isInlineLevel() and isZero(s.margin_left) and isZero(s.margin_right)) {
            s.margin_left = style.Len.auto;
            s.margin_right = style.Len.auto;
        }
        // `visible` cannot stay beside a scrolling axis.
        if (s.overflow_x != s.overflow_y) {
            const scrolls = struct {
                fn f(o: style.Overflow) bool {
                    return o == .hidden or o == .scroll or o == .auto;
                }
            }.f;
            if (s.overflow_x == .visible and scrolls(s.overflow_y)) s.overflow_x = .auto;
            if (s.overflow_y == .visible and scrolls(s.overflow_x)) s.overflow_y = .auto;
        }
        // `overflow` on the root, and on the body beside a root that leaves
        // it alone, is the viewport's: the page itself is what scrolls.
        if (is_root) s.root_overflow = s.overflow_x != .visible or s.overflow_y != .visible;
        if (is_root or (r.node.isTag("body") and r.parent.overflow_x == .visible and r.parent.overflow_y == .visible and !r.parent.root_overflow)) {
            s.locks_viewport = s.overflow_y == .hidden or s.overflow_y == .clip;
            s.overflow_x = .visible;
            s.overflow_y = .visible;
        }
        // The canvas of a dark page.
        if (is_root and s.dark_scheme and s.background.a == 0 and s.background_image.len == 0) {
            s.background = .{ .r = 18.0 / 255.0, .g = 18.0 / 255.0, .b = 18.0 / 255.0 };
        }
    }

    /// Whether the box's container is a flex or grid box, looking through
    /// `display: contents`.
    fn flexParent(r: *const Run) bool {
        if (!r.is_element) return r.parent.isFlex() or r.parent.isGrid();
        if (r.parent == &r.e.root_parent) return false;
        var s = r.parent;
        var at = r.node.parent;
        while (s.display == .contents) {
            const p = at orelse return false;
            at = p.parent;
            if (at == null) return false;
            const up = at.?;
            s = up.computed orelse return false;
        }
        return s.isFlex() or s.isGrid();
    }
};

fn isZero(l: style.Len) bool {
    return l.kind == .length and l.px == 0 and l.pct == 0;
}

fn wideOf(t: []const sheet.Token) sheet.Wide {
    const w = values.ident(t) orelse return .none;
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(w, "inherit")) return .inherit;
    if (eq(w, "initial")) return .initial;
    if (eq(w, "unset")) return .unset;
    if (eq(w, "revert") or eq(w, "revert-layer")) return .revert;
    return .none;
}

/// The bare generic `monospace` shows at 13px where sans shows at 16, unless
/// the page set a size.
fn fontQuirk(s: *Style, parent: *const Style, size_set: bool, keyword: bool) void {
    if (size_set and keyword) {
        if (s.mono_generic) s.font_size *= 13.0 / 16.0;
        return;
    }
    if (size_set or s.font_size_abs or s.mono_generic == parent.mono_generic) return;
    if (s.mono_generic) {
        s.font_size = parent.font_size * 13 / 16;
    } else {
        s.font_size = parent.font_size * 16 / 13;
    }
}

pub fn blockified(d: style.Display) style.Display {
    return switch (d) {
        .inline_, .inline_block, .table_caption, .table_row_group, .table_header_group, .table_footer_group, .table_row, .table_cell, .table_column, .table_column_group => .block,
        .inline_flex => .flex,
        .inline_grid => .grid,
        .inline_table => .table,
        else => d,
    };
}
