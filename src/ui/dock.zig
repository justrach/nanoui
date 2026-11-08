//! Dockable panels: a tree of splits (rows or columns of weighted
//! children) whose leaves are groups of tabbed panels. Pure data, no
//! drawing (the view is `dock_view.zig`): the app keeps a `Tree`, lays
//! it out into rects each frame, and moves panels between groups or into
//! new splits by dropping them on a group's edge or center.
//!
//!     var tree = ui.dock.Tree.init(&catalog);
//!     _ = tree.insert(panel_a, null);
//!     _ = tree.move(panel_b, .{ .group = tree.groupOf(panel_a).?, .zone = .right });
//!
//! Panels are small integers the app owns (an enum's value): `catalog`
//! gives each its title and its size limits. Nothing allocates.
const std = @import("std");
const types = @import("types.zig");
const layout_mod = @import("dock_layout.zig");
const resize = @import("dock_resize.zig");

pub const Rect = types.Rect;
pub const PanelId = u8;
pub const max_nodes = 32;
pub const max_children = 8;
pub const max_tabs = 8;
pub const unbounded: f32 = std.math.inf(f32);

/// What the dock knows of a panel: its tab's title and the room it needs.
pub const PanelInfo = struct {
    title: []const u8 = "",
    min_w: f32 = 120,
    min_h: f32 = 80,
    max_w: f32 = unbounded,
    max_h: f32 = unbounded,
    /// Its group's header is this tall while it is the active tab (null:
    /// `Metrics.header_height`): a panel with a toolbar in its header.
    header_height: ?f32 = null,
};

/// Sizes every layout shares.
pub const Metrics = struct {
    header_height: f32 = 36,
    divider: f32 = 4.5,
    /// How far past each side of a divider a press still grabs it.
    grab_slop: f32 = 5,
    /// The panel's content is inset by its border, and by `bottom_inset`
    /// at its foot (a rounded panel's corner).
    border: f32 = 1,
    bottom_inset: f32 = 5,
};

pub const Axis = enum(u8) { row, column };
pub const NodeKind = enum(u8) { split, group };

pub const Node = struct {
    kind: NodeKind,
    axis: Axis = .row,
    children: [max_children]u8 = undefined,
    child_count: u8 = 0,
    weights: [max_children]f32 = undefined,
    tabs: [max_tabs]PanelId = undefined,
    tab_count: u8 = 0,
    active_tab: u8 = 0,

    pub fn group(panel: ?PanelId) Node {
        var node = Node{ .kind = .group };
        if (panel) |id| {
            node.tabs[0] = id;
            node.tab_count = 1;
        }
        return node;
    }

    pub fn split(axis: Axis, children: []const u8, weights: []const f32) Node {
        var node = Node{ .kind = .split, .axis = axis };
        node.child_count = @intCast(children.len);
        for (children, 0..) |child, i| node.children[i] = child;
        for (weights, 0..) |weight, i| node.weights[i] = weight;
        return node;
    }

    pub fn activePanel(n: Node) ?PanelId {
        return if (n.kind == .group and n.tab_count > 0) n.tabs[n.active_tab] else null;
    }
};

/// Where a dragged panel lands: as a tab of `group` (`center`), or in a
/// new group beside it.
pub const DropZone = enum(u8) { center, left, right, top, bottom };
pub const DropTarget = struct { group: u8, zone: DropZone };

pub const Tree = struct {
    nodes: [max_nodes]Node = undefined,
    node_count: u8 = 1,
    root: u8 = 0,
    /// Every panel's info, by id (kept by the app).
    catalog: []const PanelInfo,
    metrics: Metrics = .{},

    /// One empty group.
    pub fn init(catalog: []const PanelInfo) Tree {
        var t: Tree = .{ .catalog = catalog };
        t.nodes[0] = Node.group(null);
        return t;
    }

    pub fn info(t: *const Tree, panel: PanelId) PanelInfo {
        return if (panel < t.catalog.len) t.catalog[panel] else .{};
    }

    pub fn title(t: *const Tree, panel: PanelId) []const u8 {
        return t.info(panel).title;
    }

    pub fn validate(t: *const Tree) bool {
        if (t.node_count == 0 or t.node_count > max_nodes or t.root >= t.node_count) return false;
        var visited: [max_nodes]bool = @splat(false);
        var panels: [256]bool = @splat(false);
        if (!validateNode(t, t.root, &visited, &panels)) return false;
        for (0..t.node_count) |i| if (!visited[i]) return false;
        return true;
    }

    pub fn contains(t: *const Tree, panel: PanelId) bool {
        return t.groupOf(panel) != null;
    }

    pub fn panelCount(t: *const Tree) usize {
        var n: usize = 0;
        for (t.nodes[0..t.node_count]) |node| {
            if (node.kind == .group) n += node.tab_count;
        }
        return n;
    }

    /// The group holding `panel`.
    pub fn groupOf(t: *const Tree, panel: PanelId) ?u8 {
        for (t.nodes[0..t.node_count], 0..) |node, i| {
            if (node.kind != .group) continue;
            for (node.tabs[0..node.tab_count]) |tab| if (tab == panel) return @intCast(i);
        }
        return null;
    }

    /// Whether `panel` is the tab its group shows.
    pub fn isShown(t: *const Tree, panel: PanelId) bool {
        const g = t.groupOf(panel) orelse return false;
        return t.nodes[g].activePanel() == panel;
    }

    /// The split holding `child`, and its slot there.
    pub fn parentOf(t: *const Tree, child: u8) ?struct { node: u8, slot: u8 } {
        for (t.nodes[0..t.node_count], 0..) |node, i| {
            if (node.kind != .split) continue;
            for (node.children[0..node.child_count], 0..) |candidate, slot| if (candidate == child) return .{ .node = @intCast(i), .slot = @intCast(slot) };
        }
        return null;
    }

    /// The header's height while `group` shows its active tab.
    pub fn headerHeight(t: *const Tree, group: u8) f32 {
        const p = t.nodes[group].activePanel() orelse return t.metrics.header_height;
        return t.info(p).header_height orelse t.metrics.header_height;
    }

    /// Adds an absent panel to `preferred` (or the first group) as its active tab.
    pub fn insert(t: *Tree, panel: PanelId, preferred: ?u8) bool {
        if (!t.validate() or t.contains(panel)) return false;
        var next = t.*;
        const g = if (preferred) |p| (if (validGroup(&next, p)) p else firstGroup(&next, next.root)) else firstGroup(&next, next.root);
        if (!appendTab(&next, g, panel) or !next.validate()) return false;
        t.* = next;
        return true;
    }

    /// Adds an absent panel at a drop target.
    pub fn insertAt(t: *Tree, panel: PanelId, target: DropTarget) bool {
        if (!t.validate() or t.contains(panel) or !validGroup(t, target.group)) return false;
        var next = t.*;
        const ok = switch (target.zone) {
            .center => appendTab(&next, target.group, panel),
            else => splitPanel(&next, target.group, panel, target.zone),
        };
        if (!ok or !next.validate()) return false;
        t.* = next;
        return true;
    }

    /// Adds `panel` in a new group on `zone`'s side of the group holding
    /// `beside`: how a default layout is written.
    pub fn split(t: *Tree, panel: PanelId, beside: PanelId, zone: DropZone) bool {
        const g = t.groupOf(beside) orelse return false;
        return t.insertAt(panel, .{ .group = g, .zone = zone });
    }

    /// Adds `panel` as a tab beside `beside`, leaving the shown tab shown.
    pub fn tabBehind(t: *Tree, panel: PanelId, beside: PanelId) bool {
        const g = t.groupOf(beside) orelse return false;
        const active = t.nodes[g].active_tab;
        if (!t.insert(panel, g)) return false;
        t.nodes[g].active_tab = active;
        return true;
    }

    /// Moves a present panel to a drop target; false (and nothing changed) if it can't go there.
    pub fn move(t: *Tree, panel: PanelId, target: DropTarget) bool {
        if (!t.validate()) return false;
        const source = t.groupOf(panel) orelse return false;
        if (!validGroup(t, target.group)) return false;
        if (source == target.group and target.zone == .center) return true;
        if (source == target.group and t.nodes[source].tab_count == 1) return false;
        var next = t.*;
        var tracked: ?u8 = target.group;
        if (!removeTracked(&next, panel, &tracked)) return false;
        const g = tracked orelse return false;
        if (!validGroup(&next, g)) return false;
        const ok = switch (target.zone) {
            .center => appendTab(&next, g, panel),
            else => splitPanel(&next, g, panel, target.zone),
        };
        if (!ok or !next.validate()) return false;
        t.* = next;
        return true;
    }

    /// Removes a panel, deleting its group if it was the last tab.
    pub fn remove(t: *Tree, panel: PanelId) bool {
        if (!t.validate()) return false;
        var next = t.*;
        var ignored: ?u8 = null;
        if (!removeTracked(&next, panel, &ignored) or !next.validate()) return false;
        t.* = next;
        return true;
    }

    pub fn setActive(t: *Tree, group: u8, tab: u8) void {
        if (!validGroup(t, group) or tab >= t.nodes[group].tab_count) return;
        t.nodes[group].active_tab = tab;
    }

    /// Shows `panel` in its group.
    pub fn focus(t: *Tree, panel: PanelId) void {
        const g = t.groupOf(panel) orelse return;
        for (t.nodes[g].tabs[0..t.nodes[g].tab_count], 0..) |p, i| if (p == panel) {
            t.nodes[g].active_tab = @intCast(i);
        };
    }

    /// Sets the weights of the split holding `panel`'s group (`levels`
    /// splits up), proportional to `weights`.
    pub fn setWeights(t: *Tree, panel: PanelId, weights: []const f32, levels: u8) bool {
        var child = t.groupOf(panel) orelse return false;
        var level: u8 = 0;
        while (true) : (level += 1) {
            const parent = t.parentOf(child) orelse return false;
            if (level == levels) {
                const node = &t.nodes[parent.node];
                if (node.child_count != weights.len) return false;
                var sum: f32 = 0;
                for (weights) |w| sum += w;
                for (weights, 0..) |w, i| node.weights[i] = w / sum;
                return true;
            }
            child = parent.node;
        }
    }

    pub const layout = layout_mod.layout;
    pub const dropTarget = layout_mod.dropTarget;
    pub const adjustDivider = layout_mod.adjustDivider;
    pub const nodeMin = layout_mod.nodeMin;
    /// Resizing by the app (`dock_resize.zig`).
    pub const groupSize = resize.groupSize;
    pub const groupRect = resize.groupRect;
    pub const adjustDividerFor = resize.adjustDividerFor;
    pub const setGroupExtent = resize.setGroupExtent;
};

pub const Layout = layout_mod.Layout;
pub const GroupItem = layout_mod.GroupItem;
pub const DividerItem = layout_mod.DividerItem;

pub fn validGroup(t: *const Tree, index: u8) bool {
    return index < t.node_count and t.nodes[index].kind == .group;
}

fn firstGroup(t: *const Tree, index: u8) u8 {
    const node = t.nodes[index];
    return if (node.kind == .group) index else firstGroup(t, node.children[0]);
}

fn validateNode(t: *const Tree, index: u8, visited: *[max_nodes]bool, panels: *[256]bool) bool {
    if (index >= t.node_count or visited[index]) return false;
    visited[index] = true;
    const node = t.nodes[index];
    switch (node.kind) {
        .group => {
            if (node.tab_count > max_tabs) return false;
            if ((node.tab_count == 0 and node.active_tab != 0) or (node.tab_count > 0 and node.active_tab >= node.tab_count)) return false;
            for (node.tabs[0..node.tab_count]) |panel| {
                if (panels[panel]) return false;
                panels[panel] = true;
            }
        },
        .split => {
            if (node.child_count < 2 or node.child_count > max_children) return false;
            var sum: f32 = 0;
            for (0..node.child_count) |i| {
                const w = node.weights[i];
                if (!std.math.isFinite(w) or w < 0 or node.children[i] >= t.node_count) return false;
                sum += w;
            }
            if (@abs(sum - 1) > 0.001) return false;
            for (node.children[0..node.child_count]) |child| if (!validateNode(t, child, visited, panels)) return false;
        },
    }
    return true;
}

fn appendTab(t: *Tree, g: u8, panel: PanelId) bool {
    const node = &t.nodes[g];
    if (node.kind != .group or node.tab_count >= max_tabs or t.contains(panel)) return false;
    node.tabs[node.tab_count] = panel;
    node.active_tab = node.tab_count;
    node.tab_count += 1;
    return true;
}

fn removeTracked(t: *Tree, panel: PanelId, tracked: *?u8) bool {
    const g = t.groupOf(panel) orelse return false;
    var node = &t.nodes[g];
    var at: usize = 0;
    while (node.tabs[at] != panel) : (at += 1) {}
    var i = at;
    while (i + 1 < node.tab_count) : (i += 1) node.tabs[i] = node.tabs[i + 1];
    node.tab_count -= 1;
    if (node.tab_count > 0) {
        if (node.active_tab > at) node.active_tab -= 1 else if (node.active_tab >= node.tab_count) node.active_tab = node.tab_count - 1;
        return true;
    }
    node.active_tab = 0;
    if (g == t.root) return true;
    removeEmptyGroup(t, g, tracked);
    return true;
}

fn removeEmptyGroup(t: *Tree, g: u8, tracked: *?u8) void {
    const parent = t.parentOf(g).?;
    var sp = &t.nodes[parent.node];
    var i: usize = parent.slot;
    while (i + 1 < sp.child_count) : (i += 1) {
        sp.children[i] = sp.children[i + 1];
        sp.weights[i] = sp.weights[i + 1];
    }
    sp.child_count -= 1;
    deleteNode(t, g, tracked);
    var pi = parent.node;
    if (g < pi) pi -= 1;
    sp = &t.nodes[pi];
    if (sp.child_count >= 2) {
        normalize(sp);
        return;
    }
    const survivor = sp.children[0];
    if (pi == t.root) {
        t.root = survivor;
    } else {
        const grand = t.parentOf(pi).?;
        t.nodes[grand.node].children[grand.slot] = survivor;
    }
    var s = survivor;
    deleteNode(t, pi, tracked);
    if (s > pi) s -= 1;
    // A survivor split along its new parent's axis merges into it.
    mergeInto(t, s, tracked);
}

/// A split whose parent splits the same way gives its children to the
/// parent, weighted by its own share: dropping a panel out never leaves a
/// row inside a row.
fn mergeInto(t: *Tree, index: u8, tracked: *?u8) void {
    if (t.nodes[index].kind != .split) return;
    const parent = t.parentOf(index) orelse return;
    const p = &t.nodes[parent.node];
    const n = t.nodes[index];
    if (p.axis != n.axis or p.child_count + n.child_count - 1 > max_children) return;
    const share = p.weights[parent.slot];
    var kids: [max_children]u8 = undefined;
    var ws: [max_children]f32 = undefined;
    var k: usize = 0;
    for (0..p.child_count) |i| {
        if (i == parent.slot) {
            for (0..n.child_count) |j| {
                kids[k] = n.children[j];
                ws[k] = n.weights[j] * share;
                k += 1;
            }
        } else {
            kids[k] = p.children[i];
            ws[k] = p.weights[i];
            k += 1;
        }
    }
    p.child_count = @intCast(k);
    @memcpy(p.children[0..k], kids[0..k]);
    @memcpy(p.weights[0..k], ws[0..k]);
    deleteNode(t, index, tracked);
}

fn deleteNode(t: *Tree, index: u8, tracked: *?u8) void {
    var i: usize = index;
    while (i + 1 < t.node_count) : (i += 1) t.nodes[i] = t.nodes[i + 1];
    t.node_count -= 1;
    if (t.root > index) t.root -= 1;
    for (t.nodes[0..t.node_count]) |*node| {
        if (node.kind != .split) continue;
        for (node.children[0..node.child_count]) |*child| if (child.* > index) {
            child.* -= 1;
        };
    }
    if (tracked.*) |v| tracked.* = if (v == index) null else if (v > index) v - 1 else v;
}

pub fn normalize(sp: *Node) void {
    var sum: f32 = 0;
    for (sp.weights[0..sp.child_count]) |w| sum += @max(w, 0);
    if (sum <= 0) {
        const fair = 1 / @as(f32, @floatFromInt(sp.child_count));
        for (sp.weights[0..sp.child_count]) |*w| w.* = fair;
    } else {
        for (sp.weights[0..sp.child_count]) |*w| w.* = @max(w.*, 0) / sum;
    }
}

fn splitPanel(t: *Tree, target: u8, panel: PanelId, zone: DropZone) bool {
    const axis: Axis = if (zone == .left or zone == .right) .row else .column;
    const before = zone == .left or zone == .top;
    const parent = t.parentOf(target);
    if (parent != null and t.nodes[parent.?.node].axis == axis) {
        var sp = &t.nodes[parent.?.node];
        if (sp.child_count >= max_children or t.node_count >= max_nodes) return false;
        const g = t.node_count;
        t.nodes[g] = Node.group(panel);
        t.node_count += 1;
        const slot: usize = parent.?.slot + @intFromBool(!before);
        var i: usize = sp.child_count;
        while (i > slot) : (i -= 1) {
            sp.children[i] = sp.children[i - 1];
            sp.weights[i] = sp.weights[i - 1];
        }
        const target_slot: usize = parent.?.slot + @intFromBool(before);
        const share = sp.weights[target_slot] * 0.5;
        sp.weights[target_slot] = share;
        sp.children[slot] = g;
        sp.weights[slot] = share;
        sp.child_count += 1;
        normalize(sp);
        return true;
    }
    if (t.node_count + 2 > max_nodes) return false;
    const g = t.node_count;
    const s = t.node_count + 1;
    t.nodes[g] = Node.group(panel);
    t.nodes[s] = if (before) Node.split(axis, &.{ g, target }, &.{ 0.5, 0.5 }) else Node.split(axis, &.{ target, g }, &.{ 0.5, 0.5 });
    t.node_count += 2;
    if (parent) |p| t.nodes[p.node].children[p.slot] = s else t.root = s;
    return true;
}

test "split, tab, move and remove keep the tree valid" {
    const catalog = [_]PanelInfo{ .{ .title = "A" }, .{ .title = "B" }, .{ .title = "C" }, .{ .title = "D" } };
    var t = Tree.init(&catalog);
    try std.testing.expect(t.insert(0, null));
    try std.testing.expect(t.split(1, 0, .right));
    try std.testing.expect(t.split(2, 1, .right));
    try std.testing.expect(t.tabBehind(3, 2));
    try std.testing.expect(t.validate());
    try std.testing.expect(t.isShown(2) and !t.isShown(3));
    // One row of three: a split beside a row member joins the row.
    try std.testing.expectEqual(@as(u8, 3), t.nodes[t.root].child_count);
    try std.testing.expect(t.move(3, .{ .group = t.groupOf(0).?, .zone = .bottom }));
    try std.testing.expect(t.validate());
    try std.testing.expect(t.move(1, .{ .group = t.groupOf(0).?, .zone = .center }));
    try std.testing.expect(t.validate());
    try std.testing.expectEqual(t.groupOf(0), t.groupOf(1));
    try std.testing.expect(t.remove(3));
    try std.testing.expect(t.remove(2));
    try std.testing.expect(t.validate());
    try std.testing.expectEqual(@as(usize, 2), t.panelCount());
    try std.testing.expectEqual(@as(u8, 1), t.node_count);
}

test "a lone tab can't be dropped beside itself" {
    const catalog = [_]PanelInfo{ .{ .title = "A" }, .{ .title = "B" } };
    var t = Tree.init(&catalog);
    try std.testing.expect(t.insert(0, null));
    try std.testing.expect(t.split(1, 0, .right));
    try std.testing.expect(!t.move(1, .{ .group = t.groupOf(1).?, .zone = .left }));
    try std.testing.expect(t.move(1, .{ .group = t.groupOf(0).?, .zone = .left }));
    try std.testing.expect(t.validate());
}
