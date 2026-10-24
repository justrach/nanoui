//! What one event brings, and what text editing keeps: keys, key
//! combinations offered to the view, text operations (typing, the input
//! method, selection, clipboard), the focused field as the input method
//! asks about it, where copied text goes, a field's editing state, and the
//! pointer and keys of this event.
const std = @import("std");
const types = @import("types.zig");

pub const Key = enum { backspace, delete, left, right, up, down, home, end, enter, tab, escape, page_up, page_down, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12 };

/// A key with modifiers, offered to the view before text editing sees it:
/// characters lowercase, other keys as `Shortcut.up` and the like.
pub const Shortcut = struct {
    key: u21,
    cmd: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    pub const up: u21 = 0xF700;
    pub const down: u21 = 0xF701;
    pub const left: u21 = 0xF702;
    pub const right: u21 = 0xF703;
    pub const escape: u21 = 0x1b;
    pub const tab: u21 = '\t';
    pub const enter: u21 = '\r';

    /// A combination as scripts write it: `cmd+shift+n`, `cmd+enter`,
    /// `escape`, `ctrl+tab`, `cmd+1`, `alt+up`.
    pub fn parse(text: []const u8) ?Shortcut {
        var s: Shortcut = .{ .key = 0 };
        var parts = std.mem.splitScalar(u8, text, '+');
        while (parts.next()) |p| {
            const eq = std.ascii.eqlIgnoreCase;
            if (eq(p, "cmd")) s.cmd = true else if (eq(p, "ctrl")) s.ctrl = true else if (eq(p, "alt") or eq(p, "opt")) s.alt = true else if (eq(p, "shift")) s.shift = true else {
                const named = [_]struct { []const u8, u21 }{
                    .{ "enter", enter }, .{ "return", enter }, .{ "escape", escape }, .{ "esc", escape },
                    .{ "tab", tab },     .{ "up", up },        .{ "down", down },     .{ "left", left },
                    .{ "right", right }, .{ "space", ' ' },    .{ "backspace", 0x7f }, .{ "delete", 0x7f },
                    .{ "plus", '+' },
                };
                s.key = for (named) |n| {
                    if (eq(p, n[0])) break n[1];
                } else blk: {
                    // One character, whole.
                    const len = std.unicode.utf8ByteSequenceLength(if (p.len > 0) p[0] else return null) catch return null;
                    if (len != p.len) return null;
                    break :blk std.unicode.utf8Decode(p) catch return null;
                };
                if (s.key < 128) s.key = std.ascii.toLower(@intCast(s.key));
            }
        }
        return if (s.key == 0) null else s;
    }

    /// As this platform has it: Command is Control off Apple's systems.
    pub fn native(s: Shortcut) Shortcut {
        if (@import("keys.zig").mac or !s.cmd) return s;
        var n = s;
        n.cmd = false;
        n.ctrl = true;
        return n;
    }
};

/// What text input does to the focused text, in AppKit's terms: typed or
/// pasted text, an input method's composition, and editing commands.
pub const TextOp = union(enum) {
    insert: []const u8,
    /// Text being composed (underlined), with the selection inside it.
    set_marked: struct { text: []const u8, sel_start: usize, sel_len: usize },
    unmark,
    command: Command,
};

pub const Command = enum {
    delete_backward,
    delete_forward,
    delete_word_backward,
    delete_to_line_start,
    delete_word_forward,
    delete_to_line_end,
    move_left,
    move_right,
    move_word_left,
    move_word_right,
    move_line_start,
    move_line_end,
    select_left,
    select_right,
    select_word_left,
    select_word_right,
    select_line_start,
    select_line_end,
    select_all,
    /// A line up or down: a multiline field's; a single line's start or end.
    move_up,
    move_down,
    select_up,
    select_down,
    insert_newline,
    /// Option-Return, Shift-Return: a new line in a multiline field.
    insert_line_break,
    insert_tab,
    cancel,
    copy,
    cut,
};

/// The focused text field as the last frame left it, for the input
/// method's questions between frames. Offsets are bytes.
pub const FocusedText = struct {
    id: u64,
    text: []const u8,
    caret: usize,
    anchor: usize,
    marked: ?[2]usize,
    /// Where the caret is drawn, in view points.
    caret_rect: types.Rect,
};

/// Where copied text goes: the system's clipboard, or the Tester's own.
pub const Clipboard = struct {
    ctx: ?*anyopaque = null,
    write: *const fn (ctx: ?*anyopaque, text: []const u8) void = systemWrite,

    fn systemWrite(_: ?*anyopaque, s: []const u8) void {
        @import("../platform.zig").clipboardWrite(s);
    }
};

/// A text field's editing state, kept across frames.
pub const EditState = struct {
    caret: usize = 0,
    anchor: usize = 0,
    marked: ?[2]usize = null,
    scroll_x: f32 = 0,
    /// A multiline field's lines scrolled up past its top.
    scroll_y: f32 = 0,
    /// Pressed in the field: dragging extends the selection.
    selecting: bool = false,
    /// Emacs's and Vim's keys (keymap.zig) and the undo history.
    keys: KeyState = .{},
    undo: @import("undo.zig").History = .{},
};

/// What Emacs's and Vim's keys remember between events.
pub const KeyState = struct {
    /// What was killed or yanked, newest first: ^Y and p put back the
    /// first, M-y the ones before it.
    ring: [4][256]u8 = undefined,
    ring_len: [4]u16 = @splat(0),
    ring_count: u8 = 0,
    /// The last command killed (the next kill joins it), or put back
    /// [from, to) from ring entry `yank_at` (M-y swaps it for an older one).
    last_kill: bool = false,
    yanked: ?[2]usize = null,
    yank_at: u8 = 0,
    /// Emacs's mark (C-Space): the region is from it to the caret.
    mark: ?usize = null,
    /// Vim: normal or visual mode (where visual began); a count, an
    /// operator (d c y) and its count, a key waiting for the next one
    /// (f F t T r g, i a after an operator); the last f F t T and its char.
    vim_normal: bool = false,
    vim_visual: bool = false,
    vim_anchor: usize = 0,
    vim_count: u16 = 0,
    vim_op: u8 = 0,
    vim_op_count: u16 = 0,
    vim_prefix: u8 = 0,
    vim_find: [2]u8 = .{ 0, 0 },
};

pub const Input = struct {
    mouse: types.Point = .{ .x = -1e6, .y = -1e6 },
    down: bool = false,
    /// The button went down / up in this event.
    pressed: bool = false,
    released: bool = false,
    click_count: u32 = 0,
    scroll: types.Point = .{},
    /// A pinch in this event (two fingers on a touch screen, a trackpad's
    /// magnify): how much it scaled by (1: none), about `mouse`.
    zoom: f32 = 1,
    /// How far two fingers moved together in this event.
    pan: types.Point = .{},
    key: ?Key = null,
    /// Text typed or pasted in this event.
    chars: []const u8 = "",
    /// Text input operations of this event, for the focused text field.
    ops: []const TextOp = &.{},
    /// A key combination offered in this event (`Context.shortcut`).
    shortcut: ?Shortcut = null,
    shift: bool = false,
    cmd: bool = false,
    ctrl: bool = false,
    /// Option on the Mac, Alt elsewhere: held with this event's key.
    alt: bool = false,

    /// The key that adds to a selection with a click: Command on the
    /// Mac, Control elsewhere.
    pub fn adding(i: Input) bool {
        return if (comptime @import("keys.zig").mac) i.cmd else i.ctrl;
    }

    pub fn clearEdges(i: *Input) void {
        i.pressed = false;
        i.released = false;
        i.scroll = .{};
        i.zoom = 1;
        i.pan = .{};
        i.key = null;
        i.chars = "";
        i.ops = &.{};
        i.shortcut = null;
    }
};
