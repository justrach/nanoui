//! The rules of shadow trees and `@container`: what `Engine` adds to a document's
//! own rules for an element inside or around a shadow tree.
const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../dom.zig");
const sheet_mod = @import("sheet.zig");
const rule_index = @import("rule_index.zig");
const match = @import("selector_match.zig");
const style = @import("style.zig");
const dom_flags = @import("../dom_flags.zig");
const cascade_mod = @import("cascade.zig");
const Engine = cascade_mod.Engine;
const Sheet = sheet_mod.Sheet;

fn isOofOrNone(s: ?*const style.Style) bool {
    const st = s orelse return true;
    return st.display == .none or (st.isOutOfFlow() and st.display != .contents);
}

fn hasOofBox(s: ?*const style.Style) bool {
    const st = s orelse return false;
    return st.display != .none and st.display != .contents and st.isOutOfFlow();
}

pub fn noteLayoutChange(e: *Engine, n: *dom.Node, old: ?*const style.Style, fresh: ?*const style.Style) void {
    dom_flags.markSubtreeLayoutDirty(n);
    if (e.layout_change_many) return;
    if (e.layout_change_node) |cur| {
        if (cur.contains(n)) return;
        e.layout_change_many = true;
        e.layout_change_node = null;
        return;
    }
    if (n.kind != .element or !isOofOrNone(old) or !isOofOrNone(fresh) or (!hasOofBox(old) and !hasOofBox(fresh))) {
        e.layout_change_many = true;
        return;
    }
    e.layout_change_node = n;
}

fn allocShareGen(e: *Engine) u32 {
    e.next_share_gen +%= 1;
    if (e.next_share_gen == 0) e.next_share_gen = 1;
    return e.next_share_gen;
}

pub fn bumpPosShareGen(e: *Engine) void {
    e.pos_share_gen = allocShareGen(e);
}

pub fn bumpShareGen(e: *Engine) void {
    e.share_gen = allocShareGen(e);
    e.pos_share_gen = allocShareGen(e);
}

pub fn resetShareForAll(e: *Engine) void {
    const frag = if (std.mem.indexOfScalar(u8, e.doc.url, '#')) |idx| e.doc.url[idx + 1 ..] else "";
    e.last_url_hash = std.hash.Wyhash.hash(0x100, frag);
    bumpShareGen(e);
}

pub fn maybeInvalidateShare(e: *Engine) void {
    const frag = if (std.mem.indexOfScalar(u8, e.doc.url, '#')) |idx| e.doc.url[idx + 1 ..] else "";
    const uh = std.hash.Wyhash.hash(0x100, frag);
    if (e.share_gen == 0 or uh != e.last_url_hash) {
        e.last_url_hash = uh;
        bumpShareGen(e);
        return;
    }
    const unpersist = (e.index != null and (e.index.?.uses_ancestor_positional or e.index.?.uses_container or e.index.?.uses_focus_within)) or e.any_scope_unpersist;
    if (unpersist) bumpPosShareGen(e);
}

fn rebindBoxRuns(b: *@import("../layout/box.zig").Box, old_s: *const style.Style, new_s: *const style.Style) void {
    if (b.style == old_s) b.style = new_s;
    if (b.lay.marker_style == old_s) b.lay.marker_style = new_s;
    for (b.runs) |*r| if (r.style == old_s) {
        @constCast(r).style = new_s;
    };
    for (b.lay.pieces) |*p| if (p.style == old_s) {
        p.style = new_s;
    };
    for (b.lay.entries) |*en| if (en.style == old_s) {
        @constCast(en).style = new_s;
    };
}

pub fn rebindPaintStyle(n: *dom.Node, old_s: *const style.Style, new_s: *const style.Style) bool {
    if (n.liveBoxParts().len != 0) return false;
    const raw = n.liveBox() orelse {
        if (old_s.display == .contents) {
            if (n.doc.documentElement()) |de| if (de.liveBox() != null) return false;
        }
        return true;
    };
    const b: *@import("../layout/box.zig").Box = @ptrCast(@alignCast(raw));
    if (b.kind != .block and b.kind != .flex and b.kind != .grid and b.kind != .replaced and b.kind != .inline_box) return false;
    var ch = b.first_child;
    while (ch) |k| : (ch = k.next) {
        if (k.node == null or k.pseudo) return false;
    }
    rebindBoxRuns(b, old_s, new_s);
    if (b.kind == .inline_box or old_s.isInlineLevel() or old_s.isOutOfFlow() or old_s.float != .none) {
        var anc = b.parent;
        while (anc) |ab| : (anc = ab.parent) {
            rebindBoxRuns(ab, old_s, new_s);
            if (ab.lay.inline_root) break;
        }
    }
    return true;
}

pub fn storeComputedStyle(
    e: *Engine,
    n: *dom.Node,
    old: ?*const style.Style,
    in_svg: bool,
    fresh_ptr: *style.Style,
    compared: @import("cascade.zig").Change,
    change: ?*@import("cascade.zig").Change,
) Allocator.Error!*const style.Style {
    if (old) |o| {
        if (compared == .none) return o;
        const s = try e.genArena().create(style.Style);
        s.* = e.scratch_fresh;
        if (compared == .paint and !in_svg and !rebindPaintStyle(n, o, s)) {
            if (change) |c| c.* = c.max(.layout);
            noteLayoutChange(e, n, o, s);
        }
        return s;
    }
    return fresh_ptr;
}

pub fn tryShareStyle(
    e: *Engine,
    n: *dom.Node,
    parent: ?*dom.Node,
    parent_is_element: bool,
    canon_parent: *const style.Style,
    parent_scope: ?*const @import("vars.zig").Scope,
    old: ?*const style.Style,
    old_before: ?*const style.Style,
    old_after: ?*const style.Style,
    change: ?*@import("cascade.zig").Change,
    out_cand: *?@import("../perf_rules.zig").ShareCand,
) Allocator.Error!bool {
    const perf = @import("../perf_rules.zig");
    out_cand.* = null;
    if (n.is_shadow) {
        if (old_before != null or old_after != null or e.anim.hasNode(n)) return false;
        if (e.style_share.lookupShadow(e.share_gen, canon_parent, parent_scope)) |sh| {
            perf.prof_style_shared += 1;
            const fake: perf.StyleShareEntry = .{
                .shared_group = sh.shared_group,
                .computed = sh.computed,
                .scope = parent_scope,
            };
            applySharedHit(e, n, old, old_before, old_after, &fake, change);
            return true;
        }
        return false;
    }
    const share_ix: *const rule_index.Index = if (n.tree_scope) |sr| (try indexOfScope(e, sr)) orelse &e.ua_index.? else if (e.index) |*ix| ix else return false;
    const host_has_rules: bool = if (n.shadow_root) |sr| blk: {
        const hix = try indexOfScope(e, sr);
        break :blk hix != null and hix.?.host.items.len > 0;
    } else false;
    const cand = perf.StyleShareCache.canShare(n, share_ix, canon_parent, parent == e.doc.node, canon_parent.display == .contents, parent_is_element and parent.?.shadow_root != null, host_has_rules, e.anim.hasNode(n)) orelse return false;
    out_cand.* = cand;
    const gen = if (cand.disallow_cousin) e.pos_share_gen else e.share_gen;
    if (e.style_share.lookup(gen, n, canon_parent, parent_scope, cand)) |hit| {
        if (hit.computed.transitions.len != 0) {
            if (e.previous(n, .none)) |prev| {
                if (prev != hit.computed and @import("style_diff.zig").compare(prev, hit.computed) != .none) return false;
            }
        }
        perf.prof_style_shared += 1;
        applySharedHit(e, n, old, old_before, old_after, hit, change);
        return true;
    }
    return false;
}

fn pseudoDiffers(a: ?*const style.Style, b: ?*const style.Style) bool {
    if (a == b) return false;
    if (a == null or b == null) return true;
    return @import("style_diff.zig").compare(a.?, b.?) != .none;
}

pub fn applySharedHit(
    e: *Engine,
    n: *dom.Node,
    old: ?*const style.Style,
    old_before: ?*const style.Style,
    old_after: ?*const style.Style,
    hit: *const @import("../perf_rules.zig").StyleShareEntry,
    change: ?*@import("cascade.zig").Change,
) void {
    const diff = @import("style_diff.zig");
    const in_svg = n.ns == .svg and !n.isTag("svg");
    if (in_svg) {
        if (old) |o| {
            if (o != hit.computed and diff.compare(o, hit.computed) != .none) {
                dom_flags.markSubtreeLayoutDirty(n);
                e.doc.svg_style_version +%= 1;
                if (change) |c| c.* = c.max(.paint);
            }
        } else {
            dom_flags.markSubtreeLayoutDirty(n);
            e.doc.svg_style_version +%= 1;
            if (change) |c| c.* = c.max(.paint);
        }
        n.computed = hit.computed;
    } else if (old) |o| {
        const cmp = if (o == hit.computed) @import("cascade.zig").Change.none else diff.compare(o, hit.computed);
        if (cmp != .none) {
            dom_flags.markSubtreeLayoutDirty(n);
            if (n.ns == .svg) e.doc.svg_style_version +%= 1;
        }
        if (cmp == .none) {
            n.computed = o;
        } else if (cmp == .paint) {
            if (rebindPaintStyle(n, o, hit.computed)) {
                if (change) |c| c.* = c.max(.paint);
            } else {
                if (change) |c| c.* = c.max(.layout);
                noteLayoutChange(e, n, o, hit.computed);
            }
            n.computed = hit.computed;
        } else {
            if (change) |c| c.* = c.max(.layout);
            noteLayoutChange(e, n, o, hit.computed);
            n.computed = hit.computed;
        }
    } else {
        dom_flags.markSubtreeLayoutDirty(n);
        if (n.ns == .svg) e.doc.svg_style_version +%= 1;
        if (change) |c| c.* = c.max(.layout);
        noteLayoutChange(e, n, null, hit.computed);
        n.computed = hit.computed;
    }
    if (pseudoDiffers(old_before, hit.before) or pseudoDiffers(old_after, hit.after)) {
        dom_flags.markSubtreeLayoutDirty(n);
        if (change) |c| c.* = c.max(.layout);
        noteLayoutChange(e, n, old, hit.computed);
    }
    n.style_generation = e.generation;
    n.css_vars = hit.scope;
    n.before = hit.before;
    n.after = hit.after;
    n.marker = null;
    n.backdrop = null;
    n.style_shared_gen = hit.shared_group;
    n.style_canon = hit.computed;
}

pub fn finishSharedHit(e: *Engine, n: *dom.Node, root: *dom.Node, change: ?*@import("cascade.zig").Change) ?*dom.Node {
    if (n.computed.?.display == .none) {
        var k = n.first_child;
        while (k) |x| : (k = x.next) e.clearSubtree(x, change, false);
        if (n.shadow_root) |x| e.clearSubtree(x, change, false);
        return n.nextDeepSkipping(root);
    }
    return n.nextDeep(root);
}

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
    var next: std.AutoHashMapUnmanaged(*dom.Node, []const *const Sheet) = .empty;
    var existing_changed = false;
    for (roots, lists) |r, l| {
        if (e.scoped.fetchRemove(r)) |kv| {
            if (std.mem.eql(*const Sheet, kv.value, l)) {
                next.put(e.gpa, r, kv.value) catch e.gpa.free(kv.value);
                continue;
            }
            existing_changed = true;
            e.gpa.free(kv.value);
        }
        const copy = e.gpa.dupe(*const Sheet, l) catch continue;
        next.put(e.gpa, r, copy) catch {
            e.gpa.free(copy);
            continue;
        };
        e.doc.markStyle(r.parent orelse r);
    }
    var rem = e.scoped.iterator();
    while (rem.next()) |kv| {
        existing_changed = true;
        e.doc.markStyle(kv.key_ptr.*.parent orelse kv.key_ptr.*);
        e.gpa.free(kv.value_ptr.*);
    }
    e.scoped.deinit(e.gpa);
    e.scoped = next;
    e.last_scope_root = null;
    e.last_scope_ix = null;
    if (existing_changed) bumpShareGen(e);
}

pub fn dropScopeIndexes(e: *Engine) void {
    e.last_scope_root = null;
    e.last_scope_ix = null;
    e.any_scope_unpersist = false;
    bumpShareGen(e);
    var it = e.scope_index.valueIterator();
    while (it.next()) |x| {
        x.*.deinit();
        e.gpa.destroy(x.*);
    }
    e.scope_index.clearRetainingCapacity();
}

/// The rules of a shadow tree, or none. Lists that are the same share an index.
pub fn indexOfScope(e: *Engine, root: *dom.Node) Allocator.Error!?*rule_index.Index {
    if (e.last_scope_root == root) return e.last_scope_ix;
    const list = e.scoped.get(root) orelse {
        e.last_scope_root = root;
        e.last_scope_ix = null;
        return null;
    };
    const key = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(list));
    if (e.scope_index.get(key)) |x| {
        e.last_scope_root = root;
        e.last_scope_ix = x;
        return x;
    }
    const ix = try e.gpa.create(rule_index.Index);
    errdefer e.gpa.destroy(ix);
    ix.* = rule_index.Index.init(e.gpa);
    ix.quirks = e.doc.quirks;
    const a = ix.arena.allocator();
    const ranks = try rule_index.LayerRanks.build(a, list, e.viewport);
    var order: u32 = 0;
    for (list) |s| try ix.addSheet(s, e.viewport, false, &ranks, &order);
    if (ix.uses_ancestor_positional or ix.uses_container or ix.uses_focus_within) e.any_scope_unpersist = true;
    e.doc.rule_flags |= ix.ruleFlags();
    e.doc.rule_attr_filter |= ix.attr_filter;
    e.doc.rule_id_bloom |= ix.referenced_ids_bloom;
    try e.scope_index.put(e.gpa, key, ix);
    e.last_scope_root = root;
    e.last_scope_ix = ix;
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
    if (n.tree_scope) |root| if ((n.attr_filter & @import("../perf_rules.zig").attrBit("part")) != 0) if (n.attr("part")) |names| {
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

pub fn readMetaScheme(e: *Engine) void {
    e.meta_dark = false;
    const head = e.doc.head() orelse return;
    var c = head.first_child;
    while (c) |k| : (c = k.next) {
        if (!k.isTag("meta")) continue;
        const name = k.attr("name") orelse continue;
        if (!std.ascii.eqlIgnoreCase(name, "color-scheme")) continue;
        const content = k.attr("content") orelse continue;
        var light = false;
        var dark = false;
        var it = std.mem.tokenizeAny(u8, content, " \t\r\n\x0c,");
        while (it.next()) |w| {
            if (std.ascii.eqlIgnoreCase(w, "light")) light = true;
            if (std.ascii.eqlIgnoreCase(w, "dark")) dark = true;
        }
        e.meta_dark = dark and (!light or e.viewport.dark);
    }
}

pub fn styleAnyway(e: *Engine, n: *dom.Node, memo: *cascade_mod.DetachedMemo, a: Allocator) Allocator.Error!?*const style.Style {
    const d = try detached(e, n, memo, a) orelse return null;
    return d.style;
}

fn detached(e: *Engine, n: *dom.Node, memo: *cascade_mod.DetachedMemo, a: Allocator) Allocator.Error!?cascade_mod.Detached {
    if (n.kind != .element) return null;
    const vars = @import("vars.zig");
    const compute = @import("compute.zig");
    if (e.current(n)) |s| {
        const scope: ?*const vars.Scope = if (n.css_vars) |raw| @ptrCast(@alignCast(raw)) else null;
        return .{ .style = s, .scope = scope };
    }
    if (memo.get(n)) |d| return d;
    try e.ensureIndex();
    var up: cascade_mod.Detached = .{ .style = &e.root_parent, .scope = null };
    if (n.parent) |p| if (p.kind == .element) {
        up = try detached(e, p, memo, a) orelse return null;
    };
    @import("../perf_rules.zig").updateAncestorBloom(n, n);
    var fresh: style.Style = undefined;
    const r = try compute.element(e, n, up.style, up.scope, &fresh);
    const s = try e.genArena().create(style.Style);
    s.* = fresh;
    const out: cascade_mod.Detached = .{ .style = s, .scope = r.scope };
    try memo.put(a, n, out);
    return out;
}
