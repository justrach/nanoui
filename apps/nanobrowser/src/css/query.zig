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

    inline fn allowsSubtree(sf: SubjectFilter, n: *const Node) bool {
        if (!sf.active) return true;
        if ((n.subtree_class_bloom & sf.class_bits) != sf.class_bits) return false;
        if ((n.subtree_attr_bloom & sf.attr_bits) != sf.attr_bits) return false;
        return true;
    }
};

fn parse(doc: *dom.Document, arena: Allocator, trimmed: []const u8) Error![]const selectors.Selector {
    if (trimmed.len > 0 and trimmed.len <= 256) {
        const idx = std.hash.Fnv1a_32.hash(trimmed) & 127;
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
const AttrFast = struct { tag: ?[]const u8, attr: []const u8, val: ?[]const u8, attr_bit: u64, ci_html: bool };

fn parseTagClass(trimmed: []const u8) ?TagClass {
    const dot = std.mem.indexOfScalar(u8, trimmed, '.') orelse return null;
    if (dot == 0 or dot + 1 >= trimmed.len) return null;
    const tag = trimmed[0..dot];
    const cls = trimmed[dot + 1 ..];
    if (!isPlainLowerIdent(tag) or !isPlainIdent(cls)) return null;
    return .{ .tag = tag, .cls = cls };
}

fn parseAttrFast(trimmed: []const u8) ?AttrFast {
    if (trimmed.len < 3 or trimmed[trimmed.len - 1] != ']') return null;
    const lb = std.mem.indexOfScalar(u8, trimmed, '[') orelse return null;
    const tag: ?[]const u8 = if (lb == 0) null else blk: {
        if (!isPlainLowerIdent(trimmed[0..lb])) return null;
        break :blk trimmed[0..lb];
    };
    const inner = std.mem.trim(u8, trimmed[lb + 1 .. trimmed.len - 1], " \t\r\n\x0c");
    if (inner.len == 0) return null;
    const eq = std.mem.indexOfScalar(u8, inner, '=');
    if (eq == null) {
        if (!isPlainLowerIdent(inner)) return null;
        return .{ .tag = tag, .attr = inner, .val = null, .attr_bit = perf.attrBit(inner), .ci_html = false };
    }
    const eq_i = eq.?;
    const aname = std.mem.trimEnd(u8, inner[0..eq_i], " \t\r\n\x0c");
    if (!isPlainLowerIdent(aname)) return null;
    const rhs = std.mem.trimStart(u8, inner[eq_i + 1 ..], " \t\r\n\x0c");
    if (rhs.len == 0) return null;
    var val: []const u8 = undefined;
    if (rhs[0] == '"' or rhs[0] == '\'') {
        const q = rhs[0];
        if (rhs.len < 2 or rhs[rhs.len - 1] != q) return null;
        val = rhs[1 .. rhs.len - 1];
        for (val) |c| if (c == q or c == '\\' or c == 0) return null;
    } else {
        if (!isPlainIdent(rhs)) return null;
        val = rhs;
    }
    return .{ .tag = tag, .attr = aname, .val = val, .attr_bit = perf.attrBit(aname), .ci_html = match.isCiHtmlAttr(aname) };
}

inline fn fastAttrMatches(af: AttrFast, el: *const Node) bool {
    if ((el.attr_filter & af.attr_bit) == 0) return false;
    if (af.tag) |t| if (!fastTagMatches(t, el)) return false;
    const v = el.attr(af.attr) orelse return false;
    const want = af.val orelse return true;
    return if (af.ci_html and el.ns == .html) std.ascii.eqlIgnoreCase(v, want) else std.mem.eql(u8, v, want);
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
            const bit = perf.classBit(want);
            if ((root.subtree_class_bloom & bit) == 0) return null;
            var at = root.first_child;
            while (at) |n| {
                if ((n.subtree_class_bloom & bit) == 0) {
                    at = n.nextSkippingChildren(root);
                    continue;
                }
                if (n.kind == .element and n.hasClass(want)) return n;
                at = n.nextInTree(root);
            }
            return null;
        }
        if (parseTagClass(trimmed)) |tc| {
            const bit = perf.classBit(tc.cls);
            if ((root.subtree_class_bloom & bit) == 0) return null;
            var at = root.first_child;
            while (at) |n| {
                if ((n.subtree_class_bloom & bit) == 0) {
                    at = n.nextSkippingChildren(root);
                    continue;
                }
                if (n.kind == .element and fastTagMatches(tc.tag, n) and n.hasClass(tc.cls)) return n;
                at = n.nextInTree(root);
            }
            return null;
        }
        if (parseAttrFast(trimmed)) |af| {
            if ((root.subtree_attr_bloom & af.attr_bit) == 0) return null;
            var at = root.first_child;
            while (at) |n| {
                if ((n.subtree_attr_bloom & af.attr_bit) == 0) {
                    at = n.nextSkippingChildren(root);
                    continue;
                }
                if (n.kind == .element and fastAttrMatches(af, n)) return n;
                at = n.nextInTree(root);
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
            if (!sf.allowsSubtree(walk_root)) return null;
            var at = walk_root.first_child;
            while (at) |n| {
                if (!sf.allowsSubtree(n)) {
                    at = n.nextSkippingChildren(walk_root);
                    continue;
                }
                if (n.kind == .element and sf.allows(n) and hit(list, n, &ctx)) return n;
                at = n.nextInTree(walk_root);
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
            const bit = perf.classBit(want);
            if ((root.subtree_class_bloom & bit) == 0) return;
            var at = root.first_child;
            while (at) |n| {
                if ((n.subtree_class_bloom & bit) == 0) {
                    at = n.nextSkippingChildren(root);
                    continue;
                }
                if (n.kind == .element and n.hasClass(want)) try out.append(arena, n);
                at = n.nextInTree(root);
            }
            return;
        }
        if (parseTagClass(trimmed)) |tc| {
            const bit = perf.classBit(tc.cls);
            if ((root.subtree_class_bloom & bit) == 0) return;
            var at = root.first_child;
            while (at) |n| {
                if ((n.subtree_class_bloom & bit) == 0) {
                    at = n.nextSkippingChildren(root);
                    continue;
                }
                if (n.kind == .element and fastTagMatches(tc.tag, n) and n.hasClass(tc.cls)) try out.append(arena, n);
                at = n.nextInTree(root);
            }
            return;
        }
        if (parseAttrFast(trimmed)) |af| {
            if ((root.subtree_attr_bloom & af.attr_bit) == 0) return;
            var at = root.first_child;
            while (at) |n| {
                if ((n.subtree_attr_bloom & af.attr_bit) == 0) {
                    at = n.nextSkippingChildren(root);
                    continue;
                }
                if (n.kind == .element and fastAttrMatches(af, n)) try out.append(arena, n);
                at = n.nextInTree(root);
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
            if (!sf.allowsSubtree(walk_root)) return;
            var at = walk_root.first_child;
            while (at) |n| {
                if (!sf.allowsSubtree(n)) {
                    at = n.nextSkippingChildren(walk_root);
                    continue;
                }
                if (n.kind == .element and sf.allows(n) and hit(list, n, &ctx)) try out.append(arena, n);
                at = n.nextInTree(walk_root);
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
        if (parseAttrFast(trimmed)) |af| {
            return node.kind == .element and fastAttrMatches(af, node);
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
        if (parseAttrFast(trimmed)) |af| {
            var at: ?*Node = if (node.kind == .element) node else node.parentElement();
            while (at) |n| : (at = n.parentElement()) {
                if (n.is_shadow) return null;
                if (fastAttrMatches(af, n)) return n;
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
