//! The CPU renderer's groups (opacity groups and the scroll fade's masked
//! ones, nested): drawn into kept layers, only within the region drawn,
//! and between bands of rows drawn on threads, they make the pixels of
//! drawing the frame whole on one thread.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const raster = @import("raster.zig");
const gpu = @import("gpu.zig");

const Scene = struct {
    x: f32 = 40,
    fn view(s: *Scene, c: *ui.Context) void {
        _ = c.open(.{ .width = .fill, .height = .fill, .background = .white }, null);
        defer c.end();
        for (0..3) |g| {
            const keys = [_][]const u8{ "g0", "g1", "g2" };
            const x = s.x + @as(f32, @floatFromInt(g)) * 110;
            _ = c.open(.{
                .absolute = true,
                .offset = .{ .x = x, .y = 30 },
                .width = .{ .px = 100 },
                .height = .{ .px = 120 },
                .opacity = 0.6,
                .group = true,
            }, keys[g]);
            defer c.end();
            const list: ui.Style = .{
                .width = .fill,
                .height = .fill,
                .scroll = true,
                .scroll_edge_fade = 24,
            };
            _ = c.open(list, "list");
            defer c.end();
            for (0..8) |k| {
                const rows = [_][]const u8{ "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7" };
                const shade = @as(f32, @floatFromInt(k)) * 0.125;
                _ = c.leaf(.{
                    .width = .fill,
                    .height = .{ .px = 30 },
                    .radius = 4,
                    .background = .{ .r = shade, .g = 0.3, .b = 1 - shade, .a = 1 },
                }, .none, rows[k]);
            }
        }
    }
};

fn render(t: *ui.Tester, out: gpu.Pixels, region: [4]usize) void {
    const no_mask: raster.Mask = .{ .pixels = &.{}, .size = 0 };
    raster.drawRegion(out, t.instances.items, no_mask, .{}, t.scale, t.theme.background, region);
}

test "groups drawn in a region or on threads make the whole frame's pixels" {
    const gpa = testing.allocator;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 400, .height = 200 });
    defer t.deinit();
    t.scroll(s.x + 50, 90, -40);
    t.settle(1);
    var begins: usize = 0;
    for (t.instances.items) |i| begins += @intFromBool(i.kind == gpu.Kind.layer_begin);
    try testing.expect(begins >= 4);

    const w: usize = @intFromFloat(t.size.w * t.scale);
    const h: usize = @intFromFloat(t.size.h * t.scale);
    const whole_bytes = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(whole_bytes);
    const part_bytes = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(part_bytes);
    const whole: gpu.Pixels = .{ .bytes = whole_bytes, .width = w, .height = h };
    const part: gpu.Pixels = .{ .bytes = part_bytes, .width = w, .height = h };

    const saved = raster.threads;
    defer raster.threads = saved;
    raster.threads = 1;
    render(&t, whole, .{ 0, 0, w, h });
    raster.threads = saved;
    render(&t, part, .{ 0, 0, w, h });
    try testing.expectEqualSlices(u8, whole.bytes, part.bytes);

    // Regions cutting through groups, over the frame's own pixels.
    const cuts = [_][4]usize{
        .{ 0, 0, w / 3, h },
        .{ w / 4, h / 3, w / 2, h / 2 },
        .{ w / 2, 0, w, h / 5 },
    };
    for (cuts) |cut| {
        @memset(part.bytes, 0x5a);
        render(&t, part, cut);
        for (cut[1]..cut[3]) |y| {
            const row = (y * w + cut[0]) * 4;
            const end = row + (cut[2] - cut[0]) * 4;
            try testing.expectEqualSlices(u8, whole.bytes[row..end], part.bytes[row..end]);
        }
    }

    // A group moved: redrawn within the damage, over the last frame.
    @memcpy(part.bytes, whole.bytes);
    const before = try gpa.dupe(gpu.Instance, t.instances.items);
    defer gpa.free(before);
    s.x = 47;
    t.settle(1);
    const d = raster.damage(w, h, before, t.instances.items, t.scale) orelse return error.NoDamage;
    render(&t, part, d);
    raster.threads = 1;
    render(&t, whole, .{ 0, 0, w, h });
    try testing.expectEqualSlices(u8, whole.bytes, part.bytes);
}

const MaskedNestedScene = struct {
    fn view(_: *@This(), c: *ui.Context) void {
        const root = ui.div(c).size(160, 160).bg(.white);
        defer root.end();
        const scroll = ui.div(c).size(160, 160).scrollY().scrollEdgeFade(24).hideScrollBar();
        defer scroll.end();
        const content = ui.div(c).size(160, 320).bg(.hex(0xff0000));
        defer content.end();
        const inner = ui.div(c).absolute().offset(20, 40).size(120, 120).scrollY().scrollEdgeFade(16).hideScrollBar();
        defer inner.end();
        ui.div(c).size(120, 240).bg(.{ .r = 0, .g = 0, .b = 1, .a = 0.5 }).end();
    }
};

test "a group inside a scroll-fade masked group keeps its own layer" {
    const gpa = testing.allocator;
    defer raster.freeLayers();
    var s: MaskedNestedScene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, MaskedNestedScene.view), .{ .width = 160, .height = 160, .scale = 1 });
    defer t.deinit();
    t.scroll(10, 80, -30);
    t.scroll(80, 80, -30);
    t.settle(1);

    var begins: usize = 0;
    for (t.instances.items) |i| begins += @intFromBool(i.kind == gpu.Kind.layer_begin);
    try testing.expect(begins >= 2);

    const w: usize = 160;
    const h: usize = 160;
    const single_bytes = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(single_bytes);
    const multi_bytes = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(multi_bytes);
    const single: gpu.Pixels = .{ .bytes = single_bytes, .width = w, .height = h };
    const multi: gpu.Pixels = .{ .bytes = multi_bytes, .width = w, .height = h };

    const saved = raster.threads;
    defer raster.threads = saved;
    raster.threads = 1;
    render(&t, single, .{ 0, 0, w, h });
    raster.threads = saved;
    render(&t, multi, .{ 0, 0, w, h });
    try testing.expectEqualSlices(u8, single.bytes, multi.bytes);

    // Center pixel is inside the semi-transparent blue inner masked group
    // over the red outer masked scroll content, clear of both edge fades:
    // BGRA must retain both red and blue channels rather than wiping depth 0.
    const center = (80 * w + 80) * 4;
    try testing.expect(single.bytes[center + 0] > 100);
    try testing.expect(single.bytes[center + 1] < 20);
    try testing.expect(single.bytes[center + 2] > 100);

    // A partial region cutting through the inner group matches the whole frame.
    const cut: [4]usize = .{ 40, 40, 120, 120 };
    @memset(multi.bytes, 0x5a);
    render(&t, multi, cut);
    for (cut[1]..cut[3]) |y| {
        const row = (y * w + cut[0]) * 4;
        const end = row + (cut[2] - cut[0]) * 4;
        try testing.expectEqualSlices(u8, single.bytes[row..end], multi.bytes[row..end]);
    }
}
