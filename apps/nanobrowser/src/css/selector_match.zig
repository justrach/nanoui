//! Matching a selector against an element, right to left with backtracking.
const std = @import("std");
const dom = @import("../dom.zig");
const sel = @import("selectors.zig");

const Node = dom.Node;
const Selector = sel.Selector;
const Compound = sel.Compound;
const Simple = sel.Simple;

pub const Ctx = struct {
    doc: *dom.Document,
    /// What `:scope` matches; the root element when null.
    scope: ?*const Node = null,
    /// For `invalidatedByState`: state pseudo-classes count as true, and
    /// `:not()` around them too, to find what a flip could affect.
    loose_state: bool = false,
    /// `:nth-child()`'s index is carried from the previous sibling, which
    /// keeps a restyle of a long list from being quadratic.
    nth_node: ?*const Node = null,
    nth_index: i32 = 0,
};

pub fn matches(s: *const Selector, el: *Node, ctx: *Ctx) bool {
    if (s.compounds.len == 0) return s.pseudo != .none;
    return from(s, s.compounds.len - 1, el, ctx, null);
}

pub fn matchesAny(list: []const Selector, el: *Node, ctx: *Ctx) bool {
    for (list) |*s| if (matches(s, el, ctx)) return true;
    return false;
}

/// Compound `i` at `el`, then everything to its left. With an `anchor`, the
/// leftmost compound must also stand in `s.leading` relation to it (`:has`).
fn from(s: *const Selector, i: usize, el: *Node, ctx: *Ctx, anchor: ?*Node) bool {
    const c = &s.compounds[i];
    if (!compound(c, el, ctx)) return false;
    if (i == 0) {
        const a = anchor orelse return true;
        return related(s.leading, el, a);
    }
    switch (c.combinator) {
        .child => {
            const p = el.parentElement() orelse return false;
            if (p.is_shadow) return crossToHost(s, i - 1, p, ctx, anchor);
            return from(s, i - 1, p, ctx, anchor);
        },
        .descendant => {
            var p = el.parentElement();
            while (p) |at| : (p = at.parentElement()) {
                if (at.is_shadow) return crossToHost(s, i - 1, at, ctx, anchor);
                if (from(s, i - 1, at, ctx, anchor)) return true;
            }
            return false;
        },
        .next => {
            const p = el.prevElement() orelse return false;
            return from(s, i - 1, p, ctx, anchor);
        },
        .later => {
            var p = el.prevElement();
            while (p) |at| : (p = at.prevElement()) {
                if (from(s, i - 1, at, ctx, anchor)) return true;
            }
            return false;
        },
    }
}

/// A selector doesn't see past its tree, but for the host when it says `:host`.
fn crossToHost(s: *const Selector, i: usize, root: *Node, ctx: *Ctx, anchor: ?*Node) bool {
    const host = root.parent orelse return false;
    for (s.compounds[i].simples) |x| switch (x) {
        .host, .host_context => return from(s, i, host, ctx, anchor),
        else => {},
    };
    return false;
}

fn related(how: sel.Combinator, el: *const Node, anchor: *const Node) bool {
    switch (how) {
        .child => return el.parent == anchor,
        .descendant => {
            var p = el.parent;
            while (p) |at| : (p = at.parent) if (at == anchor) return true;
            return false;
        },
        .next => return el.prevElement() == anchor,
        .later => {
            var p = el.prevElement();
            while (p) |at| : (p = at.prevElement()) if (at == anchor) return true;
            return false;
        },
    }
}

pub fn compound(c: *const Compound, el: *Node, ctx: *Ctx) bool {
    for (c.simples) |*s| if (!simple(s, el, ctx)) return false;
    return true;
}

fn tagMatches(want: []const u8, el: *const Node) bool {
    if (el.ns == .html) return std.mem.eql(u8, want, el.tag);
    return std.ascii.eqlIgnoreCase(want, el.tag);
}

fn simple(s: *const Simple, el: *Node, ctx: *Ctx) bool {
    return switch (s.*) {
        .universal => true,
        .tag => |t| tagMatches(t, el),
        .id => |want| blk: {
            const v = el.attr("id") orelse break :blk false;
            break :blk if (el.doc.quirks) std.ascii.eqlIgnoreCase(v, want) else std.mem.eql(u8, v, want);
        },
        .class => |want| if (el.doc.quirks) hasClassCi(el, want) else el.hasClass(want),
        .attr => |*a| attrMatches(a, el),
        .pseudo => |p| pseudo(p, el, ctx),
        .nth => |*n| nth(n, el, ctx),
        .not => |l| blk: {
            // A flip of state inside `:not()` may make it true.
            if (ctx.loose_state and listUsesState(l)) break :blk true;
            break :blk !matchesAny(l, el, ctx);
        },
        .is => |l| matchesAny(l, el, ctx),
        .has => |l| blk: {
            if (ctx.loose_state and listUsesState(l)) break :blk true;
            break :blk has(l, el, ctx);
        },
        .lang => |want| lang(want, el),
        .host => |l| el.shadow_root != null and (l.len == 0 or matchesAny(l, el, ctx)),
        .host_context => |l| blk: {
            var at: ?*Node = el;
            while (at) |a| : (at = a.parent) {
                if (a.kind == .element and !a.is_shadow and matchesAny(l, a, ctx)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn listUsesState(l: []const Selector) bool {
    for (l) |s| if (s.uses_state) return true;
    return false;
}

fn hasClassCi(el: *const Node, want: []const u8) bool {
    const list = el.attr("class") orelse return false;
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n\x0c");
    while (it.next()) |c| if (std.ascii.eqlIgnoreCase(c, want)) return true;
    return false;
}

const ci_attrs = std.StaticStringMap(void).initComptime(.{
    .{"accept"},     .{"accept-charset"}, .{"align"},     .{"alink"},    .{"axis"},     .{"bgcolor"}, .{"charset"},
    .{"checked"},    .{"clear"},          .{"codetype"},  .{"color"},    .{"compact"},  .{"declare"}, .{"defer"},
    .{"dir"},        .{"direction"},      .{"disabled"},  .{"enctype"},  .{"face"},     .{"frame"},   .{"hreflang"},
    .{"http-equiv"}, .{"lang"},           .{"language"},  .{"link"},     .{"media"},    .{"method"},  .{"multiple"},
    .{"nohref"},     .{"noresize"},       .{"noshade"},   .{"nowrap"},   .{"readonly"}, .{"rel"},     .{"rev"},
    .{"rules"},      .{"scope"},          .{"scrolling"}, .{"selected"}, .{"shape"},    .{"target"},  .{"text"},
    .{"type"},       .{"valign"},         .{"valuetype"}, .{"vlink"},
});

fn attrMatches(a: *const sel.Attr, el: *const Node) bool {
    const is_html = el.ns == .html;
    const v = el.attr(if (is_html) a.lower else a.name) orelse return false;
    if (a.op == .exists) return true;
    const ci = a.ci orelse (is_html and ci_attrs.has(a.lower));
    const want = a.value;
    return switch (a.op) {
        .exists => true,
        .equals => eql(v, want, ci),
        .includes => blk: {
            if (want.len == 0) break :blk false;
            for (want) |c| if (std.ascii.isWhitespace(c)) break :blk false;
            var it = std.mem.tokenizeAny(u8, v, " \t\r\n\x0c");
            while (it.next()) |w| if (eql(w, want, ci)) break :blk true;
            break :blk false;
        },
        .dash => eql(v, want, ci) or (v.len > want.len and v[want.len] == '-' and eql(v[0..want.len], want, ci)),
        .prefix => want.len > 0 and v.len >= want.len and eql(v[0..want.len], want, ci),
        .suffix => want.len > 0 and v.len >= want.len and eql(v[v.len - want.len ..], want, ci),
        .substring => want.len > 0 and contains(v, want, ci),
    };
}

fn eql(a: []const u8, b: []const u8, ci: bool) bool {
    return if (ci) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn contains(hay: []const u8, needle: []const u8, ci: bool) bool {
    if (ci) return std.ascii.findIgnoreCase(hay, needle) != null;
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn isControl(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "input") or std.mem.eql(u8, tag, "select") or std.mem.eql(u8, tag, "textarea");
}

fn isDisableable(el: *const Node) bool {
    if (el.ns != .html) return false;
    const list = [_][]const u8{ "input", "select", "textarea", "button", "option", "optgroup", "fieldset" };
    for (list) |t| if (std.mem.eql(u8, el.tag, t)) return true;
    return false;
}

fn isDisabled(el: *const Node) bool {
    if (!isDisableable(el)) return false;
    if (el.hasAttr("disabled")) return true;
    if (std.mem.eql(u8, el.tag, "option")) {
        if (el.parentElement()) |p| if (p.isTag("optgroup") and p.hasAttr("disabled")) return true;
        return false;
    }
    if (std.mem.eql(u8, el.tag, "optgroup")) return false;
    // Inside a disabled fieldset, but not its first legend.
    var child = el;
    var p = el.parentElement();
    while (p) |at| : ({
        child = at;
        p = at.parentElement();
    }) {
        if (at.isTag("fieldset") and at.hasAttr("disabled")) {
            var c = at.firstElementChild();
            while (c) |k| : (c = k.nextElement()) if (k.isTag("legend")) break;
            if (c != child) return true;
        }
    }
    return false;
}

fn isChecked(el: *const Node) bool {
    if (el.ns != .html) return false;
    if (el.isTag("input")) {
        const ty = el.attr("type") orelse return false;
        if (!std.ascii.eqlIgnoreCase(ty, "checkbox") and !std.ascii.eqlIgnoreCase(ty, "radio")) return false;
        return el.checked orelse el.hasAttr("checked");
    }
    if (el.isTag("option")) return el.selected orelse el.hasAttr("selected");
    return false;
}

fn editableText(el: *const Node) bool {
    if (el.isTag("textarea")) return !el.hasAttr("readonly") and !el.hasAttr("disabled");
    if (el.isTag("input")) {
        if (el.hasAttr("readonly") or el.hasAttr("disabled")) return false;
        const ty = el.attr("type") orelse return true;
        const not_text = [_][]const u8{ "checkbox", "radio", "button", "submit", "reset", "hidden", "image", "file", "range", "color" };
        for (not_text) |x| if (std.ascii.eqlIgnoreCase(ty, x)) return false;
        return true;
    }
    return false;
}

fn placeholderShown(el: *Node) bool {
    if (!el.hasAttr("placeholder")) return false;
    if (el.isTag("input")) {
        const v = el.value orelse el.attr("value") orelse "";
        return v.len == 0;
    }
    if (el.isTag("textarea")) {
        if (el.value) |v| return v.len == 0;
        var c = el.first_child;
        while (c) |k| : (c = k.next) if (k.kind == .text and k.data.len > 0) return false;
        return true;
    }
    return false;
}

fn pseudo(p: sel.PseudoClass, el: *Node, ctx: *Ctx) bool {
    if (ctx.loose_state) switch (p) {
        .hover, .active, .focus, .focus_visible, .focus_within => return true,
        else => {},
    };
    const doc = el.doc;
    return switch (p) {
        .root => doc.documentElement() == el and el.parent == doc.node,
        .empty => blk: {
            var c = el.first_child;
            while (c) |k| : (c = k.next) {
                if (k.kind == .element or (k.kind == .text and k.data.len > 0)) break :blk false;
            }
            break :blk true;
        },
        .only_child => el.prevElement() == null and el.nextElement() == null,
        .only_of_type => blk: {
            var c = el.prevElement();
            while (c) |k| : (c = k.prevElement()) if (std.mem.eql(u8, k.tag, el.tag)) break :blk false;
            c = el.nextElement();
            while (c) |k| : (c = k.nextElement()) if (std.mem.eql(u8, k.tag, el.tag)) break :blk false;
            break :blk true;
        },
        .link, .any_link => (el.isTag("a") or el.isTag("area")) and el.hasAttr("href"),
        .visited, .never => false,
        .hover => contained(doc.hover, el),
        .active => contained(doc.active, el),
        .focus, .focus_visible => doc.focus == el,
        .focus_within => contained(doc.focus, el),
        .checked => isChecked(el),
        .disabled => isDisabled(el),
        .enabled => isDisableable(el) and !isDisabled(el),
        .required => el.ns == .html and isControl(el.tag) and el.hasAttr("required"),
        .optional => el.ns == .html and isControl(el.tag) and !el.hasAttr("required"),
        .placeholder_shown => placeholderShown(el),
        .read_write => editableText(el),
        .read_only => !editableText(el),
        .scope => if (ctx.scope) |s| s == el else doc.documentElement() == el,
        .target => blk: {
            const hash = std.mem.indexOfScalar(u8, doc.url, '#') orelse break :blk false;
            const id = el.attr("id") orelse break :blk false;
            break :blk std.mem.eql(u8, doc.url[hash + 1 ..], id);
        },
        .defined => true,
        .modal => el.modal,
        .popover_open => el.popover_open,
        .open => el.popover_open or el.modal or ((el.isTag("details") or el.isTag("dialog")) and el.hasAttr("open")),
        .default => isChecked(el) or (el.isTag("button") and !el.hasAttr("type")),
        .valid => isControl(el.tag) or el.isTag("form"),
        .indeterminate => el.isTag("progress") and !el.hasAttr("value"),
        // Parsed to `nth`.
        .first_child, .last_child, .first_of_type, .last_of_type => false,
    };
}

/// Whether `el` is or holds the state's node: `:hover` covers the ancestors.
fn contained(state: ?*Node, el: *const Node) bool {
    const n = state orelse return false;
    return el.contains(n);
}

fn nth(n: *const sel.Nth, el: *Node, ctx: *Ctx) bool {
    if (el.parent == null) return false;
    if (n.of.len > 0 and !matchesAny(n.of, el, ctx)) return false;
    var index: i32 = 1;
    const plain = !n.of_type and n.of.len == 0 and !n.from_end;
    if (plain and ctx.nth_node != null and el.prevElement() == ctx.nth_node) {
        index = ctx.nth_index + 1;
    } else {
        var c = if (n.from_end) el.nextElement() else el.prevElement();
        while (c) |k| : (c = if (n.from_end) k.nextElement() else k.prevElement()) {
            if (n.of_type) {
                if (k.ns == el.ns and std.mem.eql(u8, k.tag, el.tag)) index += 1;
            } else if (n.of.len > 0) {
                if (matchesAny(n.of, k, ctx)) index += 1;
            } else {
                index += 1;
            }
        }
    }
    if (plain) {
        ctx.nth_node = el;
        ctx.nth_index = index;
    }
    if (n.a == 0) return index == n.b;
    const d = index - n.b;
    if (n.a > 0) return d >= 0 and @rem(d, n.a) == 0;
    return d <= 0 and @rem(d, n.a) == 0;
}

fn has(list: []const Selector, el: *Node, ctx: *Ctx) bool {
    for (list) |*s| {
        if (s.compounds.len == 0) continue;
        const last = s.compounds.len - 1;
        if (s.leading == .descendant or s.leading == .child) {
            var at = el.first_child;
            while (at) |n| : (at = n.nextInTree(el)) {
                if (n.kind == .element and from(s, last, n, ctx, el)) return true;
            }
        } else {
            var sib = el.nextElement();
            while (sib) |sb| : (sib = sb.nextElement()) {
                var at: ?*Node = sb;
                while (at) |n| : (at = n.nextInTree(sb)) {
                    if (n.kind == .element and from(s, last, n, ctx, el)) return true;
                }
            }
        }
    }
    return false;
}

fn lang(want: []const u8, el: *const Node) bool {
    var at: ?*const Node = el;
    while (at) |n| : (at = n.parent) {
        const v = n.attr("lang") orelse continue;
        if (want.len == 0 or v.len < want.len) return false;
        if (!std.ascii.eqlIgnoreCase(v[0..want.len], want)) return false;
        return v.len == want.len or v[want.len] == '-';
    }
    return false;
}
