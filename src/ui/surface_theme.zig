//! The macOS surface's theme and matching AppKit window appearance.
const std = @import("std");
const objc = @import("../objc.zig");
const Theme = @import("theme.zig").Theme;
const Surface = @import("surface.zig").Surface;

pub const Appearance = enum { unset, system, light, dark };

pub fn refresh(self: *Surface) void {
    const appearance = objc.msg(objc.Object, self.nsview, "effectiveAppearance", .{});
    const name = objc.fromNSString(objc.msg(?objc.Object, appearance, "name", .{}));
    self.cached_theme = if (std.mem.indexOf(u8, name, "Dark") != null) Theme.dark_theme else Theme.light;
}

pub fn theme(self: *Surface) Theme {
    return self.theme_override orelse self.theme_chosen orelse self.cached_theme;
}

/// Keeps the title bar and AppKit controls in sync; auto inherits again.
pub fn apply(self: *Surface) void {
    const forced = self.theme_override orelse self.theme_chosen;
    const want: Appearance = if (forced) |t| (if (t.dark) .dark else .light) else .system;
    if (want == self.applied_appearance) return;
    self.applied_appearance = want;
    const name: ?[]const u8 = switch (want) {
        .dark => "NSAppearanceNameDarkAqua",
        .light => "NSAppearanceNameAqua",
        .system => null,
        .unset => unreachable,
    };
    const appearance: ?objc.Object = if (name) |n| objc.msg(?objc.Object, objc.class("NSAppearance"), "appearanceNamed:", .{objc.nsString(n)}) else null;
    objc.msg(void, self.window.nswindow, "setAppearance:", .{appearance});
    // Auto falls back to what the window inherits now.
    refresh(self);
}
