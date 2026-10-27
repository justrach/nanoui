//! Emoji in text: drawn in their own colors, as AppKit draws them, not
//! filled with the text's color like a letter. With CoreText on macOS and
//! iOS; from the font's own color tables elsewhere (`tt/color.zig`).
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Line = struct {
    text: []const u8 = "Hey 👋 🎉",
    color: ui.Color = .hex(0x111111),
    fn view(s: *Line, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(10), .background = .hex(0xffffff) });
        defer ui.end(c);
        ui.text(c, s.text, .{ .size = 32, .color = s.color });
    }
};

/// Pixels whose channels differ a lot: colored, not a shade of gray.
fn colored(px: @import("gpu.zig").Pixels) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 4 <= px.bytes.len) : (i += 4) {
        const b = px.bytes[i];
        const g = px.bytes[i + 1];
        const r = px.bytes[i + 2];
        const hi = @max(r, @max(g, b));
        const lo = @min(r, @min(g, b));
        if (hi - lo > 80) n += 1;
    }
    return n;
}

/// Where nanoui reads fonts itself, the color emoji font installed (Noto
/// Color Emoji, Segoe UI Emoji or Apple Color Emoji); none, nothing to test.
fn emojiFont(t: *ui.Tester) bool {
    if (comptime @import("text.zig").portable) {
        for ([_][]const u8{ "Noto Color Emoji", "Segoe UI Emoji", "Apple Color Emoji" }) |n|
            if (t.ctx.text.db.family(n, 400, false) != null) return true;
        return false;
    }
    return true;
}

test "emoji keep their own colors in text of any color" {
    var s: Line = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Line.view), .{ .width = 260, .height = 70 });
    defer t.deinit();
    if (!emojiFont(&t)) return error.SkipZigTest;
    t.settle(1);
    if (std.c.getenv("NANOUI_EMOJI_SNAPSHOT")) |path| try t.screenshot(std.mem.span(path));
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    // Two emoji at 32 points, 2×: thousands of colored pixels. Filled with
    // the near-black text color they'd have none.
    try testing.expect(colored(px) > 1000);

    // The same in white text: the emoji's colors, not the text's.
    s.color = .hex(0xffffff);
    t.frame();
    const again = try t.render(testing.allocator);
    defer again.deinit(testing.allocator);
    try testing.expect(colored(again) > 1000);
}

test "letters stay the text's color beside an emoji" {
    var s: Line = .{ .text = "Hey" };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Line.view), .{ .width = 260, .height = 70 });
    defer t.deinit();
    t.settle(1);
    const px = try t.render(testing.allocator);
    defer px.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), colored(px));
}
