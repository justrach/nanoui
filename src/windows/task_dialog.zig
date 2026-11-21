//! Message boxes as task dialogs (comctl32 6): the caller's own button
//! labels, the first the default, and the checkbox. nanoui's apps carry no
//! manifest, so their comctl32 is version 5, which has no task dialogs;
//! version 6 is reached through shell32's activation context (its manifest,
//! resource 124, names Common Controls 6) and loaded from system32 only.
//! Where that fails, `dialog.message` falls back to `MessageBoxW`.
const std = @import("std");
const w = @import("win32.zig");
const dialog_types = @import("../dialog_types.zig");

const MessageOptions = dialog_types.MessageOptions;
const MessageResult = dialog_types.MessageResult;

/// The most buttons a dialog is given; the rest are left out.
pub const max_buttons = 8;
/// Button `i`'s id is `first_id + i`.
pub const first_id: i32 = 100;
/// The dialog's own answers: its OK button, and Esc or the close box.
pub const id_ok: i32 = 1;
pub const id_cancel: i32 = 2;

/// TASKDIALOG_FLAGS and TASKDIALOG_COMMON_BUTTON_FLAGS.
pub const tdf = struct {
    pub const allow_cancellation: u32 = 0x8;
    pub const position_relative_to_window: u32 = 0x1000;
    pub const ok_button: u32 = 0x1;
};

/// TD_WARNING_ICON, TD_ERROR_ICON, TD_INFORMATION_ICON: MAKEINTRESOURCEW(-1, -2, -3).
pub fn icon(kind: dialog_types.MessageKind) usize {
    return switch (kind) {
        .warning => 0xffff,
        .critical => 0xfffe,
        .info => 0xfffd,
    };
}

// commctrl.h packs the task dialog's structures to one byte.

/// TASKDIALOG_BUTTON.
pub const Button = extern struct {
    id: i32 align(1),
    text: [*:0]const u16 align(1),
};

/// TASKDIALOGCONFIG.
pub const Config = extern struct {
    size: u32 align(1) = @sizeOf(Config),
    parent: ?w.HWND align(1) = null,
    instance: ?w.HINSTANCE align(1) = null,
    flags: u32 align(1) = 0,
    common_buttons: u32 align(1) = 0,
    window_title: ?[*:0]const u16 align(1) = null,
    main_icon: usize align(1) = 0,
    main_instruction: ?[*:0]const u16 align(1) = null,
    content: ?[*:0]const u16 align(1) = null,
    button_count: u32 align(1) = 0,
    buttons: ?[*]const Button align(1) = null,
    default_button: i32 align(1) = 0,
    radio_count: u32 align(1) = 0,
    radios: ?[*]const Button align(1) = null,
    default_radio: i32 align(1) = 0,
    verification: ?[*:0]const u16 align(1) = null,
    expanded_information: ?[*:0]const u16 align(1) = null,
    expanded_control_text: ?[*:0]const u16 align(1) = null,
    collapsed_control_text: ?[*:0]const u16 align(1) = null,
    footer_icon: usize align(1) = 0,
    footer: ?[*:0]const u16 align(1) = null,
    callback: ?Callback align(1) = null,
    callback_data: isize align(1) = 0,
    width: u32 align(1) = 0,
};

/// PFTASKDIALOGCALLBACK.
pub const Callback = *const fn (hwnd: w.HWND, note: u32, wp: w.WPARAM, lp: w.LPARAM, data: isize) callconv(.winapi) i32;
const TaskDialogIndirect = *const fn (config: *const Config, button: ?*i32, radio: ?*i32, checked: ?*w.BOOL) callconv(.winapi) i32;

/// The strings a dialog is given, kept while it is shown.
pub const Texts = struct {
    caption: [256]u16 = undefined,
    title: [1024]u16 = undefined,
    detail: [4096]u16 = undefined,
    checkbox: [256]u16 = undefined,
    labels: [max_buttons][128]u16 = undefined,
    buttons: [max_buttons]Button = undefined,
};

/// The labels a dialog shows: the first `max_buttons`.
pub fn labelsOf(opts: MessageOptions) []const []const u8 {
    return opts.buttons[0..@min(opts.buttons.len, max_buttons)];
}

/// The button Esc and the close box answer: the one labeled "Cancel" (as
/// on the Mac), else the only one. Null when there is neither: then they do
/// nothing (the close box is disabled), as in a Yes/No message box, so
/// neither can answer an action the user didn't pick.
pub fn cancelIndex(labels: []const []const u8) ?usize {
    for (labels, 0..) |l, i| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, l, " "), "cancel")) return i;
    }
    return if (labels.len <= 1) 0 else null;
}

/// The dialog `opts` asks for, its strings in `texts`, owned by `parent`.
/// No labels is the system's own OK button.
pub fn setUp(opts: MessageOptions, texts: *Texts, parent: ?w.HWND, window_title: ?[*:0]const u16) Config {
    const labels = labelsOf(opts);
    var c: Config = .{
        .parent = parent,
        .window_title = window_title,
        .main_icon = icon(opts.kind),
        .main_instruction = w.wide(&texts.title, opts.title),
        .content = if (opts.detail.len > 0) w.wide(&texts.detail, opts.detail) else null,
        .verification = if (opts.checkbox.len > 0) literal(&texts.checkbox, opts.checkbox) else null,
    };
    if (parent != null) c.flags |= tdf.position_relative_to_window;
    if (cancelIndex(labels) != null) c.flags |= tdf.allow_cancellation;
    if (labels.len == 0) {
        c.common_buttons = tdf.ok_button;
        return c;
    }
    for (labels, 0..) |l, i| texts.buttons[i] = .{ .id = first_id + @as(i32, @intCast(i)), .text = literal(&texts.labels[i], l) };
    c.button_count = @intCast(labels.len);
    c.buttons = &texts.buttons;
    c.default_button = first_id;
    return c;
}

/// `s` as UTF-16 that a button shows as written: each `&`, which would
/// underline the next letter, doubled ("Save && Close"). Truncated to fit.
pub fn literal(buf: []u16, s: []const u8) [*:0]const u16 {
    var escaped: [512]u8 = undefined;
    var n: usize = 0;
    for (s) |b| {
        const width: usize = if (b == '&') 2 else 1;
        if (n + width > escaped.len) break;
        escaped[n] = b;
        if (b == '&') escaped[n + 1] = '&';
        n += width;
    }
    return w.wide(buf, escaped[0..n]);
}

/// The index of the button that answered with `id`. Esc and the close box
/// (IDCANCEL) answer `cancelIndex`; the dialog sends them only when there
/// is one, so the first button for no Cancel never answers them.
pub fn answer(id: i32, labels: []const []const u8) usize {
    if (id >= first_id and id < first_id + @as(i32, @intCast(labels.len))) return @intCast(id - first_id);
    if (id == id_cancel) return cancelIndex(labels) orelse 0;
    return 0;
}

extern "kernel32" fn CreateActCtxW(ctx: *const ActCtx) callconv(.winapi) isize;
extern "kernel32" fn ReleaseActCtx(ctx: isize) callconv(.winapi) void;
extern "kernel32" fn ActivateActCtx(ctx: isize, cookie: *usize) callconv(.winapi) w.BOOL;
extern "kernel32" fn DeactivateActCtx(flags: u32, cookie: usize) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetSystemDirectoryW(buf: [*]u16, len: u32) callconv(.winapi) u32;
const HMODULE = *opaque {};
extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(module: HMODULE) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetModuleFileNameW(module: ?HMODULE, buf: [*]u16, len: u32) callconv(.winapi) u32;
extern "user32" fn GetWindowTextW(hwnd: w.HWND, buf: [*]u16, len: i32) callconv(.winapi) i32;

/// ACTCTXW.
const ActCtx = extern struct {
    size: u32 = @sizeOf(ActCtx),
    flags: u32,
    source: [*:0]const u16,
    architecture: u16 = 0,
    language: u16 = 0,
    directory: ?[*:0]const u16 = null,
    resource: ?[*:0]const u16 = null,
    application: ?[*:0]const u16 = null,
    module: ?*anyopaque = null,
};
const actctx_flag_resource_name_valid: u32 = 0x8;
const invalid_handle: isize = -1;
const load_library_search_system32: u32 = 0x800;
const deactivate_force_early: u32 = 0x1;

/// comctl32 6's `TaskDialogIndirect` and the activation context it runs in.
pub const Entry = struct { show: TaskDialogIndirect, context: isize };

// Looked up once, on the main thread, where dialogs run.
var looked_up = false;
var found: ?Entry = null;

/// comctl32 6's task dialog, or null where it can't be had.
pub fn entry() ?Entry {
    if (looked_up) return found;
    looked_up = true;
    var path: [260]u16 = undefined;
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\\shell32.dll");
    const n = GetSystemDirectoryW(&path, path.len);
    if (n == 0 or n + suffix.len >= path.len) return null;
    @memcpy(path[n..][0..suffix.len], suffix);
    path[n + suffix.len] = 0;
    const context = CreateActCtxW(&.{ .flags = actctx_flag_resource_name_valid, .source = path[0 .. n + suffix.len :0], .resource = @ptrFromInt(124) });
    if (context == invalid_handle) return null;
    var cookie: usize = 0;
    if (ActivateActCtx(context, &cookie) == 0) {
        ReleaseActCtx(context);
        return null;
    }
    // Kept loaded when it has task dialogs: they come from it.
    const module = LoadLibraryExW(std.unicode.utf8ToUtf16LeStringLiteral("comctl32.dll"), null, load_library_search_system32);
    const proc = if (module) |m| GetProcAddress(m, "TaskDialogIndirect") else null;
    _ = DeactivateActCtx(0, cookie);
    if (proc == null) {
        if (module) |m| _ = FreeLibrary(m);
        ReleaseActCtx(context);
        return null;
    }
    found = .{ .show = @ptrCast(proc.?), .context = context };
    return found;
}

/// What the dialog answered: its button's id, and the checkbox.
pub const Pressed = struct { id: i32, checked: bool };

/// Shows `config` in comctl32 6's context; null when it couldn't be shown.
pub fn run(e: Entry, config: *const Config) ?Pressed {
    var cookie: usize = 0;
    const active = ActivateActCtx(e.context, &cookie) != 0;
    // Forced: app code runs in the dialog's loop, and a context it leaves
    // active must not make this deactivation raise.
    defer if (active) {
        _ = DeactivateActCtx(deactivate_force_early, cookie);
    };
    var id: i32 = 0;
    var checked: w.BOOL = 0;
    if (e.show(config, &id, null, &checked) < 0) return null;
    return .{ .id = id, .checked = checked != 0 };
}

/// The dialog's caption: the owner window's title, else the program's
/// file name without ".exe".
pub fn caption(parent: ?w.HWND, buf: []u16) [*:0]const u16 {
    if (parent) |h| {
        if (GetWindowTextW(h, buf.ptr, @intCast(buf.len)) > 0) return @ptrCast(buf.ptr);
    }
    const n = GetModuleFileNameW(null, buf.ptr, @intCast(buf.len - 1));
    return programName(buf, n).ptr;
}

/// The file name without its extension of the program path in `buf[0..n]`,
/// ended in place: "C:\a\b.exe" is "b".
pub fn programName(buf: []u16, n: usize) [:0]u16 {
    const path = buf[0..n];
    const start = if (std.mem.lastIndexOfAny(u16, path, &.{ '\\', '/' })) |i| i + 1 else 0;
    var end = n;
    if (std.mem.lastIndexOfScalar(u16, path[start..], '.')) |dot| {
        if (dot > 0) end = start + dot;
    }
    buf[end] = 0;
    return buf[start..end :0];
}

/// A task dialog modal to the app's active window, as `opts` says; null
/// where task dialogs aren't available.
pub fn message(opts: MessageOptions) ?MessageResult {
    const e = entry() orelse return null;
    var texts: Texts = .{};
    const parent = w.GetActiveWindow();
    const config = setUp(opts, &texts, parent, caption(parent, &texts.caption));
    const got = run(e, &config) orelse return null;
    return .{ .button = answer(got.id, labelsOf(opts)), .checked = got.checked };
}

test "the task dialog's structures are laid out as commctrl.h packs them" {
    const wide = @sizeOf(usize) == 8;
    try std.testing.expectEqual(@as(usize, if (wide) 160 else 96), @sizeOf(Config));
    try std.testing.expectEqual(@as(usize, if (wide) 12 else 8), @sizeOf(Button));
    try std.testing.expectEqual(@as(usize, if (wide) 64 else 40), @offsetOf(Config, "buttons"));
    try std.testing.expectEqual(@as(usize, if (wide) 92 else 60), @offsetOf(Config, "verification"));
    try std.testing.expectEqual(@as(usize, if (wide) 156 else 92), @offsetOf(Config, "width"));
}
