//! Key combinations as each platform writes them: the Mac's symbols
//! (⌘⇧M) where they are the norm, words elsewhere (Ctrl+Shift+M), where
//! Command shortcuts are Control ones.
const std = @import("std");
const builtin = @import("builtin");

/// Whether this platform's command key is Command (macOS, and iOS with a
/// keyboard) or Control.
pub const mac = builtin.os.tag == .macos or builtin.os.tag == .ios;

/// `s` (written with the Mac's ⌘ ⌃ ⌥ ⇧) as this platform shows it.
pub fn label(comptime s: []const u8) []const u8 {
    if (mac) return s;
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var out: []const u8 = "";
        var i: usize = 0;
        while (i < s.len) {
            const rest = s[i..];
            const subs = .{ .{ "⌘", "Ctrl+" }, .{ "⌃", "Ctrl+" }, .{ "⌥", "Alt+" }, .{ "⇧", "Shift+" } };
            var matched = false;
            for (subs) |sub| if (std.mem.startsWith(u8, rest, sub[0])) {
                // ⌘⌃ is one Ctrl here.
                if (!std.mem.endsWith(u8, out, sub[1])) out = out ++ sub[1];
                i += sub[0].len;
                matched = true;
                break;
            };
            if (!matched) {
                out = out ++ s[i .. i + 1];
                i += 1;
            }
        }
        break :blk out;
    };
}

/// While true, the menu bar's key equivalents are held back: a view that
/// captures key combinations (a shortcut editor) gets ⌘ chords as its
/// own shortcuts, and the main menu's `performKeyEquivalent:` says no.
pub var menu_key_equivalents_suspended: bool = false;

/// Holds the menu bar's key equivalents back (`true`) or lets them work
/// again. Main thread. No effect where nanoui has no native menu bar.
pub fn suspendMenuKeyEquivalents(on: bool) void {
    menu_key_equivalents_suspended = on;
}

/// The key a shifted punctuation mark is typed with on a US keyboard
/// (`!` is Shift+1), or null: menus and shortcuts name the unshifted key.
pub fn unshiftedUs(cp: u21) ?u21 {
    const pairs = [_][2]u21{
        .{ '!', '1' },  .{ '@', '2' }, .{ '#', '3' },  .{ '$', '4' }, .{ '%', '5' },
        .{ '^', '6' },  .{ '&', '7' }, .{ '*', '8' },  .{ '(', '9' }, .{ ')', '0' },
        .{ '~', '`' },  .{ '_', '-' }, .{ '+', '=' },  .{ '{', '[' }, .{ '}', ']' },
        .{ '|', '\\' }, .{ ':', ';' }, .{ '"', '\'' }, .{ '<', ',' }, .{ '>', '.' },
        .{ '?', '/' },
    };
    for (pairs) |p| if (p[0] == cp) return p[1];
    return null;
}

/// The unshifted character of a Mac virtual key code on an ANSI keyboard
/// (digits, punctuation), or 0: what Shift+key is offered as when the
/// keyboard layout can't say.
pub fn ansiChar(code: u16) u21 {
    return switch (code) {
        18 => '1',
        19 => '2',
        20 => '3',
        21 => '4',
        23 => '5',
        22 => '6',
        26 => '7',
        28 => '8',
        25 => '9',
        29 => '0',
        27 => '-',
        24 => '=',
        33 => '[',
        30 => ']',
        42 => '\\',
        41 => ';',
        39 => '\'',
        43 => ',',
        47 => '.',
        44 => '/',
        50 => '`',
        else => 0,
    };
}

test "shifted punctuation names its key" {
    try std.testing.expectEqual(@as(?u21, '1'), unshiftedUs('!'));
    try std.testing.expectEqual(@as(?u21, null), unshiftedUs('a'));
    try std.testing.expectEqual(@as(u21, '1'), ansiChar(18));
}

test "labels" {
    if (mac) {
        try std.testing.expectEqualStrings("⌘⇧M", label("⌘⇧M"));
    } else {
        try std.testing.expectEqualStrings("Ctrl+Shift+M", label("⌘⇧M"));
        try std.testing.expectEqualStrings("Ctrl+=", label("⌘⌃="));
        try std.testing.expectEqualStrings("Ctrl+I switches.", label("⌘I switches."));
    }
}
