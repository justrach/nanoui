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
