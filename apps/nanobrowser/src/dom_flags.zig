//! Upward-propagated DOM subtree flags and Bloom filters (`subtree_class_bloom`,
//! `subtree_attr_bloom`, `subtree_layout_dirty`, `has_resource`, `has_id`,
//! `has_insertion_work`) for selector subtree pruning and incremental layout.
const std = @import("std");
const dom = @import("dom.zig");

/// Marks `n` and all of its ancestors as having a layout-dirty subtree.
/// Stops in O(1) as soon as an already-dirty ancestor is reached.
pub inline fn markSubtreeLayoutDirty(n: *dom.Node) void {
    var at: ?*dom.Node = n;
    while (at) |x| : (at = x.parent) {
        if (x.subtree_layout_dirty) break;
        x.subtree_layout_dirty = true;
    }
}

/// Clears `subtree_layout_dirty` on all dirty nodes reachable under `root`,
/// skipping already-clean subtrees in O(1) per clean sibling via `nextDeepSkipping`.
pub fn clearSubtreeLayoutDirty(root: *dom.Node) void {
    if (!root.subtree_layout_dirty) return;
    var at: ?*dom.Node = root;
    while (at) |n| {
        if (!n.subtree_layout_dirty) {
            at = n.nextDeepSkipping(root);
            continue;
        }
        n.subtree_layout_dirty = false;
        at = n.nextDeep(root);
    }
}

/// Propagates `n`'s own `class_filter` and `attr_filter` bits upward into
/// `subtree_class_bloom` and `subtree_attr_bloom` on `n` and its ancestors.
pub inline fn propagateSelfAttrs(n: *dom.Node) void {
    const add_cls = n.class_filter & ~n.subtree_class_bloom;
    const add_att = n.attr_filter & ~n.subtree_attr_bloom;
    if ((add_cls | add_att) == 0) return;
    var at: ?*dom.Node = n;
    while (at) |x| : (at = x.parent) {
        if ((x.subtree_class_bloom & add_cls) == add_cls and (x.subtree_attr_bloom & add_att) == add_att) break;
        x.subtree_class_bloom |= add_cls;
        x.subtree_attr_bloom |= add_att;
    }
}

/// Propagates child summary flags and Bloom bits upward when inserting into `n`,
/// and marks `n`'s ancestor spine layout-dirty.
pub fn propagateInsert(
    n: *dom.Node,
    has_res: bool,
    has_id: bool,
    has_work: bool,
    sub_cls: u64,
    sub_att: u64,
) void {
    markSubtreeLayoutDirty(n);
    if (has_res) {
        var at: ?*dom.Node = n;
        while (at) |x| : (at = x.parent) x.has_resource = true;
        n.doc.scan_dirty = true;
    }
    if (has_id and !n.has_id) {
        var at: ?*dom.Node = n;
        while (at) |x| : (at = x.parent) {
            if (x.has_id) break;
            x.has_id = true;
        }
    }
    if (has_work and !n.has_insertion_work) {
        var at: ?*dom.Node = n;
        while (at) |x| : (at = x.parent) {
            if (x.has_insertion_work) break;
            x.has_insertion_work = true;
        }
    }
    const add_cls = sub_cls & ~n.subtree_class_bloom;
    const add_att = sub_att & ~n.subtree_attr_bloom;
    if ((add_cls | add_att) != 0) {
        var at: ?*dom.Node = n;
        while (at) |x| : (at = x.parent) {
            if ((x.subtree_class_bloom & add_cls) == add_cls and (x.subtree_attr_bloom & add_att) == add_att) break;
            x.subtree_class_bloom |= add_cls;
            x.subtree_attr_bloom |= add_att;
        }
    }
}

fn canScopeChildStyle(d: *const dom.Document, p: *const dom.Node) bool {
    if (d.dirty_all or d.scan_dirty or p.kind != .element or p.ns != .html or p.computed == null) return false;
    if (p.tree_scope != null or p.shadow_root != null) return false;
    if ((d.rule_flags & (1 | 4 | 8)) != 0) return false;
    if (p.html_tag == .details or p.isTag("style") or p.isTag("select") or p.isTag("optgroup")) return false;
    return true;
}

fn hasNonEmptyChild(p: *const dom.Node) bool {
    var ch = p.first_child;
    while (ch) |k| : (ch = k.next) {
        if (k.kind == .element or (k.kind == .text and k.data.len > 0)) return true;
    }
    return false;
}

fn hasNonEmptyOutside(first: *const dom.Node, last: *const dom.Node) bool {
    var b = first.prev;
    while (b) |k| : (b = k.prev) if (k.kind == .element or (k.kind == .text and k.data.len > 0)) return true;
    var f = last.next;
    while (f) |k| : (f = k.next) if (k.kind == .element or (k.kind == .text and k.data.len > 0)) return true;
    return false;
}

fn markTreeCommon(d: *dom.Document, p: *dom.Node, id_changed: bool) bool {
    const perf = @import("perf_rules.zig");
    d.generation +%= 1;
    if (!d.inDocument(p)) return false;
    if (id_changed) d.id_generation +%= 1;
    const disp_contents = p.computed != null and p.computed.?.display == .contents;
    if (!perf.isSvgInterior(p.ns == .svg, false, disp_contents)) {
        d.layout_dirty = true;
        d.oof_dirty_node = null;
        d.svg_roots_generation +%= 1;
    }
    return true;
}

pub fn touchTreeInsert(d: *dom.Document, p: *dom.Node, first: *dom.Node, last: *dom.Node, id_changed: bool) void {
    if (!markTreeCommon(d, p, id_changed)) return;
    if (!canScopeChildStyle(d, p)) {
        d.touchUnder(p);
        return;
    }
    if ((d.rule_flags & 64) != 0 and !hasNonEmptyOutside(first, last)) {
        d.touchUnder(p);
        return;
    }
    var cur: ?*dom.Node = first;
    var has_el = false;
    while (cur) |x| {
        if (x.kind == .element) {
            has_el = true;
            d.touchUnder(x);
        } else if (x.kind == .text) {
            d.touchUnder(x);
        }
        if (x == last) break;
        cur = x.next;
    }
    if (has_el) {
        var prev_el: ?*dom.Node = first.prev;
        while (prev_el) |k| : (prev_el = k.prev) if (k.kind == .element) break;
        var next_el: ?*dom.Node = last.next;
        while (next_el) |k| : (next_el = k.next) if (k.kind == .element) break;
        if (prev_el == null and (d.rule_flags & 16) != 0) if (next_el) |ne| d.touchUnder(ne);
        if (next_el == null and (d.rule_flags & 32) != 0) if (prev_el) |pe| d.touchUnder(pe);
        if ((d.rule_flags & 2) != 0) if (next_el) |ne| d.touchUnder(ne);
    }
}

pub fn touchTreeRemove(d: *dom.Document, p: *dom.Node, removed_is_el: bool, prev_el: ?*dom.Node, next_el: ?*dom.Node, id_changed: bool) void {
    if (!markTreeCommon(d, p, id_changed)) return;
    if (!canScopeChildStyle(d, p)) {
        d.touchUnder(p);
        return;
    }
    if ((d.rule_flags & 64) != 0 and !hasNonEmptyChild(p)) {
        d.touchUnder(p);
        return;
    }
    if (removed_is_el) {
        if (prev_el == null and (d.rule_flags & 16) != 0) if (next_el) |ne| d.touchUnder(ne);
        if (next_el == null and (d.rule_flags & 32) != 0) if (prev_el) |pe| d.touchUnder(pe);
        if ((d.rule_flags & 2) != 0) if (next_el) |ne| d.touchUnder(ne);
    }
}

pub fn touchTreeClear(d: *dom.Document, p: *dom.Node, id_changed: bool) void {
    if (!markTreeCommon(d, p, id_changed)) return;
    if (!canScopeChildStyle(d, p) or (d.rule_flags & 64) != 0) {
        d.touchUnder(p);
    }
}

test "tree edits keep their links and propagate subtree blooms" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const d = try dom.Document.create(a.allocator());
    const p = try d.createElement("DIV");
    try std.testing.expectEqualStrings("div", p.tag);
    d.node.appendChild(p);
    const x = try d.createText("x");
    const y = try d.createText("y");
    p.appendChild(y);
    p.insertBefore(x, y);
    try std.testing.expectEqualStrings("xy", try p.textContent(a.allocator()));
    x.remove();
    try std.testing.expect(p.first_child == y and y.prev == null);
    const f = try d.createFragment();
    const leaf = try d.createElement("span");
    try leaf.setAttr("class", "badge active");
    try leaf.setAttr("data-id", "42");
    f.appendChild(x);
    f.appendChild(leaf);
    p.appendChild(f);
    try std.testing.expect(p.last_child == leaf and f.first_child == null);
    try p.setAttr("id", "me");
    try std.testing.expect(d.getElementById("me") == p);
    try std.testing.expectEqual(leaf.class_filter, d.node.subtree_class_bloom & leaf.class_filter);
    try std.testing.expectEqual(leaf.attr_filter, d.node.subtree_attr_bloom & leaf.attr_filter);
}
