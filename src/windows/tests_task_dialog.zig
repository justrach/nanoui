//! Message boxes: the task dialog a message asks for, the answers mapped
//! back to the caller's buttons, and one dialog shown and driven on a
//! desktop of its own, never the one on screen.
const std = @import("std");
const testing = std.testing;
const w = @import("win32.zig");
const dialog = @import("dialog.zig");
const task_dialog = @import("task_dialog.zig");
const L = std.unicode.utf8ToUtf16LeStringLiteral;

test "a message's task dialog has the caller's labels, the first the default" {
    var texts: task_dialog.Texts = .{};
    const c = task_dialog.setUp(.{ .title = "Delete it?", .detail = "It can't be undone.", .kind = .warning, .buttons = &.{ "Cancel", "Delete" }, .checkbox = "Don't ask again" }, &texts, null, null);
    try testing.expectEqual(@as(u32, 2), c.button_count);
    try testing.expectEqual(task_dialog.first_id, c.default_button);
    try testing.expectEqual(@as(u32, 0), c.common_buttons);
    try testing.expectEqualSlices(u16, L("Cancel"), std.mem.span(c.buttons.?[0].text));
    try testing.expectEqualSlices(u16, L("Delete"), std.mem.span(c.buttons.?[1].text));
    try testing.expectEqual(task_dialog.first_id + 1, c.buttons.?[1].id);
    try testing.expectEqualSlices(u16, L("Don't ask again"), std.mem.span(c.verification.?));
    try testing.expectEqualSlices(u16, L("It can't be undone."), std.mem.span(c.content.?));
    try testing.expectEqual(task_dialog.icon(.warning), c.main_icon);
    // A Cancel button: Esc and the close box answer it.
    try testing.expect(c.flags & task_dialog.tdf.allow_cancellation != 0);

    // No labels: the system's OK, which Esc answers too; no checkbox.
    var ok_texts: task_dialog.Texts = .{};
    const ok = task_dialog.setUp(.{ .title = "Done" }, &ok_texts, null, null);
    try testing.expectEqual(@as(u32, 0), ok.button_count);
    try testing.expectEqual(task_dialog.tdf.ok_button, ok.common_buttons);
    try testing.expect(ok.flags & task_dialog.tdf.allow_cancellation != 0);
    try testing.expect(ok.verification == null and ok.content == null);

    // Neither a Cancel button nor only one: Esc and the close box do nothing.
    var yn_texts: task_dialog.Texts = .{};
    const yn = task_dialog.setUp(.{ .title = "Replace?", .buttons = &.{ "Replace", "Keep Both" } }, &yn_texts, null, null);
    try testing.expectEqual(@as(u32, 0), yn.flags & task_dialog.tdf.allow_cancellation);
}

test "a task dialog's answer is the index of the button pressed" {
    const mac = &[_][]const u8{ "Cancel", "Delete" };
    try testing.expectEqual(@as(usize, 0), task_dialog.answer(task_dialog.first_id, mac));
    try testing.expectEqual(@as(usize, 1), task_dialog.answer(task_dialog.first_id + 1, mac));
    // Esc or the close box: the Cancel button, wherever it is.
    try testing.expectEqual(@as(usize, 0), task_dialog.answer(task_dialog.id_cancel, mac));
    const win = &[_][]const u8{ "Save", "Don't Save", "cancel" };
    try testing.expectEqual(@as(usize, 2), task_dialog.answer(task_dialog.id_cancel, win));
    // The system's OK, for no labels.
    try testing.expectEqual(@as(usize, 0), task_dialog.answer(task_dialog.id_ok, &.{}));
    try testing.expectEqual(@as(usize, 0), task_dialog.answer(task_dialog.id_cancel, &.{}));
    try testing.expectEqual(@as(?usize, null), task_dialog.cancelIndex(&.{ "Yes", "No" }));
    try testing.expectEqual(@as(?usize, 0), task_dialog.cancelIndex(&.{"Close"}));
}

test "without task dialogs, the system's buttons answer the labels they stand for" {
    // The Mac's order: Cancel first, the default (MB_DEFBUTTON2); OK is the action.
    const mac = dialog.boxFor(&.{ "Cancel", "Delete" });
    try testing.expectEqual(@as(u32, 1 | 0x100), mac.style);
    try testing.expectEqual(@as(usize, 1), mac.answer(1));
    try testing.expectEqual(@as(usize, 0), mac.answer(2));
    // Windows' order: the action first.
    const win = dialog.boxFor(&.{ "Delete", "Cancel" });
    try testing.expectEqual(@as(u32, 1), win.style);
    try testing.expectEqual(@as(usize, 0), win.answer(1));
    try testing.expectEqual(@as(usize, 1), win.answer(2));
    // No Cancel: Yes/No, which Esc and the close box can't answer.
    const yn = dialog.boxFor(&.{ "Replace", "Keep Both" });
    try testing.expectEqual(@as(u32, 4), yn.style);
    try testing.expectEqual(@as(?usize, null), yn.cancel);
    try testing.expectEqual(@as(usize, 0), yn.answer(6));
    try testing.expectEqual(@as(usize, 1), yn.answer(7));
    // Three: Yes/No/Cancel, Cancel wherever its label is.
    const three = dialog.boxFor(&.{ "Save", "Don't Save", "Cancel" });
    try testing.expectEqual(@as(u32, 3), three.style);
    try testing.expectEqual(@as(usize, 0), three.answer(6));
    try testing.expectEqual(@as(usize, 1), three.answer(7));
    try testing.expectEqual(@as(usize, 2), three.answer(2));
    const first = dialog.boxFor(&.{ "Cancel", "Save", "Don't Save" });
    try testing.expectEqual(@as(u32, 3 | 0x200), first.style);
    try testing.expectEqual(@as(usize, 1), first.answer(6));
    try testing.expectEqual(@as(usize, 2), first.answer(7));
    try testing.expectEqual(@as(usize, 0), first.answer(2));
    // Three without Cancel: Abort/Retry/Ignore, no Esc.
    const ari = dialog.boxFor(&.{ "Merge", "Replace", "Skip" });
    try testing.expectEqual(@as(u32, 2), ari.style);
    try testing.expectEqual(@as(usize, 2), ari.answer(5));
    try testing.expectEqual(@as(?usize, null), ari.cancel);
    try testing.expectEqual(@as(usize, 0), dialog.boxFor(&.{}).answer(1));
    try testing.expectEqual(@as(usize, 0), dialog.boxFor(&.{"OK"}).answer(2));
}

test "a label's ampersands show as written, and the caption falls back to the program's name" {
    var buf: [64]u16 = undefined;
    try testing.expectEqualSlices(u16, L("Save && Close"), std.mem.span(task_dialog.literal(&buf, "Save & Close")));
    var path: [64]u16 = undefined;
    const exe = L("C:\\Apps\\my.app\\Notes.exe");
    @memcpy(path[0..exe.len], exe);
    try testing.expectEqualSlices(u16, L("Notes"), task_dialog.programName(&path, exe.len));
    const bare = L("tool");
    @memcpy(path[0..bare.len], bare);
    try testing.expectEqualSlices(u16, L("tool"), task_dialog.programName(&path, bare.len));
    // No owner: the test runner's own name.
    try testing.expect(std.mem.span(task_dialog.caption(null, &buf)).len > 0);
}

extern "user32" fn CreateDesktopW(name: [*:0]const u16, device: ?*anyopaque, mode: ?*anyopaque, flags: u32, access: u32, attrs: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn SetThreadDesktop(desktop: *anyopaque) callconv(.winapi) w.BOOL;
extern "user32" fn CloseDesktop(desktop: *anyopaque) callconv(.winapi) w.BOOL;
extern "user32" fn EnumChildWindows(parent: w.HWND, proc: *const fn (w.HWND, w.LPARAM) callconv(.winapi) w.BOOL, lp: w.LPARAM) callconv(.winapi) w.BOOL;
extern "user32" fn GetWindowTextW(hwnd: w.HWND, buf: [*]u16, len: i32) callconv(.winapi) i32;
extern "user32" fn GetFocus() callconv(.winapi) ?w.HWND;

/// A dialog driven from its own callback: what it tries first (Esc, the
/// close box), then the button it clicks, and what it saw.
const Drive = struct {
    labels: []const []const u8,
    first: enum { none, escape, close } = .none,
    click: i32,
    check: bool = false,
    clicked: [8]i32 = @splat(0),
    clicks: usize = 0,
    clicked_late: bool = false,
    shown: usize = 0,

    fn callback(hwnd: w.HWND, note: u32, wp: w.WPARAM, _: w.LPARAM, data: isize) callconv(.winapi) i32 {
        const d: *Drive = @ptrFromInt(@as(usize, @bitCast(data)));
        switch (note) {
            // TDN_CREATED: the buttons as shown, then the user's moves.
            0 => {
                _ = EnumChildWindows(hwnd, &seen, data);
                if (d.check) _ = w.SendMessageW(hwnd, 0x400 + 113, 1, 0); // TDM_CLICK_VERIFICATION
                // Queued, as the user's are, through the dialog's own loop.
                switch (d.first) {
                    .none => {},
                    .escape => _ = w.PostMessageW(GetFocus() orelse hwnd, 0x100, 0x1b, 0x00010001), // WM_KEYDOWN VK_ESCAPE
                    .close => _ = w.PostMessageW(hwnd, 0x10, 0, 0), // WM_CLOSE
                }
            },
            // TDN_BUTTON_CLICKED.
            2 => if (d.clicks < d.clicked.len) {
                d.clicked[d.clicks] = @intCast(wp);
                d.clicks += 1;
            },
            // TDN_TIMER, every 200 ms: the click, for a dialog the first
            // move left open.
            4 => if (wp >= 400 and !d.clicked_late) {
                d.clicked_late = true;
                _ = w.SendMessageW(hwnd, 0x400 + 102, @intCast(d.click), 0); // TDM_CLICK_BUTTON
            },
            else => {},
        }
        return 0;
    }

    fn seen(child: w.HWND, data: w.LPARAM) callconv(.winapi) w.BOOL {
        const d: *Drive = @ptrFromInt(@as(usize, @bitCast(data)));
        var buf: [128]u16 = undefined;
        const n = GetWindowTextW(child, &buf, buf.len);
        if (n <= 0) return 1;
        var utf8: [256]u8 = undefined;
        const len = std.unicode.utf16LeToUtf8(&utf8, buf[0..@intCast(n)]) catch return 1;
        for (d.labels) |l| {
            if (std.mem.eql(u8, l, utf8[0..len])) d.shown += 1;
        }
        return 1;
    }
};

const Run = struct { e: task_dialog.Entry, desktop: *anyopaque, opts: dialog.MessageOptions, drive: *Drive, got: ?task_dialog.Pressed = null };

/// On a thread of its own, which has no windows yet and so may move to
/// the hidden desktop.
fn runOnDesktop(r: *Run) void {
    if (SetThreadDesktop(r.desktop) == 0) return;
    var texts: task_dialog.Texts = .{};
    var c = task_dialog.setUp(r.opts, &texts, null, L("nanoui tests"));
    c.flags |= 0x800; // TDF_CALLBACK_TIMER
    c.callback = &Drive.callback;
    c.callback_data = @bitCast(@intFromPtr(r.drive));
    r.got = task_dialog.run(r.e, &c);
}

fn drive(e: task_dialog.Entry, desktop: *anyopaque, opts: dialog.MessageOptions, d: *Drive) !task_dialog.Pressed {
    var r: Run = .{ .e = e, .desktop = desktop, .opts = opts, .drive = d };
    const t = try std.Thread.spawn(.{}, runOnDesktop, .{&r});
    t.join();
    return r.got orelse error.DialogFailed;
}

test "a task dialog on a desktop nobody sees shows the labels and answers the button pressed" {
    // comctl32 6, through shell32's activation context.
    const e = task_dialog.entry() orelse return error.TaskDialogUnavailable;
    // Its own desktop, never the one on screen.
    const desktop = CreateDesktopW(L("nanoui-tests-dialog"), null, null, 0, 0x10000000, null) orelse return error.SkipZigTest;
    defer _ = CloseDesktop(desktop);

    const mac = &[_][]const u8{ "Cancel", "Delete" };
    var d: Drive = .{ .labels = mac, .click = task_dialog.first_id + 1, .check = true };
    var got = try drive(e, desktop, .{ .title = "Delete it?", .buttons = mac, .checkbox = "Don't ask again" }, &d);
    try testing.expectEqual(@as(usize, 2), d.shown);
    try testing.expectEqual(@as(usize, 1), task_dialog.answer(got.id, mac));
    try testing.expect(got.checked);

    // Esc and the close box answer Cancel, the first label here, before
    // the click comes.
    inline for (.{ .escape, .close }) |first| {
        d = .{ .labels = mac, .first = first, .click = task_dialog.first_id + 1 };
        got = try drive(e, desktop, .{ .title = "Delete it?", .buttons = mac }, &d);
        try testing.expectEqual(task_dialog.id_cancel, got.id);
        try testing.expect(!d.clicked_late);
        try testing.expectEqual(@as(usize, 0), task_dialog.answer(got.id, mac));
        try testing.expect(!got.checked);
    }

    // Without a Cancel button they do nothing: the click answers.
    const yn = &[_][]const u8{ "Replace", "Keep Both" };
    inline for (.{ .escape, .close }) |first| {
        d = .{ .labels = yn, .first = first, .click = task_dialog.first_id + 1 };
        got = try drive(e, desktop, .{ .title = "Replace it?", .buttons = yn }, &d);
        try testing.expect(d.clicked_late);
        try testing.expectEqualSlices(i32, &.{task_dialog.first_id + 1}, d.clicked[0..d.clicks]);
        try testing.expectEqual(@as(usize, 1), task_dialog.answer(got.id, yn));
    }

    // No labels: the system's OK, which Esc answers.
    d = .{ .labels = &.{}, .first = .escape, .click = task_dialog.id_ok };
    got = try drive(e, desktop, .{ .title = "Done" }, &d);
    try testing.expect(!d.clicked_late);
    try testing.expectEqual(@as(usize, 0), task_dialog.answer(got.id, &.{}));
}
