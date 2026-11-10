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

fn parse(doc: *dom.Document, arena: Allocator, trimmed: []const u8) Error![]const selectors.Selector {
    if (trimmed.len > 0 and trimmed.len <= 256) {
        const idx = std.hash.Fnv1a_32.hash(trimmed) & 31;
        if (doc.sel_cache_ptrs[idx]) |ptr| {
            if (std.mem.eql(u8, doc.sel_cache_keys[idx], trimmed)) {
                const p: [*]const selectors.Selector = @ptrCast(@alignCast(ptr));
                return p[0..doc.sel_cache_lens[idx]];
            }
        }
        const key_copy = try doc.arena.dupe(u8, trimmed);
        const list = (try selectors.parseText(doc.arena, key_copy)) orelse return error.InvalidSelector;
        doc.sel_cache_keys[idx] = key_copy;
        doc.sel_cache_ptrs[idx] = list.ptr;
        doc.sel_cache_lens[idx] = @intCast(list.len);
        return list;
    }
    const list = try selectors.parseText(arena, trimmed);
    return list orelse error.InvalidSelector;
}

const TagClass = struct { tag: []const u8, cls: []const u8 };

fn parseTagClass(trimmed: []const u8) ?TagClass {
    const dot = std.mem.indexOfScalar(u8, trimmed, '.') orelse return null;
    if (dot == 0 or dot + 1 >= trimmed.len) return null;
    const tag = trimmed[0..dot];
    const cls = trimmed[dot + 1 ..];
    if (!isPlainLowerIdent(tag) or !isPlainIdent(cls)) return null;
    return .{ .tag = tag, .cls = cls };
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

fn isPlainIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '-') {
        if (s.len < 2 or !(std.ascii.isAlphabetic(s[1]) or s[1] == '_')) return false;
    } else if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) {
        return false;
    }
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    }
    return true;
}

fn isPlainLowerIdent(s: []const u8) bool {
    if (!isPlainIdent(s)) return false;
    for (s) |c| if (c >= 'A' and c <= 'Z') return false;
    return true;
}

inline fn fastTagMatches(want: []const u8, el: *const Node) bool {
    return if (el.ns == .html) std.mem.eql(u8, want, el.tag) else std.ascii.eqlIgnoreCase(want, el.tag);
}

const Anchor = union(enum) {
    full: *Node,
    none,
    single: *Node,
};

/// Theorem 19 (`id_anchored_query_selector_sound`): prunes `root`'s search space
/// when a single selector is anchored on a `#id` in its leftmost compound.
fn resolveIdAnchor(root: *Node, list: []const selectors.Selector) Anchor {
    if (list.len != 1 or root.doc.quirks) return .{ .full = root };
    const s = &list[0];
    if (s.pseudo != .none or s.compounds.len == 0) return .{ .full = root };
    var want_id: ?[]const u8 = null;
    for (s.compounds[0].simples) |*sim| switch (sim.*) {
        .id => |id| {
            want_id = id;
            break;
        },
        .host, .host_context => return .{ .full = root },
        else => {},
    };
    const id = want_id orelse return .{ .full = root };
    for (s.compounds[1..]) |*c| {
        if (c.combinator != .descendant and c.combinator != .child) return .{ .full = root };
    }
    if (!root.doc.node.contains(root)) return .{ .full = root };
    const first = root.doc.getElementById(id) orelse return .none;
    if (root.doc.id_map_gen != root.doc.id_generation) {
        @constCast(root.doc).id_last_key = "";
        _ = root.doc.getElementById(id);
    }
    if (root.doc.id_has_dups) return .{ .full = root };
    if (s.compounds.len == 1) {
        if (first != root and root.contains(first)) return .{ .single = first };
        return .none;
    }
    if (root.contains(first)) return .{ .full = first };
    if (first.contains(root)) return .{ .full = root };
    return .none;
}

/// The first element in `root` (not `root` itself) matching `selector`, in
/// document order. `arena` holds the parsed selector.
pub fn querySelector(root: *Node, selector: []const u8, arena: Allocator) Error!?*Node {
    const trimmed = std.mem.trim(u8, selector, " \t\r\n\x0c");
    if (!root.doc.quirks and trimmed.len > 1) {
        if (trimmed[0] == '#' and isPlainIdent(trimmed[1..])) {
            const want = trimmed[1..];
            if (root == root.doc.node) return root.doc.getElementById(want);
            if (root.doc.node.contains(root)) {
                const first = root.doc.getElementById(want) orelse return null;
                if (first != root and root.contains(first)) return first;
            }
            var at = root.first_child;
            while (at) |n| : (at = n.nextInTree(root)) {
                if (n.kind == .element) if (n.attr("id")) |v| if (std.mem.eql(u8, v, want)) return n;
            }
            return null;
        }
        if (trimmed[0] == '.' and isPlainIdent(trimmed[1..])) {
            const want = trimmed[1..];
            var at = root.first_child;
            while (at) |n| : (at = n.nextInTree(root)) {
                if (n.kind == .element and n.hasClass(want)) return n;
            }
            return null;
        }
        if (parseTagClass(trimmed)) |tc| {
            var at = root.first_child;
            while (at) |n| : (at = n.nextInTree(root)) {
                if (n.kind == .element and fastTagMatches(tc.tag, n) and n.hasClass(tc.cls)) return n;
            }
            return null;
        }
    }
    if (isPlainLowerIdent(trimmed)) {
        var at = root.first_child;
        while (at) |n| : (at = n.nextInTree(root)) {
            if (n.kind == .element and fastTagMatches(trimmed, n)) return n;
        }
        return null;
    }
    const list = try parse(root.doc, arena, trimmed);
    var ctx = context(root);
    switch (resolveIdAnchor(root, list)) {
        .none => return null,
        .single => |n| return if (n.kind == .element and hit(list, n, &ctx)) n else null,
        .full => |walk_root| {
            var at = walk_root.first_child;
            while (at) |n| : (at = n.nextInTree(walk_root)) {
                if (n.kind == .element and hit(list, n, &ctx)) return n;
            }
            return null;
        },
    }
}

/// Appends every matching element to `out`, which `arena` grows.
pub fn querySelectorAll(root: *Node, selector: []const u8, arena: Allocator, out: *std.ArrayList(*Node)) Error!void {
    const trimmed = std.mem.trim(u8, selector, " \t\r\n\x0c");
    if (!root.doc.quirks and trimmed.len > 1) {
        if (trimmed[0] == '.' and isPlainIdent(trimmed[1..])) {
            const want = trimmed[1..];
            var at = root.first_child;
            while (at) |n| : (at = n.nextInTree(root)) {
                if (n.kind == .element and n.hasClass(want)) try out.append(arena, n);
            }
            return;
        }
        if (parseTagClass(trimmed)) |tc| {
            var at = root.first_child;
            while (at) |n| : (at = n.nextInTree(root)) {
                if (n.kind == .element and fastTagMatches(tc.tag, n) and n.hasClass(tc.cls)) try out.append(arena, n);
            }
            return;
        }
    }
    if (isPlainLowerIdent(trimmed)) {
        var at = root.first_child;
        while (at) |n| : (at = n.nextInTree(root)) {
            if (n.kind == .element and fastTagMatches(trimmed, n)) try out.append(arena, n);
        }
        return;
    }
    const list = try parse(root.doc, arena, trimmed);
    var ctx = context(root);
    switch (resolveIdAnchor(root, list)) {
        .none => return,
        .single => |n| if (n.kind == .element and hit(list, n, &ctx)) try out.append(arena, n),
        .full => |walk_root| {
            var at = walk_root.first_child;
            while (at) |n| : (at = n.nextInTree(walk_root)) {
                if (n.kind == .element and hit(list, n, &ctx)) try out.append(arena, n);
            }
        },
    }
}

pub fn matchesSelector(node: *Node, selector: []const u8, arena: Allocator) Error!bool {
    const trimmed = std.mem.trim(u8, selector, " \t\r\n\x0c");
    if (!node.doc.quirks and trimmed.len > 1) {
        if (trimmed[0] == '.' and isPlainIdent(trimmed[1..])) {
            return node.kind == .element and node.hasClass(trimmed[1..]);
        }
        if (parseTagClass(trimmed)) |tc| {
            return node.kind == .element and fastTagMatches(tc.tag, node) and node.hasClass(tc.cls);
        }
    }
    if (isPlainLowerIdent(trimmed)) {
        return node.kind == .element and fastTagMatches(trimmed, node);
    }
    const list = try parse(node.doc, arena, trimmed);
    if (node.kind != .element) return false;
    var ctx = context(node);
    return hit(list, node, &ctx);
}

/// `node` or its nearest ancestor that matches.
pub fn closest(node: *Node, selector: []const u8, arena: Allocator) Error!?*Node {
    const trimmed = std.mem.trim(u8, selector, " \t\r\n\x0c");
    if (!node.doc.quirks and trimmed.len > 1) {
        if (trimmed[0] == '.' and isPlainIdent(trimmed[1..])) {
            const want = trimmed[1..];
            var at: ?*Node = if (node.kind == .element) node else node.parentElement();
            while (at) |n| : (at = n.parentElement()) {
                if (n.is_shadow) return null;
                if (n.hasClass(want)) return n;
            }
            return null;
        }
        if (parseTagClass(trimmed)) |tc| {
            var at: ?*Node = if (node.kind == .element) node else node.parentElement();
            while (at) |n| : (at = n.parentElement()) {
                if (n.is_shadow) return null;
                if (fastTagMatches(tc.tag, n) and n.hasClass(tc.cls)) return n;
            }
            return null;
        }
    }
    if (isPlainLowerIdent(trimmed)) {
        var at: ?*Node = if (node.kind == .element) node else node.parentElement();
        while (at) |n| : (at = n.parentElement()) {
            if (n.is_shadow) return null;
            if (fastTagMatches(trimmed, n)) return n;
        }
        return null;
    }
    const list = try parse(node.doc, arena, trimmed);
    var ctx = context(node);
    var at: ?*Node = if (node.kind == .element) node else node.parentElement();
    while (at) |n| : (at = n.parentElement()) {
        // A shadow tree ends at its root, which is no element to scripts.
        if (n.is_shadow) return null;
        if (hit(list, n, &ctx)) return n;
    }
    return null;
}
