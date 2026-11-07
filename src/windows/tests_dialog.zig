//! The open dialog without showing it: what it was asked for, read back from
//! the dialog itself, and the paths out of a shell item array.
const std = @import("std");
const testing = std.testing;
const w = @import("win32.zig");
const dialog = @import("dialog.zig");
const Com = @import("webview2.zig").Com;

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) i32;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "shell32" fn SHCreateShellItemArrayFromShellItem(item: *Com, iid: *const w.Guid, out: *?*anyopaque) callconv(.winapi) i32;

const iid_shell_item_array: w.Guid = .{ .a = 0xb63ea76d, .b = 0x1f85, .c = 0x456f, .d = .{ 0xa1, 0x9c, 0x48, 0x15, 0x9e, 0xfa, 0x85, 0x8b } };

test "an open dialog asked for folders picks folders, several when asked" {
    // The main thread's apartment, as the app makes it.
    if (CoInitializeEx(null, 0x2) < 0) return error.SkipZigTest;
    defer CoUninitialize();
    var texts: dialog.Texts = .{};
    const folders = try dialog.make(.{ .files = false, .directories = true, .multiple = true, .title = "Sources", .button = "Add", .directory = "C:\\Windows" }, &texts);
    defer folders.release();
    const f = dialog.options(folders);
    try testing.expect(f & dialog.fos.pick_folders != 0);
    try testing.expect(f & dialog.fos.allow_multiselect != 0);
    try testing.expect(f & dialog.fos.force_file_system != 0);

    // Files, one at a time: the default.
    var file_texts: dialog.Texts = .{};
    const files = try dialog.make(.{ .extensions = &.{ "png", "jpg" } }, &file_texts);
    defer files.release();
    try testing.expectEqual(@as(u32, 0), dialog.options(files) & (dialog.fos.pick_folders | dialog.fos.allow_multiselect));
    // Files and folders both: files, as on Linux.
    var both_texts: dialog.Texts = .{};
    const both = try dialog.make(.{ .files = true, .directories = true }, &both_texts);
    defer both.release();
    try testing.expectEqual(@as(u32, 0), dialog.options(both) & dialog.fos.pick_folders);
}

test "a shell item array's paths come back as WTF-8" {
    if (CoInitializeEx(null, 0x2) < 0) return error.SkipZigTest;
    defer CoUninitialize();
    var raw: ?*anyopaque = null;
    if (dialog.SHCreateItemFromParsingName(std.unicode.utf8ToUtf16LeStringLiteral("C:\\Windows"), null, &dialog.iid_shell_item, &raw) < 0) return error.SkipZigTest;
    const item: *Com = @ptrCast(@alignCast(raw.?));
    defer item.release();
    var array_raw: ?*anyopaque = null;
    try testing.expect(SHCreateShellItemArrayFromShellItem(item, &iid_shell_item_array, &array_raw) >= 0);
    const items: *Com = @ptrCast(@alignCast(array_raw.?));
    defer items.release();
    const got = try dialog.paths(testing.allocator, items);
    defer dialog.freePaths(testing.allocator, got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expect(std.ascii.eqlIgnoreCase(got[0], "C:\\Windows"));
}
