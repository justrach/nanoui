//! Layers and fixed boxes: a box on a higher layer is drawn after the page
//! (over boxes that come later in the tree) and isn't clipped by its
//! parents; a fixed box is placed from the window's corner, whatever
//! scrolls; and clicks reach the topmost layer first.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Scene = struct {
    clicked_overlay: u32 = 0,
    clicked_page: u32 = 0,
    fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().bg(.white);
        defer root.end();
        {
            // A small clipping box holding an overlay that pokes out of it.
            const small = ui.div(c).w(40).h(40).clip().bg(.hex(0x0000ff));
            defer small.end();
            const over = ui.div(c).fixed().offset(20, 20).w(60).h(60).bg(.hex(0xff0000)).layer(1).control();
            defer over.end();
            if (over.clicked()) s.clicked_overlay += 1;
        }
        // Later in the tree, under the overlay's place.
        const page = ui.div(c).w(100).h(100).bg(.hex(0x00ff00)).control();
        defer page.end();
        if (page.clicked()) s.clicked_page += 1;
    }
};

fn at(px: anytype, x: usize, y: usize) [3]u8 {
    const i = (y * px.width + x) * 4;
    return .{ px.bytes[i + 2], px.bytes[i + 1], px.bytes[i] };
}

test "a layered, fixed box is drawn over the page, unclipped, and takes the click" {
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 120, .height = 160, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    // At (70, 70): past the blue box's clip, over the green box drawn later.
    try testing.expectEqual([3]u8{ 255, 0, 0 }, at(px, 70, 70));
    // Below the overlay, the green page.
    try testing.expectEqual([3]u8{ 0, 255, 0 }, at(px, 50, 120));
    t.click(70, 70);
    t.settle(0.1);
    try testing.expectEqual(@as(u32, 1), s.clicked_overlay);
    try testing.expectEqual(@as(u32, 0), s.clicked_page);
}

test "repainting scrolled, transformed layers borrows an unchanged tree" {
    const View = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            ui.scroll(c, .{ .width = .fill, .height = .fill });
            defer ui.end(c);
            for (0..20) |i| {
                _ = c.open(.{ .width = .fill, .height = .{ .px = 28 }, .scale = 0.9, .opacity = 0.7, .group = true }, null);
                ui.textf(c, .{}, "Row {d}", .{i});
                if (i == 3) {
                    const overlay = ui.div(c).fixed().offset(10, 10).w(50).h(20).bg(.white).layer(1);
                    ui.text(c, "Overlay", .{});
                    overlay.end();
                }
                c.end();
            }
        }
    };
    var s: View = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, View.view), .{ .width = 160, .height = 120 });
    defer t.deinit();
    t.scroll(80, 60, -84);
    const nodes = try testing.allocator.dupe(@import("context.zig").Node, t.ctx.nodes.items);
    defer testing.allocator.free(nodes);
    const items = try testing.allocator.dupe(@import("gpu.zig").Instance, t.instances.items);
    defer testing.allocator.free(items);
    // Atlas population and deferred layers may allocate during paint, but
    // source rects, styles and text must not be rewritten or transformed twice.
    t.ctx.next_hits.clearRetainingCapacity();
    @import("selection.zig").beginPaint(&t.ctx);
    @import("paint.zig").paint(&t.ctx, &t.instances);
    try testing.expectEqualDeep(nodes, t.ctx.nodes.items);
    try testing.expectEqualDeep(items, t.instances.items);
}
