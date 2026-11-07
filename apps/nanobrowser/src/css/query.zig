//! The selector API on the DOM: `querySelector`, `querySelectorAll`, `matches`
//! and `closest`. An invalid selector is `error.InvalidSelector`, which script
//! bindings turn into a SyntaxError.
const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../dom.zig");
const selectors = @import("selectors.zig");
const match = @import("selector_match.zig");

const Node = dom.Node;
pub const Error = Allocator.Error || error{InvalidSelector};

fn parse(arena: Allocator, text: []const u8) Error![]const selectors.Selector {
    const list = try selectors.parseText(arena, text);
    return list orelse error.InvalidSelector;
}

fn hit(list: []const selectors.Selector, n: *Node, ctx: *match.Ctx) bool {
    for (list) |*s| {
        // Pseudo-elements are not in the tree: `a::before` selects nothing.
        if (s.pseudo == .none and match.matches(s, n, ctx)) return true;
    }
    return false;
}

fn context(root: *Node) match.Ctx {
    return .{ .doc = root.doc, .scope = if (root.kind == .element) root else null };
}

/// The first element in `root` (not `root` itself) matching `selector`, in
/// document order. `arena` holds the parsed selector.
pub fn querySelector(root: *Node, selector: []const u8, arena: Allocator) Error!?*Node {
    const list = try parse(arena, selector);
    var ctx = context(root);
    var at = root.first_child;
    while (at) |n| : (at = n.nextInTree(root)) {
        if (n.kind == .element and hit(list, n, &ctx)) return n;
    }
    return null;
}

/// Appends every matching element to `out`, which `arena` grows.
pub fn querySelectorAll(root: *Node, selector: []const u8, arena: Allocator, out: *std.ArrayList(*Node)) Error!void {
    const list = try parse(arena, selector);
    var ctx = context(root);
    var at = root.first_child;
    while (at) |n| : (at = n.nextInTree(root)) {
        if (n.kind == .element and hit(list, n, &ctx)) try out.append(arena, n);
    }
}

pub fn matchesSelector(node: *Node, selector: []const u8, arena: Allocator) Error!bool {
    const list = try parse(arena, selector);
    if (node.kind != .element) return false;
    var ctx = context(node);
    return hit(list, node, &ctx);
}

/// `node` or its nearest ancestor that matches.
pub fn closest(node: *Node, selector: []const u8, arena: Allocator) Error!?*Node {
    const list = try parse(arena, selector);
    var ctx = context(node);
    var at: ?*Node = if (node.kind == .element) node else node.parentElement();
    while (at) |n| : (at = n.parentElement()) {
        // A shadow tree ends at its root, which is no element to scripts.
        if (n.is_shadow) return null;
        if (hit(list, n, &ctx)) return n;
    }
    return null;
}
