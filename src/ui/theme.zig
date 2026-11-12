//! The colors of native UI, light and dark, following the system appearance.
const std = @import("std");
const types = @import("types.zig");
const Color = types.Color;

pub const Theme = struct {
    dark: bool,
    background: Color,
    surface: Color,
    surface_hover: Color,
    text: Color,
    muted: Color,
    border: Color,
    accent: Color,
    accent_hover: Color,
    accent_text: Color,
    track: Color,
    knob: Color,
    danger: Color,
    success: Color,
    shadow: Color,
    /// Font families: text, and monospaced text (null: the system's, SF
    /// Pro and SF Mono). A family that is not installed falls back.
    font: ?[]const u8 = null,
    mono_font: ?[]const u8 = null,

    pub const light: Theme = .{
        .dark = false,
        .background = .hex(0xf5f5f7),
        .surface = .hex(0xffffff),
        .surface_hover = .hex(0xececf0),
        .text = .hex(0x1d1d1f),
        .muted = .hex(0x6e6e73),
        .border = .hex(0xd2d2d7),
        .accent = .hex(0x0a84ff),
        .accent_hover = .hex(0x0071e3),
        .accent_text = .white,
        .track = .hex(0xe0e0e5),
        .knob = .white,
        .danger = .hex(0xff3b30),
        .success = .hex(0x34c759),
        .shadow = .{ .a = 0.12 },
    };

    pub const dark_theme: Theme = .{
        .dark = true,
        .background = .hex(0x1c1c1e),
        .surface = .hex(0x2c2c2e),
        .surface_hover = .hex(0x3a3a3c),
        .text = .hex(0xf5f5f7),
        .muted = .hex(0x98989d),
        .border = .hex(0x48484a),
        .accent = .hex(0x0a84ff),
        .accent_hover = .hex(0x409cff),
        .accent_text = .white,
        .track = .hex(0x48484a),
        .knob = .hex(0xf5f5f7),
        .danger = .hex(0xff453a),
        .success = .hex(0x30d158),
        .shadow = .{ .a = 0.4 },
    };
};

/// Whether two theme choices pick the same theme (both null: the system's).
pub fn sameChoice(a: ?Theme, b: ?Theme) bool {
    const an = a orelse return b == null;
    const bn = b orelse return false;
    return std.meta.eql(an, bn);
}

test "sameChoice sees null as the system's" {
    const testing = std.testing;
    try testing.expect(sameChoice(null, null));
    try testing.expect(!sameChoice(Theme.light, null));
    try testing.expect(!sameChoice(null, Theme.dark_theme));
    try testing.expect(sameChoice(Theme.light, Theme.light));
    try testing.expect(!sameChoice(Theme.light, Theme.dark_theme));
}
