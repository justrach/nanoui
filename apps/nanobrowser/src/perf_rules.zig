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
