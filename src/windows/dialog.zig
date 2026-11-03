//! Dialogs on Windows: message boxes and the common file dialogs, modal
//! on the main thread.
const std = @import("std");
const w = @import("win32.zig");
const dialog_types = @import("../dialog_types.zig");

pub const OpenOptions = dialog_types.OpenOptions;
pub const SaveOptions = dialog_types.SaveOptions;
pub const MessageKind = dialog_types.MessageKind;
pub const MessageOptions = dialog_types.MessageOptions;
pub const MessageResult = dialog_types.MessageResult;
pub const freePaths = dialog_types.freePaths;

pub fn open(gpa: std.mem.Allocator, opts: OpenOptions) !?[][]u8 {
    var file: [4096]u16 = @splat(0);
    var title: [256]u16 = undefined;
    var ofn: w.OPENFILENAMEW = .{ .lpstrFile = &file, .nMaxFile = file.len, .lpstrTitle = if (opts.title.len > 0) w.wide(&title, opts.title) else null, .Flags = w.OFN_EXPLORER | w.OFN_FILEMUSTEXIST | w.OFN_NOCHANGEDIR };
    if (w.GetOpenFileNameW(&ofn) == 0) return null;
    const out = try gpa.alloc([]u8, 1);
    errdefer gpa.free(out);
    out[0] = try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.sliceTo(&file, 0));
    return out;
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
