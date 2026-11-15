//! ImageIO turns EXIF-oriented pictures upright; layout and decoded pixels
//! must match the oriented aspect ratio across both small and large images.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const image = @import("image.zig");

const State = struct {
    bytes: []const u8,
    fn view(s: *State, c: *ui.Context) void {
        const root = ui.div(c).column().wFull().hFull();
        defer root.end();
        _ = ui.image(c, .{ .key = "oriented-picture", .source = .{ .encoded = s.bytes }, .max_width = 480, .max_height = 360, .scale = 1, .radius = 0 });
    }
};

test "image orientation PNG layout and decode match upright pixels without stretching" {
    if (ui.portable or @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const cases = [_]struct { bytes: []const u8, width: u32, height: u32 }{
        .{ .bytes = @embedFile("fixtures/image_orientation/small-rotate-270.png"), .width = 240, .height = 120 },
        .{ .bytes = @embedFile("fixtures/image_orientation/large-rotate-270.png"), .width = 600, .height = 300 },
    };
    for (cases) |case| {
        const dims = image.dimensions(case.bytes).?;
        try testing.expectEqual(case.width, dims.width);
        try testing.expectEqual(case.height, dims.height);

        const fitted_small = try image.decodeFit(testing.allocator, case.bytes, 128);
        defer testing.allocator.free(fitted_small.bgra);
        try testing.expectEqual(case.width, fitted_small.width);
        try testing.expectEqual(case.height, fitted_small.height);
        try testing.expectEqual(@as(u32, 128), fitted_small.w);
        try testing.expectEqual(@as(u32, 64), fitted_small.h);

        var state: State = .{ .bytes = case.bytes };
        var tester: ui.Tester = undefined;
        try tester.init(testing.allocator, .init(&state, State.view), .{ .width = 520, .height = 400, .scale = 1 });
        defer tester.deinit();
        tester.settle(1);

        const size = ui.imageSize(&tester.ctx, "oriented-picture", case.bytes).?;
        try testing.expectEqual(@as(f32, @floatFromInt(case.width)), size.w);
        try testing.expectEqual(@as(f32, @floatFromInt(case.height)), size.h);

        var rect: ?ui.Rect = null;
        for (tester.ctx.nodes.items) |node| switch (node.content) {
            .image => rect = node.rect,
            else => {},
        };
        const fitted = rect.?;
        try testing.expectApproxEqAbs(@as(f32, 2), fitted.w / fitted.h, 0.01);

        for (tester.text.images.decoded.values()) |entry| {
            const decoded = entry.?;
            try testing.expectEqual(case.width, decoded.width);
            try testing.expectEqual(case.height, decoded.height);
            try testing.expectApproxEqAbs(@as(f32, 2), @as(f32, @floatFromInt(decoded.w)) / @as(f32, @floatFromInt(decoded.h)), 0.01);
        }

        const pixels = try tester.render(testing.allocator);
        defer pixels.deinit(testing.allocator);
        // The upright image is green/yellow above red/blue after the 270° EXIF turn.
        const colors = [_][3]u8{ .{ 20, 180, 65 }, .{ 250, 205, 20 }, .{ 240, 40, 30 }, .{ 30, 80, 240 } };
        for (colors, 0..) |rgb, i| {
            const x: usize = @intFromFloat(fitted.x + fitted.w * (if (i % 2 == 0) @as(f32, 0.25) else 0.75));
            const y: usize = @intFromFloat(fitted.y + fitted.h * (if (i < 2) @as(f32, 0.25) else 0.75));
            const at = (y * pixels.width + x) * 4;
            for (0..3) |channel| try testing.expect(@abs(@as(i16, pixels.bytes[at + 2 - channel]) - @as(i16, rgb[channel])) < 8);
        }
    }
}
