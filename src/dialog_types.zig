//! Dialogs' options and answers, the same on every platform.
const std = @import("std");

/// A named group of file name extensions an open or save panel offers
/// ("All Media", "Audio", "Images"): the user picks one, and the panel shows
/// the files it names. Extensions without dots; none means every file.
pub const Filter = struct {
    name: []const u8,
    extensions: []const []const u8 = &.{},
};

pub const OpenOptions = struct {
    title: []const u8 = "",
    /// The button's label ("Open" by default).
    button: []const u8 = "",
    message: []const u8 = "",
    directory: []const u8 = "",
    files: bool = true,
    directories: bool = false,
    multiple: bool = false,
    /// File name extensions allowed, without dots: `&.{ "png", "jpg" }`.
    /// Ignored when `filters` names groups.
    extensions: []const []const u8 = &.{},
    /// Named groups the user picks between (a popup under the panel on
    /// macOS, the file type list on Windows); the first is shown first.
    filters: []const Filter = &.{},
    show_hidden: bool = false,
};

pub const SaveOptions = struct {
    title: []const u8 = "",
    button: []const u8 = "",
    message: []const u8 = "",
    directory: []const u8 = "",
    /// The file name the panel starts with.
    name: []const u8 = "",
    extensions: []const []const u8 = &.{},
    /// As `OpenOptions.filters`.
    filters: []const Filter = &.{},
    show_hidden: bool = false,
    create_directories: bool = true,
};

pub const MessageKind = enum { info, warning, critical };

pub const MessageOptions = struct {
    title: []const u8,
    detail: []const u8 = "",
    kind: MessageKind = .info,
    /// Button labels, the first the default; "OK" when empty.
    buttons: []const []const u8 = &.{},
    /// A checkbox under the detail ("Don't ask again"), off when empty.
    checkbox: []const u8 = "",
};

pub const MessageResult = struct {
    /// The index of the button pressed.
    button: usize,
    checked: bool = false,
};

pub fn freePaths(gpa: std.mem.Allocator, paths: []const []u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

/// The groups a panel offers: `filters`, else the plain `extensions` as one
/// unnamed group (none when both are empty).
pub fn groups(filters: []const Filter, extensions: []const []const u8, one: *[1]Filter) []const Filter {
    if (filters.len > 0) return filters;
    if (extensions.len == 0) return &.{};
    one[0] = .{ .name = "", .extensions = extensions };
    return one;
}

/// The groups as `OPENFILENAMEW.lpstrFilter` wants them: each name, then its
/// patterns (`*.mov;*.mp4`, `*.*` for a group without extensions), each
/// NUL-terminated, the list ended by a second NUL. A group without a name is
/// named by its patterns. Null when they do not fit in `buf`.
pub fn windowsFilter(buf: []u16, list: []const Filter) ?[]u16 {
    var n: usize = 0;
    for (list) |f| {
        if (f.name.len > 0) {
            if (!put(buf, &n, f.name)) return null;
        } else if (!patterns(buf, &n, f.extensions)) return null;
        if (!nul(buf, &n) or !patterns(buf, &n, f.extensions) or !nul(buf, &n)) return null;
    }
    if (!nul(buf, &n)) return null;
    return buf[0..n];
}

fn put(b: []u16, at: *usize, s: []const u8) bool {
    const view = std.unicode.Utf8View.init(s) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        var pair: [2]u16 = undefined;
        var len: usize = 1;
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            pair = .{ @intCast(0xD800 + (v >> 10)), @intCast(0xDC00 + (v & 0x3ff)) };
            len = 2;
        } else pair[0] = @intCast(cp);
        // One unit is always left for the NUL that follows.
        if (at.* + len >= b.len) return false;
        @memcpy(b[at.*..][0..len], pair[0..len]);
        at.* += len;
    }
    return true;
}

fn patterns(b: []u16, at: *usize, exts: []const []const u8) bool {
    if (exts.len == 0) return put(b, at, "*.*");
    for (exts, 0..) |e, i| {
        if (i > 0 and !put(b, at, ";")) return false;
        if (!put(b, at, "*.") or !put(b, at, e)) return false;
    }
    return true;
}

fn nul(b: []u16, at: *usize) bool {
    if (at.* >= b.len) return false;
    b[at.*] = 0;
    at.* += 1;
    return true;
}

test "groups: named filters, else the extensions as one group" {
    var one: [1]Filter = undefined;
    const named = [_]Filter{ .{ .name = "Audio", .extensions = &.{"wav"} }, .{ .name = "All" } };
    try std.testing.expectEqual(@as(usize, 2), groups(&named, &.{"png"}, &one).len);
    const plain = groups(&.{}, &.{ "png", "jpg" }, &one);
    try std.testing.expectEqual(@as(usize, 1), plain.len);
    try std.testing.expectEqualStrings("jpg", plain[0].extensions[1]);
    try std.testing.expectEqual(@as(usize, 0), groups(&.{}, &.{}, &one).len);
}

test "windowsFilter: names, patterns and the double NUL" {
    var buf: [128]u16 = undefined;
    const list = [_]Filter{ .{ .name = "All Media", .extensions = &.{ "mov", "mp4" } }, .{ .name = "Everything" }, .{ .name = "", .extensions = &.{"wav"} } };
    const got = windowsFilter(&buf, &list).?;
    const want = std.unicode.utf8ToUtf16LeStringLiteral("All Media\x00*.mov;*.mp4\x00Everything\x00*.*\x00*.wav\x00*.wav\x00\x00");
    try std.testing.expectEqualSlices(u16, want, got);
    var small: [8]u16 = undefined;
    try std.testing.expect(windowsFilter(&small, &list) == null);
}
