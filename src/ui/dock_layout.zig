//! A dock tree laid out into rects: each group's frame, header and
//! content, and the dividers between a split's children. Also where a
//! dragged panel would land, and a divider dragged within its children's
//! limits.
const std = @import("std");
const dock = @import("dock.zig");
const Tree = dock.Tree;
const Rect = dock.Rect;
const Axis = dock.Axis;
const max_nodes = dock.max_nodes;
const max_children = dock.max_children;
const unbounded = dock.unbounded;

pub const GroupItem = struct { node: u8, rect: Rect, header: Rect, content: Rect };
pub const DividerItem = struct { split: u8, index: u8, axis: Axis, rect: Rect };

pub const Layout = struct {
    groups: [max_nodes]GroupItem = undefined,
    group_count: u8 = 0,
    dividers: [max_nodes]DividerItem = undefined,
    divider_count: u8 = 0,

    pub fn group(l: *const Layout, node: u8) ?GroupItem {
        for (l.groups[0..l.group_count]) |item| if (item.node == node) return item;
        return null;
    }

    /// The content rect of `panel` while it is its group's shown tab.
    pub fn contentOf(l: *const Layout, t: *const Tree, panel: dock.PanelId) ?Rect {
        const g = t.groupOf(panel) orelse return null;
        if (t.nodes[g].activePanel() != panel) return null;
        return (l.group(g) orelse return null).content;
    }

    /// The divider whose grab band (its gutter widened by `slop` on both
    /// sides) holds the point; the nearer gutter wins where bands overlap.
    pub fn dividerAt(l: *const Layout, x: f32, y: f32, slop: f32) ?u8 {
        var best: ?u8 = null;
        var best_d: f32 = slop;
        for (l.dividers[0..l.divider_count], 0..) |d, i| {
            const dist = distance(d, x, y) orelse continue;
            if (dist <= best_d) {
                if (best != null and dist == best_d) continue;
                best = @intCast(i);
                best_d = dist;
            }
        }
        return best;
    }
};

fn distance(d: DividerItem, x: f32, y: f32) ?f32 {
    const r = d.rect;
    const along = if (d.axis == .row) y - r.y else x - r.x;
    const length = if (d.axis == .row) r.h else r.w;
    if (along < 0 or along >= length) return null;
    const cross = if (d.axis == .row) x else y;
    const start = if (d.axis == .row) r.x else r.y;
    const end = start + (if (d.axis == .row) r.w else r.h);
    if (cross < start) return start - cross;
    if (cross >= end) return cross - end;
    return 0;
}

const Size = struct { w: f32, h: f32 };

/// Every group and divider in `bounds`.
pub fn layout(t: *const Tree, bounds: Rect) Layout {
    var out: Layout = .{};
    if (!t.validate()) return out;
    const safe = Rect{ .x = bounds.x, .y = bounds.y, .w = if (std.math.isFinite(bounds.w)) @max(bounds.w, 0) else 0, .h = if (std.math.isFinite(bounds.h)) @max(bounds.h, 0) else 0 };
    layoutNode(t, t.root, safe, &out);
    return out;
}

/// One group alone over `bounds` (a maximized panel's): its header with
/// every tab and its content, no dividers.
pub fn soloLayout(t: *const Tree, group_node: u8, bounds: Rect) Layout {
    var out: Layout = .{};
    if (!t.validate() or !dock.validGroup(t, group_node)) return out;
    const safe = Rect{ .x = bounds.x, .y = bounds.y, .w = if (std.math.isFinite(bounds.w)) @max(bounds.w, 0) else 0, .h = if (std.math.isFinite(bounds.h)) @max(bounds.h, 0) else 0 };
    layoutNode(t, group_node, safe, &out);
    return out;
}

/// Where a panel dropped at (x, y) lands: the nearest edge band of the
/// group under the point (a quarter of its side, at most 80 points), or
/// its center.
pub fn dropTarget(t: *const Tree, l: *const Layout, x: f32, y: f32) ?dock.DropTarget {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return null;
    for (l.groups[0..l.group_count]) |item| {
        if (!dock.validGroup(t, item.node)) continue;
        const r = item.rect;
        if (x < r.x or y < r.y or x > r.x + r.w or y > r.y + r.h) continue;
        // Over the tab strip: a tab of this group.
        if (y < item.header.y + item.header.h) return .{ .group = item.node, .zone = .center };
        const bx = @min(r.w * 0.25, 80);
        const by = @min(r.h * 0.25, 80);
        var zone: dock.DropZone = .center;
        var best: f32 = std.math.inf(f32);
        if (x - r.x <= bx and x - r.x < best) {
            zone = .left;
            best = x - r.x;
        }
        if (r.x + r.w - x <= bx and r.x + r.w - x < best) {
            zone = .right;
            best = r.x + r.w - x;
        }
        if (y - r.y <= by and y - r.y < best) {
            zone = .top;
            best = y - r.y;
        }
        if (r.y + r.h - y <= by and r.y + r.h - y < best) zone = .bottom;
        return .{ .group = item.node, .zone = zone };
    }
    return null;
}

/// The part of a group's rect a drop on `zone` fills: what to highlight.
pub fn zoneRect(r: Rect, zone: dock.DropZone) Rect {
    return switch (zone) {
        .center => r,
        .left => .{ .x = r.x, .y = r.y, .w = r.w / 2, .h = r.h },
        .right => .{ .x = r.x + r.w / 2, .y = r.y, .w = r.w / 2, .h = r.h },
        .top => .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h / 2 },
        .bottom => .{ .x = r.x, .y = r.y + r.h / 2, .w = r.w, .h = r.h / 2 },
    };
}

/// Moves a divider by `delta` points (`moveDivider`, the distance it
/// went discarded).
pub fn adjustDivider(t: *Tree, l: *const Layout, d: DividerItem, delta_in: f32) void {
    _ = moveDivider(t, l, d, delta_in);
}

/// Moves a divider by `delta` points and returns how far it went. The
/// side it moves into gives up the room, nearest child first: each holds
/// at its minimum and pushes the next one, and the divider stops when
/// every child on that side is at its minimum. The side it moves away
/// from takes the room the same way, nearest first, each up to its
/// maximum. Sizes are read from `l`, which must be the tree's layout as
/// it stands.
pub fn moveDivider(t: *Tree, l: *const Layout, d: DividerItem, delta_in: f32) f32 {
    if (!std.math.isFinite(delta_in) or delta_in == 0 or d.split >= t.node_count) return 0;
    const sp = &t.nodes[d.split];
    if (sp.kind != .split or sp.axis != d.axis or d.index + 1 >= sp.child_count) return 0;
    const n: usize = sp.child_count;
    var sizes: [max_children]f32 = @splat(0);
    var mins: [max_children]f32 = @splat(0);
    var maxs: [max_children]f32 = @splat(unbounded);
    var total: f32 = 0;
    for (0..n) |i| {
        const r = subtreeRect(t, l, sp.children[i]) orelse return 0;
        sizes[i] = extent(r, sp.axis);
        mins[i] = sizeOn(nodeMin(t, sp.children[i]), sp.axis);
        maxs[i] = sizeOn(nodeMax(t, sp.children[i]), sp.axis);
        total += sizes[i];
    }
    if (total <= 0) return 0;
    // Toward the end (delta > 0) the children after the divider give and
    // those before it take; toward the start, the other way round. Both
    // sides are walked outward from the divider.
    const before = Side{ .first = d.index, .last = 0 };
    const after = Side{ .first = d.index + 1, .last = @intCast(n - 1) };
    const giver = if (delta_in > 0) after else before;
    const taker = if (delta_in > 0) before else after;
    var give_room: f32 = 0;
    var take_room: f32 = 0;
    var it = giver.iter();
    while (it.next()) |i| give_room += @max(sizes[i] - mins[i], 0);
    it = taker.iter();
    while (it.next()) |i| take_room += @max(maxs[i] - sizes[i], 0);
    const amount = @min(@abs(delta_in), @min(give_room, take_room));
    if (!(amount > 0)) return 0;
    var left = amount;
    it = giver.iter();
    while (it.next()) |i| {
        const g = @min(left, @max(sizes[i] - mins[i], 0));
        sizes[i] -= g;
        left -= g;
    }
    left = amount;
    it = taker.iter();
    while (it.next()) |i| {
        const g = @min(left, @max(maxs[i] - sizes[i], 0));
        sizes[i] += g;
        left -= g;
    }
    for (0..n) |i| sp.weights[i] = sizes[i] / total;
    dock.normalize(sp);
    return if (delta_in > 0) amount else -amount;
}

/// A run of a split's children, walked from `first` to `last` (either
/// way round).
const Side = struct {
    first: u8,
    last: u8,

    const Iter = struct {
        at: i16,
        last: i16,
        step: i16,
        fn next(s: *Iter) ?usize {
            if ((s.step > 0 and s.at > s.last) or (s.step < 0 and s.at < s.last)) return null;
            const i: usize = @intCast(s.at);
            s.at += s.step;
            return i;
        }
    };

    fn iter(s: Side) Iter {
        return .{ .at = s.first, .last = s.last, .step = if (s.last >= s.first) 1 else -1 };
    }
};

pub fn nodeMin(t: *const Tree, index: u8) Size {
    const node = t.nodes[index];
    if (node.kind == .group) {
        var r = Size{ .w = 0, .h = t.headerHeight(index) };
        for (node.tabs[0..node.tab_count]) |p| {
            const i = t.info(p);
            r.w = @max(r.w, i.min_w);
            r.h = @max(r.h, i.min_h);
        }
        return r;
    }
    var r = Size{ .w = 0, .h = 0 };
    for (node.children[0..node.child_count]) |child| {
        const m = nodeMin(t, child);
        if (node.axis == .row) {
            r.w += m.w;
            r.h = @max(r.h, m.h);
        } else {
            r.w = @max(r.w, m.w);
            r.h += m.h;
        }
    }
    const gaps = t.metrics.divider * @as(f32, @floatFromInt(node.child_count - 1));
    if (node.axis == .row) r.w += gaps else r.h += gaps;
    return r;
}

fn nodeMax(t: *const Tree, index: u8) Size {
    const node = t.nodes[index];
    if (node.kind == .group) {
        var r = Size{ .w = unbounded, .h = unbounded };
        for (node.tabs[0..node.tab_count]) |p| {
            const i = t.info(p);
            r.w = @min(r.w, i.max_w);
            r.h = @min(r.h, i.max_h);
        }
        const m = nodeMin(t, index);
        return .{ .w = @max(r.w, m.w), .h = @max(r.h, m.h) };
    }
    var r = Size{ .w = if (node.axis == .row) 0 else unbounded, .h = if (node.axis == .row) unbounded else 0 };
    for (node.children[0..node.child_count]) |child| {
        const m = nodeMax(t, child);
        if (node.axis == .row) {
            r.w += m.w;
            r.h = @min(r.h, m.h);
        } else {
            r.w = @min(r.w, m.w);
            r.h += m.h;
        }
    }
    const gaps = t.metrics.divider * @as(f32, @floatFromInt(node.child_count - 1));
    if (node.axis == .row) r.w += gaps else r.h += gaps;
    return r;
}

fn layoutNode(t: *const Tree, index: u8, rect: Rect, out: *Layout) void {
    const node = t.nodes[index];
    const m = t.metrics;
    if (node.kind == .group) {
        const hh = @min(t.headerHeight(index), rect.h);
        out.groups[out.group_count] = .{
            .node = index,
            .rect = rect,
            .header = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = hh },
            .content = .{ .x = rect.x + @min(m.border, rect.w * 0.5), .y = rect.y + hh, .w = @max(rect.w - m.border * 2, 0), .h = @max(rect.h - hh - m.bottom_inset, 0) },
        };
        out.group_count += 1;
        return;
    }
    const n: usize = node.child_count;
    const ext = extent(rect, node.axis);
    const div = if (n > 1) @min(m.divider, ext / @as(f32, @floatFromInt(n - 1))) else 0;
    const avail = @max(ext - div * @as(f32, @floatFromInt(n - 1)), 0);
    var mins: [max_children]f32 = @splat(0);
    var maxs: [max_children]f32 = @splat(unbounded);
    var sizes: [max_children]f32 = @splat(0);
    for (0..n) |i| {
        mins[i] = sizeOn(nodeMin(t, node.children[i]), node.axis);
        maxs[i] = sizeOn(nodeMax(t, node.children[i]), node.axis);
    }
    distribute(node.weights[0..n], mins[0..n], maxs[0..n], avail, sizes[0..n]);
    // Room a ceiling freed goes to the last child that can take it.
    var used: f32 = 0;
    for (0..n) |i| used += sizes[i];
    const left = avail - used;
    if (left > 0.001) {
        var fill = n - 1;
        var scan = n;
        while (scan > 0) {
            scan -= 1;
            if (sizes[scan] + 0.001 < maxs[scan]) {
                fill = scan;
                break;
            }
        }
        sizes[fill] += left;
    }
    var cursor = if (node.axis == .row) rect.x else rect.y;
    const end = cursor + ext;
    for (0..n) |i| {
        // Whole points: panels' edges land on pixels.
        const e = if (i + 1 == n) @max(end - cursor, 0) else @round(sizes[i]);
        const r = if (node.axis == .row) Rect{ .x = cursor, .y = rect.y, .w = e, .h = rect.h } else Rect{ .x = rect.x, .y = cursor, .w = rect.w, .h = e };
        layoutNode(t, node.children[i], r, out);
        cursor += e;
        if (i + 1 < n) {
            const dr = if (node.axis == .row) Rect{ .x = cursor, .y = rect.y, .w = div, .h = rect.h } else Rect{ .x = rect.x, .y = cursor, .w = rect.w, .h = div };
            out.dividers[out.divider_count] = .{ .split = index, .index = @intCast(i), .axis = node.axis, .rect = dr };
            out.divider_count += 1;
            cursor += div;
        }
    }
}

/// A weighted share of `avail` for each child, clamped to its [min, max];
/// clamped children are pinned and the rest share again.
fn distribute(weights: []const f32, mins: []const f32, maxs: []const f32, avail: f32, out: []f32) void {
    var min_sum: f32 = 0;
    for (mins) |v| min_sum += v;
    if (min_sum > avail and min_sum > 0) {
        for (mins, 0..) |v, i| out[i] = avail * v / min_sum;
        return;
    }
    var fixed: [max_children]bool = @splat(false);
    var remaining = avail;
    var pass: usize = 0;
    while (pass < out.len) : (pass += 1) {
        var wsum: f32 = 0;
        var free: usize = 0;
        for (weights, 0..) |w, i| if (!fixed[i]) {
            wsum += w;
            free += 1;
        };
        if (free == 0) return;
        var changed = false;
        for (weights, 0..) |w, i| {
            if (fixed[i]) continue;
            const want = if (wsum > 0) remaining * w / wsum else remaining / @as(f32, @floatFromInt(free));
            if (want + 0.0001 < mins[i]) {
                out[i] = mins[i];
                remaining -= mins[i];
                fixed[i] = true;
                changed = true;
            } else if (want > maxs[i] + 0.0001) {
                out[i] = maxs[i];
                remaining -= maxs[i];
                fixed[i] = true;
                changed = true;
            }
        }
        if (!changed) {
            for (weights, 0..) |w, i| {
                if (!fixed[i]) out[i] = if (wsum > 0) remaining * w / wsum else remaining / @as(f32, @floatFromInt(free));
            }
            return;
        }
    }
}

fn extent(r: Rect, axis: Axis) f32 {
    return if (axis == .row) r.w else r.h;
}
fn sizeOn(s: Size, axis: Axis) f32 {
    return if (axis == .row) s.w else s.h;
}

fn subtreeRect(t: *const Tree, l: *const Layout, index: u8) ?Rect {
    const node = t.nodes[index];
    if (node.kind == .group) return (l.group(index) orelse return null).rect;
    var r = subtreeRect(t, l, node.children[0]) orelse return null;
    for (node.children[1..node.child_count]) |child| {
        const c = subtreeRect(t, l, child) orelse return null;
        const x2 = @max(r.x + r.w, c.x + c.w);
        const y2 = @max(r.y + r.h, c.y + c.h);
        r.x = @min(r.x, c.x);
        r.y = @min(r.y, c.y);
        r.w = x2 - r.x;
        r.h = y2 - r.y;
    }
    return r;
}

test "a row of three tiles its bounds and a divider drag respects minima" {
    const catalog = [_]dock.PanelInfo{ .{ .title = "A", .min_w = 100 }, .{ .title = "B", .min_w = 100 }, .{ .title = "C", .min_w = 100, .max_w = 200 } };
    var t = Tree.init(&catalog);
    try std.testing.expect(t.insert(0, null));
    try std.testing.expect(t.split(1, 0, .right));
    try std.testing.expect(t.split(2, 1, .right));
    var l = t.layout(.{ .w = 1000, .h = 500 });
    try std.testing.expectEqual(@as(u8, 3), l.group_count);
    try std.testing.expectEqual(@as(u8, 2), l.divider_count);
    const c = l.group(t.groupOf(2).?).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1000), c.rect.x + c.rect.w, 0.01);
    try std.testing.expect(c.rect.w <= 200.5);
    t.adjustDivider(&l, l.dividers[0], -10000);
    l = t.layout(.{ .w = 1000, .h = 500 });
    try std.testing.expectApproxEqAbs(@as(f32, 100), l.group(t.groupOf(0).?).?.rect.w, 0.5);
    const drop = t.dropTarget(&l, 990, 300).?;
    try std.testing.expectEqual(dock.DropZone.right, drop.zone);
}

test "a divider pushed past a panel's minimum pushes the next panel, then holds" {
    const catalog = [_]dock.PanelInfo{ .{ .title = "A", .min_w = 100 }, .{ .title = "B", .min_w = 100 }, .{ .title = "C", .min_w = 100 } };
    var t = Tree.init(&catalog);
    try std.testing.expect(t.insert(0, null));
    try std.testing.expect(t.split(1, 0, .right));
    try std.testing.expect(t.split(2, 1, .right));
    t.metrics.divider = 4;
    const bounds: Rect = .{ .w = 1000, .h = 500 };
    var l = t.layout(bounds);
    const a0 = l.group(t.groupOf(0).?).?.rect.w;
    // B sits beside the divider and gives first; at its minimum, C gives.
    const moved = t.moveDivider(&l, l.dividers[0], 10000);
    l = t.layout(bounds);
    try std.testing.expectApproxEqAbs(@as(f32, 100), l.group(t.groupOf(1).?).?.rect.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 100), l.group(t.groupOf(2).?).?.rect.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 792), l.group(t.groupOf(0).?).?.rect.w, 0.5);
    // It went only as far as the room the two had.
    try std.testing.expectApproxEqAbs(792 - a0, moved, 0.5);
    // Held: further in the same direction it goes nowhere.
    try std.testing.expectEqual(@as(f32, 0), t.moveDivider(&l, l.dividers[0], 50));
    // The other divider, leftward: B is at its minimum, so A gives.
    const back = t.moveDivider(&l, l.dividers[1], -200);
    try std.testing.expectApproxEqAbs(@as(f32, -200), back, 0.01);
    l = t.layout(bounds);
    try std.testing.expectApproxEqAbs(@as(f32, 592), l.group(t.groupOf(0).?).?.rect.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 100), l.group(t.groupOf(1).?).?.rect.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 300), l.group(t.groupOf(2).?).?.rect.w, 0.5);
    try std.testing.expect(t.validate());
}

test "a panel at its maximum passes the room on to the next one" {
    const catalog = [_]dock.PanelInfo{ .{ .title = "A", .min_w = 100 }, .{ .title = "B", .min_w = 100, .max_w = 300 }, .{ .title = "C", .min_w = 100 } };
    var t = Tree.init(&catalog);
    try std.testing.expect(t.insert(0, null));
    try std.testing.expect(t.split(1, 0, .right));
    try std.testing.expect(t.split(2, 1, .right));
    t.metrics.divider = 4;
    const bounds: Rect = .{ .w = 1000, .h = 500 };
    var l = t.layout(bounds);
    const b0 = l.group(t.groupOf(1).?).?.rect.w;
    const a0 = l.group(t.groupOf(0).?).?.rect.w;
    // C gives up to its minimum; B takes up to its ceiling, A the rest.
    _ = t.moveDivider(&l, l.dividers[1], 10000);
    l = t.layout(bounds);
    try std.testing.expectApproxEqAbs(@as(f32, 100), l.group(t.groupOf(2).?).?.rect.w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 300), l.group(t.groupOf(1).?).?.rect.w, 0.5);
    try std.testing.expect(l.group(t.groupOf(0).?).?.rect.w > a0);
    try std.testing.expect(b0 < 300);
}
