//! Font parity for fields, using only made-up text and offscreen frames.
//! Import from ui.zig's test block. The guards fail on main without making
//! missing options a compile error, so the same regression runs before/after.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const types = @import("types.zig");
const field = @import("textfield.zig");

const Form = struct {
    buf: ui.TextBuffer = .{},
    opts: field.Options = .{},
    last: field.Result = .{},

    fn view(s: *Form, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(12) });
        defer ui.end(c);
        s.last = ui.textField(c, &s.buf, s.opts);
    }
};

fn styleOf(opts: field.Options) types.TextStyle {
    return .{ .size = opts.size, .weight = opts.weight, .mono = opts.mono, .line_height = opts.line_height };
}

// These are the text nodes the frame paints, not a separate mock renderer.
fn expectRun(t: *ui.Tester, str: []const u8, style: types.TextStyle) !types.Rect {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, str)) {
            try testing.expectEqual(style.weight, tx.style.weight);
            try testing.expectEqual(style.mono, tx.style.mono);
            try testing.expectEqual(style.size, tx.style.size);
            try testing.expectEqual(style.line_height, tx.style.line_height);
            return n.rect;
        },
        else => {},
    };
    return error.TextNotFound;
}

fn expectCaret(t: *ui.Tester, run: types.Rect, str: []const u8, at: usize, style: types.TextStyle) !void {
    const caret = t.ctx.focused_text.?.caret_rect;
    const x = run.x + t.text.caretX(str, style, at);
    const lh = t.text.lineHeight(style);
    // The platform's IME rectangle and the painted caret must agree, and
    // must both use the chosen face rather than the default UI font.
    try testing.expectApproxEqAbs(x, caret.x, 0.05);
    try testing.expectApproxEqAbs(run.y, caret.y, 0.05);
    try testing.expectApproxEqAbs(lh, caret.h, 0.05);
    for (t.ctx.nodes.items) |n| {
        if (n.content != .none or !n.style.absolute) continue;
        const color = n.style.background orelse continue;
        if (!std.meta.eql(color, t.theme.accent)) continue;
        if (@abs(n.rect.w - caret.w) > 0.01) continue;
        try testing.expectApproxEqAbs(x, n.rect.x, 0.05);
        try testing.expectApproxEqAbs(caret.y, n.rect.y, 0.05);
        try testing.expectApproxEqAbs(lh, n.rect.h, 0.05);
        return;
    }
    return error.CaretNotPainted;
}

fn checkFont(multiline: bool, weight: types.Weight, mono: bool) !void {
    const first = "Wim iMW";
    const second = "miWW ii";
    var s: Form = .{ .opts = .{
        .width = .{ .px = 420 },
        .size = 24,
        .line_height = 36,
        .weight = weight,
        .mono = mono,
        .multiline = multiline,
    } };
    defer s.buf.deinit();
    s.buf.set(if (multiline) first ++ "\n" ++ second else first);
    s.buf.focus();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Form.view), .{ .width = 480 });
    defer t.deinit();
    t.frame(); // IME rectangles read the preceding frame's layout.
    const style = styleOf(s.opts);
    const one = try expectRun(&t, first, style);
    if (multiline) {
        const two = try expectRun(&t, second, style);
        try testing.expectEqual(@as(usize, 2), s.last.lines);
        try expectCaret(&t, two, second, second.len, style);
    } else try expectCaret(&t, one, first, first.len, style);

    // Pointer hit testing uses the same font as rendering and caretX.
    const x = t.text.caretX(first, style, 3);
    const index = t.text.indexAt(first, style, x);
    t.click(one.x + x, one.y + one.h / 2);
    try testing.expectEqual(index, s.last.caret);
    try expectCaret(&t, try expectRun(&t, first, style), first, index, style);
    if (multiline) {
        const down = t.text.indexAt(second, style, t.text.caretX(first, style, index));
        t.key(.down);
        try testing.expectEqual(first.len + 1 + down, s.last.caret);
        try expectCaret(&t, try expectRun(&t, second, style), second, down, style);
    }
}

test "text field font options preserve regular proportional defaults" {
    if (comptime !@hasField(field.Options, "weight") or !@hasField(field.Options, "mono")) return testing.expect(false);
    const opts: field.Options = .{};
    try testing.expectEqual(types.Weight.regular, opts.weight);
    try testing.expect(!opts.mono);
}

test "single and multiline fields paint and hit test with the selected font" {
    if (comptime !@hasField(field.Options, "weight") or !@hasField(field.Options, "mono")) return testing.expect(false);
    for ([_]bool{ false, true }) |multiline| {
        for ([_]types.Weight{ .regular, .bold }) |weight| {
            for ([_]bool{ false, true }) |mono| try checkFont(multiline, weight, mono);
        }
    }
}

test "multiline wrapping measures the selected font" {
    if (comptime !@hasField(field.Options, "weight") or !@hasField(field.Options, "mono")) return testing.expect(false);
    const str = "Wim iMW alpha beta end";
    var s: Form = .{ .opts = .{ .multiline = true, .size = 24, .weight = .bold, .mono = true } };
    defer s.buf.deinit();
    s.buf.set(str);
    s.buf.focus();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Form.view), .{});
    defer t.deinit();
    const style = styleOf(s.opts);
    const room = t.text.width("Wim iMW", style) + 1;
    s.opts.width = .{ .px = room + 20 }; // Non-bare fields have ten-point horizontal padding.
    t.frame();
    t.frame();
    const wrapped = t.text.wrap(str, style, room);
    try testing.expect(wrapped.len > 1);
    try testing.expectEqual(wrapped.len, s.last.lines);
    const last = wrapped[wrapped.len - 1];
    const run = try expectRun(&t, str[last.start..last.end], style);
    try expectCaret(&t, run, str[last.start..], str.len - last.start, style);
}

test "field placeholder suggestion and composition retain the selected font" {
    if (comptime !@hasField(field.Options, "weight") or !@hasField(field.Options, "mono")) return testing.expect(false);
    for ([_]bool{ false, true }) |multiline| {
        var s: Form = .{ .opts = .{
            .placeholder = "Command",
            .suggestion = " status",
            .width = .{ .px = 420 },
            .size = 24,
            .weight = .semibold,
            .mono = true,
            .multiline = multiline,
        } };
        defer s.buf.deinit();
        s.buf.focus();
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&s, Form.view), .{});
        defer t.deinit();
        const style = styleOf(s.opts);
        _ = try expectRun(&t, "Command", style);
        t.typeText("git");
        t.frame();
        const run = try expectRun(&t, "git", style);
        _ = try expectRun(&t, " status", style);
        try expectCaret(&t, run, "git", 3, style);
        t.textOps(&.{.{ .set_marked = .{ .text = "ii", .sel_start = 1, .sel_len = 0 } }});
        t.frame();
        try testing.expectEqualStrings("gitii", s.buf.text());
        try testing.expect(t.ctx.focused_text.?.marked != null);
        const marked = try expectRun(&t, "gitii", style);
        try expectCaret(&t, marked, "gitii", 4, style);
        t.textOps(&.{.{ .insert = "W" }});
        try testing.expectEqualStrings("gitW", s.buf.text());
        try testing.expect(t.ctx.focused_text.?.marked == null);
    }
}
