//! Dialogs: open and save panels, and message boxes. They run modally on
//! the main thread (from a menu click, a bound method, a view) and return
//! the user's answer.
const std = @import("std");
const objc = @import("objc.zig");
const dialog_types = @import("dialog_types.zig");
pub const OpenOptions = dialog_types.OpenOptions;
pub const SaveOptions = dialog_types.SaveOptions;
pub const MessageKind = dialog_types.MessageKind;
pub const MessageOptions = dialog_types.MessageOptions;
pub const MessageResult = dialog_types.MessageResult;
pub const freePaths = dialog_types.freePaths;
pub const Filter = dialog_types.Filter;
const filters = @import("dialog_filters.zig");

/// The paths the user chose, or null if they canceled. Free with
/// `freePaths`.
pub fn open(gpa: std.mem.Allocator, opts: OpenOptions) !?[][]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = objc.msg(objc.Object, objc.class("NSOpenPanel"), "openPanel", .{});
    objc.msg(void, panel, "setCanChooseFiles:", .{opts.files});
    objc.msg(void, panel, "setCanChooseDirectories:", .{opts.directories});
    objc.msg(void, panel, "setAllowsMultipleSelection:", .{opts.multiple});
    configure(panel, opts.title, opts.button, opts.message, opts.directory, opts.show_hidden);
    var one: [1]Filter = undefined;
    var acc: filters.Accessory = .{ .panel = panel, .groups = dialog_types.groups(opts.filters, opts.extensions, &one) };
    acc.attach();
    defer acc.deinit();
    if (objc.msg(objc.NSInteger, panel, "runModal", .{}) != 1) return null;
    const urls = objc.msg(objc.Object, panel, "URLs", .{});
    const n = objc.msg(objc.NSUInteger, urls, "count", .{});
    const out = try gpa.alloc([]u8, n);
    var filled: usize = 0;
    errdefer freePaths(gpa, out[0..filled]);
    for (0..n) |i| {
        const url = objc.msg(objc.Object, urls, "objectAtIndex:", .{i});
        out[i] = try gpa.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, url, "path", .{})));
        filled += 1;
    }
    return out;
}

/// The path the user chose, or null if they canceled. Caller frees it.
pub fn save(gpa: std.mem.Allocator, opts: SaveOptions) !?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = objc.msg(objc.Object, objc.class("NSSavePanel"), "savePanel", .{});
    objc.msg(void, panel, "setCanCreateDirectories:", .{opts.create_directories});
    if (opts.name.len > 0) objc.msg(void, panel, "setNameFieldStringValue:", .{objc.nsString(opts.name)});
    configure(panel, opts.title, opts.button, opts.message, opts.directory, opts.show_hidden);
    var one: [1]Filter = undefined;
    var acc: filters.Accessory = .{ .panel = panel, .groups = dialog_types.groups(opts.filters, opts.extensions, &one) };
    acc.attach();
    defer acc.deinit();
    if (objc.msg(objc.NSInteger, panel, "runModal", .{}) != 1) return null;
    const url = objc.msg(?objc.Object, panel, "URL", .{}) orelse return null;
    return try gpa.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, url, "path", .{})));
}

fn configure(panel: objc.Object, title: []const u8, button: []const u8, text: []const u8, directory: []const u8, show_hidden: bool) void {
    if (title.len > 0) objc.msg(void, panel, "setTitle:", .{objc.nsString(title)});
    if (button.len > 0) objc.msg(void, panel, "setPrompt:", .{objc.nsString(button)});
    if (text.len > 0) objc.msg(void, panel, "setMessage:", .{objc.nsString(text)});
    objc.msg(void, panel, "setShowsHiddenFiles:", .{show_hidden});
    if (directory.len > 0) {
        const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:isDirectory:", .{ objc.nsString(directory), objc.YES });
        objc.msg(void, panel, "setDirectoryURL:", .{url});
    }
}

/// Shows a message box and waits for a button.
pub fn message(opts: MessageOptions) MessageResult {
    const pool = objc.Pool.push();
    defer pool.pop();
    const alert = objc.new("NSAlert");
    defer objc.release(alert);
    objc.msg(void, alert, "setMessageText:", .{objc.nsString(opts.title)});
    if (opts.detail.len > 0) objc.msg(void, alert, "setInformativeText:", .{objc.nsString(opts.detail)});
    const style: objc.NSUInteger = switch (opts.kind) {
        .warning => 0,
        .info => 1,
        .critical => 2,
    };
    objc.msg(void, alert, "setAlertStyle:", .{style});
    for (opts.buttons) |b| _ = objc.msg(objc.Object, alert, "addButtonWithTitle:", .{objc.nsString(b)});
    if (opts.checkbox.len > 0) {
        objc.msg(void, alert, "setShowsSuppressionButton:", .{objc.YES});
        const cb = objc.msg(objc.Object, alert, "suppressionButton", .{});
        objc.msg(void, cb, "setTitle:", .{objc.nsString(opts.checkbox)});
    }
    const response = objc.msg(objc.NSInteger, alert, "runModal", .{});
    var checked = false;
    if (opts.checkbox.len > 0) {
        const cb = objc.msg(objc.Object, alert, "suppressionButton", .{});
        checked = objc.msg(objc.NSInteger, cb, "state", .{}) == 1;
    }
    // NSAlertFirstButtonReturn is 1000.
    return .{ .button = @intCast(@max(0, response - 1000)), .checked = checked };
}

test {
    _ = filters;
}
