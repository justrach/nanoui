//! What a hover, active or focus flip can affect: the highest element whose
//! style may change. Conservative where it cannot tell, never too low.
const std = @import("std");
const dom = @import("../dom.zig");
const sel = @import("selectors.zig");
const match = @import("selector_match.zig");
const rule_index = @import("rule_index.zig");

const Node = dom.Node;

/// Which state changed. A hover says nothing of `:focus-within`: a page with
/// `html:focus-within` would otherwise restyle whole on every hover.
pub const Flip = enum { hover, active, focus };

fn pseudoFlips(p: sel.PseudoClass, flip: Flip, is_self: bool) bool {
    return switch (flip) {
        .hover => p == .hover,
        .active => p == .active,
        .focus => p == .focus_within or (is_self and (p == .focus or p == .focus_visible)),
    };
}

fn listFlips(l: []const sel.Selector, flip: Flip) bool {
    for (l) |*x| {
        if (!x.uses_state) continue;
        // Anywhere inside a list, an element other than `node` may be the one tested.
        for (x.compounds) |*c| if (compoundFlips(c, flip, true)) return true;
    }
    return false;
}

/// Whether a flip at `is_self` (the flipping node, not an ancestor of it)
/// reaches this compound: `:focus` holds of the node alone, the rest of its
/// ancestors too.
fn compoundFlips(c: *const sel.Compound, flip: Flip, is_self: bool) bool {
    for (c.simples) |*s| switch (s.*) {
        .pseudo => |p| if (pseudoFlips(p, flip, is_self)) return true,
        .not, .is, .has, .host, .host_context => |l| if (listFlips(l, flip)) return true,
        .nth => |n| if (listFlips(n.of, flip)) return true,
        else => {},
    };
    return false;
}

fn hasStateOnSibling(s: *const sel.Selector, flip: Flip) bool {
    for (s.compounds) |*c| for (c.simples) |*x| switch (x.*) {
        .has => |l| for (l) |*y| {
            if (y.leading != .next and y.leading != .later) continue;
            if (listFlips(y[0..1], flip)) return true;
        },
        else => {},
    };
    return false;
}

/// See `Engine.invalidatedByState`. A flip changes the state of `node` and, for
/// `:hover`, `:active` and `:focus-within`, of each ancestor; any of them may be
/// the compound a selector's state test sits on.
pub fn invalidatedBy(ix: *const rule_index.Index, doc: *dom.Document, node: *Node, flip: Flip) ?*Node {
    if (ix.state_deps.items.len == 0) return null;
    var ctx: match.Ctx = .{ .doc = doc, .loose_state = true };
    var highest: ?*Node = null;
    var at: ?*Node = if (node.kind == .element) node else node.parentElement();
    while (at) |a| : (at = a.parentElement()) {
        for (ix.state_deps.items) |dep| {
            const hit = affected(dep.sel, a, a == node, flip, &ctx, doc) orelse continue;
            if (highest == null or hit.contains(highest.?)) highest = hit;
        }
    }
    return highest;
}

/// The element that must restyle if `a`'s state flip affects this selector.
fn affected(s: *const sel.Selector, a: *Node, is_self: bool, flip: Flip, ctx: *match.Ctx, doc: *dom.Document) ?*Node {
    // `:has(+ :hover)` sits on an element off the pointer's chain: only the root
    // is safe. Other `:has`es sit on an ancestor, which the loop below finds.
    if (hasStateOnSibling(s, flip)) return doc.documentElement();
    for (s.compounds, 0..) |*c, i| {
        if (!compoundFlips(c, flip, is_self)) continue;
        if (!match.compound(c, a, ctx)) continue;
        // A sibling combinator to its right reaches beyond `a`'s subtree.
        var sibling = false;
        var j = i + 1;
        while (j < s.compounds.len) : (j += 1) {
            const cb = s.compounds[j].combinator;
            if (cb == .next or cb == .later) sibling = true;
        }
        if (sibling) return a.parentElement() orelse a;
        return a;
    }
    return null;
}
