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

test "labels" {
    if (mac) {
        try std.testing.expectEqualStrings("⌘⇧M", label("⌘⇧M"));
    } else {
        try std.testing.expectEqualStrings("Ctrl+Shift+M", label("⌘⇧M"));
        try std.testing.expectEqualStrings("Ctrl+=", label("⌘⌃="));
        try std.testing.expectEqualStrings("Ctrl+I switches.", label("⌘I switches."));
    }
}
