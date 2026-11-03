//! What a box's style does to how it is drawn: text cut to fit with an
//! ellipsis, text faded toward its edge, a subtree scaled around a point,
//! and a shadow knocked out of its box.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");

const title = "A very long tab title that runs on far past its little pill!"; // 60 bytes

const Titles = struct {
    /// The title beside a fixed box (a pill's icon).
    beside: u32 = 0,
    fn view(s: *Titles, c: *ui.Context) void {
        ui.column(c, .{});
        defer ui.end(c);
        {
            ui.row(c, .{ .width = .{ .px = 100 } });
            defer ui.end(c);
            ui.text(c, title, .{ .size = 13, .truncate = .ellipsis });
        }
        {
            ui.row(c, .{ .width = .{ .px = 100 }, .gap = 4 });
            defer ui.end(c);
            _ = c.leaf(.{ .width = .{ .px = 20 }, .height = .{ .px = 16 } }, .none, null);
            s.beside = @intCast(c.nodes.items.len);
            ui.text(c, title, .{ .size = 13, .truncate = .ellipsis });
        }
        ui.text(c, "Short", .{ .size = 13, .truncate = .ellipsis });
    }
};

test "truncate ends with ellipsis and fits" {
    try testing.expectEqual(@as(usize, 60), title.len);
    var s: Titles = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Titles.view), .{});
    defer t.deinit();
    var cut: u32 = 0;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.endsWith(u8, tx.str, "…")) {
            cut += 1;
            try testing.expect(tx.str.len > "…".len and tx.str.len < title.len);
            try testing.expect(std.mem.startsWith(u8, title, tx.str[0 .. tx.str.len - "…".len]));
            try testing.expect(n.rect.w <= 100);
            try testing.expect(t.text.width(tx.str, tx.style) <= n.rect.w + 0.5);
        },
        else => {},
    };
    try testing.expectEqual(@as(u32, 2), cut);
    // Beside the fixed box, the row shrinks it to the room left.
    const b = t.ctx.node(s.beside);
    try testing.expectEqual(@as(f32, 24), b.rect.x);
    try testing.expect(b.rect.w <= 100 - 20 - 4 + 0.5);
    try testing.expect(std.mem.endsWith(u8, b.content.text.str, "…"));
    // What fits is left whole.
    try testing.expect(t.hasText("Short"));
}

const Faded = struct {
    fn view(_: *Faded, c: *ui.Context) void {
        const box = ui.div(c).w(50);
        defer box.end();
        ui.text(c, "MMMMMM", .{ .size = 14, .truncate = .fade, .fade_width = 40 });
    }
};

test "fade marks glyphs to fade at the box's right edge" {
    var s: Faded = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Faded.view), .{});
    defer t.deinit();
    var glyphs: std.ArrayList(gpu.Instance) = .empty;
    defer glyphs.deinit(testing.allocator);
    for (t.instances.items) |i| if (i.kind == gpu.Kind.text) try glyphs.append(testing.allocator, i);
    try testing.expect(glyphs.items.len > 0);
    for (glyphs.items) |g| {
        try testing.expect(g.border_width > 0);
        try testing.expectEqual(glyphs.items[0].radius, g.radius);
    }
}

const red: ui.Color = .{ .r = 1 };

const Scaled = struct {
    fn view(_: *Scaled, c: *ui.Context) void {
        _ = c.open(.{ .width = .{ .px = 200 }, .height = .{ .px = 100 }, .scale = 0.5 }, null);
        _ = c.leaf(.{ .width = .fill, .height = .fill, .background = red, .radius = 8, .border = red, .border_width = 2 }, .none, null);
        c.end();
    }
};

test "scale 0.5 halves child rect around center" {
    var s: Scaled = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scaled.view), .{});
    defer t.deinit();
    var found = false;
    for (t.instances.items) |i| if (i.color[0] == 1 and i.color[1] == 0) {
        found = true;
        try testing.expectEqual([4]f32{ 50, 25, 100, 50 }, i.rect);
        try testing.expectEqual(@as(f32, 4), i.radius);
        try testing.expectEqual(@as(f32, 1), i.border_width);
    };
    try testing.expect(found);
}

const Lifted = struct {
    fn view(_: *Lifted, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(40) });
        defer ui.end(c);
        _ = c.leaf(.{ .width = .{ .px = 80 }, .height = .{ .px = 60 }, .radius = 10, .shadow = .{ .color = .{ .a = 0.6 }, .blur = 12, .y = 4, .knockout = true } }, .none, null);
    }
};

fn px(p: gpu.Pixels, x: usize, y: usize) [4]u8 {
    return p.bytes[(y * p.width + x) * 4 ..][0..4].*;
}

test "knockout shadow is clear inside, visible 3 pt outside" {
    const gpa = testing.allocator;
    // The CPU renderer, one instance.
    const bytes = try gpa.alloc(u8, 120 * 120 * 4);
    defer gpa.free(bytes);
    const out: gpu.Pixels = .{ .bytes = bytes, .width = 120, .height = 120 };
    const white: ui.Color = .{ .r = 1, .g = 1, .b = 1 };
    raster.draw(out, &.{.{ .rect = .{ 15, 15, 30, 30 }, .color = .{ 0, 0, 0, 1 }, .radius = 6, .border_width = 3, .kind = gpu.Kind.shadow_out }}, .{ .pixels = &.{}, .size = 0 }, .{}, 2, white);
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, px(out, 60, 60));
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, px(out, 32, 60)); // 1 pt inside its edge
    try testing.expect(px(out, 24, 60)[0] < 235); // 3 pt outside

    // A box's knocked out shadow, as the Tester renders it (Metal on macOS).
    var s: Lifted = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Lifted.view), .{ .width = 200, .height = 160 });
    defer t.deinit();
    var kinds: u32 = 0;
    for (t.instances.items) |i| if (i.kind == gpu.Kind.shadow_out) {
        kinds += 1;
    };
    try testing.expectEqual(@as(u32, 1), kinds);
    const frame = try t.render(gpa);
    defer frame.deinit(gpa);
    const ground = px(frame, 2, 2);
    // The box is (40, 40, 80, 60), its shadow 4 pt lower: clear inside the
    // box (its top too), shaded 3 pt outside it.
    try testing.expectEqual(ground, px(frame, 160, 140));
    try testing.expectEqual(ground, px(frame, 160, 84));
    try testing.expect(px(frame, 74, 150)[1] + 8 < ground[1]);
}
