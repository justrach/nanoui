//! The CPU renderer against the Metal renderer: one frame of widgets
//! (text, icons, borders, rounded corners, shadows, clipping, rounded
//! clips, a picture) drawn by both must come out the same, to rounding.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const raster = @import("raster.zig");

pub const Scene = struct {
    on: bool = true,
    value: f32 = 0.4,
    picture: []const u8 = "",
    pub fn view(s: *Scene, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 14, .width = .fill, .height = .fill });
        defer ui.end(c);
        ui.text(c, "Settings", .{ .size = 22, .weight = .bold });
        ui.card(c, .{ .gap = 10, .shadow = .{ .blur = 18, .y = 6 } });
        {
            defer ui.end(c);
            ui.text(c, "Wrapped text in a card with a shadow, long enough to break onto a second line.", .{ .size = 13, .wrap = true });
            _ = ui.toggle(c, "Notifications", &s.on);
            _ = ui.slider(c, &s.value, .{});
        }
        {
            // A rounded box clipping its children, one a clip of its own
            // that shares the box's right corners.
            const box = ui.div(c).row().w(150).h(36).rounded(12).clip();
            defer box.end();
            const left = ui.div(c).w(90).hFull().bg(.hex(0xd04a2f));
            left.end();
            const right = ui.div(c).grow().hFull().clip().bg(.hex(0x2f6fd0));
            defer right.end();
            ui.text(c, "clipped", .{ .size = 12, .color = .{ .r = 1, .g = 1, .b = 1 } });
        }
        ui.row(c, .{ .gap = 8 });
        defer ui.end(c);
        _ = ui.button(c, "Save", .{ .variant = .primary, .icon = "checkmark" });
        _ = ui.button(c, "Cancel", .{});
        ui.icon(c, "star.fill", .{ .size = 18, .color = c.theme.accent });
        ui.badge(c, "new", c.theme.accent);
        _ = ui.image(c, .{ .key = "gradient", .bytes = s.picture, .max_width = 60, .radius = 8 });
        // The same picture's shape, tinted (a monochrome mark).
        _ = ui.image(c, .{ .key = "gradient", .bytes = s.picture, .max_width = 30, .radius = 0, .tint = c.theme.accent });
    }
};

test "the CPU renderer draws what the Metal renderer draws" {
    // Where text is nanoui's own there is no Metal renderer to compare.
    if (@import("text.zig").portable) return error.SkipZigTest else try compare();
}

fn compare() !void {
    const gpa = testing.allocator;
    // A gradient picture, half transparent at one end.
    var px: [48 * 32 * 4]u8 = undefined;
    for (0..32) |y| for (0..48) |x| {
        const a: u8 = @intCast(255 - x * 2);
        const o = (y * 48 + x) * 4;
        px[o..][0..4].* = .{ @intCast(y * 8 * a / 255), @intCast(x * 5 * a / 255), @intCast(200 * @as(u32, a) / 255), a };
    };
    const picture = try @import("png.zig").encode(gpa, .{ .bytes = &px, .width = 48, .height = 32 });
    defer gpa.free(picture);
    var s: Scene = .{ .picture = picture };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 360, .height = 300 });
    defer t.deinit();
    t.settle(1);
    t.renderer.syncImages(&t.text.images);
    const metal = try t.renderer.drawOffscreen(gpa, t.instances.items, t.text.texture(), t.size, t.scale, t.theme.background);
    defer metal.deinit(gpa);
    const texels = try t.text.atlas.read(gpa);
    defer gpa.free(texels);
    const cpu_bytes = try gpa.alloc(u8, metal.bytes.len);
    defer gpa.free(cpu_bytes);
    const cpu: @TypeOf(metal) = .{ .bytes = cpu_bytes, .width = metal.width, .height = metal.height };
    raster.draw(cpu, t.instances.items, .{ .pixels = texels, .size = t.text.atlas.size }, t.text.images.pictures(), t.scale, t.theme.background);

    var total: u64 = 0;
    var off: usize = 0;
    var worst: u8 = 0;
    for (metal.bytes, cpu.bytes) |a, b| {
        const d = if (a > b) a - b else b - a;
        total += d;
        worst = @max(worst, d);
        if (d > 8) off += 1;
    }
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(metal.bytes.len));
    // Measured: a mean of 0.001 and at worst 6 levels apart.
    try testing.expect(mean < 0.05);
    try testing.expect(worst <= 16);
    // Edges may round differently; no more than one channel in a thousand.
    try testing.expect(off * 1000 < metal.bytes.len);
}

test "a box with rounded corners clips its children at them, nested clips too" {
    const gpa = testing.allocator;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 360, .height = 300 });
    defer t.deinit();
    t.settle(1);
    const gpu = @import("gpu.zig");
    var boxes: u4 = 0;
    var inner: u4 = 0;
    for (t.instances.items) |i| {
        const round = gpu.clipCorners(i.clip_round);
        if (round.corners == 0) continue;
        try testing.expectEqual(@as(f32, 12), round.radius);
        // The red and blue boxes are clipped by the rounded box: all four
        // corners. The white text in the blue box by the blue box's own
        // clip: rounded only where it shares the rounded box's corners.
        if (i.color[0] > 0.9 and i.color[1] > 0.9 and i.color[2] > 0.9) inner |= round.corners else boxes |= round.corners;
    }
    try testing.expectEqual(@as(u4, 15), boxes);
    try testing.expectEqual(@as(u4, 2 | 4), inner);
}

test "nanoui's PNG decoder reads what ImageIO writes (compressed), pixel for pixel" {
    if (@import("text.zig").portable) return error.SkipZigTest;
    const gpa = testing.allocator;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 200, .height = 120 });
    defer t.deinit();
    t.settle(1);
    var path_buf: [256]u8 = undefined;
    const path = try @import("../temp_path.zig").tempPath(&path_buf, "nanoui-test-imageio.png");
    try t.screenshot(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(8 << 20));
    defer gpa.free(bytes);
    const ours = try @import("png_decode.zig").decode(gpa, bytes);
    defer ours.deinit(gpa);
    const theirs = try @import("image.zig").decode(gpa, bytes);
    defer gpa.free(theirs.bgra);
    try testing.expectEqual(theirs.width, ours.width);
    try testing.expectEqual(theirs.height, ours.height);
    var worst: u8 = 0;
    for (ours.bgra, theirs.bgra) |a, b| worst = @max(worst, if (a > b) a - b else b - a);
    try testing.expect(worst <= 2);
}

test "pictures written straight to the GPU draw as the CPU atlas's copy does" {
    if (@import("text.zig").portable) return error.SkipZigTest;
    const gpa = testing.allocator;
    var px: [40 * 30 * 4]u8 = undefined;
    for (0..30) |y| for (0..40) |x| {
        px[(y * 40 + x) * 4 ..][0..4].* = .{ @intCast(x * 6), @intCast(y * 8), 180, 255 };
    };
    const picture = try @import("png.zig").encode(gpa, .{ .bytes = &px, .width = 40, .height = 30 });
    defer gpa.free(picture);
    var frames: [2]@import("gpu.zig").Pixels = undefined;
    var kept_cpu: usize = 1;
    for (0..2) |k| {
        var s: Scene = .{ .picture = picture };
        var t: ui.Tester = undefined;
        try t.init(gpa, .init(&s, Scene.view), .{ .width = 360, .height = 300 });
        defer t.deinit();
        if (k == 1) {
            // Its pictures start over, going to the GPU only.
            t.text.images.deinit();
            t.text.images = .{ .gpa = gpa, .sink = .{ .ctx = &t.renderer, .upload = @import("metal.zig").Renderer.uploadImage } };
            t.frame();
        }
        t.settle(1);
        t.renderer.syncImages(&t.text.images);
        frames[k] = try t.renderer.drawOffscreen(gpa, t.instances.items, t.text.texture(), t.size, t.scale, t.theme.background);
        if (k == 1) kept_cpu = t.text.images.pixels.len;
    }
    defer for (frames) |f| f.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), kept_cpu);
    try testing.expectEqualSlices(u8, frames[0].bytes, frames[1].bytes);
}

test "a box at x = 10.3 pt with a 1 pt border snaps to device pixels with full coverage" {
    const SnapScene = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            _ = c.open(.{ .width = .fill, .height = .fill, .background = .white }, null);
            defer c.end();
            _ = c.leaf(.{
                .absolute = true,
                .offset = .{ .x = 10.3, .y = 10.3 },
                .width = .{ .px = 20 },
                .height = .{ .px = 20 },
                .background = .white,
                .border = .black,
                .border_width = 1,
            }, .none, null);
        }
    };
    const gpa = testing.allocator;
    var s: SnapScene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, SnapScene.view), .{ .width = 60, .height = 60 });
    defer t.deinit();
    t.settle(1);
    const w: usize = @intFromFloat(t.size.w * t.scale);
    const h: usize = @intFromFloat(t.size.h * t.scale);
    const bytes = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(bytes);
    const out: @import("gpu.zig").Pixels = .{ .bytes = bytes, .width = w, .height = h };
    raster.draw(out, t.instances.items, .{ .pixels = &.{}, .size = 0 }, .{}, t.scale, .white);
    // 10.3 pt at 2x snaps to 10.5 pt = pixel 21; a 1 pt border spans 2 device pixels (21 and 22),
    // while pixel 20 (outside) and pixel 23 (inside fill) stay pure white.
    const px20 = out.bytes[(30 * w + 20) * 4 ..][0..4].*;
    const px21 = out.bytes[(30 * w + 21) * 4 ..][0..4].*;
    const px22 = out.bytes[(30 * w + 22) * 4 ..][0..4].*;
    const px23 = out.bytes[(30 * w + 23) * 4 ..][0..4].*;
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, px20);
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, px21);
    try testing.expectEqual([4]u8{ 0, 0, 0, 255 }, px22);
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, px23);
}

test "a translating box keeps its width in device pixels" {
    const MoveScene = struct {
        x: f32 = 10.1,
        fn view(s: *@This(), c: *ui.Context) void {
            _ = c.open(.{ .width = .fill, .height = .fill, .background = .white }, null);
            defer c.end();
            _ = c.leaf(.{
                .absolute = true,
                .offset = .{ .x = s.x, .y = 10 },
                .width = .{ .px = 19.4 },
                .height = .{ .px = 20 },
                .background = .black,
            }, .none, "box");
        }
    };
    const gpa = testing.allocator;
    var s: MoveScene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, MoveScene.view), .{ .width = 80, .height = 60 });
    defer t.deinit();
    for ([_]f32{ 10.1, 10.3, 10.6, 10.8 }) |x| {
        s.x = x;
        t.frame();
        const inst = t.instances.items[t.instances.items.len - 1];
        try testing.expectApproxEqAbs(@as(f32, 39), inst.rect[2] * t.scale, 1e-4);
    }
}

test "group opacity composites once" {
    const GroupScene = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            _ = c.open(.{ .width = .fill, .height = .fill, .background = .white }, null);
            defer c.end();
            _ = c.open(.{ .width = .{ .px = 120 }, .height = .{ .px = 80 }, .opacity = 0.5, .group = true }, "grp");
            defer c.end();
            _ = c.leaf(.{
                .absolute = true,
                .offset = .{ .x = 10, .y = 10 },
                .width = .{ .px = 50 },
                .height = .{ .px = 40 },
                .background = .{ .r = 1, .g = 0, .b = 0, .a = 1 },
            }, .none, "a");
            _ = c.leaf(.{
                .absolute = true,
                .offset = .{ .x = 30, .y = 20 },
                .width = .{ .px = 50 },
                .height = .{ .px = 40 },
                .background = .{ .r = 1, .g = 0, .b = 0, .a = 1 },
            }, .none, "b");
        }
    };
    const gpa = testing.allocator;
    var s: GroupScene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, GroupScene.view), .{ .width = 140, .height = 100 });
    defer t.deinit();
    t.settle(1);
    const w: usize = @intFromFloat(t.size.w * t.scale);
    const h: usize = @intFromFloat(t.size.h * t.scale);
    const cpu_bytes = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(cpu_bytes);
    const cpu: @import("gpu.zig").Pixels = .{ .bytes = cpu_bytes, .width = w, .height = h };
    raster.draw(cpu, t.instances.items, .{ .pixels = &.{}, .size = 0 }, .{}, t.scale, t.theme.background);

    // Single-box pixel at (20, 20) pt -> (40, 40) px; overlap pixel at (40, 30) pt -> (80, 60) px.
    // Control pixel outside both boxes at (5, 5) pt -> (10, 10) px.
    const outside_cpu = cpu.bytes[(10 * w + 10) * 4 ..][0..4].*;
    const single_cpu = cpu.bytes[(40 * w + 40) * 4 ..][0..4].*;
    const overlap_cpu = cpu.bytes[(60 * w + 80) * 4 ..][0..4].*;
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, outside_cpu);
    try testing.expectEqual(single_cpu, overlap_cpu);
    try testing.expect(@abs(@as(i16, single_cpu[0]) - 128) <= 2);
    try testing.expect(@abs(@as(i16, single_cpu[1]) - 128) <= 2);
    try testing.expectEqual(@as(u8, 255), single_cpu[2]);
    try testing.expectEqual(@as(u8, 255), single_cpu[3]);

    if (!@import("text.zig").portable) {
        const metal = try t.renderer.drawOffscreen(gpa, t.instances.items, t.text.texture(), t.size, t.scale, t.theme.background);
        defer metal.deinit(gpa);
        const outside_mtl = metal.bytes[(10 * w + 10) * 4 ..][0..4].*;
        const single_mtl = metal.bytes[(40 * w + 40) * 4 ..][0..4].*;
        const overlap_mtl = metal.bytes[(60 * w + 80) * 4 ..][0..4].*;
        try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, outside_mtl);
        try testing.expectEqual(single_mtl, overlap_mtl);
        var total: u64 = 0;
        var worst: u8 = 0;
        for (metal.bytes, cpu.bytes) |a, b| {
            const d = if (a > b) a - b else b - a;
            total += d;
            worst = @max(worst, d);
        }
        const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(metal.bytes.len));
        try testing.expect(mean < 0.05);
        try testing.expect(worst <= 16);
    }
}

test "drawing only what a frame changed makes the pixels drawing it all does" {
    // The CPU renderer's own atlas: where nanoui shapes text itself.
    if (!@import("text.zig").portable) return error.SkipZigTest else try partial();
}

fn partial() !void {
    const gpa = testing.allocator;
    const Instance = @import("gpu.zig").Instance;
    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 360, .height = 300 });
    defer t.deinit();
    t.settle(1);
    const pixels = try t.render(gpa);
    defer pixels.deinit(gpa);
    const w = pixels.width;
    const h = pixels.height;
    const before = try gpa.dupe(Instance, t.instances.items);
    defer gpa.free(before);
    try testing.expectEqual(@as(?[4]usize, null), raster.damage(w, h, before, before, t.scale));

    // The same number of instances: a hovered button and a toggle turned off.
    const save = t.findText("Save") orelse return error.TextNotFound;
    t.moveTo(save.x + save.w / 2, save.y + save.h / 2);
    s.on = false;
    t.settle(1);
    const d = raster.damage(w, h, before, t.instances.items, t.scale) orelse return error.NoDamage;
    try testing.expect((d[2] - d[0]) * (d[3] - d[1]) < w * h / 2);
    raster.drawRegion(pixels, t.instances.items, t.text.atlas.mask(), t.text.images.pictures(), t.scale, t.theme.background, d);
    const whole = try t.render(gpa);
    defer whole.deinit(gpa);
    try testing.expectEqualSlices(u8, whole.bytes, pixels.bytes);

    // One fewer instance: a glyph past the middle gone.
    var fewer: std.ArrayList(Instance) = .empty;
    defer fewer.deinit(gpa);
    try fewer.appendSlice(gpa, t.instances.items);
    var k = fewer.items.len / 2;
    while (fewer.items[k].kind != @import("gpu.zig").Kind.text) k += 1;
    _ = fewer.orderedRemove(k);
    const e = raster.damage(w, h, t.instances.items, fewer.items, t.scale) orelse return error.NoDamage;
    raster.drawRegion(pixels, fewer.items, t.text.atlas.mask(), t.text.images.pictures(), t.scale, t.theme.background, e);
    raster.draw(whole, fewer.items, t.text.atlas.mask(), t.text.images.pictures(), t.scale, t.theme.background);
    try testing.expectEqualSlices(u8, whole.bytes, pixels.bytes);
}

test "rounded boxes, borders, glyphs and shadows" {
    const gpa = std.testing.allocator;
    const bytes = try gpa.alloc(u8, 40 * 40 * 4);
    defer gpa.free(bytes);
    const out: @import("gpu.zig").Pixels = .{ .bytes = bytes, .width = 40, .height = 40 };
    var texels: [4]u8 = .{ 255, 255, 255, 255 };
    raster.draw(out, &.{
        .{ .rect = .{ 2, 2, 16, 16 }, .color = .{ 1, 0, 0, 1 }, .radius = 4 },
        .{ .rect = .{ 0, 0, 10, 10 }, .color = .{ 0, 0, 1, 1 }, .uv = .{ 0, 0, 1, 1 }, .kind = @import("gpu.zig").Kind.text, .clip = .{ 0, 0, 5, 20 } },
    }, .{ .pixels = &texels, .size = 2 }, .{}, 2, .{ .r = 1, .g = 1, .b = 1 });
    const at = struct {
        fn f(o: @import("gpu.zig").Pixels, x: usize, y: usize) [4]u8 { return o.bytes[(y * o.width + x) * 4 ..][0..4].*; }
    }.f;
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 20, 20));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 4, 34));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, at(out, 2, 2));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 15, 2));
}

test "a clip's rounded corners cut what it clips, only where asked" {
    const gpa = std.testing.allocator;
    const bytes = try gpa.alloc(u8, 40 * 40 * 4);
    defer gpa.free(bytes);
    const out: @import("gpu.zig").Pixels = .{ .bytes = bytes, .width = 40, .height = 40 };
    raster.draw(out, &.{
        .{ .rect = .{ 0, 0, 20, 20 }, .color = .{ 1, 0, 0, 1 }, .clip = .{ 0, 0, 20, 20 }, .clip_round = @import("gpu.zig").clipRound(8, 1 | 8) },
    }, .{ .pixels = &.{}, .size = 0 }, .{}, 2, .{ .r = 1, .g = 1, .b = 1 });
    const at = struct {
        fn f(o: @import("gpu.zig").Pixels, x: usize, y: usize) [4]u8 { return o.bytes[(y * o.width + x) * 4 ..][0..4].*; }
    }.f;
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 0, 0));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, at(out, 0, 39));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 39, 0));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 39, 39));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, at(out, 20, 20));
    const unpacked = @import("gpu.zig").clipCorners(@import("gpu.zig").clipRound(8, 1 | 8));
    try std.testing.expectEqual(@as(f32, 8), unpacked.radius);
    try std.testing.expectEqual(@as(u4, 9), unpacked.corners);
}

test {
    _ = @import("tests_corners.zig");
    _ = @import("tests_text_weight.zig");
}
