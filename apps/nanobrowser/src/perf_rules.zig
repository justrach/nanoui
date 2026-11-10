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
    return switch (tag.len) {
        4 => std.mem.eql(u8, tag, "link"),
        6 => std.mem.eql(u8, tag, "script") or std.mem.eql(u8, tag, "iframe"),
        else => std.mem.indexOfScalar(u8, tag, '-') != null,
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

const svg_pres_attrs = std.StaticStringMap(void).initComptime(.{
    .{"color"},             .{"fill"},              .{"fill-opacity"},      .{"fill-rule"},
    .{"clip-rule"},         .{"clip-path"},         .{"mask"},              .{"stroke"},
    .{"stroke-width"},      .{"stroke-opacity"},    .{"stroke-linecap"},    .{"stroke-linejoin"},
    .{"stroke-miterlimit"}, .{"stroke-dasharray"},  .{"stroke-dashoffset"}, .{"stop-color"},
    .{"stop-opacity"},      .{"opacity"},           .{"visibility"},        .{"display"},
    .{"paint-order"},       .{"vector-effect"},
});

const html_style_attrs = std.StaticStringMap(void).initComptime(.{
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
    if (n.id_attr) |id| b |= attrBit(id);
    return b;
}

/// Computes `n.ancestor_bloom` from its parent (or walks up to the root if `n == root`).
pub inline fn updateAncestorBloom(n: *dom.Node, root: *const dom.Node) void {
    if (n != root) if (n.parent) |p| if (p.kind == .element) {
        n.ancestor_bloom = p.ancestor_bloom | (if (p.is_shadow) 0 else nodeSelfBloom(p));
        return;
    };
    var b: u64 = 0;
    var at = n.parent;
    while (at) |x| : (at = x.parent) {
        if (x.kind == .element and !x.is_shadow) b |= nodeSelfBloom(x);
    }
    n.ancestor_bloom = b;
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

const unshareable_tags = std.StaticStringMap(void).initComptime(.{
    .{"body"}, .{"td"}, .{"th"}, .{"noscript"}, .{"select"},
    .{"textarea"}, .{"option"}, .{"optgroup"}, .{"fieldset"}, .{"progress"}, .{"summary"},
});

const html_style_attr_mask: u64 = blk: {
    var m: u64 = attrBit("style") | attrBit("slot") | attrBit("part") | attrBit("inert");
    for (html_style_attrs.keys()) |k| m |= attrBit(k);
    break :blk m;
};

fn eqlOptSlice(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub const ShareCand = struct {
    slot: usize,
    pos_flags: u8,
    uses_next: bool = false,
    extra_name: []const u8 = "",
    extra_val: ?[]const u8 = null,
    prev_tag: []const u8 = "",
    prev_class: ?[]const u8 = null,
};

/// Theorem 72 (`NanoUI.Speedometer3Apex.sibling_cousin_style_sharing_equiv`):
/// 32-slot direct-mapped per-generation style sharing cache for sibling and cousin elements.
pub const StyleShareEntry = struct {
    generation: u32 = 0,
    tree_scope: ?*const dom.Node = null,
    parent: ?*const dom.Node = null,
    parent_shared: bool = false,
    parent_style: ?*const style.Style = null,
    parent_scope: ?*const vars.Scope = null,
    ancestor_bloom: u64 = 0,
    tag: []const u8 = "",
    class_attr: ?[]const u8 = null,
    extra_name: []const u8 = "",
    extra_val: ?[]const u8 = null,
    pos_flags: u8 = 0,
    prev_tag: []const u8 = "",
    prev_class: ?[]const u8 = null,
    computed: *const style.Style = undefined,
    before: ?*const style.Style = null,
    after: ?*const style.Style = null,
    scope: ?*const vars.Scope = null,
};

pub const StyleShareCache = struct {
    entries: [32]StyleShareEntry = @splat(.{}),

    fn slotOf(parent_style: *const style.Style, tag: []const u8, class_filter: u64, pos_flags: u8) usize {
        var h: u64 = (@intFromPtr(parent_style) >> 4) *% 0x9E3779B97F4A7C15;
        h ^= class_filter *% 0x517CC1B727220A95;
        h ^= (@as(u64, tag.len) << 8) | (if (tag.len > 0) @as(u64, tag[0]) else 0);
        h ^= @as(u64, pos_flags) *% 0x94D049BB133111EB;
        return @intCast((h ^ (h >> 32)) & 31);
    }

    pub fn canShare(n: *const dom.Node, ix: *const rule_index.Index, parent_style: *const style.Style, parent_is_root: bool, parent_contents: bool, parent_is_host: bool, has_anim: bool) ?ShareCand {
        if (n.ns != .html or parent_is_root or parent_contents or parent_is_host or has_anim or n.doc.quirks) return null;
        if (n.is_shadow or n.shadow_root != null or n.id_attr != null) return null;
        if (n.tree_scope != null and (n.attr_filter & attrBit("part")) != 0) return null;
        if (n.modal or n.popover_open or n.checked != null or n.selected != null or n.value != null) return null;
        if (ix.uses_has or ix.uses_container or ix.uses_nth_index or ix.uses_later_sibling) return null;
        const doc = n.doc;
        if (doc.hover != null or doc.active != null) return null;
        if (doc.focus) |f| {
            if (f == n) return null;
            if (n.first_child != null and !(n.parent != null and (n.parent.?.style_shared or f.parent == n.parent)) and n.contains(f)) return null;
        }
        if (unshareable_tags.has(n.tag)) return null;
        if ((n.isTag("button") or n.isTag("input")) and (n.ancestor_bloom & (attrBit("fieldset") | attrBit("optgroup"))) != 0) return null;
        const rel_mask = ix.attr_filter | html_style_attr_mask;
        var extra_name: []const u8 = "";
        var extra_val: ?[]const u8 = null;
        if (n.attrs.items.len > @as(usize, @intFromBool(n.class_attr != null))) {
            if ((n.attr_filter & rel_mask) != 0) {
                for (n.attrs.items) |a| {
                    if (a.name.len == 5 and a.name[0] == 'c' and std.mem.eql(u8, a.name, "class")) continue;
                    if ((attrBit(a.name) & rel_mask) == 0) continue;
                    if (a.name.len == 5 and a.name[0] == 's' and std.mem.eql(u8, a.name, "style")) return null;
                    if (extra_val != null) return null;
                    extra_name = a.name;
                    extra_val = a.value;
                }
            }
        }
        const prev = if (ix.uses_first_child or ix.uses_next_sibling) n.prevElement() else null;
        var prev_tag: []const u8 = "";
        var prev_class: ?[]const u8 = null;
        if (ix.uses_next_sibling) {
            if (ix.uses_chained_next and prev != null) return null;
            if (prev) |pr| {
                if (pr.id_attr != null or pr.checked != null or pr.selected != null or pr.value != null or pr.modal or pr.popover_open or doc.focus == pr) return null;
                if ((pr.attr_filter & (attrBit("checked") | attrBit("disabled") | attrBit("open") | attrBit("readonly") | attrBit("required"))) != 0) return null;
                if (ix.uses_attr_before_next and (pr.attr_filter & ~attrBit("class") & rel_mask) != 0) return null;
                prev_tag = pr.tag;
                prev_class = pr.class_attr;
            }
        }
        var pos_flags: u8 = 0;
        if (ix.uses_first_child and prev == null) pos_flags |= 1;
        if (ix.uses_last_child and n.nextElement() == null) pos_flags |= 2;
        if (ix.uses_empty) {
            var is_empty = true;
            var ch = n.first_child;
            while (ch) |k| : (ch = k.next) {
                if (k.kind == .element or (k.kind == .text and k.data.len > 0)) {
                    is_empty = false;
                    break;
                }
            }
            if (is_empty) pos_flags |= 4;
        }
        return .{
            .slot = slotOf(parent_style, n.tag, n.class_filter, pos_flags),
            .pos_flags = pos_flags,
            .uses_next = ix.uses_next_sibling,
            .extra_name = extra_name,
            .extra_val = extra_val,
            .prev_tag = prev_tag,
            .prev_class = prev_class,
        };
    }

    pub fn lookup(self: *const StyleShareCache, gen: u32, n: *const dom.Node, parent_style: *const style.Style, parent_scope: ?*const vars.Scope, cand: ShareCand) ?*const StyleShareEntry {
        const entry = &self.entries[cand.slot];
        if (entry.generation != gen or entry.tree_scope != n.tree_scope or entry.parent_style != parent_style or entry.parent_scope != parent_scope) return null;
        if (entry.pos_flags != cand.pos_flags or entry.ancestor_bloom != n.ancestor_bloom) return null;
        if (n.parent != entry.parent and !(n.parent != null and n.parent.?.style_shared and entry.parent_shared)) return null;
        if (!std.mem.eql(u8, entry.tag, n.tag) or !eqlOptSlice(entry.class_attr, n.class_attr)) return null;
        if (!std.mem.eql(u8, entry.extra_name, cand.extra_name) or !eqlOptSlice(entry.extra_val, cand.extra_val)) return null;
        if (cand.uses_next) {
            if (!std.mem.eql(u8, entry.prev_tag, cand.prev_tag) or !eqlOptSlice(entry.prev_class, cand.prev_class)) return null;
        }
        return entry;
    }

    pub fn record(self: *StyleShareCache, gen: u32, n: *dom.Node, parent_style: *const style.Style, parent_scope: ?*const vars.Scope, cand: ShareCand, stored: *const style.Style, before: ?*const style.Style, after: ?*const style.Style, scope: ?*const vars.Scope, has_extra_pseudo: bool) void {
        if (has_extra_pseudo or stored.display == .none or stored.container_type != .normal) return;
        if (stored.transitions.len != 0 or stored.animations.len != 0) return;
        if (stored.counter_reset.len != 0 or stored.counter_increment.len != 0 or stored.counter_set.len != 0) return;
        if (before) |b| if (b.transitions.len != 0 or b.animations.len != 0 or b.content_parts.len != 0) return;
        if (after) |a| if (a.transitions.len != 0 or a.animations.len != 0 or a.content_parts.len != 0) return;
        n.style_shared = true;
        n.style_canon = stored;
        self.entries[cand.slot] = .{
            .generation = gen,
            .tree_scope = n.tree_scope,
            .parent = n.parent,
            .parent_shared = if (n.parent) |p| p.style_shared else false,
            .parent_style = parent_style,
            .parent_scope = parent_scope,
            .ancestor_bloom = n.ancestor_bloom,
            .tag = n.tag,
            .class_attr = n.class_attr,
            .extra_name = cand.extra_name,
            .extra_val = cand.extra_val,
            .pos_flags = cand.pos_flags,
            .prev_tag = cand.prev_tag,
            .prev_class = cand.prev_class,
            .computed = stored,
            .before = before,
            .after = after,
            .scope = scope,
        };
    }
};

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
