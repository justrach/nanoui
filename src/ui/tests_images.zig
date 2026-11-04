//! Tests for `ui.image` device-pixel sizing in the atlas and decode budgeting.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const images = @import("images.zig");

const ViewState = struct {
    bytes: []const u8,
    fn view(s: *ViewState, c: *ui.Context) void {
        _ = ui.image(c, .{ .key = "icon", .bytes = s.bytes, .max_width = 15, .max_height = 15, .radius = 0, .scale = 0.5 });
    }
};

test "ui.image at 15 pt packs side 30 at scale 2 and side 15 at scale 1" {
    const gpa = testing.allocator;
    const raw = try gpa.alloc(u8, 64 * 64 * 4);
    defer gpa.free(raw);
    @memset(raw, 200);
    const png = try ui.png.encode(gpa, .{ .bytes = raw, .width = 64, .height = 64 });
    defer gpa.free(png);

    const k = images.Images.key("icon");
    {
        var s: ViewState = .{ .bytes = png };
        var t: ui.Tester = undefined;
        try t.init(gpa, ui.View.init(&s, ViewState.view), .{ .width = 100, .height = 100, .scale = 2 });
        defer t.deinit();
        t.frame();
        try testing.expect(t.ctx.text.images.entries.get(.{ .key = k, .side = 30 }).?.entry != null);
    }
    {
        var s: ViewState = .{ .bytes = png };
        var t: ui.Tester = undefined;
        try t.init(gpa, ui.View.init(&s, ViewState.view), .{ .width = 100, .height = 100, .scale = 1 });
        defer t.deinit();
        t.frame();
        try testing.expect(t.ctx.text.images.entries.get(.{ .key = k, .side = 15 }).?.entry != null);
    }
}

const BudgetState = struct {
    bytes: []const u8,
    fn view(s: *BudgetState, c: *ui.Context) void {
        for (0..9) |i| {
            _ = ui.image(c, .{ .key = c.print("icon.{d}", .{i}), .bytes = s.bytes, .max_width = 15, .max_height = 15, .radius = 0, .scale = 0.5 });
        }
    }
};

test "decode budget limits to 8 decodes per frame and requests next frame" {
    const gpa = testing.allocator;
    const raw = try gpa.alloc(u8, 16 * 16 * 4);
    defer gpa.free(raw);
    @memset(raw, 200);
    const png = try ui.png.encode(gpa, .{ .bytes = raw, .width = 16, .height = 16 });
    defer gpa.free(png);

    var s: BudgetState = .{ .bytes = png };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&s, BudgetState.view), .{ .width = 200, .height = 200, .scale = 2 });
    defer t.deinit();
    try testing.expectEqual(@as(usize, 8), t.ctx.text.images.entries.count());
    try testing.expect(t.ctx.text.images.wants_frame);
    t.frame();
    try testing.expectEqual(@as(usize, 9), t.ctx.text.images.entries.count());
    try testing.expect(!t.ctx.text.images.wants_frame);
}

test "sink uploads survive render after pre-sink pixels allocation" {
    if (@import("build_options").portable or @import("builtin").os.tag != .macos) return;
    const gpa = testing.allocator;
    const raw = try gpa.alloc(u8, 16 * 16 * 4);
    defer gpa.free(raw);
    @memset(raw, 220);
    const png = try ui.png.encode(gpa, .{ .bytes = raw, .width = 16, .height = 16 });
    defer gpa.free(png);

    var s: BudgetState = .{ .bytes = png };
    var t: ui.Tester = undefined;
    // Frame 1 runs with sink == null, allocating im.pixels and decoding 8 of 9 icons.
    try t.init(gpa, ui.View.init(&s, BudgetState.view), .{ .width = 200, .height = 200, .scale = 2, .dark = true });
    defer t.deinit();
    // Sync the first 8 icons into images_texture, then attach the direct GPU sink for icon.8.
    t.renderer.syncImages(&t.text.images);
    t.text.images.sink = .{ .ctx = &t.renderer, .upload = @TypeOf(t.renderer).uploadImage };
    t.frame();
    const px = try t.render(gpa);
    defer px.deinit(gpa);
    const k8 = images.Images.key("icon.8");
    const e6 = t.ctx.text.images.entries.get(.{ .key = k8, .side = 30 }).?.entry.?;
    var r6: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .image => |im| if (im.key == k8) {
            r6 = n.rect;
        },
        else => {},
    };
    try testing.expect(e6.uv[0] > 0);
    const rect = r6.?;
    const cx: usize = @intFromFloat(@round((rect.x + rect.w * 0.5) * 2));
    const cy: usize = @intFromFloat(@round((rect.y + rect.h * 0.5) * 2));
    const idx = (cy * px.width + cx) * 4;
    try testing.expect(px.bytes[idx] > 180 and px.bytes[idx + 1] > 180 and px.bytes[idx + 2] > 180);
}

const PartState = struct {
    bytes: []const u8,
    fn view(s: *PartState, c: *ui.Context) void {
        // Its left half, stretched over a box twice as wide as tall.
        _ = ui.image(c, .{ .key = "sides", .bytes = s.bytes, .radius = 0, .box = .{ .w = 40, .h = 20 }, .part = .{ 0, 0, 0.5, 1 } });
        _ = ui.image(c, .{ .key = "sides", .bytes = s.bytes, .radius = 0, .box = .{ .w = 40, .h = 20 }, .part = .{ 0.5, 0, 1, 1 } });
    }
};

test "ui.image shows the part asked for, in the box asked for" {
    const gpa = testing.allocator;
    // Red on its left half, blue on its right, 8x8 (BGRA).
    var raw: [8 * 8 * 4]u8 = undefined;
    for (0..8) |y| for (0..8) |x| {
        const px: [4]u8 = if (x < 4) .{ 0, 0, 255, 255 } else .{ 255, 0, 0, 255 };
        @memcpy(raw[(y * 8 + x) * 4 ..][0..4], &px);
    };
    const png = try ui.png.encode(gpa, .{ .bytes = &raw, .width = 8, .height = 8 });
    defer gpa.free(png);
    var s: PartState = .{ .bytes = png };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&s, PartState.view), .{ .width = 60, .height = 60, .scale = 1 });
    defer t.deinit();
    t.frame();
    const px = try t.render(gpa);
    defer px.deinit(gpa);
    const at = struct {
        fn bgra(p: anytype, x: usize, y: usize) [4]u8 {
            return p.bytes[(y * p.width + x) * 4 ..][0..4].*;
        }
    }.bgra;
    // Both ends of the first box are red, both ends of the second blue.
    for ([_][2]usize{ .{ 3, 10 }, .{ 36, 10 } }) |p| {
        const v = at(px, p[0], p[1]);
        try testing.expect(v[2] > 200 and v[0] < 60);
    }
    for ([_][2]usize{ .{ 3, 30 }, .{ 36, 30 } }) |p| {
        const v = at(px, p[0], p[1]);
        try testing.expect(v[0] > 200 and v[2] < 60);
    }
    try testing.expectEqual(@as(f32, 8), ui.imageSize(&t.ctx, "sides", png).?.w);
    try testing.expect(ui.imageSize(&t.ctx, "not", "not a picture") == null);
}

const FormatState = struct {
    bytes: []const u8,
    fn view(s: *FormatState, c: *ui.Context) void {
        _ = ui.image(c, .{ .key = "picture", .bytes = s.bytes, .radius = 0, .box = .{ .w = 32, .h = 32 } });
    }
};

/// Whichever decodes it (ImageIO, or nanoui's own with `-Dportable`), the
/// picture is the same size and comes out in the same place.
fn drawsAt(bytes: []const u8, width: f32, height: f32) ![4]u8 {
    const gpa = testing.allocator;
    var s: FormatState = .{ .bytes = bytes };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&s, FormatState.view), .{ .width = 32, .height = 32, .scale = 1 });
    defer t.deinit();
    t.frame();
    const size = ui.imageSize(&t.ctx, "picture", bytes).?;
    try testing.expectEqual(width, size.w);
    try testing.expectEqual(height, size.h);
    const px = try t.render(gpa);
    defer px.deinit(gpa);
    return px.bytes[(16 * px.width + 16) * 4 ..][0..4].*;
}

test "a GIF and a JPEG draw on every platform" {
    // One red pixel: GIF89a, a palette of two, LZW's clear, 0, end.
    const gif = "GIF89a\x01\x00\x01\x00\x80\x00\x00\xff\x00\x00\x00\x00\x00" ++
        "\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";
    const red = try drawsAt(gif, 1, 1);
    try testing.expect(red[2] > 240 and red[1] < 20 and red[0] < 20);
    const jpeg = &@import("jpeg_decode_test.zig").real_sips;
    const px = try drawsAt(jpeg, @floatFromInt(@import("jpeg_decode.zig").size(jpeg).?.width), @floatFromInt(@import("jpeg_decode.zig").size(jpeg).?.height));
    try testing.expectEqual(@as(u8, 255), px[3]);
}
