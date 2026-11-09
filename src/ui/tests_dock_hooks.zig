//! The dock's hooks and counters: a tab drags only past the threshold
//! (any direction), a divider drag counts once as `resized`, a tab let go
//! off the dock goes to `dropOutside`, one group lays out alone (`solo`),
//! the app may draw the dividers, and VoiceOver sees tabs and splitters.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const catalog = [_]ui.dock.PanelInfo{
    .{ .title = "Alpha", .min_w = 60, .min_h = 60 },
    .{ .title = "Beta", .min_w = 60, .min_h = 60 },
    .{ .title = "Gamma", .min_w = 60, .min_h = 60 },
};

const Scene = struct {
    tree: ui.dock.Tree = ui.dock.Tree.init(&catalog),
    st: ui.dock.State = .{},
    solo: ?ui.dock.PanelId = null,
    outside: ?struct { panel: ui.dock.PanelId, at: ui.Point } = null,
    dividers_drawn: u32 = 0,
    divider_hovered: bool = false,
    ghosts: u32 = 0,

    const Hooks = struct {
        pub fn tab(_: *Scene, c: *ui.Context, p: ui.dock.PanelId, _: ui.dock.TabState) void {
            ui.text(c, catalog[p].title, .{ .size = 12 });
        }
        pub fn content(_: *Scene, c: *ui.Context, p: ui.dock.PanelId, _: ui.Rect) void {
            ui.text(c, c.print("{s} body", .{catalog[p].title}), .{ .size = 12 });
        }
        pub fn dropOutside(s: *Scene, p: ui.dock.PanelId, at: ui.Point) void {
            s.outside = .{ .panel = p, .at = at };
        }
        pub fn ghost(s: *Scene, c: *ui.Context, p: ui.dock.PanelId, _: ui.Rect) void {
            s.ghosts += 1;
            ui.text(c, c.print("{s} ghost", .{catalog[p].title}), .{ .size = 12 });
        }
    };

    const DrawnHooks = struct {
        pub const tab = Hooks.tab;
        pub const content = Hooks.content;
        pub fn divider(s: *Scene, _: *ui.Context, _: ui.dock.DividerItem, hovered: bool, _: f32) void {
            s.dividers_drawn += 1;
            if (hovered) s.divider_hovered = true;
        }
    };

    fn view(s: *Scene, c: *ui.Context) void {
        ui.dock.view(c, &s.tree, &s.st, .{ .background = .black, .solo = s.solo }, s, Hooks);
    }

    fn drawnView(s: *Scene, c: *ui.Context) void {
        ui.dock.view(c, &s.tree, &s.st, .{ .background = .black }, s, DrawnHooks);
    }

    /// Alpha | Beta, Gamma tabbed behind Beta.
    fn three(s: *Scene) !void {
        try testing.expect(s.tree.insert(0, null));
        try testing.expect(s.tree.split(1, 0, .right));
        try testing.expect(s.tree.tabBehind(2, 1));
    }
};

fn start(t: *ui.Tester, s: *Scene, comptime view: anytype) !void {
    try t.init(testing.allocator, .init(s, view), .{ .width = 400, .height = 300, .scale = 1 });
    t.settle(0.1);
}

test "dock: a tab drags past 6 points in any direction, not before" {
    var s: Scene = .{};
    try s.three();
    var t: ui.Tester = undefined;
    try start(&t, &s, Scene.view);
    defer t.deinit();
    const tab = t.findText("Alpha").?;
    const x = tab.x + 4;
    const y = tab.y + 4;
    t.down(x, y);
    try testing.expect(s.st.press_panel != null);
    // 3,4: 5 points away (7 by the old sum of both axes): still a press.
    t.move(x + 3, y + 4);
    try testing.expect(!s.st.dragging);
    // 7 points straight across: a drag.
    t.move(x + 7, y);
    try testing.expect(s.st.dragging);
    try testing.expect(s.ghosts > 0);
    try testing.expect(t.hasText("Alpha ghost"));
    t.move(x, y);
    t.up();
    try testing.expect(!s.st.dragging and s.st.press_panel == null);
    try testing.expectEqual(@as(u32, 0), s.st.moved);
}

test "dock: a divider drag counts once as resized, a still press not at all" {
    var s: Scene = .{};
    try s.three();
    var t: ui.Tester = undefined;
    try start(&t, &s, Scene.view);
    defer t.deinit();
    const d = s.st.layout.dividers[0].rect;
    const x = d.x + d.w / 2;
    t.drag(x, 150, x + 40, 150);
    t.frame();
    try testing.expectEqual(@as(u32, 1), s.st.resized);
    // Pressed and let go where it was: the weights stay.
    const d2 = s.st.layout.dividers[0].rect;
    t.click(d2.x + d2.w / 2, 150);
    t.frame();
    try testing.expectEqual(@as(u32, 1), s.st.resized);
    t.drag(d2.x + d2.w / 2, 150, d2.x + d2.w / 2 - 30, 150);
    t.frame();
    try testing.expectEqual(@as(u32, 2), s.st.resized);
}

test "dock: a tab let go off the dock goes to dropOutside" {
    var s: Scene = .{};
    try s.three();
    var t: ui.Tester = undefined;
    try start(&t, &s, Scene.view);
    defer t.deinit();
    const before = s.tree;
    // Inside the dock, on no group (the gutter): nothing.
    const tab = t.findText("Beta").?;
    t.down(tab.x + 4, tab.y + 4);
    t.move(tab.x + 40, tab.y + 40);
    t.move(390, 330);
    t.up();
    t.frame();
    const o = s.outside orelse return error.NoDropOutside;
    try testing.expectEqual(@as(ui.dock.PanelId, 1), o.panel);
    try testing.expectApproxEqAbs(@as(f32, 330), o.at.y, 0.01);
    try testing.expectEqual(@as(u32, 0), s.st.moved);
    try testing.expect(std.meta.eql(before.nodes, s.tree.nodes));
}

test "dock: solo lays out one group with all its tabs, no dividers" {
    var s: Scene = .{};
    try s.three();
    s.solo = 2;
    var t: ui.Tester = undefined;
    try start(&t, &s, Scene.view);
    defer t.deinit();
    try testing.expectEqual(@as(u8, 1), s.st.layout.group_count);
    try testing.expectEqual(@as(u8, 0), s.st.layout.divider_count);
    try testing.expectEqual(@as(f32, 400), s.st.layout.groups[0].rect.w);
    try testing.expect(t.hasText("Beta") and t.hasText("Gamma") and !t.hasText("Alpha"));
    try testing.expect(t.hasText("Beta body"));
    s.solo = null;
    t.frame();
    try testing.expectEqual(@as(u8, 2), s.st.layout.group_count);
}

test "dock: the app draws the dividers, told which is hovered" {
    var s: Scene = .{};
    try s.three();
    var t: ui.Tester = undefined;
    try start(&t, &s, Scene.drawnView);
    defer t.deinit();
    try testing.expect(s.dividers_drawn > 0);
    try testing.expect(!s.divider_hovered);
    const d = s.st.layout.dividers[0].rect;
    t.moveTo(d.x + d.w / 2, 120);
    try testing.expect(s.divider_hovered);
}

test "dock: tabs, their strip and the dividers as VoiceOver has them" {
    var s: Scene = .{};
    try s.three();
    var t: ui.Tester = undefined;
    try start(&t, &s, Scene.view);
    defer t.deinit();
    var strips: u32 = 0;
    var tabs: u32 = 0;
    var selected: u32 = 0;
    var splitter: ?ui.A11yItem = null;
    for (t.ctx.a11y_items.items) |it| switch (it.role) {
        .group => if (std.mem.eql(u8, it.label, "Panel tabs")) {
            strips += 1;
        },
        .tab => {
            tabs += 1;
            if (it.selected) selected += 1;
        },
        .splitter => splitter = it,
        else => {},
    };
    try testing.expectEqual(@as(u32, 2), strips);
    try testing.expectEqual(@as(u32, 3), tabs);
    try testing.expectEqual(@as(u32, 2), selected);
    const sp = splitter orelse return error.NoSplitter;
    try testing.expect(sp.adjustable);
    // An increment nudges the divider and counts as a resize.
    const w = s.st.layout.groups[0].rect.w;
    t.ctx.a11yStep(sp.id, 1);
    t.frame();
    t.frame();
    try testing.expect(s.st.layout.groups[0].rect.w > w);
    try testing.expectEqual(@as(u32, 1), s.st.resized);
}
