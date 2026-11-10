//! Pure performance and scheduling decision kernels for `nanobrowser`,
//! backed by formal Lean 4 proofs in `lean-proofs/NanoUI/BrowserPerf.lean`.
const std = @import("std");
const dom = @import("dom.zig");
const box = @import("layout/box.zig");
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
    if (d.dirty_nodes.items.len >= 4096) {
        d.dirty_all = true;
        return;
    }
    n.style_queued = true;
    d.dirty_nodes.append(d.arena, n) catch {
        n.style_queued = false;
        d.dirty_all = true;
    };
}

/// Theorem 28 & 29 (`NanoUI.Speedometer3Perf.attr_invalidation_scope`, `svg_geometry_attr_style_invariance`):
/// Scoped style invalidation when attribute `name` changes on element `n`.
pub fn touchAttr(d: *dom.Document, n: *dom.Node, name: []const u8) void {
    d.generation +%= 1;
    const is_id = std.mem.eql(u8, name, "id");
    if (is_id) d.id_generation +%= 1;
    if (n.has_resource) d.scan_dirty = true;
    if (!d.inDocument(n)) return;
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
