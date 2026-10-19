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
    const path = "/tmp/nanoui-test-imageio.png";
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
