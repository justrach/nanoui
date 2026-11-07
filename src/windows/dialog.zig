//! Dialogs on Windows: message boxes and the common file dialogs, modal
//! on the main thread. Opening is the Common Item Dialog (`IFileOpenDialog`),
//! which picks folders and several items as well as one file, called through
//! its vtables by slot in the order `shobjidl_core.h` declares them; the
//! main thread's COM apartment is the app's (`app.zig`).
const std = @import("std");
const w = @import("win32.zig");
const dialog_types = @import("../dialog_types.zig");
const webview2 = @import("webview2.zig");
const Com = webview2.Com;

pub const OpenOptions = dialog_types.OpenOptions;
pub const SaveOptions = dialog_types.SaveOptions;
pub const MessageKind = dialog_types.MessageKind;
pub const MessageOptions = dialog_types.MessageOptions;
pub const MessageResult = dialog_types.MessageResult;
pub const freePaths = dialog_types.freePaths;

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) i32;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "shell32" fn SHCreateItemFromParsingName(path: [*:0]const u16, bind: ?*anyopaque, iid: *const w.Guid, out: *?*anyopaque) callconv(.winapi) i32;

const clsid_file_open_dialog: w.Guid = .{ .a = 0xdc1c5a9c, .b = 0xe88a, .c = 0x4dde, .d = .{ 0xa5, 0xa1, 0x60, 0xf8, 0x2a, 0x20, 0xae, 0xf7 } };
const iid_file_open_dialog: w.Guid = .{ .a = 0xd57c7288, .b = 0xd4ad, .c = 0x4768, .d = .{ 0xbe, 0x02, 0x9d, 0x96, 0x95, 0x32, 0xd9, 0x60 } };
pub const iid_shell_item: w.Guid = .{ .a = 0x43826d1e, .b = 0xe718, .c = 0x42ee, .d = .{ 0xbc, 0x55, 0xa1, 0xe2, 0x61, 0xc3, 0x7b, 0xfe } };

/// `IFileOpenDialog`'s slots: `IModalWindow::Show`, then `IFileDialog`'s,
/// then its own; `IShellItemArray`'s and `IShellItem`'s, each after
/// `IUnknown`'s three.
const slot = struct {
    const show = 3;
    const set_file_types = 4;
    const set_options = 9;
    const get_options = 10;
    const set_folder = 12;
    const set_title = 17;
    const set_ok_button_label = 18;
    const get_results = 27;
    const array_get_count = 7;
    const array_get_item_at = 8;
    const item_get_display_name = 5;
};

/// FILEOPENDIALOGOPTIONS.
pub const fos = struct {
    pub const no_change_dir: u32 = 0x8;
    pub const pick_folders: u32 = 0x20;
    pub const force_file_system: u32 = 0x40;
    pub const allow_multiselect: u32 = 0x200;
    pub const path_must_exist: u32 = 0x800;
    pub const file_must_exist: u32 = 0x1000;
    pub const force_show_hidden: u32 = 0x10000000;
};
const sigdn_file_sys_path: u32 = 0x80058000;
const clsctx_inproc_server: u32 = 0x1;
/// HRESULT_FROM_WIN32(ERROR_CANCELLED): the user closed the dialog.
const cancelled: i32 = @bitCast(@as(u32, 0x800704c7));

const FilterSpec = extern struct { name: [*:0]const u16, spec: [*:0]const u16 };
const SetText = *const fn (*Com, [*:0]const u16) callconv(.winapi) i32;

/// The strings a dialog is given, kept while it is set up and shown (it
/// copies them, but needn't be trusted to).
pub const Texts = struct {
    title: [256]u16 = undefined,
    button: [64]u16 = undefined,
    folder: [1024]u16 = undefined,
    types: [512]u16 = undefined,
};

/// What `opts` adds to an open dialog's options. It picks one kind of item:
/// folders when files aren't wanted, files otherwise, as on Linux.
pub fn optionsFor(opts: OpenOptions) u32 {
    var f: u32 = fos.no_change_dir | fos.force_file_system | fos.path_must_exist | fos.file_must_exist;
    if (opts.directories and !opts.files) f |= fos.pick_folders;
    if (opts.multiple) f |= fos.allow_multiselect;
    if (opts.show_hidden) f |= fos.force_show_hidden;
    return f;
}

/// The options the dialog has now.
pub fn options(d: *Com) u32 {
    var f: u32 = 0;
    _ = d.slot(*const fn (*Com, *u32) callconv(.winapi) i32, slot.get_options)(d, &f);
    return f;
}

/// An open dialog set up as `opts` says, not yet shown; its strings live in
/// `texts`. The caller releases it.
pub fn make(opts: OpenOptions, texts: *Texts) !*Com {
    var raw: ?*anyopaque = null;
    if (w.CoCreateInstance(&clsid_file_open_dialog, null, clsctx_inproc_server, &iid_file_open_dialog, &raw) < 0) return error.DialogUnavailable;
    const d: *Com = @ptrCast(@alignCast(raw orelse return error.DialogUnavailable));
    errdefer d.release();
    if (d.slot(*const fn (*Com, u32) callconv(.winapi) i32, slot.set_options)(d, options(d) | optionsFor(opts)) < 0) return error.DialogOptions;
    if (opts.title.len > 0) _ = d.slot(SetText, slot.set_title)(d, w.wide(&texts.title, opts.title));
    if (opts.button.len > 0) _ = d.slot(SetText, slot.set_ok_button_label)(d, w.wide(&texts.button, opts.button));
    if (opts.directory.len > 0) setFolder(d, w.wide(&texts.folder, opts.directory));
    if (opts.extensions.len > 0 and optionsFor(opts) & fos.pick_folders == 0) setFileTypes(d, &texts.types, opts.extensions);
    return d;
}

/// Starts the dialog in `path`; a folder that isn't there is passed over.
fn setFolder(d: *Com, path: [*:0]const u16) void {
    var raw: ?*anyopaque = null;
    if (SHCreateItemFromParsingName(path, null, &iid_shell_item, &raw) < 0) return;
    const folder: *Com = @ptrCast(@alignCast(raw orelse return));
    defer folder.release();
    _ = d.slot(*const fn (*Com, *Com) callconv(.winapi) i32, slot.set_folder)(d, folder);
}

/// One filter of the extensions allowed, "*.png;*.jpg", named by itself.
fn setFileTypes(d: *Com, buf: []u16, extensions: []const []const u8) void {
    var spec: [512]u8 = undefined;
    var len: usize = 0;
    for (extensions, 0..) |ext, i| {
        const part = std.fmt.bufPrint(spec[len..], "{s}*.{s}", .{ if (i > 0) ";" else "", ext }) catch break;
        len += part.len;
    }
    const s = w.wide(buf, spec[0..len]);
    const filter = [_]FilterSpec{.{ .name = s, .spec = s }};
    _ = d.slot(*const fn (*Com, u32, [*]const FilterSpec) callconv(.winapi) i32, slot.set_file_types)(d, filter.len, &filter);
}

/// The file system paths in an `IShellItemArray`, as WTF-8. Free with `freePaths`.
pub fn paths(gpa: std.mem.Allocator, items: *Com) ![][]u8 {
    var n: u32 = 0;
    if (items.slot(*const fn (*Com, *u32) callconv(.winapi) i32, slot.array_get_count)(items, &n) < 0) return error.DialogResults;
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    for (0..n) |i| {
        var raw: ?*anyopaque = null;
        if (items.slot(*const fn (*Com, u32, *?*anyopaque) callconv(.winapi) i32, slot.array_get_item_at)(items, @intCast(i), &raw) < 0) continue;
        const item: *Com = @ptrCast(@alignCast(raw orelse continue));
        defer item.release();
        var name: ?[*:0]u16 = null;
        if (item.slot(*const fn (*Com, u32, *?[*:0]u16) callconv(.winapi) i32, slot.item_get_display_name)(item, sigdn_file_sys_path, &name) < 0) continue;
        const wide = name orelse continue;
        defer webview2.coTaskMemFree(wide);
        try out.ensureUnusedCapacity(gpa, 1);
        out.appendAssumeCapacity(try std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.span(wide)));
    }
    return out.toOwnedSlice(gpa);
}

/// The paths the user chose, or null if they canceled. Free with `freePaths`.
pub fn open(gpa: std.mem.Allocator, opts: OpenOptions) !?[][]u8 {
    // The app's apartment on its main thread; one of this call's own where
    // there is none (it balances the app's otherwise).
    const apartment = CoInitializeEx(null, 0x2) >= 0;
    defer if (apartment) CoUninitialize();
    var texts: Texts = .{};
    const d = try make(opts, &texts);
    defer d.release();
    // Owned by the app's active window: above it, and the window held still
    // until it closes, as the system's modal dialogs do.
    const shown = d.slot(*const fn (*Com, ?w.HWND) callconv(.winapi) i32, slot.show)(d, w.GetActiveWindow());
    if (shown == cancelled) return null;
    if (shown < 0) return error.DialogFailed;
    var raw: ?*anyopaque = null;
    if (d.slot(*const fn (*Com, *?*anyopaque) callconv(.winapi) i32, slot.get_results)(d, &raw) < 0) return error.DialogResults;
    const items: *Com = @ptrCast(@alignCast(raw orelse return error.DialogResults));
    defer items.release();
    return try paths(gpa, items);
}

pub fn save(gpa: std.mem.Allocator, opts: SaveOptions) !?[]u8 {
    var file: [4096]u16 = @splat(0);
    _ = w.wide(&file, opts.name);
    var title: [256]u16 = undefined;
    var ofn: w.OPENFILENAMEW = .{ .lpstrFile = &file, .nMaxFile = file.len, .lpstrTitle = if (opts.title.len > 0) w.wide(&title, opts.title) else null, .Flags = w.OFN_EXPLORER | w.OFN_OVERWRITEPROMPT | w.OFN_NOCHANGEDIR };
    if (w.GetSaveFileNameW(&ofn) == 0) return null;
    return try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.sliceTo(&file, 0));
}

/// A message box: OK, OK/Cancel or Yes/No/Cancel for one to three buttons
/// (the labels are the system's).
pub fn message(opts: MessageOptions) MessageResult {
    var text: [2048]u16 = undefined;
    var buf: [1024]u8 = undefined;
    const body = if (opts.detail.len > 0) std.fmt.bufPrint(&buf, "{s}\n\n{s}", .{ opts.title, opts.detail }) catch opts.title else opts.title;
    const icon: u32 = switch (opts.kind) {
        .info => 0x40,
        .warning => 0x30,
        .critical => 0x10,
    };
    const n = opts.buttons.len;
    const kind: u32 = if (n >= 3) 3 else if (n == 2) 1 else 0;
    const r = w.MessageBoxW(null, w.wide(&text, body), std.unicode.utf8ToUtf16LeStringLiteral("nanoui"), kind | icon);
    // IDOK 1, IDCANCEL 2, IDYES 6, IDNO 7.
    const button: usize = switch (r) {
        1, 6 => 0,
        7 => 1,
        2 => if (n >= 3) 2 else 1,
        else => 0,
    };
    return .{ .button = button };
}
