//! The input method on Windows: the IME's composition string, through IMM32,
//! becomes the text ops a focused field applies (marked text, then the committed
//! text), and the IME's own windows follow the caret.
//!
//! Two decisions come from having watched a real IME on Windows, and both are
//! load-bearing:
//!
//! 1. **nanoui draws the composition itself**, in the text field: the pinyin is
//!    underlined where it will commit (`textfield.zig` paints the marked range).
//!    So the system's composition window is cleared in `WM_IME_SETCONTEXT` — if
//!    both drew, there would be two pinyin on screen. The candidate list stays
//!    the IME's: it is the one the user knows, and it is placed at the caret.
//!
//! 2. **`ImmSetCandidateWindow` and `ImmSetCompositionWindow` send their
//!    `IMN_*` notification from inside the call**, synchronously, to this
//!    window. A `WM_IME_NOTIFY` handler that answers those by placing the window
//!    again recurses until the UI thread stops pumping messages — the window
//!    freezes on the first click into a field. `place` carries a guard so that
//!    cannot happen whatever a handler does, and `notify` places nothing for
//!    those two.
//!
//! The composition drives the same `TextOp.set_marked` / `insert` path macOS
//! uses, so there is no new text-field API here.
const std = @import("std");
const w = @import("win32.zig");
const ctx_mod = @import("../ui/context.zig");

pub const HIMC = *opaque {};
pub const COMPOSITIONFORM = extern struct {
    dwStyle: u32 = 0,
    ptCurrentPos: w.POINT = .{},
    rcArea: w.RECT = .{},
};
pub const CANDIDATEFORM = extern struct {
    dwIndex: u32 = 0,
    dwStyle: u32 = 0,
    ptCurrentPos: w.POINT = .{},
    rcArea: w.RECT = .{},
};

/// `ImmGetCompositionStringW`'s indexes (GCS_*).
pub const GCS_COMPSTR = 0x0008;
pub const GCS_CURSORPOS = 0x0080;
pub const GCS_RESULTSTR = 0x0800;
/// `COMPOSITIONFORM` and `CANDIDATEFORM` styles (CFS_*).
pub const CFS_POINT = 0x0002;
pub const CFS_CANDIDATEPOS = 0x0040;
pub const CFS_EXCLUDE = 0x0080;
/// `WM_IME_SETCONTEXT`'s bit for the system's composition window.
pub const ISC_SHOWUICOMPOSITIONWINDOW: u32 = 0x80000000;
/// `WM_IME_NOTIFY`'s commands (IMN_*).
pub const IMN_SETOPENSTATUS = 0x0008;
pub const IMN_SETCANDIDATEPOS = 0x0009;
pub const IMN_SETCOMPOSITIONWINDOW = 0x000B;
pub const IMN_SETCOMPOSITIONFONT = 0x000A;
pub const IMN_OPENCANDIDATE = 0x0005;
pub const IMN_CHANGECANDIDATE = 0x0003;
pub const IMN_CLOSECANDIDATE = 0x0004;
/// `WM_IME_REQUEST`'s queries (IMR_*): wParam, not message numbers.
pub const IMR_COMPOSITIONWINDOW = 0x0001;
pub const IMR_CANDIDATEWINDOW = 0x0002;

pub extern "imm32" fn ImmGetContext(hwnd: w.HWND) callconv(.winapi) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(hwnd: w.HWND, himc: HIMC) callconv(.winapi) w.BOOL;
pub extern "imm32" fn ImmGetCompositionStringW(himc: HIMC, index: u32, buf: ?*anyopaque, len: u32) callconv(.winapi) i32;
pub extern "imm32" fn ImmSetCompositionWindow(himc: HIMC, form: *const COMPOSITIONFORM) callconv(.winapi) w.BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(himc: HIMC, form: *const CANDIDATEFORM) callconv(.winapi) w.BOOL;

/// What the input method remembers between messages.
pub const State = struct {
    /// Between `WM_IME_STARTCOMPOSITION` and `WM_IME_ENDCOMPOSITION`.
    composing: bool = false,
    /// The focused field shows a composition (the IME's text is in it, marked).
    /// An empty `GCS_COMPSTR` while this is false must not clear a selection.
    marked: bool = false,
    /// A placement call is running: the notification it raises must not place
    /// again. See the note at the top of the file; this is the freeze.
    placing: bool = false,
    /// The caret the IME was last told about, so a frame that did not move it
    /// says nothing (taking a context costs a call each way).
    told_x: f32 = -1e9,
    told_y: f32 = -1e9,
    /// Scratch, reused: the UTF-16 of the last string read, the UTF-8 of each
    /// string, and the ops one message makes.
    wide: std.ArrayList(u16) = .empty,
    result: std.ArrayList(u8) = .empty,
    composition: std.ArrayList(u8) = .empty,
    out: [2]ctx_mod.TextOp = undefined,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.wide.deinit(gpa);
        s.result.deinit(gpa);
        s.composition.deinit(gpa);
        s.* = .{};
    }
};

/// The strings one `WM_IME_COMPOSITION` carries.
pub const Message = struct {
    /// GCS_RESULTSTR: text the IME committed, UTF-8.
    result: []const u8 = "",
    /// GCS_COMPSTR: the text being composed, UTF-8; null when the message
    /// carries no composition string.
    composition: ?[]const u8 = null,
    /// The caret inside the composition, in UTF-8 bytes.
    caret: usize = 0,
};

/// The UTF-8 of `units` in `out`; null when they are not UTF-16 (or out of
/// memory), and "" for none.
pub fn decode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), units: []const u16) ?[]const u8 {
    out.clearRetainingCapacity();
    // Three UTF-8 bytes per UTF-16 unit at most (four for a surrogate pair of
    // two units).
    out.resize(gpa, units.len * 3) catch return null;
    const n = std.unicode.utf16LeToUtf8(out.items, units) catch {
        out.clearRetainingCapacity();
        return null;
    };
    out.shrinkRetainingCapacity(n);
    return out.items;
}

/// Where in UTF-8 a caret at UTF-16 unit `at` of `units` is.
///
/// `GCS_CURSORPOS` counts UTF-16 code units, and the field counts bytes: a
/// hanzi is one unit and three bytes, and a surrogate pair is two units and
/// four bytes. Treating the two as the same number puts the caret in the wrong
/// place as soon as a character outside the BMP is typed.
pub fn byteOfUnit(units: []const u16, at: usize) usize {
    var i: usize = 0;
    var bytes: usize = 0;
    while (i < units.len and i < at) : (i += 1) {
        const u = units[i];
        if (u >= 0xD800 and u <= 0xDBFF) {
            // A surrogate pair: four bytes, whether the caret is between its
            // halves or after it.
            bytes += 4;
            if (i + 1 < at) i += 1;
        } else if (u >= 0xDC00 and u <= 0xDFFF) {
            bytes += 3; // a lone low half: U+FFFD
        } else bytes += std.unicode.utf8CodepointSequenceLength(@intCast(u)) catch 3;
    }
    return bytes;
}

/// The ops one composition message makes, in `s.out`: the committed text first
/// (an insert, which replaces the marked text), then the composition (marked
/// text, underlined). Empty when there is nothing to change.
pub fn ops(s: *State, m: Message, out: *[2]ctx_mod.TextOp) []const ctx_mod.TextOp {
    var n: usize = 0;
    if (m.result.len > 0) {
        out[n] = .{ .insert = m.result };
        n += 1;
        s.marked = false;
    }
    if (m.composition) |text| {
        // An empty composition with nothing marked is the IME's "nothing
        // composed" between real ones: it must not eat a selection.
        if (text.len > 0 or s.marked) {
            out[n] = .{ .set_marked = .{ .text = text, .sel_start = m.caret, .sel_len = 0 } };
            n += 1;
            s.marked = text.len > 0;
        }
    }
    return out[0..n];
}

/// The end of a composition: the field's text is no longer underlined (its
/// bytes stay, as the IME committed them in its last message). Empty when the
/// field shows no composition.
pub fn end(s: *State, out: *[1]ctx_mod.TextOp) []const ctx_mod.TextOp {
    s.composing = false;
    if (!s.marked) return out[0..0];
    s.marked = false;
    out[0] = .unmark;
    return out[0..1];
}

/// One composition string (`index` is a GCS_*), as UTF-8 in `out`; its UTF-16
/// units stay in `s.wide` for the caret (`GCS_CURSORPOS`). Null when the string
/// cannot be read: nothing changes, rather than the field's composition going
/// away.
fn string(himc: HIMC, index: u32, s: *State, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) ?[]const u8 {
    const bytes = ImmGetCompositionStringW(himc, index, null, 0);
    if (bytes < 0) return null;
    if (bytes == 0) {
        s.wide.clearRetainingCapacity();
        out.clearRetainingCapacity();
        return "";
    }
    const units: usize = @intCast(@divTrunc(bytes, 2));
    s.wide.resize(gpa, units) catch {
        s.wide.clearRetainingCapacity();
        return null;
    };
    const got = ImmGetCompositionStringW(himc, index, @ptrCast(s.wide.items.ptr), @intCast(bytes));
    if (got < 0) {
        s.wide.clearRetainingCapacity();
        return null;
    }
    const used = @min(@as(usize, @intCast(got)), units * 2);
    s.wide.shrinkRetainingCapacity(used / 2);
    return decode(gpa, out, s.wide.items);
}

/// Reads the strings of one `WM_IME_COMPOSITION` through its input context.
pub fn read(himc: HIMC, flags: u32, s: *State, gpa: std.mem.Allocator) Message {
    var m: Message = .{};
    if (flags & GCS_RESULTSTR != 0) if (string(himc, GCS_RESULTSTR, s, gpa, &s.result)) |text| {
        m.result = text;
    };
    if (flags & GCS_COMPSTR != 0) if (string(himc, GCS_COMPSTR, s, gpa, &s.composition)) |text| {
        m.composition = text;
        // The cursor is in UTF-16 units of the composition; at its end when the
        // message does not say.
        var caret: usize = s.wide.items.len;
        if (flags & GCS_CURSORPOS != 0) {
            const pos = ImmGetCompositionStringW(himc, GCS_CURSORPOS, null, 0);
            if (pos >= 0) caret = @intCast(pos);
        }
        caret = @min(caret, s.wide.items.len);
        m.caret = byteOfUnit(s.wide.items, caret);
    };
    return m;
}

/// The ops of a `WM_IME_COMPOSITION`; null when there is nothing to apply (or no
/// input context: no IME).
pub fn compose(s: *State, h: w.HWND, flags: u32, gpa: std.mem.Allocator) ?[]const ctx_mod.TextOp {
    const himc = ImmGetContext(h) orelse return null;
    defer _ = ImmReleaseContext(h, himc);
    const m = read(himc, flags, s, gpa);
    if (m.result.len == 0 and m.composition == null) return null;
    const n = ops(s, m, &s.out);
    return if (n.len == 0) null else n;
}

/// Places the composition and candidate windows at the caret: IMM's points are
/// client pixels, and the caret is in view points.
///
/// The candidate list is placed with `CFS_EXCLUDE` rather than
/// `CFS_CANDIDATEPOS`: the first names the area to keep clear of — the caret's
/// own line — and the IME puts the list below it. The second pins the list's
/// corner to a point the IME may still move, so the list had no reason to be
/// under the text at all.
pub fn follow(h: w.HWND, c: *ctx_mod.Context, scale: f32, s: *State) void {
    const f = c.focused_text orelse return;
    if (s.placing) return;
    s.placing = true;
    defer s.placing = false;
    const himc = ImmGetContext(h) orelse return;
    defer _ = ImmReleaseContext(h, himc);

    const r = f.caret_rect;
    const left: i32 = @intFromFloat(r.x * scale);
    const top: i32 = @intFromFloat(r.y * scale);
    const line_h: i32 = @intFromFloat(@max(1, r.h * scale));
    const bottom = top + line_h;

    // `CFS_FORCE_POSITION`, not `CFS_POINT`: with the latter the IME may move
    // the composition window elsewhere, and it did — off the field.
    const comp: COMPOSITIONFORM = .{ .dwStyle = CFS_FORCE_POSITION, .ptCurrentPos = .{ .x = left, .y = top } };
    _ = ImmSetCompositionWindow(himc, &comp);

    const cand: CANDIDATEFORM = .{
        .dwStyle = CFS_EXCLUDE,
        .ptCurrentPos = .{ .x = left, .y = bottom },
        .rcArea = .{ .left = left, .top = top, .right = left + line_h, .bottom = bottom },
    };
    _ = ImmSetCandidateWindow(himc, &cand);
}

/// `CFS_FORCE_POSITION` (0x0020) lives here with the forms that use it.
pub const CFS_FORCE_POSITION = 0x0020;

/// `follow` only when the caret moved: a frame that did not move it has nothing
/// to tell the IME.
pub fn followIfMoved(h: w.HWND, c: *ctx_mod.Context, scale: f32, s: *State) void {
    const f = c.focused_text orelse return;
    if (f.caret_rect.x == s.told_x and f.caret_rect.y == s.told_y) return;
    s.told_x = f.caret_rect.x;
    s.told_y = f.caret_rect.y;
    follow(h, c, scale, s);
}

/// `WM_IME_NOTIFY`: the IME changed something about its own windows.
///
/// `IMN_SETCANDIDATEPOS` and `IMN_SETCOMPOSITIONWINDOW` are **echoes** of
/// `ImmSetCandidateWindow`/`ImmSetCompositionWindow` and place nothing — see the
/// note at the top of the file. `IMN_OPENCANDIDATE`/`IMN_CHANGECANDIDATE` are
/// worth a placement, and its echo then lands on the ignored arm.
pub fn notify(h: w.HWND, c: *ctx_mod.Context, scale: f32, s: *State, wp: w.WPARAM) void {
    switch (@as(u32, @intCast(wp))) {
        IMN_OPENCANDIDATE, IMN_CHANGECANDIDATE => follow(h, c, scale, s),
        // Echoes (place nothing), and state that places nothing.
        IMN_SETCANDIDATEPOS, IMN_SETCOMPOSITIONWINDOW, IMN_SETCOMPOSITIONFONT, IMN_SETOPENSTATUS, IMN_CLOSECANDIDATE => {},
        else => {},
    }
}

/// `WM_IME_REQUEST`: the IME asking where to put its windows, in `wp`, writing
/// the answer through `lp`. Answering 0 means "I have no position", which is why
/// a modern IME falls back to a default spot.
pub fn request(c: *ctx_mod.Context, scale: f32, wp: w.WPARAM, lp: w.LPARAM) w.LRESULT {
    const f = c.focused_text orelse return 0;
    const r = f.caret_rect;
    const left: i32 = @intFromFloat(r.x * scale);
    const top: i32 = @intFromFloat(r.y * scale);
    const line_h: i32 = @intFromFloat(@max(1, r.h * scale));
    switch (@as(u32, @intCast(wp))) {
        IMR_COMPOSITIONWINDOW => {
            // A POINT: where the composition window's upper left goes.
            const out: *w.POINT = @ptrFromInt(@as(usize, @bitCast(lp)));
            out.* = .{ .x = left, .y = top };
            return 1;
        },
        IMR_CANDIDATEWINDOW => {
            // A CANDIDATEFORM, filled the way `follow` fills it.
            const out: *CANDIDATEFORM = @ptrFromInt(@as(usize, @bitCast(lp)));
            out.* = .{
                .dwStyle = CFS_EXCLUDE,
                .ptCurrentPos = .{ .x = left, .y = top + line_h },
                .rcArea = .{ .left = left, .top = top, .right = left + line_h, .bottom = top + line_h },
            };
            return 1;
        },
        else => return 0,
    }
}

/// `WM_IME_SETCONTEXT`: nanoui draws the composition in its own text field, so
/// the system's composition window is not shown; the candidate window still is.
///
/// Only that one bit is cleared — every other bit in `lParam` reaches
/// `DefWindowProc` exactly as it arrived, which is why this is a mask on the
/// original `isize` and not a truncation to 32 bits: `lParam` is 64 wide on a
/// 64-bit build and the upper half is not ours to drop.
pub fn setContext(h: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) w.LRESULT {
    return w.DefWindowProcW(h, msg, wp, clearCompositionBit(lp));
}

/// `lParam` with only `ISC_SHOWUICOMPOSITIONWINDOW` cleared, in the width
/// `LPARAM` actually has.
///
/// The bit is `0x80000000`, which is bit 31 — *not* the sign bit of a 64-bit
/// `isize`. Widening the constant to the parameter's width by sign extension
/// (what `~@as(isize, ISC_SHOWUICOMPOSITIONWINDOW)` does) would clear the whole
/// upper half of `lParam` as well, dropping every flag above bit 31. This masks
/// with the value zero-extended, so only bit 31 changes.
pub fn clearCompositionBit(lp: w.LPARAM) w.LPARAM {
    const bits: usize = @bitCast(lp);
    const mask: usize = ~@as(usize, ISC_SHOWUICOMPOSITIONWINDOW);
    return @bitCast(bits & mask);
}

/// A character the keyboard or the IME produced, as a UTF-16 unit: `WM_CHAR`,
/// `WM_IME_CHAR`, or one half of a surrogate pair.
///
/// A composition in progress wins over it. The letters being composed arrive
/// here as well as through `WM_IME_COMPOSITION`, and only the composition
/// counts — otherwise the pinyin is inserted in front of the characters it
/// becomes ("sa d'sa d'萨达").
pub fn char(surface: anytype, unit: u16) void {
    if (surface.ime.composing) return;
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        surface.high = unit;
        return;
    }
    var cp: u21 = unit;
    if (unit >= 0xDC00 and unit <= 0xDFFF) {
        if (surface.high == 0) return;
        cp = 0x10000 + ((@as(u21, surface.high) - 0xD800) << 10) + (unit - 0xDC00);
        surface.high = 0;
    }
    // Controls (Ctrl+letters, Enter, Tab, Backspace) came as keys.
    if (cp < 0x20 or cp == 0x7f) return;
    const n = std.unicode.utf8Encode(cp, &surface.chars) catch return;
    surface.ctx.input.chars = surface.chars[0..n];
    surface.frame();
}

/// Every `WM_IME_*` message, in one place: null when `msg` is not one of them,
/// so `surface.zig` falls through to `DefWindowProc`.
///
/// The message numbers are matched here rather than in `surface.zig` so the
/// window procedure stays about the window, and this file about the input
/// method.
pub fn handle(surface: anytype, h: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
    const s = &surface.ime;
    const c = &surface.ctx;
    switch (msg) {
        // The composition starts: the keys belong to the IME from here until it
        // ends, and its windows go to the caret.
        w.WM_IME_STARTCOMPOSITION => {
            s.composing = true;
            follow(h, c, surface.scale, s);
        },
        w.WM_IME_COMPOSITION => {
            // 0, not `DefWindowProc`: its default handling posts `WM_IME_CHAR`
            // for the result string, which would put the committed text in a
            // second time.
            if (compose(s, h, @intCast(lp), surface.gpa)) |made| {
                c.input.ops = made;
                surface.frame();
                c.input.ops = &.{};
            }
            follow(h, c, surface.scale, s);
        },
        w.WM_IME_ENDCOMPOSITION => {
            var op: [1]ctx_mod.TextOp = undefined;
            const unmark = end(s, &op);
            if (unmark.len > 0) {
                c.input.ops = unmark;
                surface.frame();
                c.input.ops = &.{};
            }
        },
        w.WM_IME_SETCONTEXT => {
            // Losing the keyboard ends any composition: a field left `composing`
            // would swallow the next keystroke.
            if (wp == 0) s.composing = false;
            return setContext(h, msg, wp, lp);
        },
        w.WM_IME_NOTIFY => notify(h, c, surface.scale, s, wp),
        w.WM_IME_REQUEST => return request(c, surface.scale, wp, lp),
        else => return null,
    }
    return 0;
}

