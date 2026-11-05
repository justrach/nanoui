//! What a hover, active or focus flip can affect: the highest element whose
//! style may change. Conservative where it cannot tell, never too low.
const std = @import("std");
const dom = @import("../dom.zig");
const sel = @import("selectors.zig");
const match = @import("selector_match.zig");
const rule_index = @import("rule_index.zig");

const Node = dom.Node;

/// Whether a flip at `is_self` (the flipping node, not an ancestor of it)
/// reaches this compound: `:focus` holds of the node alone, the rest of its
/// ancestors too.
fn compoundHasState(c: *const sel.Compound, is_self: bool) bool {
    for (c.simples) |*s| switch (s.*) {
        .pseudo => |p| switch (p) {
            .hover, .active, .focus_within => return true,
            .focus, .focus_visible => if (is_self) return true,
            else => {},
        },
        .not, .is, .has => |l| for (l) |x| if (x.uses_state) return true,
        .nth => |n| for (n.of) |x| if (x.uses_state) return true,
        else => {},
    };
    return false;
}

fn hasStateOnSibling(s: *const sel.Selector) bool {
    for (s.compounds) |*c| for (c.simples) |*x| switch (x.*) {
        .has => |l| for (l) |y| if (y.uses_state and (y.leading == .next or y.leading == .later)) return true,
        else => {},
    };
    return false;
}

/// See `Engine.invalidatedByState`. A flip changes the state of `node` and, for
/// `:hover`, `:active` and `:focus-within`, of each ancestor; any of them may be
/// the compound a selector's state test sits on.
pub fn invalidatedBy(ix: *const rule_index.Index, doc: *dom.Document, node: *Node) ?*Node {
    if (ix.state_deps.items.len == 0) return null;
    var ctx: match.Ctx = .{ .doc = doc, .loose_state = true };
    var highest: ?*Node = null;
    var at: ?*Node = if (node.kind == .element) node else node.parentElement();
    while (at) |a| : (at = a.parentElement()) {
        for (ix.state_deps.items) |dep| {
            const hit = affected(dep.sel, a, a == node, &ctx, doc) orelse continue;
            if (highest == null or hit.contains(highest.?)) highest = hit;
        }
    }
    return highest;
}

/// The element that must restyle if `a`'s state flip affects this selector.
fn affected(s: *const sel.Selector, a: *Node, is_self: bool, ctx: *match.Ctx, doc: *dom.Document) ?*Node {
    // `:has(+ :hover)` sits on an element off the pointer's chain: only the root
    // is safe. Other `:has`es sit on an ancestor, which the loop below finds.
    if (hasStateOnSibling(s)) return doc.documentElement();
    for (s.compounds, 0..) |*c, i| {
        if (!compoundHasState(c, is_self)) continue;
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
