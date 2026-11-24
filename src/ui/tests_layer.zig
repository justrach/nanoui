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

test "absolute().occlude() blocks clicks, hover and right-clicks without a hand cursor or implied a11y button" {
    const OccludePage = struct {
        bg_clicks: u32 = 0,
        bg_secondary: u32 = 0,
        bg_right: u32 = 0,
        bg_hovered: bool = false,
        in_clicks: u32 = 0,
        field: ui.TextBuffer = .{},

        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull().p(10).gap(8);
            defer root.end();
            _ = ui.textField(c, &s.field, .{ .placeholder = "BgField", .width = .{ .px = 200 } });
            const bg = ui.div(c).w(240).h(140).bg(.hex(0x00ff00));
            const bg_it = bg.interaction();
            s.bg_hovered = bg_it.hovered;
            if (bg_it.clicked) s.bg_clicks += 1;
            if (bg_it.secondary_clicked) s.bg_secondary += 1;
            if (bg_it.right_clicked) s.bg_right += 1;
            bg.end();

            const ov = ui.div(c).absolute().offset(10, 50).w(180).h(120).p(10).gap(8).bg(.white).occlude();
            defer ov.end();
            ui.text(c, "Overlay title", .{});
            if (ui.button(c, "Inside", .{}).clicked) s.in_clicks += 1;

            const banner = ui.div(c).absolute().offset(210, 50).w(120).h(40).p(8).bg(.white).occlude();
            ui.text(c, "Static banner", .{});
            banner.end();
        }
    };
    var s: OccludePage = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, OccludePage.view), .{ .width = 400, .height = 240, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);

    // Empty overlay space blocks hover and keeps the arrow cursor.
    t.moveTo(150, 140);
    try testing.expect(!s.bg_hovered);
    try testing.expect(!t.ctx.cursor_hand);

    t.click(150, 140);
    try testing.expectEqual(@as(u32, 0), s.bg_clicks);
    try testing.expectEqual(@as(u32, 0), s.in_clicks);
    try testing.expect(!t.ctx.cursor_hand);

    t.secondaryClick(150, 140);
    try testing.expectEqual(@as(u32, 0), s.bg_secondary);

    // Left-clicking empty overlay space blurs focused fields; right-clicks do not.
    try t.clickText("BgField");
    try testing.expect(t.ctx.focus != 0);
    t.secondaryClick(150, 140);
    try testing.expect(t.ctx.focus != 0);
    t.rightClick(150, 140);
    try testing.expect(t.ctx.focus != 0);
    try testing.expectEqual(@as(u32, 0), s.bg_secondary);
    try testing.expectEqual(@as(u32, 0), s.bg_right);
    t.click(150, 140);
    try testing.expectEqual(@as(u64, 0), t.ctx.focus);

    // Interactive children inside the overlay still work normally.
    try t.clickText("Inside");
    try testing.expectEqual(@as(u32, 1), s.in_clicks);
    try testing.expectEqual(@as(u32, 0), s.bg_clicks);
    try testing.expect(t.ctx.cursor_hand);

    // An occluding box with static text does not become an implied a11y button.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var els: std.ArrayList(ui.access.Element) = .empty;
    try ui.access.tree(&t.ctx, arena.allocator(), &els);
    var saw_banner_static = false;
    for (els.items) |el| {
        if (std.mem.eql(u8, el.label, "Static banner")) {
            try testing.expectEqual(ui.access.Role.static_text, el.role);
            saw_banner_static = true;
        }
        if (el.role == .button) {
            try testing.expect(!std.mem.eql(u8, el.label, "Static banner"));
            try testing.expect(!std.mem.eql(u8, el.label, "Overlay title"));
        }
    }
    try testing.expect(saw_banner_static);
}

test "layer(1).occlude() declared before a scrolling, selectable page blocks clicks, selection, scroll and scrollbars" {
    const ScrollPage = struct {
        inner_scroll_id: u64 = 0,
        page_y_id: u64 = 0,
        page_x_id: u64 = 0,
        bg_clicks: u32 = 0,
        below_clicks: u32 = 0,

        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull();
            defer root.end();

            // Declared BEFORE the page in tree order, painted above via layer(1).
            const ov = ui.div(c).fixed().offset(10, 10).w(230).h(110).layer(1).column().bg(.white).occlude();
            {
                ui.key(c, "inner-scroll");
                const inner = ui.div(c).column().wFull().h(50).scrollY();
                s.inner_scroll_id = inner.id();
                for (0..10) |i| ui.textf(c, .{}, "Inner {d}", .{i});
                inner.end();
            }
            ui.text(c, "Panel body", .{});
            ov.end();

            ui.key(c, "page-y");
            const page = ui.div(c).column().sizeFull().scrollY();
            defer page.end();
            s.page_y_id = page.id();
            {
                ui.key(c, "page-x");
                const hx = c.open(.{ .direction = .row, .scroll_x = true, .width = .fill, .height = .{ .px = 140 }, .scroll_bar = false }, null);
                defer c.end();
                s.page_x_id = c.node(hx).id;
                {
                    const sel = ui.div(c).column().w(240).h(140).pt(70).px(20).gap(6);
                    c.node(sel.index).style.selectable = true;
                    defer sel.end();
                    ui.text(c, "Selectable line behind overlay", .{ .size = 13 });
                    const bg_btn = ui.div(c).w(140).h(26);
                    if (bg_btn.clicked()) s.bg_clicks += 1;
                    bg_btn.end();
                }
                for (0..4) |_| ui.div(c).w(100).h(140).end();
            }
            const below = ui.div(c).w(180).h(30).bg(.hex(0x00ff00));
            if (below.clicked()) s.below_clicks += 1;
            below.end();
            for (0..20) |_| ui.div(c).wFull().h(40).end();
        }
    };
    var s: ScrollPage = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, ScrollPage.view), .{ .width = 240, .height = 200, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);

    // Moving and dragging over the overlay above selectable text does not select it.
    t.moveTo(100, 78);
    try testing.expect(!t.ctx.cursor_text);
    try testing.expect(!t.ctx.pointerOverText());
    t.drag(30, 78, 140, 78);
    try testing.expect(t.ctx.selection.anchor == null);
    try testing.expectEqual(@as(usize, 0), t.ctx.selection.text.items.len);
    try testing.expect(!t.ctx.cursor_text);

    // Clicks over covered controls do not punch through.
    t.click(80, 104);
    try testing.expectEqual(@as(u32, 0), s.bg_clicks);

    // Vertical and horizontal scroll stop at the overlay without setting wheelAt.
    t.ctx.input.mouse = .{ .x = 100, .y = 100 };
    try testing.expect(!t.ctx.wheelAt());
    t.scroll(100, 100, -40);
    t.hscroll(100, 100, -40);
    try testing.expectEqual(@as(f32, 0), t.ctx.scroll.get(s.page_y_id) orelse 0);
    try testing.expectEqual(@as(f32, 0), t.ctx.scroll_x.get(s.page_x_id) orelse 0);

    // Scrolling inside the overlay's own scroller works without moving the page.
    t.scroll(100, 30, -30);
    try testing.expectEqual(@as(f32, 30), t.ctx.scroll.get(s.inner_scroll_id) orelse 0);
    try testing.expectEqual(@as(f32, 0), t.ctx.scroll.get(s.page_y_id) orelse 0);

    // Overlapping the background scrollbar track does not start a scrollbar drag.
    t.down(236, 90);
    try testing.expect(t.ctx.scrollbar_drag == null);
    t.move(236, 115);
    t.up();
    try testing.expectEqual(@as(f32, 0), t.ctx.scroll.get(s.page_y_id) orelse 0);

    // Outside the overlay, horizontal/vertical scroll and clicks still reach the page.
    t.hscroll(100, 130, -40);
    try testing.expectEqual(@as(f32, 40), t.ctx.scroll_x.get(s.page_x_id) orelse 0);
    t.click(80, 155);
    try testing.expectEqual(@as(u32, 1), s.below_clicks);
    t.scroll(100, 160, -40);
    try testing.expectEqual(@as(f32, 40), t.ctx.scroll.get(s.page_y_id) orelse 0);
}
