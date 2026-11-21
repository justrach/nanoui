//! GTK sends preedit and committed text through one IM context shared by the surface's fields.
//!
//! 1. Signals queue input and ask for a frame. A nested GTK loop can send more
//!    text during a build, so beforeBuild lends the field separate frame storage.
//! 2. Resetting the context or changing its focus can emit synchronous signals.
//!    While finishing a draft, mute those callbacks: the field already holds the text.
//! 3. When a field loses focus or finishes its draft, cycle the active IM's focus.
//!    On Wayland a reset alone can leave the old candidate active at the new caret.
//! 4. GTK 4 wants widget coordinates. GTK 3 wants GdkWindow coordinates, so a
//!    windowless widget such as GtkGLArea adds its allocation in the parent's window.
const std = @import("std");
const Surface = @import("surface.zig").Surface;
const gtk = @import("gtk.zig");
const context = @import("../ui/context.zig");
const Rect = @import("../ui/types.zig").Rect;
const byteOfCodepoint = @import("../ui/textfield_lines.zig").byteOfCodepoint;

pub const State = struct {
    /// Committed UTF-8 text queued for the next build.
    pending_text: std.ArrayList(u8) = .empty,
    /// The preedit notification the next build will apply.
    pending_preedit: enum { none, changed, cancel } = .none,
    /// The focus id that owns the queued input.
    input_target: u64 = 0,
    /// The field showing the marked range of the current draft.
    marked_field: ?u64 = null,
    /// Ignore commit and preedit signals from the current call into GTK.
    ignoring_callbacks: bool = false,

    /// Committed text borrowed by the current build.
    frame_text: std.ArrayList(u8) = .empty,
    /// Space for a commit followed by a preedit update in the same build.
    out: [2]context.TextOp = undefined,
    /// GTK's allocated preedit string, borrowed by the field until afterBuild.
    preedit: ?[*:0]u8 = null,
    /// The text field focused before the build, or zero if none.
    field_before: u64 = 0,

    pub fn deinit(state: *State, gpa: std.mem.Allocator) void {
        state.pending_text.deinit(gpa);
        state.frame_text.deinit(gpa);
        if (state.preedit) |str| gtk.api.g_free(str);
        state.* = .{};
    }
};

pub fn connect(s: *Surface) void {
    if (!gtk.v4) gtk.connect(s.area, "unrealize", @ptrCast(&onUnrealize), s);
    gtk.connect(s.im, "commit", @ptrCast(&onCommit), s);
    gtk.connect(s.im, "preedit-changed", @ptrCast(&onPreeditChanged), s);
}

fn onUnrealize(_: *gtk.Widget, data: ?*anyopaque) callconv(.c) void {
    const s: *Surface = @ptrCast(@alignCast(data.?));
    gtk.v3.gtk_im_context_set_client_window(s.im, null);
}

pub fn disconnect(s: *Surface) void {
    const match_data = 1 << 4;
    _ = gtk.api.g_signal_handlers_disconnect_matched(s.im, match_data, 0, 0, null, null, s);
    _ = gtk.api.g_signal_handlers_disconnect_matched(s.area, match_data, 0, 0, null, null, s);
    if (gtk.v4) gtk.v4api.gtk_im_context_set_client_widget(s.im, null) else gtk.v3.gtk_im_context_set_client_window(s.im, null);
    s.ime_state.deinit(s.gpa);
}

fn syncInputTarget(s: *Surface) void {
    const state = &s.ime_state;
    if (state.input_target == s.ctx.focus) return;
    state.input_target = s.ctx.focus;
    state.pending_text.clearRetainingCapacity();
    state.pending_preedit = .none;
}

fn onPreeditChanged(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const s: *Surface = @ptrCast(@alignCast(data.?));
    if (s.ime_state.ignoring_callbacks or !s.ctx.focus_is_text) return;
    syncInputTarget(s);
    s.ime_state.pending_preedit = .changed;
    s.frame();
}

fn onCommit(_: *anyopaque, str: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    const s: *Surface = @ptrCast(@alignCast(data.?));
    if (!s.ime_state.ignoring_callbacks) queueCommit(s, std.mem.span(str));
}

fn queueCommit(s: *Surface, text: []const u8) void {
    if (text.len == 0) return;
    syncInputTarget(s);
    s.ime_state.pending_text.appendSlice(s.gpa, text) catch return;
    s.ime_state.pending_preedit = .none;
    s.frame();
}

pub fn beforeBuild(s: *Surface) void {
    const state = &s.ime_state;
    state.field_before = if (s.ctx.focused_text) |field| field.id else 0;
    syncInputTarget(s);
    var n: usize = 0;
    if (state.pending_text.items.len != 0) {
        std.mem.swap(std.ArrayList(u8), &state.frame_text, &state.pending_text);
        state.pending_text.clearRetainingCapacity();
        if (state.marked_field != null or (state.pending_preedit == .changed and s.ctx.focus_is_text)) {
            state.out[0] = .{ .insert = state.frame_text.items };
            s.ctx.input.ops = state.out[0..1];
            n = 1;
        } else s.ctx.input.chars = state.frame_text.items;
        state.marked_field = null;
    }
    const pending = state.pending_preedit;
    if (pending == .none) return;
    state.pending_preedit = .none;
    var cursor_chars: c_int = 0;
    if (pending == .changed) gtk.api.gtk_im_context_get_preedit_string(s.im, &state.preedit, null, &cursor_chars);
    const text = if (pending == .cancel) "" else std.mem.span(state.preedit orelse return);
    // An empty notification after commit must not delete a new selection.
    if (text.len != 0 or (state.marked_field == s.ctx.focus and
        s.ctx.focused_text != null and s.ctx.focused_text.?.marked != null))
    {
        state.out[n] = .{ .set_marked = .{
            .text = text,
            .sel_start = byteOfCodepoint(text, @intCast(@max(0, cursor_chars))),
            .sel_len = 0,
        } };
        s.ctx.input.ops = state.out[0 .. n + 1];
    }
    state.marked_field = if (text.len != 0) s.ctx.focus else null;
}

// Finish the marked text at its old position before moving the insertion point.
fn finishPreedit(s: *Surface) void {
    const state = &s.ime_state;
    const id = state.marked_field orelse return;
    if (s.ctx.edits.getPtr(id)) |e| e.marked = null;
    state.marked_field = null;
    state.pending_preedit = .none;
    resetContext(s);
}

fn mute(state: *State) bool {
    defer state.ignoring_callbacks = true;
    return state.ignoring_callbacks;
}

fn resetContext(s: *Surface) void {
    const was = mute(&s.ime_state);
    defer s.ime_state.ignoring_callbacks = was;
    gtk.api.gtk_im_context_reset(s.im);
}

/// Offer the early GTK 3 event to the IM, then handle a plain Escape it left to the field.
pub fn keyBefore(s: *Surface, e: ?*gtk.Event, escape: bool) bool {
    const input = &s.ctx.input;
    const cancel = escape and !input.ctrl and !input.alt;
    if (e) |event| {
        if (gtk.v3.gtk_im_context_filter_keypress(s.im, event) != 0) return true;
    }
    return cancel and !input.shift and cancelPreedit(s);
}

/// A GTK 3 text key left by the view. An event is supplied if the IM has yet to see it.
pub fn keyAfter(s: *Surface, e: ?*gtk.Event, cp: u21) bool {
    if (e) |event| {
        if (gtk.v3.gtk_im_context_filter_keypress(s.im, event) != 0) return true;
    }
    if (cp >= 0x20 and cp != 0x7f) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return false;
        queueCommit(s, buf[0..n]);
    }
    return true;
}

// Escape not consumed by GTK still cancels the draft in the focused field.
fn cancelPreedit(s: *Surface) bool {
    if (s.ime_state.marked_field != s.ctx.focus) return false;
    resetContext(s);
    s.ime_state.pending_preedit = .cancel;
    s.frame();
    return true;
}

pub fn focusOut(s: *Surface) void {
    // Some IMs commit or clear the draft synchronously during focus_out.
    // The field already contains it.
    const state = &s.ime_state;
    const was = if (state.marked_field != null) mute(state) else state.ignoring_callbacks;
    defer state.ignoring_callbacks = was;
    gtk.api.gtk_im_context_focus_out(s.im);
    finishPreedit(s);
}

pub fn afterBuild(s: *Surface) void {
    if (s.ime_state.preedit) |str| gtk.api.g_free(str);
    s.ime_state.preedit = null;
    endDraft(s);
    placeCandidates(s);
}

fn endDraft(s: *Surface) void {
    const previous_field = s.ime_state.field_before;
    const c = &s.ctx;
    const current_field = if (c.focused_text) |field| field.id else 0;
    const left_previous_field = previous_field != 0 and previous_field != current_field;
    // A click may finish the marked text while keeping this field focused.
    // On Wayland a reset alone can leave its old candidate active at the new caret.
    const preedit_ended = if (s.ime_state.marked_field) |id|
        c.focused_text == null or current_field != id or c.focused_text.?.marked == null
    else
        false;
    if (preedit_ended) finishPreedit(s);
    if ((left_previous_field or preedit_ended) and c.input.window_active) {
        const was = mute(&s.ime_state);
        defer s.ime_state.ignoring_callbacks = was;
        gtk.api.gtk_im_context_focus_out(s.im);
        gtk.api.gtk_im_context_focus_in(s.im);
    }
}

const Offset = struct { x: c_int = 0, y: c_int = 0 };

fn placeCandidates(s: *Surface) void {
    const field = s.ctx.focused_text orelse return;
    var offset: Offset = .{};
    if (!gtk.v4 and gtk.v3.gtk_widget_get_has_window(s.area) == 0) {
        var allocation: gtk.Rectangle = undefined;
        gtk.v3.gtk_widget_get_allocation(s.area, &allocation);
        offset = .{ .x = allocation.x, .y = allocation.y };
    }
    const rect = candidateRect(&s.ctx, field, offset);
    gtk.api.gtk_im_context_set_cursor_location(s.im, &rect);
}

pub fn candidateRect(c: *const context.Context, field: context.FocusedText, offset: Offset) gtk.Rectangle {
    var caret = field.caret_rect;
    // Text fields build against the previous layout. GTK needs the position
    // in the frame just drawn, including when a field first takes focus.
    if (c.rects.get(field.id)) |rect| {
        const prev = c.prev_rects.get(field.id) orelse Rect{};
        caret.x += rect.x - prev.x;
        caret.y += rect.y - prev.y;
        if (!c.focused_multiline) caret.y += (rect.h - prev.h) / 2;
    }
    // GTK takes logical coordinates, including on a scaled display.
    return .{
        .x = @as(c_int, @intFromFloat(@floor(caret.x))) + offset.x,
        .y = @as(c_int, @intFromFloat(@floor(caret.y))) + offset.y,
        .width = @intFromFloat(@max(1, @round(caret.w))),
        .height = @intFromFloat(@max(1, @round(caret.h))),
    };
}
