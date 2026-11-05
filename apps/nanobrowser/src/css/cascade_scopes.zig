//! The rules of shadow trees and `@container`: what `Engine` adds to a document's
//! own rules for an element inside or around a shadow tree.
const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../dom.zig");
const sheet_mod = @import("sheet.zig");
const rule_index = @import("rule_index.zig");
const match = @import("selector_match.zig");
const Engine = @import("cascade.zig").Engine;
const Sheet = sheet_mod.Sheet;

/// The nearest ancestor that is a container, with this name if one is given.
fn nearestContainer(n: *const dom.Node, name: []const u8) ?*const dom.Node {
    var at = n.parent;
    while (at) |a| : (at = a.parent) {
        const st = a.computed orelse continue;
        if (a.kind != .element or st.container_type == .normal) continue;
        if (name.len == 0) return a;
        for (st.container_names) |x| if (std.mem.eql(u8, x, name)) return a;
    }
    return null;
}

/// Every shadow tree's sheets, replacing what was set; `list`'s slices are
/// copied. A root with none has no entry.
pub fn setScopedSheets(e: *Engine, roots: []const *dom.Node, lists: []const []const *const Sheet) void {
    var old = e.scoped.valueIterator();
    while (old.next()) |l| e.gpa.free(l.*);
    e.scoped.clearRetainingCapacity();
    for (roots, lists) |r, l| {
        const copy = e.gpa.dupe(*const Sheet, l) catch continue;
        e.scoped.put(e.gpa, r, copy) catch e.gpa.free(copy);
    }
    dropScopeIndexes(e);
    e.doc.touchStyle();
}

pub fn dropScopeIndexes(e: *Engine) void {
    var it = e.scope_index.valueIterator();
    while (it.next()) |x| {
        x.*.deinit();
        e.gpa.destroy(x.*);
    }
    e.scope_index.clearRetainingCapacity();
}

/// The rules of a shadow tree, or none. Lists that are the same share an index.
fn indexOfScope(e: *Engine, root: *dom.Node) Allocator.Error!?*rule_index.Index {
    const list = e.scoped.get(root) orelse return null;
    const key = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(list));
    if (e.scope_index.get(key)) |x| return x;
    const ix = try e.gpa.create(rule_index.Index);
    errdefer e.gpa.destroy(ix);
    ix.* = rule_index.Index.init(e.gpa);
    ix.quirks = e.doc.quirks;
    const a = ix.arena.allocator();
    const ranks = try rule_index.LayerRanks.build(a, list, e.viewport);
    var order: u32 = 0;
    for (list) |s| try ix.addSheet(s, e.viewport, false, &ranks, &order);
    try e.scope_index.put(e.gpa, key, ix);
    return ix;
}

/// The rules that can match `n`, from its tree, the tree inside it and the
/// tree around it, into `collected`.
pub fn collectFor(e: *Engine, n: *dom.Node) Allocator.Error!void {
    const gpa = e.gpa;
    const list = &e.collected;
    if (n.tree_scope) |root| {
        try e.ua_index.?.collect(gpa, n, &e.match_ctx, list);
        if (try indexOfScope(e, root)) |ix| try ix.collect(gpa, n, &e.match_ctx, list);
    } else try e.index.?.collect(gpa, n, &e.match_ctx, list);
    if (e.scoped.count() == 0 and n.tree_scope == null) return;
    if (n.shadow_root) |root| if (try indexOfScope(e, root)) |ix| {
        try rule_index.collectFrom(gpa, ix.host.items, n, &e.match_ctx, list);
    };
    // Each shadow tree `n` is slotted through: a `<slot>` that is itself a host's
    // child forwards what it takes to that host's slots.
    var through: *dom.Node = n;
    var hops: u32 = 0;
    while (through.parent) |p| : (hops += 1) {
        const root = p.shadow_root orelse break;
        if (try indexOfScope(e, root)) |ix| {
            for (ix.slotted.items) |entry| if (match.matchesAny(entry.sel.slotted, n, &e.match_ctx)) try list.append(gpa, entry);
        }
        if (hops >= 16) break;
        through = slotFor(root, through) orelse break;
    }
    if (n.tree_scope) |root| if (n.attr("part")) |names| {
        const host = root.parent orelse return;
        const outer = if (host.tree_scope) |r2| try indexOfScope(e, r2) else &e.index.?;
        const ix = outer orelse return;
        for (ix.parts.items) |entry| {
            var it = std.mem.tokenizeAny(u8, names, " \t\r\n\x0c");
            while (it.next()) |w| if (std.mem.eql(u8, w, entry.sel.part)) {
                if (match.matches(entry.sel, host, &e.match_ctx)) try list.append(gpa, entry);
                break;
            };
        }
    };
}

/// The `<slot>` in a shadow tree that a child of its host goes to.
fn slotFor(root: *dom.Node, child: *const dom.Node) ?*dom.Node {
    const wants = if (child.kind == .element) child.attr("slot") orelse "" else "";
    var at = root.first_child;
    while (at) |x| : (at = x.nextInTree(root)) {
        if (x.kind == .element and x.isTag("slot") and std.mem.eql(u8, x.attr("name") orelse "", wants)) return x;
    }
    return null;
}

/// Whether the `@container` a rule sits under holds for `n`: each level asks
/// the nearest container with its name, and an unlaid one answers no.
pub fn containerHolds(e: *const Engine, cond: *const sheet_mod.ContainerCond, n: *const dom.Node) bool {
    _ = e;
    var at: ?*const sheet_mod.ContainerCond = cond;
    while (at) |c| : (at = c.parent) {
        const box = nearestContainer(n, c.name) orelse return false;
        if (c.query) |q| {
            if (box.container_w < 0) return false;
            const st = box.computed.?;
            const high = if (st.container_type == .size) box.container_h else -1;
            if (!q.matches(.{ .width = box.container_w, .height = high })) return false;
        }
    }
    return true;
}
