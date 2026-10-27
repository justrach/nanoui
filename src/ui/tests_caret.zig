//! Text input's repaint cadence, driven without a window or real keys.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

const Field = struct {
    text: ui.TextBuffer = .{},
    multiline: bool = false,
    focused: bool = true,

    fn view(s: *Field, c: *ui.Context) void {
        c.focus = if (s.focused) c.peekId(null) else 0;
        _ = ui.textField(c, &s.text, .{ .multiline = s.multiline });
    }
};

fn carets(t: *const ui.Tester) usize {
    var count: usize = 0;
    for (t.ctx.nodes.items) |n| {
        if (n.content == .none and n.style.absolute and n.style.width == .px and n.style.width.px == 1.5 and n.style.height == .px and n.style.height.px > 2) count += 1;
    }
    return count;
}

test "single and multiline carets blink at 500 ms and reset immediately on typing" {
    for ([_]bool{ false, true }) |multiline| {
        var s: Field = .{ .multiline = multiline };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Field.view), .{});
        defer t.deinit();
        try testing.expectEqual(@as(usize, 1), carets(&t));
        try testing.expect(t.ctx.frame_in != null);
        try testing.expectApproxEqAbs(@as(f32, 0.5), t.ctx.frame_in.?, 0.001);
        t.time = 0.5;
        t.frame();
        try testing.expectEqual(@as(usize, 0), carets(&t));
        t.time = 0.9;
        t.textOps(&.{.{ .insert = "hi" }});
        try testing.expectEqualStrings("hi", s.text.text());
        try testing.expectEqual(@as(usize, 1), carets(&t));
        try testing.expectApproxEqAbs(@as(f32, 0.5), t.ctx.frame_in.?, 0.001);
        t.time = 1.41;
        t.frame();
        try testing.expectEqual(@as(usize, 0), carets(&t));
        s.focused = false;
        t.frame();
        try testing.expectEqual(@as(usize, 0), carets(&t));
        try testing.expect(t.ctx.frame_in == null);
    }
}

test "inactive windows and selections schedule no caret frames; focus and movement restart it" {
    for ([_]bool{ false, true }) |multiline| {
        var s: Field = .{ .multiline = multiline };
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Field.view), .{});
        defer t.deinit();
        t.textOps(&.{.{ .insert = "hello" }});
        t.ctx.input.window_active = false;
        t.frame();
        try testing.expectEqual(@as(usize, 0), carets(&t));
        try testing.expect(t.ctx.frame_in == null);
        // Clearing event edges must not make an inactive window active.
        t.time = 10;
        t.frame();
        try testing.expect(t.ctx.frame_in == null);
        t.ctx.input.window_active = true;
        t.frame();
        try testing.expectEqual(@as(usize, 1), carets(&t));
        t.time = 10.6;
        t.frame();
        try testing.expectEqual(@as(usize, 0), carets(&t));
        t.textOps(&.{.{ .command = .move_left }});
        try testing.expectEqual(@as(usize, 1), carets(&t));
        t.textOps(&.{.{ .command = .select_all }});
        try testing.expectEqual(@as(usize, 0), carets(&t));
        try testing.expect(t.ctx.frame_in == null);
        t.textOps(&.{.{ .set_marked = .{ .text = "a", .sel_start = 1, .sel_len = 0 } }});
        try testing.expectEqual(@as(usize, 1), carets(&t));
        try testing.expect(t.ctx.frame_in == null);
        t.textOps(&.{.unmark});
        try testing.expect(t.ctx.frame_in != null);
    }
}
