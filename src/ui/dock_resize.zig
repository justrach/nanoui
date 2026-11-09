//! A dock resized by the app rather than by a dragged divider: a panel's
//! group read back at its laid-out size, grown or shrunk by a number of
//! points, or set to an extent (a mixer collapsing to its strip), always
//! within the limits a drag keeps (`PanelInfo`'s min and max).
//!
//!     _ = tree.setGroupExtent(&dock_state.layout, mixer, .column, 72);
//!
//! Each moves the one divider beside the panel's group (or beside the
//! nearest split above it running along `axis`), as a drag of it would.
const std = @import("std");
const dock = @import("dock.zig");
const dl = @import("dock_layout.zig");
const types = @import("types.zig");
const Tree = dock.Tree;
const Axis = dock.Axis;

/// The size of `panel`'s group in `l` (a frame's layout), its header
/// included; null if the panel isn't docked or wasn't laid out.
pub fn groupSize(t: *const Tree, l: *const dl.Layout, panel: dock.PanelId) ?types.Size {
    const g = t.groupOf(panel) orelse return null;
    const item = l.group(g) orelse return null;
    return .{ .w = item.rect.w, .h = item.rect.h };
}

/// The rect of `panel`'s group in `l`, header included.
pub fn groupRect(t: *const Tree, l: *const dl.Layout, panel: dock.PanelId) ?types.Rect {
    const g = t.groupOf(panel) orelse return null;
    return (l.group(g) orelse return null).rect;
}

/// The divider that resizes `panel`'s group along `axis`, and the sign a
/// delta takes on it so the group grows: the one after the group (or the
/// subtree holding it) in the nearest split along `axis`, else the one
/// before it.
pub fn dividerFor(t: *const Tree, l: *const dl.Layout, panel: dock.PanelId, axis: Axis) ?struct { divider: dl.DividerItem, sign: f32 } {
    var child = t.groupOf(panel) orelse return null;
    while (t.parentOf(child)) |parent| : (child = parent.node) {
        const sp = t.nodes[parent.node];
        if (sp.axis != axis) continue;
        const after = parent.slot + 1 < sp.child_count;
        const index: u8 = if (after) parent.slot else parent.slot - 1;
        for (l.dividers[0..l.divider_count]) |d| {
            if (d.split == parent.node and d.index == index) return .{ .divider = d, .sign = if (after) 1 else -1 };
        }
        return null;
    }
    return null;
}

/// Grows `panel`'s group by `delta` points along `axis` (shrinks it when
/// negative), taking the room from its neighbour, within both one's
/// limits. Whether the split's weights changed. Lay the tree out again
/// before reading sizes back.
pub fn adjustDividerFor(t: *Tree, l: *const dl.Layout, panel: dock.PanelId, axis: Axis, delta: f32) bool {
    if (!std.math.isFinite(delta) or delta == 0) return false;
    const found = dividerFor(t, l, panel, axis) orelse return false;
    const sp = &t.nodes[found.divider.split];
    const n = sp.child_count;
    const before = sp.weights;
    dl.adjustDivider(t, l, found.divider, delta * found.sign);
    return !std.mem.eql(f32, before[0..n], sp.weights[0..n]);
}

/// Sets `panel`'s group to `extent` points along `axis` (its height for
/// `.column`), as near as its and its neighbour's limits let it: the
/// layout is run again over `l`'s bounds to land on whole points. A
/// split's last child takes what the others leave, dividers included, so
/// with a fractional divider (`Metrics.divider`, 4.5) it lands within
/// half a point. Whether anything changed.
pub fn setGroupExtent(t: *Tree, l: *const dl.Layout, panel: dock.PanelId, axis: Axis, extent: f32) bool {
    if (!std.math.isFinite(extent)) return false;
    const bounds = layoutBounds(l) orelse return false;
    var cur = l.*;
    var changed = false;
    // Weights are shares of the split, and the layout rounds to points:
    // a second pass takes up what the first left.
    for (0..3) |_| {
        const r = groupRect(t, &cur, panel) orelse return changed;
        const have = if (axis == .row) r.w else r.h;
        const delta = extent - have;
        if (@abs(delta) <= 0.5) break;
        if (!adjustDividerFor(t, &cur, panel, axis, delta)) break;
        changed = true;
        cur = dl.layout(t, bounds);
    }
    return changed;
}

/// The bounds a layout was made over: its groups' and dividers' union.
fn layoutBounds(l: *const dl.Layout) ?types.Rect {
    if (l.group_count == 0) return null;
    var r = l.groups[0].rect;
    for (l.groups[1..l.group_count]) |g| r = unite(r, g.rect);
    for (l.dividers[0..l.divider_count]) |d| r = unite(r, d.rect);
    return r;
}

fn unite(a: types.Rect, b: types.Rect) types.Rect {
    const x2 = @max(a.x + a.w, b.x + b.w);
    const y2 = @max(a.y + a.h, b.y + b.h);
    const x = @min(a.x, b.x);
    const y = @min(a.y, b.y);
    return .{ .x = x, .y = y, .w = x2 - x, .h = y2 - y };
}

test "setGroupExtent collapses a panel to a 72-point strip and back" {
    const catalog = [_]dock.PanelInfo{ .{ .title = "Timeline", .min_h = 80 }, .{ .title = "Mixer", .min_h = 40 }, .{ .title = "Bin" } };
    var t = Tree.init(&catalog);
    try std.testing.expect(t.insert(0, null));
    // The mixer above the timeline, the bin beside the timeline.
    try std.testing.expect(t.split(1, 0, .top));
    try std.testing.expect(t.split(2, 0, .left));
    const bounds: types.Rect = .{ .w = 900, .h = 600 };
    var l = t.layout(bounds);
    try std.testing.expect(t.setGroupExtent(&l, 1, .column, 72));
    l = t.layout(bounds);
    try std.testing.expectEqual(@as(f32, 72), t.groupSize(&l, 1).?.h);
    try std.testing.expect(t.validate());
    // Below its minimum it stops there, as a drag would.
    _ = t.setGroupExtent(&l, 1, .column, 10);
    l = t.layout(bounds);
    try std.testing.expectEqual(@as(f32, 40), t.groupSize(&l, 1).?.h);
    // Grown back by a delta.
    try std.testing.expect(t.adjustDividerFor(&l, 1, .column, 200));
    l = t.layout(bounds);
    try std.testing.expectApproxEqAbs(@as(f32, 240), t.groupSize(&l, 1).?.h, 1);
    // The mixer spans the width: no split above it runs along a row.
    try std.testing.expect(!t.setGroupExtent(&l, 1, .row, 300));
    // The bin, in the row below, is set by its width.
    try std.testing.expect(t.setGroupExtent(&l, 2, .row, 300));
    l = t.layout(bounds);
    try std.testing.expectEqual(@as(f32, 300), t.groupSize(&l, 2).?.w);
    try std.testing.expect(t.groupSize(&l, 9) == null);
}

test "setGroupExtent on a split's last child: from the divider before it, within half a point" {
    const catalog = [_]dock.PanelInfo{ .{ .title = "Timeline", .min_h = 80 }, .{ .title = "Mixer", .min_h = 40 } };
    var t = Tree.init(&catalog);
    try std.testing.expect(t.insert(0, null));
    try std.testing.expect(t.split(1, 0, .bottom));
    const bounds: types.Rect = .{ .w = 900, .h = 600 };
    var l = t.layout(bounds);
    try std.testing.expect(t.setGroupExtent(&l, 1, .column, 72));
    l = t.layout(bounds);
    try std.testing.expectApproxEqAbs(@as(f32, 72), t.groupSize(&l, 1).?.h, 0.5);
    // A divider of whole points: exact.
    t.metrics.divider = 4;
    l = t.layout(bounds);
    _ = t.setGroupExtent(&l, 1, .column, 200);
    l = t.layout(bounds);
    try std.testing.expect(t.setGroupExtent(&l, 1, .column, 72));
    l = t.layout(bounds);
    try std.testing.expectEqual(@as(f32, 72), t.groupSize(&l, 1).?.h);
}
