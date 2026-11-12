//! Pure performance and scheduling decision kernels for `nanobrowser`,
//! backed by formal Lean 4 proofs in `lean-proofs/NanoUI/BrowserPerf.lean`.
const std = @import("std");
const dom = @import("dom.zig");
const box = @import("layout/box.zig");
const style = @import("css/style.zig");
const vars = @import("css/vars.zig");
const rule_index = @import("css/rule_index.zig");
const Rect = box.Rect;

/// Theorem 1 (`NanoUI.BrowserPerf.isHoverHeld`):
/// Whether `:hover` updates are held back by a recent scroll under a still pointer.
pub fn isHoverHeld(inside: bool, now: f64, hover_held_until: f64, moved: bool, button_event: bool) bool {
    return inside and hover_held_until > now and !moved and !button_event;
}

/// Theorem 1 (`NanoUI.BrowserPerf.effectiveHover`):
/// The effective hover node while `held` is active.
pub fn effectiveHover(held: bool, old_hover: ?*dom.Node, under: ?*dom.Node) ?*dom.Node {
    return if (held) old_hover else under;
}

/// Theorem 1a & 1b (`NanoUI.BrowserPerf.hover_hold_quiescent_when_same`,
/// `NanoUI.BrowserPerf.hover_hold_wakes_when_changed`):
/// Only schedule a wakeup timer at `hover_held_until` when `held` is actually
/// deferring a hover transition (`old_hover != under`). When `old_hover == under`,
/// waking at `hover_held_until` is a no-op and must not schedule an extra frame.
pub fn shouldWakeForHoverHold(held: bool, old_hover: ?*dom.Node, under: ?*dom.Node) bool {
    return held and old_hover != under;
}

/// Theorem 2 (`NanoUI.BrowserPerf.needsResolve`, `resolve_cache_sound`):
/// Whether `display.List.resolve` needs to recompute clip offsets and transforms
/// for `window` at `scroll_rev`.
pub fn needsResolve(scroll_rev: u32, resolved_rev: u32, resolved_rect: Rect, window: Rect) bool {
    return scroll_rev != resolved_rev or !std.meta.eql(resolved_rect, window);
}

/// Theorem 2 (`NanoUI.BrowserPerf.needsPrepare`):
/// Whether `prepare` needs to run again after `web.frameLaid` or input dispatch
/// when the viewport size and theme have not changed.
pub fn needsPrepare(style_dirty: bool, layout_dirty: bool, list_dirty: bool, svg_dirty: bool, has_list: bool) bool {
    return style_dirty or layout_dirty or list_dirty or svg_dirty or !has_list;
}

/// Theorem 4 (`NanoUI.BrowserPerf.needsWorld`, `static_page_zero_prelude_cost`):
/// Whether a page needs a JS `World` created on initial parse or declarative invoke.
pub fn needsWorld(no_scripts: bool, has_scripts: bool, eval_asked: bool, declarative_invoker: bool) bool {
    return !no_scripts and (has_scripts or eval_asked or declarative_invoker);
}

/// Theorem 5 (`NanoUI.BrowserPerf.pre_focus_single_pass`):
/// Resolves `wants_focus` before `ui.textField` so focus lands in 1 frame pass.
pub fn preFocus(focus: *u64, wants_focus: *bool, peeked_id: u64) void {
    if (wants_focus.*) {
        focus.* = peeked_id;
        wants_focus.* = false;
    }
}

/// Theorem 8 (`NanoUI.BrowserPerf.proto_epoch_ic_sound`):
/// Whether a multi-hop prototype inline cache entry hits under `vm_epoch`.
pub inline fn protoIcHits(obj_shape: ?*const anyopaque, ic_shape: ?*const anyopaque, holder_shape: ?*const anyopaque, ic_holder_shape: ?*const anyopaque, vm_epoch: u32, ic_epoch: u32) bool {
    return obj_shape == ic_shape and holder_shape == ic_holder_shape and vm_epoch == ic_epoch;
}

/// Theorem 9 (`NanoUI.BrowserPerf.resource_bit_skip_sound`):
/// Whether an HTML tag is a subresource or sheet carrier that `loader.scan` inspects.
pub fn isResourceTag(tag: []const u8) bool {
    return switch (tag.len) {
        3 => std.mem.eql(u8, tag, "img"),
        4 => std.mem.eql(u8, tag, "link") or std.mem.eql(u8, tag, "base"),
        5 => std.mem.eql(u8, tag, "style"),
        6 => std.mem.eql(u8, tag, "iframe") or std.mem.eql(u8, tag, "source"),
        7 => std.mem.eql(u8, tag, "picture"),
        else => false,
    };
}

/// Theorem 52 (`NanoUI.Speedometer3Climb.subtree_has_id_and_insertion_work_propagation_sound`):
/// Whether an element tag requires post-insertion work in `mutate.inserted` (`script`, `iframe`, `link`, or custom element).
pub fn isInsertionWorkTag(tag: []const u8) bool {
    if (std.mem.indexOfScalar(u8, tag, '-') != null) return true;
    return switch (tag.len) {
        4 => std.mem.eql(u8, tag, "link"),
        6 => std.mem.eql(u8, tag, "script") or std.mem.eql(u8, tag, "iframe"),
        else => false,
    };
}

/// Theorem 10 (`NanoUI.BrowserPerf.layout_only_flush_sound`):
/// Whether `flushLayoutOnly` needs to recompute style or box layout for `getBoundingClientRect` / `offsetWidth`.
pub fn needsLayoutFlush(style_dirty: bool, layout_dirty: bool, has_tree: bool, vw_same: bool, vh_same: bool) bool {
    return style_dirty or layout_dirty or !has_tree or !vw_same or !vh_same;
}

/// Theorem 11 (`NanoUI.BrowserPerf.agent_microtask_checkpoint_sound`):
/// Whether exiting `World.leave` at `depth` with `has_caller` is an Agent microtask checkpoint.
pub inline fn isAgentMicrotaskCheckpoint(depth: u32, has_caller: bool) bool {
    return depth == 1 and !has_caller;
}

/// Theorem 12 (`NanoUI.BrowserPerf.style_queued_dedup_sound`):
/// Whether `Document.touchUnder` should append `n` to `dirty_nodes`.
pub inline fn shouldQueueDirtyNode(self_queued: bool, parent_queued: bool) bool {
    return !self_queued and !parent_queued;
}

/// Theorem 14 (`NanoUI.BrowserPerf.svg_interior_mutation_paint_only`):
/// Whether a node is strictly inside a replaced `<svg>` subtree (has no CSS layout box).
pub inline fn isSvgInterior(in_svg_ns: bool, is_svg_root: bool, display_contents: bool) bool {
    return in_svg_ns and !is_svg_root and !display_contents;
}

/// Theorem 28 & 29 (`NanoUI.Speedometer3Perf.attr_invalidation_scope`, `svg_geometry_attr_style_invariance`):
/// 64-bit Bloom filter bit for a lowercase CSS attribute name.
pub fn attrBit(name: []const u8) u64 {
    if (name.len == 0) return 0;
    const c0 = std.ascii.toLower(name[0]);
    const c1 = std.ascii.toLower(name[name.len - 1]);
    const mix = @as(u32, c0) *% 31 +% @as(u32, c1) *% 17 +% @as(u32, @truncate(name.len));
    return @as(u64, 1) << @intCast(mix & 63);
}

pub const svg_pres_attrs = std.StaticStringMap(void).initComptime(.{
    .{"color"},             .{"fill"},              .{"fill-opacity"},      .{"fill-rule"},
    .{"clip-rule"},         .{"clip-path"},         .{"mask"},              .{"stroke"},
    .{"stroke-width"},      .{"stroke-opacity"},    .{"stroke-linecap"},    .{"stroke-linejoin"},
    .{"stroke-miterlimit"}, .{"stroke-dasharray"},  .{"stroke-dashoffset"}, .{"stop-color"},
    .{"stop-opacity"},      .{"opacity"},           .{"visibility"},        .{"display"},
    .{"paint-order"},       .{"vector-effect"},
});

pub const html_style_attrs = std.StaticStringMap(void).initComptime(.{
    .{"href"},        .{"disabled"},    .{"checked"},     .{"selected"},   .{"readonly"},
    .{"required"},    .{"placeholder"}, .{"open"},        .{"value"},      .{"type"},
    .{"lang"},        .{"dir"},         .{"size"},        .{"face"},       .{"color"},
    .{"text"},        .{"cellpadding"}, .{"cellspacing"}, .{"border"},     .{"bgcolor"},
    .{"background"},  .{"width"},       .{"height"},      .{"align"},      .{"valign"},
    .{"nowrap"},      .{"frameborder"}, .{"hspace"},      .{"vspace"},     .{"noshade"},
    .{"hidden"},      .{"popover"},     .{"title"},       .{"multiple"},
});

/// Theorem 27 (`NanoUI.Speedometer3Perf.ancestor_style_queued_subsumption`):
/// Whether `n` or any of its ancestors is already queued in `dirty_nodes`.
pub inline fn hasQueuedAncestor(n: *const dom.Node) bool {
    var at: ?*const dom.Node = n;
    while (at) |x| : (at = x.parent) {
        if (x.style_queued) return true;
    }
    return false;
}

pub fn touchUnder(d: *dom.Document, n: *dom.Node) void {
    d.style_dirty = true;
    if (d.dirty_all) return;
    if (hasQueuedAncestor(n)) return;
    if (d.dirty_nodes.items.len >= 16384) {
        d.dirty_all = true;
        return;
    }
    n.style_queued = true;
    d.dirty_nodes.append(d.arena, n) catch {
        n.style_queued = false;
        d.dirty_all = true;
    };
}

/// Theorem 28, 29 & 43 (`NanoUI.Speedometer3Perf.attr_invalidation_scope`,
/// `svg_geometry_attr_style_invariance`, `NanoUI.Speedometer3Climb.resource_tag_only_scan_dirty_sound`):
/// Scoped style invalidation when attribute `name` changes on element `n`.
pub fn touchAttr(d: *dom.Document, n: *dom.Node, name: []const u8) void {
    d.generation +%= 1;
    const is_id = std.mem.eql(u8, name, "id");
    if (isResourceTag(n.tag)) d.scan_dirty = true;
    if (!d.inDocument(n)) return;
    if (is_id) d.id_generation +%= 1;
    if (std.mem.eql(u8, name, "style")) {
        touchUnder(d, n);
        return;
    }
    const is_class = std.mem.eql(u8, name, "class");
    const in_filter = (d.rule_attr_filter & attrBit(name)) != 0;
    if (n.ns == .svg and !n.isTag("svg")) {
        if (!is_class and !is_id and !in_filter and !svg_pres_attrs.has(name) and !std.mem.eql(u8, name, "lang")) {
            return;
        }
    } else if (n.ns == .html) {
        if (!is_class and !is_id and !in_filter and !html_style_attrs.has(name) and !std.mem.eql(u8, name, "slot") and !std.mem.eql(u8, name, "part")) {
            return;
        }
    }
    touchState(d, n);
}

/// Scoped style invalidation when element state (`:checked`, `:placeholder-shown`) changes on `n`.
pub fn touchState(d: *dom.Document, n: *dom.Node) void {
    if (!d.inDocument(n)) return;
    const uses_has = (d.rule_flags & 1) != 0;
    const uses_next = (d.rule_flags & 2) != 0;
    const uses_later = (d.rule_flags & 4) != 0;
    if (uses_has or uses_later or n.tree_scope != null or n.shadow_root != null) {
        touchUnder(d, n.parent orelse n);
        return;
    }
    touchUnder(d, n);
    if (uses_next) {
        if (n.nextElement()) |nx| touchUnder(d, nx);
    }
}

/// Theorem 35 (`NanoUI.Speedometer3Perf.cached_id_and_single_class_fast_path_sound`):
/// 64-bit Bloom filter bit for a class token.
pub inline fn classBit(name: []const u8) u64 {
    const mix = @as(u32, name[0]) *% 31 +% @as(u32, name[name.len - 1]) *% 17 +% @as(u32, @truncate(name.len));
    return @as(u64, 1) << @intCast(mix & 63);
}

/// Theorem 44 (`NanoUI.Speedometer3Climb.ancestor_and_attr_bloom_filter_sound`):
/// Self Bloom filter of an element's tag, `id`, and `class` tokens for ancestor selector filtering.
pub inline fn nodeSelfBloom(n: *const dom.Node) u64 {
    var b: u64 = n.class_filter | attrBit(n.tag);
    if (n.id_attr) |id| b |= (attrBit(id) & n.doc.rule_id_bloom);
    return b;
}

const anc_state_attr_mask: u64 = attrBit("disabled") | attrBit("open") | attrBit("inert") |
    attrBit("lang") | attrBit("dir") | attrBit("readonly") | attrBit("required") |
    attrBit("checked") | attrBit("selected") | attrBit("type") | attrBit("href");

pub fn nodeSelfHash(n: *const dom.Node) u64 {
    const doc = n.doc;
    var h: u64 = std.hash.Wyhash.hash(@intFromEnum(n.ns), n.tag);
    if (n.class_attr) |ca| h = std.hash.Wyhash.hash(h ^ 0x517CC1B727220A95, ca);
    if (n.id_attr) |id| {
        const ref_id = (doc.rule_id_bloom & attrBit(id)) != 0 or (doc.rule_attr_filter & attrBit("id")) != 0 or blk: {
            if (std.mem.indexOfScalar(u8, doc.url, '#')) |idx| break :blk std.mem.eql(u8, doc.url[idx + 1 ..], id);
            break :blk false;
        };
        if (ref_id) h = std.hash.Wyhash.hash(h ^ 0x94D049BB133111EB, id);
    }
    const mask = doc.rule_attr_filter | anc_state_attr_mask;
    if ((n.attr_filter & mask) != 0) {
        for (n.attrs.items) |a| {
            if ((a.name.len == 5 and a.name[0] == 'c' and std.mem.eql(u8, a.name, "class")) or
                (a.name.len == 2 and a.name[0] == 'i' and std.mem.eql(u8, a.name, "id"))) continue;
            if ((attrBit(a.name) & mask) == 0) continue;
            h = std.hash.Wyhash.hash(std.hash.Wyhash.hash(h ^ 0xBF58476D1CE4E5B9, a.name), a.value);
        }
    }
    var flags: u64 = @intFromBool(doc.hover == n);
    flags |= @as(u64, @intFromBool(doc.active == n)) << 1;
    flags |= @as(u64, @intFromBool(doc.focus == n)) << 2;
    if (doc.focus) |f| flags |= @as(u64, @intFromBool(n.contains(f))) << 3;
    if (n.checked) |ck| flags |= (@as(u64, 1) + @intFromBool(ck)) << 4;
    if (n.selected) |sl| flags |= (@as(u64, 1) + @intFromBool(sl)) << 6;
    flags |= @as(u64, @intFromBool(n.modal)) << 8;
    flags |= @as(u64, @intFromBool(n.popover_open)) << 9;
    flags |= @as(u64, @intFromBool(n.value != null)) << 10;
    return h ^ (flags *% 0xD6E8FEB86659FD93);
}

/// Computes `n.ancestor_bloom` and `n.ancestor_hash` from its parent (or walks up to the root if `n == root`).
pub inline fn updateAncestorBloom(n: *dom.Node, root: *const dom.Node) void {
    if (n.parent) |p| if (p.is_shadow) {
        n.ancestor_bloom = 0;
        n.ancestor_hash = 0;
        return;
    };
    if (n != root) if (n.parent) |p| if (p.kind == .element) {
        n.ancestor_bloom = p.ancestor_bloom | nodeSelfBloom(p);
        n.ancestor_hash = (p.ancestor_hash *% 0x9E3779B97F4A7C15) ^ nodeSelfHash(p);
        return;
    };
    var b: u64 = 0;
    var chain: [64]*const dom.Node = undefined;
    var len: usize = 0;
    var at = n.parent;
    while (at) |x| : (at = x.parent) {
        if (x.is_shadow) break;
        if (x.kind == .element) {
            b |= nodeSelfBloom(x);
            if (len < chain.len) {
                chain[len] = x;
                len += 1;
            }
        }
    }
    var h: u64 = 0;
    while (len > 0) {
        len -= 1;
        h = (h *% 0x9E3779B97F4A7C15) ^ nodeSelfHash(chain[len]);
    }
    n.ancestor_bloom = b;
    n.ancestor_hash = h;
}

/// Synchronizes `attr_filter`, `id_attr`, `class_attr`, `class_filter`, and `class_single` on `dom.Node`.
pub fn syncNodeAttr(n: *dom.Node, name: []const u8, val: ?[]const u8) void {
    if (val != null) {
        n.attr_filter |= attrBit(name);
    } else {
        var ab: u64 = 0;
        for (n.attrs.items) |at| ab |= attrBit(at.name);
        n.attr_filter = ab;
    }
    if (std.mem.eql(u8, name, "id")) {
        n.id_attr = val;
        if (val) |v| if (v.len != 0 and !n.has_id) {
            var at: ?*dom.Node = n;
            while (at) |x| : (at = x.parent) {
                if (x.has_id) break;
                x.has_id = true;
            }
        };
    } else if (std.mem.eql(u8, name, "class")) {
        n.class_attr = val;
        if (val) |list| {
            var bits: u64 = 0;
            var count: u32 = 0;
            var first: []const u8 = "";
            var words = std.mem.tokenizeAny(u8, list, " \t\r\n\x0c");
            while (words.next()) |w| {
                bits |= classBit(w);
                if (count == 0) first = w;
                count += 1;
            }
            n.class_filter = bits;
            n.class_single = (count == 1);
            n.class_src = first.ptr;
            n.class_src_len = first.len;
        } else {
            n.class_filter = 0;
            n.class_single = false;
            n.class_src_len = 0;
        }
    }
    @import("dom_flags.zig").propagateSelfAttrs(n);
}

/// O(1) Bloom-filtered and single-class fast-pathed `Node.hasClass` (Theorem 35).
pub inline fn hasNodeClass(n: *const dom.Node, name: []const u8) bool {
    if (name.len == 0 or (n.class_filter & classBit(name)) == 0) return false;
    if (n.class_single) return n.class_src_len == name.len and std.mem.eql(u8, n.class_src[0..n.class_src_len], name);
    const list = n.class_attr orelse return false;
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n\x0c");
    while (it.next()) |c| if (std.mem.eql(u8, c, name)) return true;
    return false;
}

/// Theorem 42 & 52 (`NanoUI.Speedometer3Perf.id_lookup_negative_cache_escalation_sound`,
/// `NanoUI.Speedometer3Climb.subtree_has_id_and_insertion_work_propagation_sound`):
/// Subtree-skipping and generation-cached `Document.getElementById`.
pub fn getElementById(d: *const dom.Document, id: []const u8) ?*dom.Node {
    if (id.len == 0 or !d.node.has_id) return null;
    if (d.id_map_gen == d.id_generation) return d.id_map.get(id);
    const self = @constCast(d);
    if (d.id_last_gen == d.id_generation) {
        if (std.mem.eql(u8, d.id_last_key, id)) return d.id_last_node;
        self.id_map.clearRetainingCapacity();
        self.id_has_dups = false;
        var at = d.node.first_child;
        while (at) |n| : (at = if (n.has_id) n.nextInTree(d.node) else n.nextSkippingChildren(d.node)) {
            if (n.kind == .element) if (n.id_attr) |v| if (v.len != 0) {
                const gop = self.id_map.getOrPut(d.arena, v) catch break;
                if (!gop.found_existing) gop.value_ptr.* = n else self.id_has_dups = true;
            };
        }
        self.id_map_gen = d.id_generation;
        return d.id_map.get(id);
    }
    var found: ?*dom.Node = null;
    var at = d.node.first_child;
    while (at) |n| : (at = if (n.has_id) n.nextInTree(d.node) else n.nextSkippingChildren(d.node)) {
        if (n.kind == .element) if (n.id_attr) |v| if (std.mem.eql(u8, v, id)) {
            found = n;
            break;
        };
    }
    self.id_last_gen = d.id_generation;
    self.id_last_key = if (found) |f| f.id_attr.? else d.arena.dupe(u8, id) catch "";
    self.id_last_node = found;
    return found;
}

const style_share = @import("css/style_share.zig");
pub const ShareCand = style_share.ShareCand;
pub const StyleShareEntry = style_share.StyleShareEntry;
pub const StyleShareCache = style_share.StyleShareCache;

test "hover hold is quiescent when element under pointer matches old hover" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try dom.Document.create(arena.allocator());
    const a = try doc.createElement("div");
    const b = try doc.createElement("div");

    const held = isHoverHeld(true, 1.0, 1.12, false, false);
    try std.testing.expect(held);
    // Same node: no wakeup needed, and effective hover equals unheld hover.
    try std.testing.expect(!shouldWakeForHoverHold(held, a, a));
    try std.testing.expectEqual(effectiveHover(false, a, a), effectiveHover(held, a, a));
    // Different node: wakeup is scheduled while held, and hover stays on `a` until hold ends.
    try std.testing.expect(shouldWakeForHoverHold(held, a, b));
    try std.testing.expectEqual(@as(?*dom.Node, a), effectiveHover(held, a, b));
    try std.testing.expectEqual(@as(?*dom.Node, b), effectiveHover(false, a, b));
}

test "display list resolve cache skips redundant passes and invalidates on scroll or resize" {
    const r1: Rect = .{ .x = 0, .y = 38, .w = 1280, .h = 762 };
    const r2: Rect = .{ .x = 0, .y = 38, .w = 1000, .h = 762 };
    // Initial build (scroll_rev = 1, resolved_rev = 0) must resolve.
    try std.testing.expect(needsResolve(1, 0, .{}, r1));
    // Subsequent checkpoints with same scroll_rev and rect skip resolve.
    try std.testing.expect(!needsResolve(1, 1, r1, r1));
    // Scroll mutation (scroll_rev = 2) or viewport change invalidates cache.
    try std.testing.expect(needsResolve(2, 1, r1, r1));
    try std.testing.expect(needsResolve(1, 1, r1, r2));
}

test "static pages without scripts or declarative invokers skip JS world creation" {
    try std.testing.expect(!needsWorld(false, false, false, false));
    try std.testing.expect(!needsWorld(true, true, true, true));
    try std.testing.expect(needsWorld(false, true, false, false));
    try std.testing.expect(needsWorld(false, false, true, false));
    try std.testing.expect(needsWorld(false, false, false, true));
}

test "preFocus assigns focus id and clears wants_focus in one pass" {
    var focus: u64 = 0;
    var wants_focus = true;
    preFocus(&focus, &wants_focus, 42);
    try std.testing.expectEqual(@as(u64, 42), focus);
    try std.testing.expect(!wants_focus);
}

test "protoIcHits validates epoch and resource tags and layout-only flush" {
    const s1: usize = 10;
    const s2: usize = 20;
    const p1: *const anyopaque = @ptrFromInt(s1);
    const p2: *const anyopaque = @ptrFromInt(s2);
    try std.testing.expect(protoIcHits(p1, p1, p2, p2, 5, 5));
    try std.testing.expect(!protoIcHits(p1, p1, p2, p2, 6, 5));
    try std.testing.expect(isResourceTag("style"));
    try std.testing.expect(isResourceTag("link"));
    try std.testing.expect(isResourceTag("iframe"));
    try std.testing.expect(isResourceTag("img"));
    try std.testing.expect(!isResourceTag("div"));
    try std.testing.expect(!isResourceTag("span"));
    try std.testing.expect(!needsLayoutFlush(false, false, true, true, true));
    try std.testing.expect(needsLayoutFlush(false, true, true, true, true));
}

pub var prof_style_ns: u64 = 0;
pub var prof_js_task_ns: u64 = 0;
pub var prof_replay_ns: u64 = 0;
pub var prof_style_shared: u64 = 0;
pub var prof_style_elems: u64 = 0;
pub var prof_ss_has: u64 = 0;
pub var prof_ss_unshare: u64 = 0;
pub var prof_ss_univ: u64 = 0;
pub var prof_ss_cand: u64 = 0;
pub var prof_ss_rec: u64 = 0;
pub var prof_layout_ns: u64 = 0;
pub var prof_layout_runs: u64 = 0;
pub var prof_lay_gen_ns: u64 = 0;
pub var prof_lay_size_ns: u64 = 0;
pub var prof_lay_fin_ns: u64 = 0;
pub var prof_list_ns: u64 = 0;
pub var prof_svg_ns: u64 = 0;
pub var prof_gc_ns: u64 = 0;
pub var prof_html_ns: u64 = 0;
pub var prof_query_ns: u64 = 0;
pub var prof_compile_ns: u64 = 0;
pub var prof_compile_calls: u64 = 0;
pub var prof_interp_ops: u64 = 0;
pub var prof_jit_disabled: u64 = 0;
pub var prof_jit_calls: u64 = 0;
pub var prof_nat_calls: u64 = 0;
pub var prof_nat_ns: u64 = 0;
pub var prof_slow_ops: u64 = 0;
pub var prof_slow_hist: [256]u64 = @splat(0);
pub var prof_ic_helpers: u64 = 0;
pub var prof_ic_acc: u64 = 0;
pub var prof_ic_miss_slot: u64 = 0;
pub var prof_ic_prim: u64 = 0;
pub var prof_ic_exotic: u64 = 0;
pub var prof_ss_rej_style: u64 = 0;
pub var prof_ss_rej_id: u64 = 0;
pub var prof_ss_rej_state: u64 = 0;
pub var prof_ss_rej_val: u64 = 0;
pub var prof_ss_rej_root_host: u64 = 0;
pub var prof_ss_rej_tag: u64 = 0;
pub var prof_ss_miss_gen: u64 = 0;
pub var prof_ss_miss_pstyle: u64 = 0;
pub var prof_ss_miss_cousin: u64 = 0;
pub var prof_ss_miss_key: u64 = 0;
pub var prof_lay_adopted: u64 = 0;
pub const HtmlTag = enum(u8) {
    other,
    br,
    wbr,
    input,
    button,
    control,
    img,
    replaced,
    list,
    table,
    tr,
    cell,
    center,
    details,
    slot,
};

const html_tag_map = std.StaticStringMap(HtmlTag).initComptime(.{
    .{ "br", .br },
    .{ "wbr", .wbr },
    .{ "input", .input },
    .{ "button", .button },
    .{ "select", .control },
    .{ "textarea", .control },
    .{ "progress", .control },
    .{ "meter", .control },
    .{ "img", .img },
    .{ "canvas", .replaced },
    .{ "video", .replaced },
    .{ "iframe", .replaced },
    .{ "object", .replaced },
    .{ "embed", .replaced },
    .{ "ol", .list },
    .{ "ul", .list },
    .{ "menu", .list },
    .{ "dir", .list },
    .{ "table", .table },
    .{ "tr", .tr },
    .{ "td", .cell },
    .{ "th", .cell },
    .{ "center", .center },
    .{ "details", .details },
    .{ "slot", .slot },
});

pub inline fn classifyHtmlTag(name: []const u8) HtmlTag {
    return html_tag_map.get(name) orelse .other;
}

pub fn nowNs() u64 {
    return @import("js/conv.zig").monotonicNs();
}
