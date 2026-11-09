//! The native view's side of AppKit's text input (NSTextInputClient): key
//! events go through `interpretKeyEvents:`, which answers with text to
//! insert, an input method's composition, or editing commands from the
//! system's key bindings. They become `TextOp`s for the focused field.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const ctx_mod = @import("context.zig");
const textfield = @import("textfield.zig");
const Surface = @import("surface.zig").Surface;

const NSRange = extern struct { location: usize, length: usize };
const not_found: usize = @as(usize, std.math.maxInt(isize));

extern "c" fn sel_getName(sel: objc.SEL) [*:0]const u8;

pub const methods = [_]objc.Method{
    .{ .name = "insertText:replacementRange:", .imp = &insertText, .types = "v@:@{_NSRange=QQ}" },
    .{ .name = "setMarkedText:selectedRange:replacementRange:", .imp = &setMarkedText, .types = "v@:@{_NSRange=QQ}{_NSRange=QQ}" },
    .{ .name = "unmarkText", .imp = &unmarkText, .types = "v@:" },
    .{ .name = "hasMarkedText", .imp = &hasMarkedText, .types = "c@:" },
    .{ .name = "markedRange", .imp = &markedRange, .types = "{_NSRange=QQ}@:" },
    .{ .name = "selectedRange", .imp = &selectedRange, .types = "{_NSRange=QQ}@:" },
    .{ .name = "validAttributesForMarkedText", .imp = &validAttributes, .types = "@@:" },
    // NSTextInputTraits: macOS 14's inline predictions (`setInlinePredictions`).
    .{ .name = "inlinePredictionType", .imp = &inlinePredictionType, .types = "q@:" },
    .{ .name = "attributedSubstringForProposedRange:actualRange:", .imp = &attributedSubstring, .types = "@@:{_NSRange=QQ}^{_NSRange=QQ}" },
    .{ .name = "firstRectForCharacterRange:actualRange:", .imp = &firstRect, .types = "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}" },
    .{ .name = "characterIndexForPoint:", .imp = &characterIndex, .types = "Q@:{CGPoint=dd}" },
    .{ .name = "doCommandBySelector:", .imp = &doCommand, .types = "v@::" },
    .{ .name = "undo:", .imp = &undoAction, .types = "v@:@" },
    .{ .name = "redo:", .imp = &redoAction, .types = "v@:@" },
    .{ .name = "copy:", .imp = &copyAction, .types = "v@:@" },
    .{ .name = "cut:", .imp = &cutAction, .types = "v@:@" },
    .{ .name = "delete:", .imp = &deleteAction, .types = "v@:@" },
    .{ .name = "selectAll:", .imp = &selectAllAction, .types = "v@:@" },
    .{ .name = "validateMenuItem:", .imp = &validateMenuItem, .types = "c@:@" },
};

/// Operations of the event being interpreted, run as one frame after it.
pub const Queue = struct {
    ops: std.ArrayList(ctx_mod.TextOp) = .empty,
    arena: std.heap.ArenaAllocator,
    /// Inside `keyDown:`: operations wait for the end of the event.
    collecting: bool = false,
    /// The focused field as the operations waiting leave it. An input
    /// method sets its text and asks about it in the same event (where the
    /// composition is, what is selected): the answers are this, not the
    /// last frame's, or it loses its place (Japanese's Space and ↓).
    pending: ?ctx_mod.FocusedText = null,
    text: textfield.TextBuffer = .{},
    edit: ctx_mod.EditState = .{},

    pub fn init(gpa: std.mem.Allocator) Queue {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(q: *Queue, gpa: std.mem.Allocator) void {
        q.ops.deinit(gpa);
        q.arena.deinit();
        q.text.deinit();
    }

    /// Applies `op` to a copy of the focused field `base`, as the frame
    /// will to the field itself.
    pub fn preview(q: *Queue, base: ?ctx_mod.FocusedText, multiline: bool, op: ctx_mod.TextOp) void {
        const f = q.pending orelse base orelse return;
        if (q.pending == null and q.text.replace(0, q.text.buf.items.len, f.text) != f.text.len) return;
        q.edit.caret = f.caret;
        q.edit.anchor = f.anchor;
        q.edit.marked = f.marked;
        var r: textfield.Result = .{};
        textfield.apply(&q.text, &q.edit, op, .{ .multiline = multiline }, .{ .write = ignoreCopy }, &r);
        q.pending = .{ .id = f.id, .text = q.text.text(), .caret = q.edit.caret, .anchor = q.edit.anchor, .marked = q.edit.marked, .caret_rect = f.caret_rect };
    }

    /// The focused field as the input method should see it now.
    pub fn focused(q: *const Queue, base: ?ctx_mod.FocusedText) ?ctx_mod.FocusedText {
        return q.pending orelse base;
    }
};

fn ignoreCopy(_: ?*anyopaque, _: []const u8) void {}

fn push(s: *Surface, op: ctx_mod.TextOp) void {
    logOp(op);
    s.text_queue.ops.append(s.gpa, op) catch return;
    if (!s.text_queue.collecting) return flush(s);
    s.text_queue.preview(s.ctx.focused_text, s.ctx.focused_multiline, op);
}

fn focusedOf(s: *Surface) ?ctx_mod.FocusedText {
    return s.text_queue.focused(s.ctx.focused_text);
}

/// An input method is composing in the focused field: keys are its first.
pub fn composing(s: *Surface) bool {
    const f = focusedOf(s) orelse return false;
    return f.marked != null;
}

fn dupe(s: *Surface, str: []const u8) []const u8 {
    return s.text_queue.arena.allocator().dupe(u8, str) catch "";
}

/// Runs a frame with the queued operations.
pub fn flush(s: *Surface) void {
    const tok = s.token();
    const q = &s.text_queue;
    if (q.ops.items.len == 0 and s.ctx.undo_op == .none) return;
    s.ctx.input.ops = q.ops.items;
    s.frame();
    if (!Surface.alive(tok)) return;
    s.ctx.input.ops = &.{};
    s.ctx.undo_op = .none;
    q.pending = null;
    q.ops.clearRetainingCapacity();
    _ = q.arena.reset(.retain_capacity);
}

/// Sends a key event through the input system; true if a text field
/// had the focus to receive it.
pub fn interpret(s: *Surface, event: objc.Object) bool {
    if (s.ctx.focused_text == null) return false;
    s.text_queue.collecting = true;
    const arr = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{event});
    objc.msg(void, s.nsview, "interpretKeyEvents:", .{arr});
    s.text_queue.collecting = false;
    flush(s);
    return true;
}

fn stringOf(obj: objc.Object) []const u8 {
    // An NSAttributedString or an NSString.
    if (objc.msg(objc.BOOL, obj, "isKindOfClass:", .{objc.class("NSAttributedString")}))
        return objc.fromNSString(objc.msg(?objc.Object, obj, "string", .{}));
    return objc.fromNSString(obj);
}

/// The text an input method replaces (the accent menu's held letter, a
/// reconversion), selected first: `replacement` is UTF-16, ignored when
/// NSNotFound or while composing (the marked text is what is replaced).
fn selectReplacement(s: *Surface, replacement: NSRange) void {
    if (replacement.location == not_found) return;
    const f = focusedOf(s) orelse return;
    if (f.marked != null) return;
    const b = clampRange(f.text, replacement) orelse return;
    push(s, .{ .select = .{ .anchor = b[0], .caret = b[1] } });
}

fn insertText(obj: objc.Object, _: objc.SEL, str: objc.Object, replacement: NSRange) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    const t = stringOf(str);
    // Control characters arrive as commands, not text.
    if (t.len == 1 and (t[0] < 0x20 or t[0] == 0x7f)) return;
    selectReplacement(s, replacement);
    push(s, .{ .insert = dupe(s, t) });
}

fn setMarkedText(obj: objc.Object, _: objc.SEL, str: objc.Object, sel: NSRange, replacement: NSRange) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    selectReplacement(s, replacement);
    const t = dupe(s, stringOf(str));
    const loc: cf.CFIndex = if (sel.location == not_found) 0 else @intCast(@min(sel.location, t.len * 2));
    const len: cf.CFIndex = if (sel.location == not_found) 0 else @intCast(@min(sel.length, t.len * 2));
    const start = cf.byteOffset(t, loc);
    const end = cf.byteOffset(t, loc + len);
    push(s, .{ .set_marked = .{ .text = t, .sel_start = start, .sel_len = end - start } });
}

fn unmarkText(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    push(s, .unmark);
}

fn hasMarkedText(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const s = objc.getZig(Surface, obj) orelse return objc.NO;
    return composing(s);
}

fn range16(text: []const u8, lo: usize, hi: usize) NSRange {
    const a: usize = @intCast(cf.utf16Offset(text, lo));
    const b: usize = @intCast(cf.utf16Offset(text, hi));
    return .{ .location = a, .length = b - a };
}

fn markedRange(obj: objc.Object, _: objc.SEL) callconv(.c) NSRange {
    const s = objc.getZig(Surface, obj) orelse return .{ .location = not_found, .length = 0 };
    const f = focusedOf(s) orelse return .{ .location = not_found, .length = 0 };
    const m = f.marked orelse return .{ .location = not_found, .length = 0 };
    return range16(f.text, m[0], m[1]);
}

fn selectedRange(obj: objc.Object, _: objc.SEL) callconv(.c) NSRange {
    const s = objc.getZig(Surface, obj) orelse return .{ .location = not_found, .length = 0 };
    const f = focusedOf(s) orelse return .{ .location = not_found, .length = 0 };
    return range16(f.text, @min(f.caret, f.anchor), @max(f.caret, f.anchor));
}

/// Whether the system may offer inline predictions in text fields: its
/// completion arrives as marked text, so a letter just typed is held
/// uncommitted until the next one (`ui.setInlinePredictions`).
pub var inline_predictions: bool = true;

fn inlinePredictionType(_: objc.Object, _: objc.SEL) callconv(.c) objc.NSInteger {
    // NSTextInputTraitTypeDefault, NSTextInputTraitTypeNo.
    return if (inline_predictions) 0 else 1;
}

/// `NANOUI_TEXT_LOG=1`: every text operation the input system sends, on stderr.
var text_log: ?bool = null;

fn logOp(op: ctx_mod.TextOp) void {
    if (text_log == null) text_log = std.c.getenv("NANOUI_TEXT_LOG") != null;
    if (!text_log.?) return;
    switch (op) {
        .insert => |t| std.debug.print("text: insert \"{s}\"\n", .{t}),
        .set_marked => |m| std.debug.print("text: set_marked \"{s}\" sel {d}+{d}\n", .{ m.text, m.sel_start, m.sel_len }),
        else => std.debug.print("text: {s}\n", .{@tagName(op)}),
    }
}

fn validAttributes(_: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    return objc.msg(objc.Object, objc.class("NSArray"), "array", .{});
}

/// The field's text in `r` (UTF-16), as input methods read around the
/// caret to reconvert or to pick the next candidate; `actual` gets the part
/// that exists.
fn attributedSubstring(obj: objc.Object, _: objc.SEL, r: NSRange, actual: ?*NSRange) callconv(.c) ?objc.Object {
    const s = objc.getZig(Surface, obj) orelse return null;
    const f = focusedOf(s) orelse return null;
    const b = clampRange(f.text, r) orelse return null;
    if (actual) |a| a.* = range16(f.text, b[0], b[1]);
    const str = objc.nsString(f.text[b[0]..b[1]]);
    const as = objc.msg(objc.Object, objc.class("NSAttributedString"), "alloc", .{});
    return objc.msg(objc.Object, objc.msg(objc.Object, as, "initWithString:", .{str}), "autorelease", .{});
}

/// A UTF-16 range in `text` as byte offsets, cut to the text; null when it
/// starts past the end.
pub fn clampRange(text: []const u8, r: NSRange) ?[2]usize {
    if (r.location == not_found) return null;
    const n: usize = @intCast(cf.utf16Offset(text, text.len));
    if (r.location > n) return null;
    const end = @min(n, r.location +| r.length);
    return .{ cf.byteOffset(text, @intCast(r.location)), cf.byteOffset(text, @intCast(end)) };
}

/// Where the input method's candidate window goes: under the clause it
/// converts while composing (Kotoeri, Pinyin), else under the caret, in
/// screen coordinates; `actual` gets the range the rect is for.
fn firstRect(obj: objc.Object, _: objc.SEL, range: NSRange, actual: ?*NSRange) callconv(.c) objc.CGRect {
    const s = objc.getZig(Surface, obj) orelse return .{};
    const f = s.ctx.focused_text orelse return .{};
    const at = if (f.marked != null) f.clause_rect orelse f.caret_rect else f.caret_rect;
    if (actual) |a| a.* = if (range.location == not_found) range else .{ .location = range.location, .length = 0 };
    const r: objc.CGRect = .{ .origin = .{ .x = at.x, .y = at.y }, .size = .{ .width = at.w, .height = at.h } };
    const in_window = objc.msg(objc.CGRect, obj, "convertRect:toView:", .{ r, @as(?objc.Object, null) });
    return objc.msg(objc.CGRect, s.window.nswindow, "convertRectToScreen:", .{in_window});
}

fn characterIndex(_: objc.Object, _: objc.SEL, _: objc.CGPoint) callconv(.c) usize {
    return not_found;
}

const commands = .{
    .{ "deleteBackward:", .delete_backward },
    .{ "deleteBackwardByDecomposingPreviousCharacter:", .delete_backward },
    .{ "deleteForward:", .delete_forward },
    .{ "deleteWordBackward:", .delete_word_backward },
    .{ "deleteToBeginningOfLine:", .delete_to_line_start },
    .{ "deleteToEndOfLine:", .delete_to_line_end },
    .{ "deleteToEndOfParagraph:", .delete_to_line_end },
    .{ "deleteWordForward:", .delete_word_forward },
    .{ "moveToBeginningOfParagraph:", .move_line_start },
    .{ "moveToEndOfParagraph:", .move_line_end },
    .{ "moveLeft:", .move_left },
    .{ "moveRight:", .move_right },
    .{ "moveBackward:", .move_left },
    .{ "moveForward:", .move_right },
    .{ "moveWordLeft:", .move_word_left },
    .{ "moveWordRight:", .move_word_right },
    .{ "moveToBeginningOfLine:", .move_line_start },
    .{ "moveToLeftEndOfLine:", .move_line_start },
    .{ "moveToBeginningOfDocument:", .move_line_start },
    .{ "moveUp:", .move_up },
    .{ "moveToEndOfLine:", .move_line_end },
    .{ "moveToRightEndOfLine:", .move_line_end },
    .{ "moveToEndOfDocument:", .move_line_end },
    .{ "moveDown:", .move_down },
    .{ "moveLeftAndModifySelection:", .select_left },
    .{ "moveRightAndModifySelection:", .select_right },
    .{ "moveWordLeftAndModifySelection:", .select_word_left },
    .{ "moveWordRightAndModifySelection:", .select_word_right },
    .{ "moveToBeginningOfLineAndModifySelection:", .select_line_start },
    .{ "moveToLeftEndOfLineAndModifySelection:", .select_line_start },
    .{ "moveUpAndModifySelection:", .select_up },
    .{ "moveToEndOfLineAndModifySelection:", .select_line_end },
    .{ "moveToRightEndOfLineAndModifySelection:", .select_line_end },
    .{ "moveDownAndModifySelection:", .select_down },
    .{ "selectAll:", .select_all },
    .{ "insertNewline:", .insert_newline },
    .{ "insertLineBreak:", .insert_line_break },
    .{ "insertNewlineIgnoringFieldEditor:", .insert_line_break },
    .{ "insertTab:", .insert_tab },
    .{ "insertBacktab:", .insert_tab },
    .{ "cancelOperation:", .cancel },
};

fn doCommand(obj: objc.Object, _: objc.SEL, sel: objc.SEL) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    const name = std.mem.span(sel_getName(sel));
    if (std.mem.eql(u8, name, "undo:")) return undoAction(obj, sel, null);
    if (std.mem.eql(u8, name, "redo:")) return redoAction(obj, sel, null);
    inline for (commands) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return push(s, .{ .command = entry[1] });
    }
}

/// An Edit-menu action with no field focused is offered to the view as its
/// shortcut, as `paste:` is (surface_events.zig): the menu always takes
/// ⌘Z/⌘C/⌘X/⌘A before `keyDown:`, so an app's own (an editor's undo, copying
/// clips) would otherwise never see them. True if the view took it.
fn offerShortcut(s: *Surface, key: u21, shift: bool) bool {
    const tok = s.token();
    s.ctx.shortcut_taken = false;
    s.ctx.input.shortcut = .{ .key = key, .cmd = true, .shift = shift };
    s.frame();
    if (!Surface.alive(tok)) return true;
    s.ctx.input.shortcut = null;
    return s.ctx.shortcut_taken;
}

fn undoAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.ctx.focused_text == null) {
        _ = offerShortcut(s, 'z', false);
        return;
    }
    s.ctx.undo_op = .undo;
    if (!s.text_queue.collecting) flush(s);
}

fn redoAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.ctx.focused_text == null) {
        _ = offerShortcut(s, 'z', true);
        return;
    }
    s.ctx.undo_op = .redo;
    if (!s.text_queue.collecting) flush(s);
}

pub fn copy(s: *Surface) void {
    push(s, .{ .command = .copy });
}

pub fn cut(s: *Surface) void {
    if (s.ctx.focused_text != null) push(s, .{ .command = .cut });
}

pub fn selectAll(s: *Surface) void {
    if (s.ctx.focused_text != null) push(s, .{ .command = .select_all });
}

fn copyAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.ctx.focused_text == null and offerShortcut(s, 'c', false)) return;
    copy(s);
}

fn cutAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.ctx.focused_text == null and offerShortcut(s, 'x', false)) return;
    cut(s);
}

fn deleteAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.ctx.focused_text != null) push(s, .{ .command = .delete_backward });
}

fn selectAllAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.ctx.focused_text == null and offerShortcut(s, 'a', false)) return;
    selectAll(s);
}

pub fn validateMenuItem(obj: objc.Object, _: objc.SEL, item: objc.Object) callconv(.c) objc.BOOL {
    const s = objc.getZig(Surface, obj) orelse return objc.NO;
    const action = objc.msg(?objc.SEL, item, "action", .{}) orelse return objc.YES;
    const name = std.mem.span(sel_getName(action));
    const f = s.ctx.focused_text;
    if (std.mem.eql(u8, name, "cut:") or std.mem.eql(u8, name, "copy:")) {
        if (f) |ft| if (ft.caret != ft.anchor and !s.ctx.focused_password) return objc.YES;
        if (std.mem.eql(u8, name, "copy:")) return if (s.ctx.selection.text.items.len > 0) objc.YES else objc.NO;
        return objc.NO;
    }
    if (std.mem.eql(u8, name, "paste:")) {
        return objc.YES;
    }
    if (std.mem.eql(u8, name, "selectAll:") or std.mem.eql(u8, name, "delete:")) {
        return if (f != null) objc.YES else objc.NO;
    }
    if (std.mem.eql(u8, name, "undo:")) {
        if (f) |ft| if (s.ctx.edits.get(ft.id)) |e| return if (e.undo.count > 0 and e.undo.at > 0) objc.YES else objc.NO;
        return objc.NO;
    }
    if (std.mem.eql(u8, name, "redo:")) {
        if (f) |ft| if (s.ctx.edits.get(ft.id)) |e| return if (e.undo.at + 1 < e.undo.count) objc.YES else objc.NO;
        return objc.NO;
    }
    return objc.YES;
}

/// Pasted text, as if typed.
pub fn paste(s: *Surface, text: []const u8) void {
    s.ctx.paste_op = true;
    push(s, .{ .insert = dupe(s, text) });
}

/// Pops up the standard Cut / Copy / Paste / Select All context menu for the focused text field.
pub fn popMenu(s: *Surface) void {
    if (!s.visible()) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const m = objc.new("NSMenu");
    defer objc.release(m);
    const entries = .{
        .{ "Cut", "cut:" },
        .{ "Copy", "copy:" },
        .{ "Paste", "paste:" },
    };
    inline for (entries) |e| {
        const it = objc.msg(objc.Object, objc.alloc("NSMenuItem"), "initWithTitle:action:keyEquivalent:", .{
            objc.nsString(e[0]), objc.sel(e[1]), objc.nsString(""),
        });
        defer objc.release(it);
        objc.msg(void, m, "addItem:", .{it});
    }
    objc.msg(void, m, "addItem:", .{objc.msg(objc.Object, objc.class("NSMenuItem"), "separatorItem", .{})});
    const all = objc.msg(objc.Object, objc.alloc("NSMenuItem"), "initWithTitle:action:keyEquivalent:", .{
        objc.nsString("Select All"), objc.sel("selectAll:"), objc.nsString(""),
    });
    defer objc.release(all);
    objc.msg(void, m, "addItem:", .{all});
    const at: objc.CGPoint = .{ .x = s.ctx.input.mouse.x, .y = s.ctx.input.mouse.y };
    _ = objc.msg(objc.BOOL, m, "popUpMenuPositioningItem:atLocation:inView:", .{ @as(?objc.Object, null), at, s.nsview });
}

test "the input method's questions see what it set in the same event" {
    const t = std.testing;
    var q: Queue = .init(t.allocator);
    defer q.deinit(t.allocator);
    const base: ctx_mod.FocusedText = .{ .id = 1, .text = "emacs ", .caret = 6, .anchor = 6, .marked = null, .caret_rect = .{} };
    // ふくすう becomes 複数, committed; ぎょう is composed, all selected.
    q.preview(base, false, .{ .set_marked = .{ .text = "ふくすう", .sel_start = 12, .sel_len = 0 } });
    q.preview(base, false, .{ .insert = "複数" });
    q.preview(base, false, .{ .set_marked = .{ .text = "ぎょう", .sel_start = 0, .sel_len = 9 } });
    const f = q.focused(base).?;
    try t.expectEqualStrings("emacs 複数ぎょう", f.text);
    try t.expectEqual(@as(?[2]usize, .{ 12, 21 }), f.marked);
    try t.expectEqual(@as(usize, 12), f.anchor);
    try t.expectEqual(@as(usize, 21), f.caret);
    // The frame ran them: the field's own state answers again.
    q.pending = null;
    try t.expectEqualStrings("emacs ", q.focused(base).?.text);
}
