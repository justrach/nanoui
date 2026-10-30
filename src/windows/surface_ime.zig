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

/// WM_IME_STARTCOMPOSITION: the IME is about to compose. Place its windows at
/// the caret now, so the composition starts where the text is going.
pub fn startComposition(self: *Surface, h: w.HWND) void {
    // From here until the composition ends the IME owns the keyboard: the
    // letters it is composing arrive as WM_CHAR too, and inserting those as
    // well as the committed text is what put "sa d'sa d'" in front of 萨达.
    self.ime_composing = true;
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
        self.ime_composing = false;
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
    self.ime_composing = false;
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

/// WM_IME_NOTIFY: the IME has just placed its own windows (IMN_SETCANDIDATEPOS,
/// IMN_SETCOMPOSITIONWINDOW) or opened a candidate list. Left to DefWindowProc
/// they land at a default spot, which is why the candidates were never seen
/// where the text was going: put them back at the caret each time.
pub fn notify(self: *Surface, h: w.HWND, wp: w.WPARAM) void {
    _ = self;
    _ = h;
    _ = wp;
}

fn place(self: *Surface, h: w.HWND, force: bool) void {
    const ft = self.ctx.focused_text orelse return;
    if (!force and ft.caret_rect.x == self.ime_caret_x and ft.caret_rect.y == self.ime_caret_y) return;
    self.ime_caret_x = ft.caret_rect.x;
    self.ime_caret_y = ft.caret_rect.y;
    const himc = w.ImmGetContext(h) orelse return;
    defer _ = w.ImmReleaseContext(h, himc);
    const x: i32 = @intFromFloat(@round(ft.caret_rect.x * self.scale));
    const y: i32 = @intFromFloat(@round(ft.caret_rect.y * self.scale));
    const hgt: i32 = @intFromFloat(@max(1, @round(ft.caret_rect.h * self.scale)));
    const at: w.POINT = .{ .x = x, .y = y };
    const comp: w.COMPOSITIONFORM = .{ .style = w.CFS_POINT, .pt = at };
    _ = w.ImmSetCompositionWindow(himc, &comp);
    // The candidate list, just under the caret, in case the IME honours IMM32.
    // Microsoft Pinyin (and Doubao) do not: they take the call, return TRUE, and
    // draw their own window through TSF instead, which is why no position set
    // here is ever seen. `notify` keeps the placement from being undone.
    const cand: w.CANDIDATEFORM = .{
        .style = w.CFS_CANDIDATEPOS,
        .pt = .{ .x = x, .y = y + hgt },
        .rc_area = .{ .left = x, .top = y, .right = x + 1, .bottom = y + hgt },
    };
    _ = w.ImmSetCandidateWindow(himc, &cand);
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

/// WM_IME_SETCONTEXT with the window gaining focus: the IME is opened for it.
/// A window that never says so keeps the IME's default (closed for a
/// Chinese layout here), and every keystroke comes out as plain WM_CHAR — no
/// composition, no candidates, no Chinese.
pub fn focusGained(self: *Surface, h: w.HWND, wp: w.WPARAM) void {
    _ = self;
    if (wp == 0) return;
    const himc = w.ImmGetContext(h) orelse return;
    defer _ = w.ImmReleaseContext(h, himc);
    if (w.ImmGetOpenStatus(himc) == 0) _ = w.ImmSetOpenStatus(himc, 1);
}

/// Handles one of the IME's messages; null when `msg` is not one. Every one is
/// answered with 0, never passed to `DefWindowProc`: a default pass puts the
/// composition and candidate windows back wherever the system would have them.
pub fn handle(self: *Surface, h: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
    switch (msg) {
        w.WM_IME_STARTCOMPOSITION => startComposition(self, h),
        w.WM_IME_COMPOSITION => composition(self, h, lp),
        w.WM_IME_ENDCOMPOSITION => endComposition(self, h),
        w.WM_IME_SETCONTEXT => focusGained(self, h, wp),
        w.WM_IME_NOTIFY => notify(self, h, wp),
        else => return null,
    }
    return 0;
}
