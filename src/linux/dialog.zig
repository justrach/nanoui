//! Dialogs on Linux: GTK's message dialogs and native file choosers (the
//! desktop portal's where there is one), modal on the main thread. GTK 4's
//! answer with a "response" signal, waited for on GLib's loop.
const std = @import("std");
const gtk = @import("gtk.zig");
const dialog_types = @import("../dialog_types.zig");

pub const OpenOptions = dialog_types.OpenOptions;
pub const SaveOptions = dialog_types.SaveOptions;
pub const MessageKind = dialog_types.MessageKind;
pub const MessageOptions = dialog_types.MessageOptions;
pub const MessageResult = dialog_types.MessageResult;
pub const freePaths = dialog_types.freePaths;

fn z(buf: []u8, s: []const u8) [*:0]const u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

/// A GTK 4 dialog's answer, waited for.
const Answer = struct {
    response: ?c_int = null,
    fn on(_: *anyopaque, response: c_int, data: ?*anyopaque) callconv(.c) void {
        const a: *Answer = @ptrCast(@alignCast(data));
        a.response = response;
    }
    fn wait(a: *Answer) c_int {
        while (a.response == null) _ = gtk.api.g_main_context_iteration(null, 1);
        return a.response.?;
    }
};

/// Runs a native file chooser: GTK 3 waits itself; GTK 4 answers later.
fn runChooser(chooser: *anyopaque) c_int {
    if (!gtk.v4) return gtk.v3.gtk_native_dialog_run(chooser);
    var a: Answer = .{};
    gtk.connect(chooser, "response", @ptrCast(&Answer.on), &a);
    gtk.v4api.gtk_native_dialog_show(chooser);
    return a.wait();
}

fn setFolder(chooser: *anyopaque, path: [*:0]const u8) void {
    if (!gtk.v4) {
        _ = gtk.v3.gtk_file_chooser_set_current_folder(chooser, path);
        return;
    }
    const file = gtk.v4api.g_file_new_for_path(path);
    defer gtk.api.g_object_unref(file);
    _ = gtk.v4api.gtk_file_chooser_set_current_folder(chooser, file, null);
}

/// A GFile's path, as `gpa`'s; the file is released.
fn pathOf(gpa: std.mem.Allocator, file: *anyopaque) !?[]u8 {
    defer gtk.api.g_object_unref(file);
    const p = gtk.v4api.g_file_get_path(file) orelse return null;
    defer gtk.api.g_free(p);
    return try gpa.dupe(u8, std.mem.span(p));
}

pub fn open(gpa: std.mem.Allocator, opts: OpenOptions) !?[][]u8 {
    if (!gtk.ready()) return error.GtkMissing;
    const g = &gtk.api;
    var tb: [256]u8 = undefined;
    // Open file 0, select folder 2.
    const action: c_int = if (opts.directories and !opts.files) 2 else 0;
    const chooser = g.gtk_file_chooser_native_new(z(&tb, if (opts.title.len > 0) opts.title else "Open"), null, action, null, null);
    defer g.g_object_unref(chooser);
    g.gtk_file_chooser_set_select_multiple(chooser, @intFromBool(opts.multiple));
    var db: [1024]u8 = undefined;
    if (opts.directory.len > 0) setFolder(chooser, z(&db, opts.directory));
    // GTK_RESPONSE_ACCEPT is -3.
    if (runChooser(chooser) != -3) return null;
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    if (gtk.v4) {
        const files = gtk.v4api.gtk_file_chooser_get_files(chooser);
        defer g.g_object_unref(files);
        var i: c_uint = 0;
        while (i < gtk.v4api.g_list_model_get_n_items(files)) : (i += 1) {
            const file = gtk.v4api.g_list_model_get_item(files, i) orelse continue;
            if (try pathOf(gpa, file)) |p| try paths.append(gpa, p);
        }
        return try paths.toOwnedSlice(gpa);
    }
    const list = gtk.v3.gtk_file_chooser_get_filenames(chooser);
    var node = list;
    while (node) |n| : (node = n.next) {
        const name: [*:0]u8 = @ptrCast(n.data orelse continue);
        try paths.append(gpa, try gpa.dupe(u8, std.mem.span(name)));
        g.g_free(name);
    }
    g.g_slist_free(list);
    return try paths.toOwnedSlice(gpa);
}

pub fn save(gpa: std.mem.Allocator, opts: SaveOptions) !?[]u8 {
    if (!gtk.ready()) return error.GtkMissing;
    const g = &gtk.api;
    var tb: [256]u8 = undefined;
    const chooser = g.gtk_file_chooser_native_new(z(&tb, if (opts.title.len > 0) opts.title else "Save"), null, 1, null, null);
    defer g.g_object_unref(chooser);
    var nb: [512]u8 = undefined;
    if (opts.name.len > 0) g.gtk_file_chooser_set_current_name(chooser, z(&nb, opts.name));
    var db: [1024]u8 = undefined;
    if (opts.directory.len > 0) setFolder(chooser, z(&db, opts.directory));
    if (runChooser(chooser) != -3) return null;
    if (gtk.v4) return pathOf(gpa, gtk.v4api.gtk_file_chooser_get_file(chooser) orelse return null);
    const name = gtk.v3.gtk_file_chooser_get_filename(chooser) orelse return null;
    defer g.g_free(name);
    return try gpa.dupe(u8, std.mem.span(name));
}

pub fn message(opts: MessageOptions) MessageResult {
    if (!gtk.ready()) return .{ .button = 0 };
    const g = &gtk.api;
    var tb: [1024]u8 = undefined;
    // Info 0, warning 1, error 3; no buttons of its own (0): ours follow.
    const kind: c_int = switch (opts.kind) {
        .info => 0,
        .warning => 1,
        .critical => 3,
    };
    const dlg = g.gtk_message_dialog_new(null, 2, kind, 0, "%s", z(&tb, opts.title));
    defer if (gtk.v4) gtk.v4api.gtk_window_destroy(dlg) else gtk.v3.gtk_widget_destroy(dlg);
    const labels: []const []const u8 = if (opts.buttons.len > 0) opts.buttons else &.{"OK"};
    // GTK puts the last added at the right, where the default goes.
    var i = labels.len;
    while (i > 0) {
        i -= 1;
        var lb: [128]u8 = undefined;
        _ = g.gtk_dialog_add_button(dlg, z(&lb, labels[i]), @intCast(i));
    }
    const r = if (gtk.v4) blk: {
        var a: Answer = .{};
        gtk.connect(dlg, "response", @ptrCast(&Answer.on), &a);
        g.gtk_window_present(dlg);
        break :blk a.wait();
    } else gtk.v3.gtk_dialog_run(dlg);
    return .{ .button = if (r >= 0) @intCast(r) else labels.len - 1 };
}
