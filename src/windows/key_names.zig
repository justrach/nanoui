//! Windows' virtual keys as nanoui names them, platform-free and tested on
//! every platform: the characters a key combination is offered with
//! (letters and digits lowered, the punctuation keys), the keys
//! `input.key_up` names (`Shortcut.left`, `Shortcut.f(n)`, …), the
//! modifier keys, and the auto-repeat bit of a key message's lParam.
const std = @import("std");
const S = @import("../ui/input.zig").Shortcut;

/// The character a letter, digit or punctuation key offers a combination
/// with, unshifted (Shift+1 is '1'); 0 for the others. Other characters
/// come as WM_CHAR.
pub fn letter(vk: u32) u21 {
    if ((vk >= 'A' and vk <= 'Z') or (vk >= '0' and vk <= '9')) return std.ascii.toLower(@intCast(vk));
    return switch (vk) {
        0xBC => ',',
        0xBE => '.',
        0xBF => '/',
        0xDB => '[',
        0xDD => ']',
        0xDC => '\\',
        0xBD => '-',
        0xBB => '=',
        0x20 => ' ',
        else => 0,
    };
}

/// A key that is not a character, as a shortcut names it; 0 for the rest.
pub fn named(vk: u32) u21 {
    return switch (vk) {
        0x25 => S.left,
        0x26 => S.up,
        0x27 => S.right,
        0x28 => S.down,
        0x09 => S.tab,
        0x1B => S.escape,
        0x0D => S.enter,
        0x08 => S.backspace,
        0x2E => S.forward_delete,
        0x24 => S.home,
        0x23 => S.end,
        0x21 => S.page_up,
        0x22 => S.page_down,
        0x70...0x83 => S.f(@intCast(vk - 0x70 + 1)),
        // The keypad's + and -: the zoom keys' other home.
        0x6B => '+',
        0x6D => '-',
        else => 0,
    };
}

/// The key `input.key_up` names for virtual key `vk`; 0 for keys it
/// names none for (the modifiers alone, media keys, …).
pub fn upKey(vk: u32) u21 {
    const n = named(vk);
    if (n != 0) return n;
    const l = letter(vk);
    if (l != 0) return l;
    // Keys whose characters come as WM_CHAR alone, never offered with
    // Control or Alt: named here so their release is not lost.
    return switch (vk) {
        0xBA => ';',
        0xDE => '\'',
        0xC0 => '`',
        else => 0,
    };
}

/// Shift, Control and Alt, either side or unsided: they change
/// `input.shift`/`ctrl`/`alt` and are no key of their own.
pub fn isModifier(vk: u32) bool {
    return vk == 0x10 or vk == 0x11 or vk == 0x12 or (vk >= 0xA0 and vk <= 0xA5);
}

/// A WM_KEYDOWN's (or WM_CHAR's) lParam bit 30: the key was already down,
/// so this is the system's auto-repeat.
pub fn isRepeat(lp: isize) bool {
    return (lp >> 30) & 1 != 0;
}

test "letters, digits and punctuation are offered lowered and unshifted" {
    try std.testing.expectEqual(@as(u21, 'j'), letter('J'));
    try std.testing.expectEqual(@as(u21, '1'), letter('1'));
    try std.testing.expectEqual(@as(u21, ','), letter(0xBC));
    try std.testing.expectEqual(@as(u21, '='), letter(0xBB));
    try std.testing.expectEqual(@as(u21, ' '), letter(0x20));
    try std.testing.expectEqual(@as(u21, 0), letter(0x25));
}

test "a key let go is named as a shortcut names it" {
    try std.testing.expectEqual(S.left, upKey(0x25));
    try std.testing.expectEqual(S.escape, upKey(0x1B));
    try std.testing.expectEqual(S.forward_delete, upKey(0x2E));
    try std.testing.expectEqual(S.f(1), upKey(0x70));
    try std.testing.expectEqual(S.f(12), upKey(0x7B));
    try std.testing.expectEqual(@as(u21, 'k'), upKey('K'));
    try std.testing.expectEqual(@as(u21, '+'), upKey(0x6B));
    try std.testing.expectEqual(@as(u21, ';'), upKey(0xBA));
    try std.testing.expectEqual(@as(u21, 0), letter(0xBA));
    // The modifiers alone, and keys with no name, are none.
    for ([_]u32{ 0x10, 0x11, 0x12, 0xA0, 0xA5, 0xAD }) |vk| try std.testing.expectEqual(@as(u21, 0), upKey(vk));
    try std.testing.expect(isModifier(0x12) and isModifier(0xA1) and !isModifier('A') and !isModifier(0xA6));
}

test "lParam bit 30 is the auto-repeat" {
    try std.testing.expect(!isRepeat(0x001E0001));
    try std.testing.expect(isRepeat(0x401E0001));
    // A key-up's bits 30 and 31 are both set; a sign-extended lParam too.
    try std.testing.expect(isRepeat(@as(isize, @bitCast(@as(usize, 0xC01E0001)))));
    try std.testing.expect(isRepeat(@as(i32, @bitCast(@as(u32, 0xC01E0001)))));
}
