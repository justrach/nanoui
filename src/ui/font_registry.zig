//! Fonts an app brings (`ui.registerFont`): a TrueType or OpenType file's
//! bytes, kept by the app, found by family name like an installed font. On
//! macOS and iOS CoreText registers them for the process; where nanoui
//! reads fonts itself, its font database adds them before the system's.
const std = @import("std");
const builtin = @import("builtin");

const portable = @import("text.zig").portable;

pub var fonts: [64][]const u8 = undefined;
pub var count: usize = 0;

/// Registers the font file `bytes` (kept by the caller: an `@embedFile`).
/// False if it can't be read or too many are registered. Register fonts
/// before the windows that use them.
pub fn register(bytes: []const u8) bool {
    if (count == fonts.len) return false;
    if (!portable and !@import("fonts.zig").registerData(bytes)) return false;
    fonts[count] = bytes;
    count += 1;
    return true;
}

pub fn registered() []const []const u8 {
    return fonts[0..count];
}
