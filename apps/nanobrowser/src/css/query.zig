//! The selector API on the DOM: `querySelector`, `querySelectorAll`, `matches`
//! and `closest`. An invalid selector is `error.InvalidSelector`, which script
//! bindings turn into a SyntaxError.
const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../dom.zig");
const selectors = @import("selectors.zig");
const match = @import("selector_match.zig");
const perf = @import("../perf_rules.zig");

const Node = dom.Node;
pub const Error = Allocator.Error || error{InvalidSelector};

fn inLightDocument(root: *const Node) bool {
    var at: ?*const Node = root;
    while (at) |x| : (at = x.parent) {
        if (x.is_shadow) return false;
        if (x == root.doc.node) return true;
    }
    return false;
}

const SubjectFilter = struct {
    active: bool = false,
    req_tag: ?[]const u8 = null,
    class_bits: u64 = 0,
    attr_bits: u64 = 0,

    fn fromList(root: *const Node, list: []const selectors.Selector) SubjectFilter {
        var sf: SubjectFilter = .{};
        if (list.len != 1 or root.doc.quirks) return sf;
        const s = &list[0];
        if (s.pseudo != .none or s.compounds.len == 0) return sf;
        const subj = &s.compounds[s.compounds.len - 1];
        for (subj.simples) |*sim| switch (sim.*) {
            .tag => |t| {
                sf.req_tag = t;
                sf.active = true;
            },
            .class => |c| {
                sf.class_bits |= perf.classBit(c);
                sf.active = true;
            },
            .attr => |a| {
                sf.attr_bits |= perf.attrBit(a.lower);
                sf.active = true;
            },
            else => {},
        };
        return sf;
    }

    inline fn allows(sf: SubjectFilter, n: *const Node) bool {
        if (!sf.active) return true;
        if ((n.class_filter & sf.class_bits) != sf.class_bits) return false;
        if ((n.attr_filter & sf.attr_bits) != sf.attr_bits) return false;
        if (sf.req_tag) |t| if (!fastTagMatches(t, n)) return false;
        return true;
    }
};

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
/// when a single selector is anchored on a `#id` in its subject or ancestor compound.
fn resolveIdAnchor(root: *Node, list: []const selectors.Selector) Anchor {
    if (list.len != 1 or root.doc.quirks) return .{ .full = root };
    const s = &list[0];
    if (s.pseudo != .none or s.compounds.len == 0) return .{ .full = root };
    if (!inLightDocument(root)) return .{ .full = root };
    var want_id: ?[]const u8 = null;
    var id_compound: usize = 0;
    var k: usize = s.compounds.len;
    while (k > 0) {
        k -= 1;
        for (s.compounds[k].simples) |*sim| switch (sim.*) {
            .id => |id| {
                if (want_id == null) {
                    want_id = id;
                    id_compound = k;
                }
            },
            .host, .host_context => return .{ .full = root },
            else => {},
        };
        if (want_id != null) break;
        const comb = s.compounds[k].combinator;
        if (comb != .descendant and comb != .child) break;
    }
    const id = want_id orelse return .{ .full = root };
    const first = root.doc.getElementById(id) orelse return .none;
    if (root.doc.id_map_gen != root.doc.id_generation) {
        @constCast(root.doc).id_last_key = "";
        _ = root.doc.getElementById(id);
    }
    if (root.doc.id_has_dups) return .{ .full = root };
    if (id_compound + 1 == s.compounds.len) {
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
    const t0 = perf.nowNs();
    defer perf.prof_query_ns += perf.nowNs() -| t0;
    const trimmed = std.mem.trim(u8, selector, " \t\r\n\x0c");
    if (!root.doc.quirks and trimmed.len > 1) {
        if (trimmed[0] == '#' and isPlainIdent(trimmed[1..])) {
            const want = trimmed[1..];
            if (root == root.doc.node) return root.doc.getElementById(want);
            if (!root.has_id) return null;
            if (inLightDocument(root)) {
                const first = root.doc.getElementById(want) orelse return null;
                if (first != root and root.contains(first)) return first;
            }
            var at = root.first_child;
            while (at) |n| : (at = if (n.has_id) n.nextInTree(root) else n.nextSkippingChildren(root)) {
                if (n.kind == .element) if (n.id_attr) |v| if (std.mem.eql(u8, v, want)) return n;
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
            const sf = SubjectFilter.fromList(root, list);
            var at = walk_root.first_child;
            while (at) |n| : (at = n.nextInTree(walk_root)) {
                if (n.kind == .element and sf.allows(n) and hit(list, n, &ctx)) return n;
            }
            return null;
        },
    }
}

/// Appends every matching element to `out`, which `arena` grows.
pub fn querySelectorAll(root: *Node, selector: []const u8, arena: Allocator, out: *std.ArrayList(*Node)) Error!void {
    const t0 = perf.nowNs();
    defer perf.prof_query_ns += perf.nowNs() -| t0;
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
            const sf = SubjectFilter.fromList(root, list);
            var at = walk_root.first_child;
            while (at) |n| : (at = n.nextInTree(walk_root)) {
                if (n.kind == .element and sf.allows(n) and hit(list, n, &ctx)) try out.append(arena, n);
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
