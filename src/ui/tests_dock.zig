//! The dock drawn and driven: a divider dragged resizes its split, a tab
//! clicked shows its panel, and a tab dragged onto another group's edge
//! docks there.
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
    contents: [3]u32 = @splat(0),

    const Hooks = struct {
        pub fn tab(_: *Scene, c: *ui.Context, p: ui.dock.PanelId, t: ui.dock.TabState) void {
            ui.text(c, catalog[p].title, .{ .size = 12, .color = if (t.active) .white else .hex(0x888888) });
        }
        pub fn content(s: *Scene, c: *ui.Context, p: ui.dock.PanelId, _: ui.Rect) void {
            s.contents[p] += 1;
            ui.text(c, c.print("{s} body", .{catalog[p].title}), .{ .size = 12 });
        }
    };

    fn view(s: *Scene, c: *ui.Context) void {
        ui.dock.view(c, &s.tree, &s.st, .{ .background = .black, .header = .hex(0x222222) }, s, Hooks);
    }
};

test "dock: dividers resize, tabs switch and dock elsewhere" {
    var s: Scene = .{};
    try testing.expect(s.tree.insert(0, null));
    try testing.expect(s.tree.split(1, 0, .right));
    try testing.expect(s.tree.tabBehind(2, 1));
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 400, .height = 300, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    t.frame();
    try testing.expect(t.hasText("Alpha body"));
    try testing.expect(t.hasText("Beta body"));
    try testing.expect(!t.hasText("Gamma body"));

    // The divider sits near x = 200; drag it to 260.
    const before = s.st.layout.group(s.tree.groupOf(0).?).?.rect.w;
    const d = s.st.layout.dividers[0].rect;
    t.drag(d.x + d.w / 2, 150, d.x + d.w / 2 + 60, 150);
    t.frame();
    const after = s.st.layout.group(s.tree.groupOf(0).?).?.rect.w;
    try testing.expectApproxEqAbs(before + 60, after, 1.5);

    // A click on Gamma's tab shows it.
    try t.clickText("Gamma");
    t.frame();
    try testing.expect(t.hasText("Gamma body"));

    // Drag Gamma's tab onto Alpha's bottom edge: a new group under Alpha.
    const tab = t.findText("Gamma").?;
    const alpha = s.st.layout.group(s.tree.groupOf(0).?).?.rect;
    t.drag(tab.x + 4, tab.y + 4, alpha.x + alpha.w / 2, alpha.y + alpha.h - 10);
    t.frame();
    try testing.expect(s.tree.validate());
    try testing.expect(s.tree.groupOf(2).? != s.tree.groupOf(1).?);
    try testing.expectEqual(@as(u8, 3), s.st.layout.group_count);
    try testing.expect(t.hasText("Gamma body") and t.hasText("Beta body") and t.hasText("Alpha body"));
}

fn glowView(s: *Scene, c: *ui.Context) void {
    ui.dock.view(c, &s.tree, &s.st, .{ .background = .black, .header = .hex(0x222222), .glow = .hex(0xff3030) }, s, Scene.Hooks);
}

fn brightness(px: anytype, x: f32, y: f32) u32 {
    const i = (@as(usize, @intFromFloat(y)) * px.width + @as(usize, @intFromFloat(x))) * 4;
    return @as(u32, px.bytes[i]) + px.bytes[i + 1] + px.bytes[i + 2];
}

test "dock: a divider under the pointer glows there, fading up and out" {
    var s: Scene = .{};
    try testing.expect(s.tree.insert(0, null));
    try testing.expect(s.tree.split(1, 0, .right));
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, glowView), .{ .width = 400, .height = 300, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    try testing.expectEqual(@as(f32, 0), s.st.glow);

    const d = s.st.layout.dividers[0].rect;
    const x = d.x + d.w / 2;
    t.moveTo(x, 80);
    // Partway up after a few frames, then lit.
    t.advance(0.05);
    try testing.expect(s.st.glow > 0.1 and s.st.glow < 0.9);
    t.settle(1);
    try testing.expectEqual(@as(f32, 1), s.st.glow);
    try testing.expectApproxEqAbs(@as(f32, 80), s.st.glow_along, 0.5);

    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    // Brightest at the pointer, dark far along the gutter.
    // Brightest at the pointer, fading along the gutter, but lit its whole length.
    try testing.expect(brightness(px, x, 80) > brightness(px, x, 200) + 120);
    try testing.expect(brightness(px, x, 290) > 25);

    // The pointer leaves: the glow goes out.
    t.moveTo(100, 150);
    t.settle(1);
    try testing.expectEqual(@as(f32, 0), s.st.glow);
}
