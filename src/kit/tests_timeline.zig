//! Synthetic, offscreen timeline fixtures; no window or system clipboard.
const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const kit = @import("kit.zig");
const Node = @import("../ui/context.zig").Node;
const Pixels = @import("../ui/gpu.zig").Pixels;

const Fixture = struct {
    use_timeline: bool = true,
    rows: [4]u32 = undefined,
    const options = [_]kit.TimelineItemOptions{
        .{ .first = true },
        .{ .height = 72, .color = .hex(0x269f70), .selected = true },
        .{ .height = 40, .last = true },
        .{ .height = 32, .first = true, .last = true, .color = .hex(0xc27821) },
    };
    const labels = [_][]const u8{ "Package prepared", "In transit", "Ready for collection", "A separate event" };

    fn view(a: *Fixture, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(16).bg(c.theme.background);
        defer root.end();
        for (options, labels, 0..) |opts, label, i| {
            ui.key(c, label);
            const row = if (a.use_timeline) kit.timelineItem(c, opts) else ui.div(c).row().wFull().h(opts.height).itemsCenter();
            a.rows[i] = row.index;
            defer row.end();
            const body = ui.div(c).column().grow().gap(3);
            defer body.end();
            ui.text(c, label, .{ .size = 13 });
            if (i == 1) ui.text(c, "Expected this afternoon", .{ .size = 11, .color = c.theme.muted });
        }
    }
};

fn near(expected: f32, actual: f32) !void {
    try testing.expectApproxEqAbs(expected, actual, 0.01);
}

fn pixel(p: Pixels, scale: f32, x: f32, y: f32) [4]u8 {
    const ix: usize = @intFromFloat(x * scale);
    const iy: usize = @intFromFloat(y * scale);
    return p.bytes[(iy * p.width + ix) * 4 ..][0..4].*;
}

fn colorAt(p: Pixels, scale: f32, x: f32, y: f32, col: ui.Color) !void {
    const bgra = pixel(p, scale, x, y);
    const expected = [_]f32{ col.b, col.g, col.r, col.a };
    for (bgra, expected) |actual, value| {
        try testing.expectApproxEqAbs(value, @as(f32, @floatFromInt(actual)) / 255, 0.015);
    }
}

fn over(fg: ui.Color, bg: ui.Color) ui.Color {
    return .{ .r = fg.r * fg.a + bg.r * (1 - fg.a), .g = fg.g * fg.a + bg.g * (1 - fg.a), .b = fg.b * fg.a + bg.b * (1 - fg.a) };
}

fn decorative(n: Node) !void {
    try testing.expect(!n.interactive);
    try testing.expect(!n.style.clip and !n.style.scroll and !n.style.wheel and !n.style.control);
}

test "kit timeline: first, middle, last and single rails render in light and dark; idle stays quiet" {
    for ([_]bool{ false, true }) |dark| {
        var a: Fixture = .{};
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&a, Fixture.view), .{ .width = 400, .height = 240, .dark = dark });
        defer t.deinit();
        t.settle(0.5);
        const p = try t.render(testing.allocator);
        defer p.deinit(testing.allocator);
        var y: f32 = 16;
        for (a.rows, Fixture.options, Fixture.labels) |index, opts, label| {
            const row = t.ctx.node(index).*;
            const rail = t.ctx.node(row.first_child).*;
            const half = (opts.height - 8) / 2;
            const col = opts.color orelse kit.tokens(&t.ctx).primary;
            const bg = if (opts.selected) over(col.alpha(0.08), t.theme.background) else t.theme.background;
            try near(16, row.rect.x);
            try near(y, row.rect.y);
            try near(368, row.rect.w);
            try near(opts.height, row.rect.h);
            try near(24, rail.rect.w);
            try near(opts.height, rail.rect.h);
            try testing.expectEqual(1 + @as(u32, @intFromBool(!opts.first)) + @as(u32, @intFromBool(!opts.last)), rail.child_count);
            try decorative(row);
            try decorative(rail);
            var child = rail.first_child;
            while (child != @import("../ui/context.zig").none) {
                const n = t.ctx.node(child).*;
                try decorative(n);
                try testing.expect(n.rect.y >= y and n.rect.y + n.rect.h <= y + opts.height);
                try testing.expect(n.rect.x >= rail.rect.x and n.rect.x + n.rect.w <= rail.rect.x + rail.rect.w);
                child = n.next;
            }
            const text = t.findText(label).?;
            try near(48, text.x);
            try testing.expect(text.y >= y and text.y + text.h <= y + opts.height);
            // Dot centers are opaque, connectors are tinted, omitted ends stay clear.
            try colorAt(p, t.scale, 28, y + half + 4, col);
            try colorAt(p, t.scale, 27.5, y + 2, if (opts.first) bg else over(col.alpha(0.35), bg));
            try colorAt(p, t.scale, 27.5, y + opts.height - 2, if (opts.last) bg else over(col.alpha(0.35), bg));
            // Away from the rail, selection is a tint, not an opaque fill.
            try colorAt(p, t.scale, 380, y + 2, bg);
            y += opts.height;
        }
        try testing.expect(!t.ctx.animating);
        t.moveTo(28, 44);
        t.advance(1);
        try testing.expect(!t.ctx.animating and !t.ctx.changed);
        try testing.expect(!t.shortcut(.{ .key = ui.Shortcut.escape }));
        var path_buf: [256]u8 = undefined;
        try t.screenshot(try @import("../temp_path.zig").tempPath(&path_buf, if (dark) "nanoui-kit-timeline-dark.png" else "nanoui-kit-timeline-light.png"));
        // The same synthetic native content without the new decoration.
        a.use_timeline = false;
        t.frame();
        try t.screenshot(try @import("../temp_path.zig").tempPath(&path_buf, if (dark) "nanoui-kit-timeline-before-dark.png" else "nanoui-kit-timeline-before-light.png"));
    }
}

test "kit timeline: short heights keep the dot and connectors inside the rail" {
    const Short = struct {
        height: f32 = 0,
        row: u32 = 0,
        fn view(a: *@This(), c: *ui.Context) void {
            const row = kit.timelineItem(c, .{ .height = a.height });
            a.row = row.index;
            row.end();
        }
    };
    var a: Short = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, Short.view), .{});
    defer t.deinit();
    for ([_]f32{ -10, 0, 8, 9, 120 }) |height| {
        a.height = height;
        t.frame();
        const row = t.ctx.node(a.row).*;
        const rail = t.ctx.node(row.first_child).*;
        try near(@max(8, height), row.rect.h);
        var child = rail.first_child;
        while (child != @import("../ui/context.zig").none) {
            const n = t.ctx.node(child).*;
            try testing.expect(n.rect.h > 0 and n.rect.y >= rail.rect.y);
            try testing.expect(n.rect.y + n.rect.h <= rail.rect.y + rail.rect.h);
            child = n.next;
        }
        try testing.expect(!t.ctx.animating);
    }
}

test "kit timeline: decorations pass pointer input through; native content keeps clicks and keyboard" {
    const Controls = struct {
        clicks: u32 = 0,
        rail_clicks: u32 = 0,
        buffer: ui.TextBuffer = .{},
        fn view(a: *@This(), c: *ui.Context) void {
            const parent = ui.div(c).column().sizeFull().p(16);
            defer parent.end();
            if (parent.clicked()) a.rail_clicks += 1;
            const row = kit.timelineItem(c, .{ .first = true, .last = true, .selected = true });
            defer row.end();
            if (kit.button(c, "Inspect", .{}).clicked) a.clicks += 1;
            _ = ui.textField(c, &a.buffer, .{ .placeholder = "Add a note", .width = .{ .px = 150 } });
            // Prove the row does not clip native content extending outside its height.
            const overflow = ui.div(c).absolute().offset(32, 66).size(20, 12).bg(.hex(0xd05070));
            overflow.end();
        }
    };
    var a: Controls = .{};
    defer a.buffer.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, Controls.view), .{ .width = 400, .height = 160 });
    defer t.deinit();
    t.settle(0.5);
    const p = try t.render(testing.allocator);
    defer p.deinit(testing.allocator);
    try colorAt(p, t.scale, 52, 86, .hex(0xd05070));
    t.click(28, 44);
    try testing.expectEqual(@as(u32, 1), a.rail_clicks);
    try testing.expectEqual(@as(u32, 0), a.clicks);
    try t.clickText("Inspect");
    try testing.expectEqual(@as(u32, 1), a.clicks);
    try t.clickText("Add a note");
    t.typeText("Synthetic note");
    try testing.expectEqualStrings("Synthetic note", a.buffer.text());
    t.textOps(&.{.{ .command = .delete_backward }});
    try testing.expectEqualStrings("Synthetic not", a.buffer.text());
}
