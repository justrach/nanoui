//! A tab dragged in from another window (`State.external_drag`): the
//! dock washes its landing zone and draws its ghost though the pointer
//! never pressed in this window, and `dropExternal` docks it there.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const catalog = [_]ui.dock.PanelInfo{
    .{ .title = "Alpha", .min_w = 60, .min_h = 60 },
    .{ .title = "Beta", .min_w = 60, .min_h = 60 },
    .{ .title = "Float", .min_w = 60, .min_h = 60 },
};

const style: ui.dock.Style = .{ .background = .black };

const Scene = struct {
    tree: ui.dock.Tree = ui.dock.Tree.init(&catalog),
    st: ui.dock.State = .{},
    ghosts: u32 = 0,

    const Hooks = struct {
        pub fn tab(_: *Scene, c: *ui.Context, p: ui.dock.PanelId, _: ui.dock.TabState) void {
            ui.text(c, catalog[p].title, .{ .size = 12 });
        }
        pub fn content(_: *Scene, c: *ui.Context, p: ui.dock.PanelId, _: ui.Rect) void {
            ui.text(c, c.print("{s} body", .{catalog[p].title}), .{ .size = 12 });
        }
        pub fn ghost(s: *Scene, c: *ui.Context, p: ui.dock.PanelId, _: ui.Rect) void {
            s.ghosts += 1;
            ui.text(c, c.print("{s} ghost", .{catalog[p].title}), .{ .size = 12 });
        }
    };

    fn view(s: *Scene, c: *ui.Context) void {
        ui.dock.view(c, &s.tree, &s.st, style, s, Hooks);
    }
};

/// The drop wash's box in the last frame, if one was drawn.
fn wash(t: *ui.Tester) ?ui.Rect {
    for (t.ctx.nodes.items) |n| {
        const bg = n.style.background orelse continue;
        if (!std.meta.eql(bg, style.drop)) continue;
        const b = n.style.border orelse continue;
        if (std.meta.eql(b, style.drop_border)) return t.ctx.rects.get(n.id);
    }
    return null;
}

test "dock: an external drag washes the zone under it and drops there" {
    var s: Scene = .{};
    try testing.expect(s.tree.insert(0, null));
    try testing.expect(s.tree.split(1, 0, .right));
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 400, .height = 300, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    try testing.expect(wash(&t) == null);

    // Near Beta's right edge, as another window's drag maps there.
    const beta = s.st.layout.group(s.tree.groupOf(1).?).?;
    const at: ui.Point = .{ .x = beta.rect.x + beta.rect.w - 10, .y = beta.rect.y + beta.rect.h / 2 };
    s.st.external_drag = .{ .panel = 2, .point = at };
    t.frame();
    const w = wash(&t) orelse return error.NoOverlay;
    // The right half of Beta's content.
    try testing.expect(w.x > beta.rect.x + beta.rect.w / 2 - 6);
    try testing.expect(s.ghosts > 0 and t.hasText("Float ghost"));
    try testing.expectEqual(ui.dock.DropZone.right, ui.dock.externalTarget(&s.tree, &s.st).?.zone);

    // Released: the panel (not in the tree) docks right of Beta.
    const landed = ui.dock.dropExternal(&s.tree, &s.st) orelse return error.NoDrop;
    try testing.expectEqual(ui.dock.DropZone.right, landed.zone);
    try testing.expect(s.st.external_drag == null);
    try testing.expectEqual(@as(u32, 1), s.st.moved);
    try testing.expect(s.tree.contains(2) and s.tree.validate());
    t.frame();
    try testing.expect(wash(&t) == null);
    try testing.expect(t.hasText("Float body"));
    const float = s.st.layout.group(s.tree.groupOf(2).?).?;
    try testing.expect(float.rect.x > beta.rect.x);

    // Off every group: no drop, and the tree stays.
    const before = s.tree;
    s.st.external_drag = .{ .panel = 0, .point = .{ .x = -50, .y = -50 } };
    t.frame();
    try testing.expect(wash(&t) == null);
    try testing.expect(ui.dock.dropExternal(&s.tree, &s.st) == null);
    try testing.expect(std.meta.eql(before.nodes, s.tree.nodes));
}
