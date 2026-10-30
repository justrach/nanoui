//! The IME on Windows: where its composition and candidate windows go, and the
//! text being composed. macOS gets both through NSTextInputClient
//! (`ui/textinput.zig`); here the IME talks to the window directly, in
//! WM_IME_* messages, and has to be told where the caret is — otherwise its
//! windows sit at a default position and do not follow typing.
//!
//! `surface.zig` keeps the events and calls this while it handles them.
const std = @import("std");
const w = @import("win32.zig");
const ctx_mod = @import("../ui/context.zig");
const surface = @import("surface.zig");
const Surface = surface.Surface;

/// The IME's state for one window. `surface.zig` holds one of these; the fields
/// are here because only this file uses them, and each one has a reason that is
/// easy to lose from a distance.
pub const State = struct {
    /// A composition is running: the letters it is composing also arrive as
    /// `WM_CHAR`, and only the composition counts (else the pinyin is inserted
    /// in front of the characters it becomes).
    composing: bool = false,
    /// A placement call is running. `ImmSetCandidateWindow` sends
    /// `IMN_SETCANDIDATEPOS` and `ImmSetCompositionWindow` sends
    /// `IMN_SETCOMPOSITIONWINDOW`, both synchronously from inside the call; a
    /// handler that placed again from there would recurse until the window
    /// stopped responding. That is exactly what happened once, and this guard
    /// makes it impossible whatever the handler does.
    ///
    /// One flag per window, not one for both: the two calls are independent, and
    /// a shared flag would make placing the composition silently skip placing
    /// the list when they happen in sequence.
    placing_composition: bool = false,
    placing_candidate: bool = false,
    /// The caret the IME was last told about, in view points, so a frame that
    /// did not move it says nothing (taking a context costs a call each way).
    caret_x: f32 = -1e9,
    caret_y: f32 = -1e9,
};

/// WM_IME_STARTCOMPOSITION: the IME is about to compose. Place its windows at
/// the caret now, so the composition starts where the text is going.
pub fn startComposition(self: *Surface, h: w.HWND) void {
    // From here until the composition ends the IME owns the keyboard: the
    // letters it is composing arrive as WM_CHAR too, and inserting those as
    // well as the committed text is what put "sa d'sa d'" in front of 萨达.
    self.ime.composing = true;
    placeWindows(self, h);
}

/// WM_IME_COMPOSITION: the composition changed (`GCS_COMPSTR`) or was committed
/// (`GCS_RESULTSTR`). The committed text is inserted; the composition string is
/// set as marked text, underlined, the way the Mac does it.
pub fn composition(self: *Surface, h: w.HWND, lp: w.LPARAM) void {
    const himc = w.ImmGetContext(h) orelse return;
    defer _ = w.ImmReleaseContext(h, himc);
    const flags: u32 = @intCast(lp & 0xffffffff);

    if (flags & w.GCS_RESULTSTR != 0) {
        self.ime.composing = false;
        // The composition became text. `.insert` replaces what is marked (the
        // composition string), so the mark must still be there: unmarking first
        // would leave the pinyin in the field and append the characters after
        // it, which is what put "sa d'sa d'" in front of 萨达.
        const text = readString(self, himc, w.GCS_RESULTSTR);
        defer if (text) |t| self.gpa.free(t);
        if (text) |t| if (t.len > 0) {
            const ops = self.text_scratch[0..1];
            ops[0] = .{ .insert = t };
            send(self, ops[0..1]);
        };
        placeWindows(self, h);
        return;
    }

    if (flags & w.GCS_COMPSTR != 0) {
        const text = readString(self, himc, w.GCS_COMPSTR);
        defer if (text) |t| self.gpa.free(t);
        const ops = self.text_scratch[0..1];
        if (text) |t| if (t.len > 0) {
            // The caret inside the composition, so the underline covers it.
            const cur = w.ImmGetCompositionStringW(himc, w.GCS_CURSORPOS, null, 0);
            const at: usize = if (cur > 0) @intCast(cur) else 0;
            ops[0] = .{ .set_marked = .{ .text = t, .sel_start = at, .sel_len = 0 } };
            send(self, ops[0..1]);
        } else {
            ops[0] = .unmark;
            send(self, ops[0..1]);
        };
        placeWindows(self, h);
    }
}

/// WM_IME_ENDCOMPOSITION: nothing is being composed; the mark goes.
pub fn endComposition(self: *Surface, h: w.HWND) void {
    self.ime.composing = false;
    if (self.ctx.focused_text) |ft| if (ft.marked != null) {
        const ops = self.text_scratch[0..1];
        ops[0] = .unmark;
        send(self, ops[0..1]);
    };
    placeWindows(self, h);
}

/// Runs one frame with `ops` as its text operations.
fn send(self: *Surface, ops: []const ctx_mod.TextOp) void {
    if (ops.len == 0) return;
    self.ctx.input.ops = ops;
    self.frame();
    self.ctx.input.ops = &.{};
}

/// Puts the IME's composition and candidate windows under the caret, in client
/// pixels (the view's points times the display scale). Only when the caret
/// moved: a frame that did not move it has nothing to tell the IME, and taking
/// its context costs a call each way.
pub fn placeWindows(self: *Surface, h: w.HWND) void {
    place(self, h, false);
}

/// WM_IME_NOTIFY: the IME changed something about its own windows or its state.
///
/// The one rule that matters here, learned by freezing the window on the first
/// click into a field: **`IMN_SETCANDIDATEPOS` and `IMN_SETCOMPOSITIONWINDOW`
/// are echoes.** Microsoft documents that `ImmSetCandidateWindow` "causes an
/// `IMN_SETCANDIDATEPOS` command to be sent" (and `ImmSetCompositionWindow` does
/// the same for `IMN_SETCOMPOSITIONWINDOW`) — synchronously, on this thread, to
/// this window. Placing a window from inside the notification that the window's
/// own placement sent is therefore an infinite recursion: `place()` →
/// `ImmSetCandidateWindow` → `IMN_SETCANDIDATEPOS` → `place()` → … The window
/// stops responding the moment a field is focused, which is what was seen.
/// Those two are answered with nothing at all.
///
/// What remains:
///
///   - `IMN_OPENCANDIDATE`/`IMN_CHANGECANDIDATE`: the list is new or its page
///     changed. Place it once — the echo of that call lands on the ignored arm
///     above and stops there.
///   - `IMN_CLOSECANDIDATE`: the list is gone; redraw, so the frame does not
///     keep whatever it drew for it.
///   - `IMN_SETOPENSTATUS` (Shift, the taskbar) and `IMN_SETCOMPOSITIONFONT`:
///     state, nothing to place.
pub fn notify(self: *Surface, h: w.HWND, wp: w.WPARAM) void {
    const cmd: u32 = @intCast(wp);
    switch (cmd) {
        w.IMN_OPENCANDIDATE, w.IMN_CHANGECANDIDATE => {
            placeCandidateWindow(self, h);
            self.requestFrame();
        },
        w.IMN_CLOSECANDIDATE => self.requestFrame(),
        // Echoes of our own placement calls (see above), and state that places
        // nothing. Answering either of the first two by placing again is the
        // freeze: the notification is sent from inside the placement call.
        w.IMN_SETCANDIDATEPOS, w.IMN_SETCOMPOSITIONWINDOW, w.IMN_SETCOMPOSITIONFONT, w.IMN_SETOPENSTATUS => {},
        else => {},
    }
}

/// WM_IME_REQUEST: the IME asking the application a question, in `wp`, with the
/// answer written through `lp`. Answering `0` means "I know nothing", which
/// tells a modern IME it has no position to use — that is why `IMR_CANDIDATEWINDOW`
/// and `IMR_COMPOSITIONWINDOW` matter and the rest do not.
///
/// `IMR_COMPOSITIONFONT` is deliberately still unanswered: the reply is a
/// `LOGFONTW` and the field's font is the theme's, whose metrics the IME does not
/// need to lay out its own window.
pub fn request(self: *Surface, h: w.HWND, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
    const query: u32 = @intCast(wp);
    switch (query) {
        w.IMR_COMPOSITIONWINDOW => {
            // A POINT, in client coordinates: where the composition window's
            // upper left goes.
            const c = caretOf(self) orelse return 0;
            const out: *w.POINT = @ptrFromInt(@as(usize, @bitCast(lp)));
            out.* = .{ .x = c.x, .y = c.y };
            return 1;
        },
        w.IMR_CANDIDATEWINDOW => {
            // A CANDIDATEFORM, filled the same way `placeCandidateWindow` does.
            const c = caretOf(self) orelse return 0;
            const out: *w.CANDIDATEFORM = @ptrFromInt(@as(usize, @bitCast(lp)));
            const line_bottom = c.y + c.h;
            out.* = .{
                .index = 0,
                .style = w.CFS_EXCLUDE,
                .pt = .{ .x = c.x, .y = line_bottom },
                .rc_area = .{ .left = c.x, .top = c.y, .right = c.x + c.h, .bottom = line_bottom },
            };
            return 1;
        },
        else => {
            _ = h;
            return 0;
        },
    }
}

/// Where the caret is, in client pixels (the window's, which is what IMM32
/// wants: `CANDIDATEFORM` and `COMPOSITIONFORM` are both relative to the upper
/// left of the window that contains the list, never the screen).
const Caret = struct { x: i32, y: i32, h: i32 };

fn caretOf(self: *Surface) ?Caret {
    const ft = self.ctx.focused_text orelse return null;
    return .{
        .x = @intFromFloat(@round(ft.caret_rect.x * self.scale)),
        .y = @intFromFloat(@round(ft.caret_rect.y * self.scale)),
        .h = @intFromFloat(@max(1, @round(ft.caret_rect.h * self.scale))),
    };
}

/// The composition window: the pinyin being typed, underlined, at the caret.
/// `CFS_FORCE_POSITION` rather than `CFS_POINT`: with `CFS_POINT` the IME is
/// free to move the window elsewhere, and it did — off the field, which is one
/// reason the pinyin was never seen where it was being typed.
///
/// Re-entrancy guard: `ImmSetCompositionWindow` sends `IMN_SETCOMPOSITIONWINDOW`
/// from inside this call. That notification is ignored now, but a guard here
/// means a future handler cannot turn the echo into a freeze again — the second
/// call in returns without doing anything.
pub fn placeCompositionWindow(self: *Surface, h: w.HWND) void {
    if (self.ime.placing_composition) return;
    self.ime.placing_composition = true;
    defer self.ime.placing_composition = false;
    const c = caretOf(self) orelse return;
    const himc = w.ImmGetContext(h) orelse return;
    defer _ = w.ImmReleaseContext(h, himc);
    const comp: w.COMPOSITIONFORM = .{
        .style = w.CFS_FORCE_POSITION,
        .pt = .{ .x = c.x, .y = c.y },
    };
    _ = w.ImmSetCompositionWindow(himc, &comp);
}

/// The candidate list. `CFS_EXCLUDE` with the caret as the point of interest and
/// the caret's own line as the area to keep clear — which is what a text editor
/// uses, and what Microsoft documents as "exclude the candidate window from the
/// area specified by `rcArea`".
///
/// The list then goes just below that line, placed by the IME. `CFS_CANDIDATEPOS`
/// was used before, which pins the list's own corner to a point the IME may
/// still adjust, and gave it no line to avoid, so it had no reason to be under
/// the text at all.
pub fn placeCandidateWindow(self: *Surface, h: w.HWND) void {
    if (self.ime.placing_candidate) return;
    self.ime.placing_candidate = true;
    defer self.ime.placing_candidate = false;
    const c = caretOf(self) orelse return;
    const himc = w.ImmGetContext(h) orelse return;
    defer _ = w.ImmReleaseContext(h, himc);
    // The caret's line, and the field's own height below it, so the list cannot
    // cover the text being typed into.
    const line_bottom = c.y + c.h;
    const cand: w.CANDIDATEFORM = .{
        .index = 0,
        .style = w.CFS_EXCLUDE,
        .pt = .{ .x = c.x, .y = line_bottom },
        .rc_area = .{ .left = c.x, .top = c.y, .right = c.x + c.h, .bottom = line_bottom },
    };
    _ = w.ImmSetCandidateWindow(himc, &cand);
}

/// Both of them, when the caller cannot tell which moved.
fn place(self: *Surface, h: w.HWND, force: bool) void {
    const ft = self.ctx.focused_text orelse return;
    if (!force and ft.caret_rect.x == self.ime.caret_x and ft.caret_rect.y == self.ime.caret_y) return;
    self.ime.caret_x = ft.caret_rect.x;
    self.ime.caret_y = ft.caret_rect.y;
    placeCompositionWindow(self, h);
    placeCandidateWindow(self, h);
}

/// A composition string from `himc` as UTF-8, in the surface's allocator.
fn readString(self: *Surface, himc: w.HIMC, index: u32) ?[]u8 {
    const bytes = w.ImmGetCompositionStringW(himc, index, null, 0);
    if (bytes <= 0) return null;
    const units: usize = @intCast(@divTrunc(bytes, 2));
    if (units == 0) return null;
    const buf = self.gpa.alloc(u16, units) catch return null;
    defer self.gpa.free(buf);
    const got = w.ImmGetCompositionStringW(himc, index, buf.ptr, @intCast(bytes));
    if (got <= 0) return null;
    const n: usize = @intCast(@divTrunc(got, 2));
    return std.unicode.utf16LeToUtf8Alloc(self.gpa, buf[0..n]) catch null;
}

/// A character the keyboard or the IME produced, as a UTF-16 unit: `WM_CHAR`,
/// `WM_IME_CHAR`, or one half of a surrogate pair.
///
/// A composition in progress wins over it. The letters being composed arrive
/// here as well as through `WM_IME_COMPOSITION`, and only the composition
/// counts — otherwise the pinyin is inserted in front of the characters it
/// becomes ("sa d'sa d'萨达").
pub fn char(self: *Surface, unit: u16) void {
    if (self.ime.composing) return;
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        self.high = unit;
        return;
    }
    var cp: u21 = unit;
    if (unit >= 0xDC00 and unit <= 0xDFFF) {
        if (self.high == 0) return;
        cp = 0x10000 + ((@as(u21, self.high) - 0xD800) << 10) + (unit - 0xDC00);
        self.high = 0;
    }
    // Controls (Ctrl+letters, Enter, Tab, Backspace) came as keys.
    if (cp < 0x20 or cp == 0x7f) return;
    const n = std.unicode.utf8Encode(cp, &self.chars) catch return;
    self.ctx.input.chars = self.chars[0..n];
    self.frame();
}

/// Handles one of the IME's messages; null when `msg` is not one, which lets
/// `surface.zig` fall through to `DefWindowProc`.
///
/// Every one of these is answered `0` except `WM_IME_SETCONTEXT`, which returns
/// null. That one carries `ISC_*` bits in `lParam` saying which of the IME's own
/// windows the system may draw; an app that draws the composition itself clears
/// the composition bit, and this one does not draw it, so the bits must reach
/// `DefWindowProc` untouched. Answering it with a bare `0` cleared them all —
/// telling Windows the application draws everything, which it does not.
pub fn handle(self: *Surface, h: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
    switch (msg) {
        w.WM_IME_STARTCOMPOSITION => startComposition(self, h),
        w.WM_IME_COMPOSITION => composition(self, h, lp),
        w.WM_IME_ENDCOMPOSITION => endComposition(self, h),
        // Handed on to `DefWindowProc` so the ISC_* bits in lParam reach it.
        // Answering 0 cleared them, which tells Windows the app draws the
        // composition and candidate windows itself; it draws neither.
        w.WM_IME_SETCONTEXT => return null,
        w.WM_IME_NOTIFY => notify(self, h, wp),
        w.WM_IME_REQUEST => return request(self, h, wp, lp),
        // A character the IME produced without a composition (a soft keyboard, a
        // direct commit). Its wParam is a UTF-16 unit and it replaces WM_CHAR,
        // so a field that only listened for WM_CHAR never saw it.
        w.WM_IME_CHAR => {
            char(self, @truncate(wp));
            return 0;
        },
        else => return null,
    }
    return 0;
}
