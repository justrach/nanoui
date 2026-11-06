//! Synthetic lifecycle regressions: no windows, real input or user data.
//! Import from ui.zig's test block. The feature guards make this file also
//! compile on main/PR88, where the regressions fail rather than get skipped.
const std = @import("std");
const ui = @import("ui.zig");
const Input = @import("input.zig").Input;
const testing = std.testing;

const Field = struct {
    text: ui.TextBuffer = .{},
    multiline: bool = false,
    focused: bool = true,
    vim: bool = false,

    fn view(s: *Field, c: *ui.Context) void {
        c.focus = if (s.focused) c.peekId(null) else 0;
        _ = ui.textField(c, &s.text, .{
            .bare = true,
            .multiline = s.multiline,
            .keys = if (s.vim) .vim else .system,
        });
    }
};

fn at(t: *ui.Tester, time: f64) void {
    t.time = time;
    t.frame();
}

fn carets(t: *const ui.Tester) usize {
    var count: usize = 0;
    for (t.ctx.nodes.items) |n| {
        if (n.content == .none and n.style.absolute and n.style.width == .px and
            n.style.width.px == 1.5 and n.style.height == .px and n.style.height.px > 2) count += 1;
    }
    return count;
}

fn deadline(t: *const ui.Tester, seconds: f32) !void {
    try testing.expect(!t.ctx.animating);
    try testing.expectApproxEqAbs(seconds, t.ctx.frame_in orelse return error.NoCaretWakeup, 0.001);
}

fn asleep(t: *const ui.Tester) !void {
    try testing.expectEqual(@as(usize, 0), carets(t));
    try testing.expect(t.ctx.frame_in == null);
    try testing.expect(!t.ctx.animating);
}

fn active(t: *ui.Tester, value: bool) void {
    if (comptime @hasField(@TypeOf(t.ctx.input), "window_active")) {
        t.ctx.input.window_active = value;
    } else if (comptime @hasField(ui.Context, "window_focused")) {
        // Exercise PR88's old host flag too: it hides the bar, but cannot
        // restart its old clock when the window becomes active again.
        t.ctx.window_focused = value;
    }
    t.frame();
}

test "caret activity has a persistent host flag, not an event edge" {
    if (comptime @hasField(Input, "window_active")) {
        var input: Input = .{};
        try testing.expect(input.window_active);
        input.window_active = false;
        input.pressed = true;
        input.chars = "synthetic";
        input.clearEdges();
        try testing.expect(!input.window_active);
        try testing.expect(!input.pressed);
        try testing.expectEqualStrings("", input.chars);
    } else return error.WindowActivityMissing;
}

test "caret activity single and multiline schedule 500 ms edges and restart on typing" {
    for ([_]bool{ false, true }) |multiline| {
        var s: Field = .{ .multiline = multiline };
        defer s.text.deinit();
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Field.view), .{});
        defer t.deinit();
        try testing.expectEqual(@as(usize, 1), carets(&t));
        try deadline(&t, 0.5);
        at(&t, 0.49);
        try testing.expectEqual(@as(usize, 1), carets(&t));
        try deadline(&t, 0.01);
        at(&t, 0.5);
        try testing.expectEqual(@as(usize, 0), carets(&t));
        try deadline(&t, 0.5);
        at(&t, 1);
        try testing.expectEqual(@as(usize, 1), carets(&t));
        at(&t, 1.5);
        try testing.expectEqual(@as(usize, 0), carets(&t));
        t.time = 1.75;
        t.typeText("Synthetic draft");
        try testing.expectEqualStrings("Synthetic draft", s.text.text());
        try testing.expectEqual(@as(usize, 1), carets(&t));
        try deadline(&t, 0.5);
        at(&t, 2.24);
        try testing.expectEqual(@as(usize, 1), carets(&t));
        at(&t, 2.25);
        try testing.expectEqual(@as(usize, 0), carets(&t));
    }
}

test "caret activity inactive windows sleep and reactivation starts a full phase" {
    for ([_]bool{ false, true }) |multiline| {
        var s: Field = .{ .multiline = multiline };
        defer s.text.deinit();
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Field.view), .{});
        defer t.deinit();
        t.time = 0.125;
        t.typeText("Synthetic draft");
        t.time = 0.75;
        active(&t, false);
        try asleep(&t);
        at(&t, 10);
        try asleep(&t);
        // Not an old clock's visible phase: PR88 leaves its bar hidden.
        t.time = 10.875;
        active(&t, true);
        try testing.expectEqual(@as(usize, 1), carets(&t));
        try deadline(&t, 0.5);
        at(&t, 11.365);
        try testing.expectEqual(@as(usize, 1), carets(&t));
        at(&t, 11.375);
        try testing.expectEqual(@as(usize, 0), carets(&t));
    }
}

test "caret activity blur and selection sleep without a bare focus animation" {
    for ([_]bool{ false, true }) |multiline| {
        var s: Field = .{ .multiline = multiline };
        defer s.text.deinit();
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Field.view), .{});
        defer t.deinit();
        t.typeText("Synthetic draft");
        s.focused = false;
        at(&t, 0.75);
        try asleep(&t);
        at(&t, 10);
        try asleep(&t);
        s.focused = true;
        at(&t, 10.75);
        try testing.expectEqual(@as(usize, 1), carets(&t));
        try deadline(&t, 0.5);
        t.textOps(&.{.{ .command = .select_all }});
        try asleep(&t);
        at(&t, 20);
        try asleep(&t);
        t.time = 20.75;
        t.textOps(&.{.{ .command = .move_left }});
        try testing.expectEqual(@as(usize, 1), carets(&t));
        try deadline(&t, 0.5);
        at(&t, 21.25);
        try testing.expectEqual(@as(usize, 0), carets(&t));
        // Even an explicit request for the same position restarts it.
        s.text.want_caret = t.ctx.focused_text.?.caret;
        at(&t, 21.375);
        try testing.expectEqual(@as(usize, 1), carets(&t));
        try deadline(&t, 0.5);
    }
}

test "caret activity composition stays solid without polling and unmark restarts" {
    for ([_]bool{ false, true }) |multiline| {
        var s: Field = .{ .multiline = multiline };
        defer s.text.deinit();
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Field.view), .{});
        defer t.deinit();
        t.time = 0.75;
        t.textOps(&.{.{ .set_marked = .{ .text = "a", .sel_start = 1, .sel_len = 0 } }});
        try testing.expectEqual(@as(usize, 1), carets(&t));
        try testing.expect(t.ctx.frame_in == null);
        try testing.expect(!t.ctx.animating);
        at(&t, 10.5);
        try testing.expectEqual(@as(usize, 1), carets(&t));
        try testing.expect(t.ctx.frame_in == null);
        t.time = 10.75;
        t.textOps(&.{.unmark});
        try testing.expectEqual(@as(usize, 1), carets(&t));
        try deadline(&t, 0.5);
        at(&t, 11.25);
        try testing.expectEqual(@as(usize, 0), carets(&t));
    }
}

test "caret activity Vim blocks stay solid but disappear while inactive" {
    for ([_]bool{ false, true }) |multiline| {
        var s: Field = .{ .multiline = multiline, .vim = true };
        defer s.text.deinit();
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Field.view), .{});
        defer t.deinit();
        t.typeText("Synthetic draft");
        // Model Vim's state directly; no real key or window is involved.
        t.ctx.edits.getPtr(t.ctx.focus).?.keys.vim_normal = true;
        at(&t, 0.75);
        try testing.expect(t.ctx.frame_in == null);
        try testing.expect(!t.ctx.animating);
        const visible_nodes = t.ctx.nodes.items.len;
        active(&t, false);
        try asleep(&t);
        try testing.expectEqual(visible_nodes - 1, t.ctx.nodes.items.len);
        at(&t, 10);
        try asleep(&t);
        active(&t, true);
        try testing.expectEqual(visible_nodes, t.ctx.nodes.items.len);
        try testing.expect(t.ctx.frame_in == null);
    }
}
