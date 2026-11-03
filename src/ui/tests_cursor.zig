//! The pointer over boxes and text: a control's label is the control's,
//! not text to select; a box drawn over text (a pill, a popover) takes the
//! pointer from the text beneath, and both answers agree between frames,
//! so the cursor never flickers. A box stays hovered while the pointer is
//! on a box inside it, so what it shows on hover stays.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

const Page = struct {
    clicks: u32 = 0,
    fn view(p: *Page, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        {
            const sel = ui.div(c).column().sizeFull().p(10);
            c.node(sel.index).style.selectable = true;
            defer sel.end();
            for (0..8) |_| ui.text(c, "output you can copy, line after line, under the pill", .{ .size = 13 });
            if (ui.button(c, "Copy output", .{ .size = 12 }).clicked) p.clicks += 1;
        }
        // Over the text, after it in the tree: drawn on top.
        const pill = ui.div(c).absolute().offset(60, 40).px(12).py(6).rounded(14).bg(c.theme.surface).hover(c.theme.accent);
        defer pill.end();
        if (pill.clicked()) p.clicks += 10;
        ui.text(c, "Jump to latest", .{ .size = 12 });
    }
};

/// Moves the pointer within one box as a surface does: a frame only when
/// the box under it changes, else the cursor from what was painted.
fn move(t: *ui.Tester, x: f32, y: f32) void {
    const before = t.ctx.hot;
    t.ctx.input.mouse = .{ .x = x, .y = y };
    t.ctx.updateHot();
    if (t.ctx.hot != before) t.frame() else t.ctx.cursor_text = t.ctx.pointerOverText();
}

test "a control's label is not text: the pointer is a hand all over it" {
    var p: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 420, .height = 360 });
    defer t.deinit();
    t.settle(1);
    const label = t.findText("Copy output").?;
    // Across the button, padding and label alike, frame after frame.
    var x = label.x - 8;
    while (x < label.x + label.w + 8) : (x += 3) {
        move(&t, x, label.y + label.h / 2);
        try testing.expect(!t.ctx.cursor_text);
        t.frame();
        try testing.expect(t.ctx.cursor_hand and !t.ctx.cursor_text);
    }
    try t.clickText("Copy output");
    try testing.expectEqual(@as(u32, 1), p.clicks);
}

test "a box over text takes the pointer from it" {
    var p: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 420, .height = 360 });
    defer t.deinit();
    t.settle(1);
    const pill = t.findText("Jump to latest").?;
    var x = pill.x;
    while (x < pill.x + pill.w) : (x += 3) {
        move(&t, x, pill.y + pill.h / 2);
        try testing.expect(!t.ctx.cursor_text);
        try testing.expect(!t.ctx.pointerOverText());
        // The hover animation's frames give the same answer.
        t.frame();
        try testing.expect(t.ctx.cursor_hand and !t.ctx.cursor_text);
    }
    // A click on it is its click, not the start of a selection.
    try t.clickText("Jump to latest");
    try testing.expectEqual(@as(u32, 10), p.clicks);
    // Beside it, the text is text again.
    const line = t.findText("output you can copy, line after line, under the pill").?;
    move(&t, line.x + 4, line.y + line.h / 2);
    try testing.expect(t.ctx.cursor_text);
}

const Row = struct {
    row_clicks: u32 = 0,
    button_clicks: u32 = 0,
    fn view(r: *Row, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(10);
        defer root.end();
        // A row that shows its buttons while hovered, as a block does.
        const row = ui.div(c).row().wFull().h(40).px(10).itemsCenter().gap(8).hover(c.theme.surface);
        defer row.end();
        if (row.clicked()) r.row_clicks += 1;
        ui.text(c, "git status", .{ .size = 13 });
        ui.spacer(c);
        if (row.hovered()) if (ui.button(c, "Rerun", .{ .size = 12 }).clicked) {
            r.button_clicks += 1;
        };
    }
};

test "a row stays hovered while the pointer is on its button, and the click is the button's" {
    var r: Row = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&r, Row.view), .{ .width = 420, .height = 200 });
    defer t.deinit();
    t.settle(1);
    try testing.expect(!t.hasText("Rerun"));
    const label = t.findText("git status").?;
    t.moveTo(label.x + 4, label.y + label.h / 2);
    t.settle(1);
    const button = t.findText("Rerun") orelse return error.NotShown;
    // On the button, frame after frame: it stays (it once came and went).
    t.moveTo(button.x + button.w / 2, button.y + button.h / 2);
    for (0..20) |_| {
        t.frame();
        try testing.expect(t.hasText("Rerun"));
    }
    try t.clickText("Rerun");
    try testing.expectEqual(@as(u32, 1), r.button_clicks);
    try testing.expectEqual(@as(u32, 0), r.row_clicks);
    try t.clickText("git status");
    try testing.expectEqual(@as(u32, 1), r.row_clicks);
}

const Menu = struct {
    asked: u32 = 0,
    clicks: u32 = 0,
    button_clicks: u32 = 0,
    focused_field: bool = false,
    field: ui.TextBuffer = .{},

    fn view(m: *Menu, c: *ui.Context) void {
        const root = ui.div(c).column().p(20).gap(8);
        defer root.end();
        _ = ui.textField(c, &m.field, .{ .placeholder = "note" });
        const row = ui.div(c).row().p(8).gap(8).itemsCenter().hover(c.theme.surface);
        defer row.end();
        ui.text(c, "release notes", .{ .size = 13 });
        if (ui.button(c, "Open", .{ .size = 12 }).clicked) m.button_clicks += 1;
        if (row.secondaryClicked()) m.asked += 1;
        if (row.clicked()) m.clicks += 1;
    }
};

test "a right-click asks for a box's context menu, from inside it too, and is no click" {
    var m: Menu = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&m, Menu.view), .{ .width = 420, .height = 200 });
    defer t.deinit();
    t.settle(1);
    const label = t.findText("release notes").?;
    t.secondaryClick(label.x + 4, label.y + label.h / 2);
    try testing.expectEqual(@as(u32, 1), m.asked);
    try testing.expectEqual(@as(u32, 0), m.clicks);
    // Once: the next frame doesn't ask again.
    t.settle(1);
    try testing.expectEqual(@as(u32, 1), m.asked);
    // On the row's button, the row's menu still; the button isn't clicked.
    const open = t.findText("Open").?;
    t.secondaryClick(open.x + open.w / 2, open.y + open.h / 2);
    try testing.expectEqual(@as(u32, 2), m.asked);
    try testing.expectEqual(@as(u32, 0), m.button_clicks);
    // Outside the row, nothing; a left click is a click, not a menu.
    t.secondaryClick(400, 190);
    try testing.expectEqual(@as(u32, 2), m.asked);
    t.click(label.x + 4, label.y + label.h / 2);
    try testing.expectEqual(@as(u32, 1), m.clicks);
    try testing.expectEqual(@as(u32, 2), m.asked);
}

test "a right-click keeps the focus where it was" {
    var m: Menu = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&m, Menu.view), .{ .width = 420, .height = 200 });
    defer t.deinit();
    t.settle(1);
    try t.clickText("note");
    t.settle(1);
    const before = t.ctx.focus;
    try testing.expect(before != 0);
    t.secondaryClick(400, 190);
    try testing.expectEqual(before, t.ctx.focus);
}
