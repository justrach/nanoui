//! A hidden Windows surface's key messages: keys let go (WM_KEYUP), the
//! auto-repeat bit, the modifier keys alone, every key let go when the
//! keyboard goes elsewhere, and what Alt leaves to DefWindowProc (Alt+F4,
//! the window menu, WM_SYSCHAR's beep).
const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const w = @import("win32.zig");
const App = @import("app.zig").App;

const Seen = struct {
    up: ?ui.Shortcut = null,
    repeat: bool = false,
    mods: u32 = 0,
    released: u32 = 0,

    fn view(s: *Seen, c: *ui.Context) void {
        if (c.input.key_up) |u| s.up = u;
        if (c.input.mods_changed) s.mods += 1;
        if (c.input.keys_released) s.released += 1;
        if (c.input.key != null) s.repeat = c.input.repeat;
        ui.text(c, "keys", .{});
    }
};

test "key messages: a key let go, the repeat bit, modifiers alone, Alt's system keys" {
    const gpa = testing.allocator;
    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .options = .{ .quit_on_last_window_closed = false },
        .flags = .{ .hidden = true },
        .gui = true,
    };
    defer app.destroy();
    var seen: Seen = .{};
    const win = try app.newWindow(.{ .title = "keys", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&seen, Seen.view) } });
    const h = win.hwnd orelse return error.SkipZigTest;
    const s = win.surface.?;
    try testing.expect(s.ctx.key_up_supported);

    // K let go: named as a shortcut names it, for one frame.
    try testing.expectEqual(@as(?w.LRESULT, 0), s.handle(h, w.WM_KEYUP, 'K', 0xC0250001));
    try testing.expectEqual(@as(u21, 'k'), seen.up.?.key);
    try testing.expect(s.ctx.input.key_up == null);
    seen.up = null;
    _ = s.handle(h, w.WM_KEYUP, 0x25, 0xC14B0001);
    try testing.expectEqual(ui.Shortcut.left, seen.up.?.key);

    // ← held: its repeats say so, and the frame spends the flag.
    _ = s.handle(h, w.WM_KEYDOWN, 0x25, 0x014B0001);
    try testing.expect(!seen.repeat);
    _ = s.handle(h, w.WM_KEYDOWN, 0x25, 0x414B0001);
    try testing.expect(seen.repeat);
    try testing.expect(!s.ctx.input.repeat);

    // Shift alone: a frame with mods_changed down and up, none for its repeats.
    const before = seen.mods;
    try testing.expectEqual(@as(?w.LRESULT, null), s.handle(h, w.WM_KEYDOWN, 0x10, 0x002A0001));
    _ = s.handle(h, w.WM_KEYDOWN, 0x10, 0x402A0001);
    try testing.expectEqual(before + 1, seen.mods);
    try testing.expectEqual(@as(?w.LRESULT, null), s.handle(h, w.WM_KEYUP, 0x10, 0xC02A0001));
    try testing.expectEqual(before + 2, seen.mods);
    try testing.expect(seen.up.?.key == ui.Shortcut.left);

    // Alt+F4 is the system's; so is Alt's window menu, unless Alt was used.
    try testing.expectEqual(@as(?w.LRESULT, null), s.handle(h, w.WM_SYSKEYDOWN, 0x73, 0x203E0001));
    s.alt_used = true;
    try testing.expectEqual(@as(?w.LRESULT, 0), s.handle(h, w.WM_SYSKEYUP, 0x12, 0xC0380001));
    try testing.expect(!s.alt_used);
    try testing.expectEqual(@as(?w.LRESULT, null), s.handle(h, w.WM_SYSKEYUP, 0x12, 0xC0380001));

    // A WM_SYSCHAR after a combination the view took is not a mnemonic.
    try testing.expectEqual(@as(?w.LRESULT, null), s.handle(h, w.WM_SYSCHAR, '1', 0x20020001));
    s.sys_taken = true;
    try testing.expectEqual(@as(?w.LRESULT, 0), s.handle(h, w.WM_SYSCHAR, '1', 0x20020001));
    try testing.expect(!s.sys_taken);

    // Alt+Tab away: the keys and Alt's gestures are let go, in.alt with them.
    s.ctx.input.alt = true;
    s.alt_used = true;
    _ = s.handle(h, w.WM_KILLFOCUS, 0, 0);
    try testing.expectEqual(@as(u32, 1), seen.released);
    try testing.expect(!s.ctx.input.alt and !s.alt_used and !s.ctx.input.keys_released);
    // A menu's or a dialog's modal loop does the same, and DefWindowProc runs.
    try testing.expectEqual(@as(?w.LRESULT, null), s.handle(h, w.WM_ENTERMENULOOP, 0, 0));
    try testing.expectEqual(@as(?w.LRESULT, null), s.handle(h, w.WM_CANCELMODE, 0, 0));
    try testing.expectEqual(@as(u32, 3), seen.released);
}

test "native key-ups pumped during a Windows view build are delivered in order" {
    const Nested = struct {
        surface: ?*@import("surface.zig").Surface = null,
        send: bool = false,
        count: usize = 0,
        seen: [2]u21 = @splat(0),
        fn view(n: *@This(), c: *ui.Context) void {
            if (c.input.key_up) |up| {
                n.seen[n.count] = up.key;
                n.count += 1;
            }
            if (n.send) {
                n.send = false;
                const s = n.surface.?;
                const h = s.window.hwnd.?;
                _ = s.handle(h, w.WM_KEYUP, 'K', 0xC0250001);
                _ = s.handle(h, w.WM_KEYUP, 'L', 0xC0260001);
            }
            ui.text(c, "nested", .{});
        }
    };
    const app = try testing.allocator.create(App);
    app.* = .{
        .gpa = testing.allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .options = .{ .quit_on_last_window_closed = false },
        .flags = .{ .hidden = true },
        .gui = true,
    };
    defer app.destroy();
    var nested: Nested = .{};
    const win = try app.newWindow(.{ .title = "nested keys", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&nested, Nested.view) } });
    nested.surface = win.surface.?;
    nested.send = true;
    nested.surface.?.frame();
    try testing.expectEqual(@as(usize, 2), nested.count);
    try testing.expectEqualSlices(u21, &.{ 'k', 'l' }, &nested.seen);
    nested.surface.?.frame();
    try testing.expectEqual(@as(usize, 2), nested.count);
}
