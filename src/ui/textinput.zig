//! The native view's side of AppKit's text input (NSTextInputClient): key
//! events go through `interpretKeyEvents:`, which answers with text to
//! insert, an input method's composition, or editing commands from the
//! system's key bindings. They become `TextOp`s for the focused field.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const ctx_mod = @import("context.zig");
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

    pub fn init(gpa: std.mem.Allocator) Queue {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(q: *Queue, gpa: std.mem.Allocator) void {
        q.ops.deinit(gpa);
        q.arena.deinit();
    }
};

fn push(s: *Surface, op: ctx_mod.TextOp) void {
    s.text_queue.ops.append(s.gpa, op) catch return;
    if (!s.text_queue.collecting) flush(s);
}

fn dupe(s: *Surface, str: []const u8) []const u8 {
    return s.text_queue.arena.allocator().dupe(u8, str) catch "";
}

/// Runs a frame with the queued operations.
pub fn flush(s: *Surface) void {
    const q = &s.text_queue;
    if (q.ops.items.len == 0 and s.ctx.undo_op == .none) return;
    s.ctx.input.ops = q.ops.items;
    s.frame();
    s.ctx.input.ops = &.{};
    s.ctx.undo_op = .none;
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

fn insertText(obj: objc.Object, _: objc.SEL, str: objc.Object, _: NSRange) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    const t = stringOf(str);
    // Control characters arrive as commands, not text.
    if (t.len == 1 and (t[0] < 0x20 or t[0] == 0x7f)) return;
    push(s, .{ .insert = dupe(s, t) });
}

fn setMarkedText(obj: objc.Object, _: objc.SEL, str: objc.Object, sel: NSRange, _: NSRange) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
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
    const f = s.ctx.focused_text orelse return objc.NO;
    return f.marked != null;
}

fn range16(text: []const u8, lo: usize, hi: usize) NSRange {
    const a: usize = @intCast(cf.utf16Offset(text, lo));
    const b: usize = @intCast(cf.utf16Offset(text, hi));
    return .{ .location = a, .length = b - a };
}

fn markedRange(obj: objc.Object, _: objc.SEL) callconv(.c) NSRange {
    const s = objc.getZig(Surface, obj) orelse return .{ .location = not_found, .length = 0 };
    const f = s.ctx.focused_text orelse return .{ .location = not_found, .length = 0 };
    const m = f.marked orelse return .{ .location = not_found, .length = 0 };
    return range16(f.text, m[0], m[1]);
}

fn selectedRange(obj: objc.Object, _: objc.SEL) callconv(.c) NSRange {
    const s = objc.getZig(Surface, obj) orelse return .{ .location = not_found, .length = 0 };
    const f = s.ctx.focused_text orelse return .{ .location = not_found, .length = 0 };
    return range16(f.text, @min(f.caret, f.anchor), @max(f.caret, f.anchor));
}

fn validAttributes(_: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    return objc.msg(objc.Object, objc.class("NSArray"), "array", .{});
}

fn attributedSubstring(_: objc.Object, _: objc.SEL, _: NSRange, _: ?*NSRange) callconv(.c) ?objc.Object {
    return null;
}

/// Where the input method's candidate window goes: under the caret, in
/// screen coordinates.
fn firstRect(obj: objc.Object, _: objc.SEL, _: NSRange, _: ?*NSRange) callconv(.c) objc.CGRect {
    const s = objc.getZig(Surface, obj) orelse return .{};
    const f = s.ctx.focused_text orelse return .{};
    const r: objc.CGRect = .{ .origin = .{ .x = f.caret_rect.x, .y = f.caret_rect.y }, .size = .{ .width = f.caret_rect.w, .height = f.caret_rect.h } };
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

fn undoAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.ctx.focused_text == null) return;
    s.ctx.undo_op = .undo;
    if (!s.text_queue.collecting) flush(s);
}

fn redoAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.ctx.focused_text == null) return;
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
    copy(s);
}

fn cutAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    cut(s);
}

fn deleteAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.ctx.focused_text != null) push(s, .{ .command = .delete_backward });
}

fn selectAllAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
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
