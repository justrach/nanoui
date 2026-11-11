//! Keys let go (`input.key_up`), all of them (`input.keys_released`) and
//! auto-repeat (`input.repeat`): edges a frame spends, that do not count as keyboard input (a key-up doesn't
//! wake the caret), and that the Tester delivers as a window does.
const std = @import("std");
const ui = @import("ui.zig");
const Input = @import("input.zig").Input;
const testing = std.testing;

test "clearEdges spends a key-up and the repeat flag, and keeps the modifiers" {
    var in: Input = .{};
    in.key_up = .{ .key = 'k', .shift = true };
    in.repeat = true;
    in.shift = true;
    in.clearEdges();
    try testing.expect(in.key_up == null);
    try testing.expect(!in.repeat);
    try testing.expect(in.shift);
}

test "a key-up alone is not keyboard input" {
    var in: Input = .{};
    in.key_up = .{ .key = ui.Shortcut.left };
    try testing.expect(!in.hasKeyboardInput());
    in.repeat = true;
    try testing.expect(!in.hasKeyboardInput());
    in.key = .left;
    try testing.expect(in.hasKeyboardInput());
}

const Held = struct {
    down: ?u21 = null,
    up: ?ui.Shortcut = null,
    repeats: u32 = 0,
    frames: u32 = 0,
    released: u32 = 0,
    shift_at_release: bool = false,
    /// Asks for a release while the frame is built, as a nested modal loop does.
    release_in_build: bool = false,

    fn view(h: *Held, c: *ui.Context) void {
        h.frames += 1;
        if (c.input.shortcut) |s| {
            h.down = s.key;
            if (c.input.repeat) h.repeats += 1;
            _ = c.shortcut(s);
        }
        if (c.input.key_up) |u| if (c.key_up_supported) {
            h.up = u;
        };
        if (c.input.keys_released) {
            h.released += 1;
            h.shift_at_release = c.input.shift;
            h.down = null;
        }
        if (h.release_in_build) {
            h.release_in_build = false;
            c.input.releaseKeys();
            c.changed = true;
        }
        ui.text(c, "held", .{});
    }
};

test "the Tester lets a key go for one frame, and reports no key-ups unless told" {
    var h: Held = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&h, Held.view), .{ .width = 200, .height = 100 });
    defer t.deinit();
    try testing.expect(!t.ctx.key_up_supported);
    t.keyUp(.{ .key = 'k' });
    try testing.expect(h.up == null);
    t.ctx.key_up_supported = true;
    try testing.expect(t.shortcut(.{ .key = 'k' }));
    try testing.expectEqual(@as(?u21, 'k'), h.down);
    t.ctx.input.repeat = true;
    _ = t.shortcut(.{ .key = 'k' });
    try testing.expectEqual(@as(u32, 1), h.repeats);
    // The frame spent it.
    try testing.expect(!t.ctx.input.repeat);
    t.keyUp(.{ .key = 'k', .alt = true });
    const up = h.up orelse return error.NoKeyUp;
    try testing.expectEqual(@as(u21, 'k'), up.key);
    try testing.expect(up.alt and !up.shift);
    try testing.expect(t.ctx.input.key_up == null);
    // The next frame sees no key let go.
    h.up = null;
    t.frame();
    try testing.expect(h.up == null);
}

test "releaseKeys: one frame lets every key go, the modifiers up; asked mid-build, the rebuild has it" {
    var h: Held = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&h, Held.view), .{ .width = 200, .height = 100 });
    defer t.deinit();
    t.ctx.key_up_supported = true;
    _ = t.shortcut(.{ .key = 'j' });
    try testing.expectEqual(@as(?u21, 'j'), h.down);
    t.ctx.input.shift = true;
    t.releaseKeys();
    try testing.expectEqual(@as(u32, 1), h.released);
    try testing.expect(!h.shift_at_release);
    try testing.expect(h.down == null);
    try testing.expect(!t.ctx.input.keys_released and !t.ctx.input.keys_release_pending);
    t.frame();
    try testing.expectEqual(@as(u32, 1), h.released);
    // A release asked while the view builds (a menu's loop inside it).
    h.release_in_build = true;
    t.frame();
    try testing.expectEqual(@as(u32, 2), h.released);
    try testing.expect(!t.ctx.input.keys_released and !t.ctx.input.keys_release_pending);
}
