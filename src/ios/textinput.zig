//! iOS's text input (UITextInput) on the hidden view the software keyboard
//! types into (`keys.zig`). Input methods compose in marked text (pinyin,
//! kana, Hangul), autocorrect and dictation replace ranges of the field's
//! text, and the edit menu copies, cuts and pastes. Positions are UTF-16
//! offsets into the focused field's text, as the last frame left it
//! (`Context.focused_text`); edits become the field's `TextOp`s.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("../ui/cf.zig");
const Surface = @import("surface.zig").Surface;

const NSRange = extern struct { location: usize, length: usize };
const not_found: usize = @as(usize, std.math.maxInt(isize));

pub const State = struct {
    delegate: ?objc.Object = null,
    tokenizer: ?objc.Object = null,
    /// The field as UIKit last knew it: anything else changed it.
    told: Snapshot = .{},
    /// Inside an edit UIKit made (or the keyboard's keys): not news to it.
    editing: bool = false,

    pub fn deinit(st: *State) void {
        if (st.tokenizer) |t| objc.release(t);
        st.tokenizer = null;
    }
};

const Snapshot = struct { id: u64 = 0, len: usize = 0, hash: u64 = 0, caret: usize = 0, anchor: usize = 0 };

const P = "@@:";
const rect_t = "{CGRect={CGPoint=dd}{CGSize=dd}}";
pub const methods = [_]objc.Method{
    .{ .name = "textInRange:", .imp = &textInRange, .types = "@@:@" },
    .{ .name = "replaceRange:withText:", .imp = &replaceRange, .types = "v@:@@" },
    .{ .name = "selectedTextRange", .imp = &selectedTextRange, .types = P },
    .{ .name = "setSelectedTextRange:", .imp = &setSelectedTextRange, .types = "v@:@" },
    .{ .name = "markedTextRange", .imp = &markedTextRange, .types = P },
    .{ .name = "markedTextStyle", .imp = &nothing, .types = P },
    .{ .name = "setMarkedTextStyle:", .imp = &ignore, .types = "v@:@" },
    .{ .name = "setMarkedText:selectedRange:", .imp = &setMarkedText, .types = "v@:@{_NSRange=QQ}" },
    .{ .name = "unmarkText", .imp = &unmarkText, .types = "v@:" },
    .{ .name = "beginningOfDocument", .imp = &beginning, .types = P },
    .{ .name = "endOfDocument", .imp = &endOfDocument, .types = P },
    .{ .name = "textRangeFromPosition:toPosition:", .imp = &rangeFrom, .types = "@@:@@" },
    .{ .name = "positionFromPosition:offset:", .imp = &positionOffset, .types = "@@:@q" },
    .{ .name = "positionFromPosition:inDirection:offset:", .imp = &positionDirection, .types = "@@:@qq" },
    .{ .name = "comparePosition:toPosition:", .imp = &compare, .types = "q@:@@" },
    .{ .name = "offsetFromPosition:toPosition:", .imp = &offsetFrom, .types = "q@:@@" },
    .{ .name = "inputDelegate", .imp = &inputDelegate, .types = P },
    .{ .name = "setInputDelegate:", .imp = &setInputDelegate, .types = "v@:@" },
    .{ .name = "tokenizer", .imp = &tokenizer, .types = P },
    .{ .name = "positionWithinRange:farthestInDirection:", .imp = &farthest, .types = "@@:@q" },
    .{ .name = "characterRangeByExtendingPosition:inDirection:", .imp = &extending, .types = "@@:@q" },
    .{ .name = "baseWritingDirectionForPosition:inDirection:", .imp = &writingDirection, .types = "q@:@q" },
    .{ .name = "setBaseWritingDirection:forRange:", .imp = &setWritingDirection, .types = "v@:q@" },
    .{ .name = "firstRectForRange:", .imp = &firstRect, .types = rect_t ++ "@:@" },
    .{ .name = "caretRectForPosition:", .imp = &firstRect, .types = rect_t ++ "@:@" },
    .{ .name = "selectionRectsForRange:", .imp = &selectionRects, .types = "@@:@" },
    .{ .name = "closestPositionToPoint:", .imp = &closest, .types = "@@:{CGPoint=dd}" },
    .{ .name = "closestPositionToPoint:withinRange:", .imp = &closestWithin, .types = "@@:{CGPoint=dd}@" },
    .{ .name = "characterRangeAtPoint:", .imp = &nothingAt, .types = "@@:{CGPoint=dd}" },
    // The edit menu's and a keyboard's shortcuts bar's commands.
    .{ .name = "canPerformAction:withSender:", .imp = &canPerform, .types = "B@::@" },
    .{ .name = "copy:", .imp = &copyAction, .types = "v@:@" },
    .{ .name = "cut:", .imp = &cutAction, .types = "v@:@" },
    .{ .name = "paste:", .imp = &pasteAction, .types = "v@:@" },
    .{ .name = "selectAll:", .imp = &selectAllAction, .types = "v@:@" },
};

// Positions and ranges: UITextPosition and UITextRange subclasses whose one
// pointer-sized slot holds their offsets (bit 63 set, so never null).
const tag: usize = 1 << 63;

fn position(at: usize) objc.Object {
    const cls = objc.defineClass(.{ .name = "NanoUITextPosition", .superclass = "UITextPosition", .methods = &.{} });
    const p = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "init", .{});
    objc.setZig(p, @ptrFromInt(tag | at));
    objc.autorelease(p);
    return p;
}

fn offsetOf(p: ?objc.Object) ?usize {
    const o = p orelse return null;
    const v: usize = @intFromPtr(objc.getZig(u8, o) orelse return null);
    return v & ~tag;
}

const range_methods = [_]objc.Method{
    .{ .name = "start", .imp = &rangeStart, .types = P },
    .{ .name = "end", .imp = &rangeEnd, .types = P },
    .{ .name = "isEmpty", .imp = &rangeEmpty, .types = "B@:" },
};

fn range(a: usize, b: usize) objc.Object {
    const cls = objc.defineClass(.{ .name = "NanoUITextRange", .superclass = "UITextRange", .methods = &range_methods });
    const r = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "init", .{});
    const lo = @min(a, b) & 0x7fff_ffff;
    const hi = @max(a, b) & 0x7fff_ffff;
    objc.setZig(r, @ptrFromInt(tag | (lo << 31) | hi));
    objc.autorelease(r);
    return r;
}

fn bounds(r: ?objc.Object) ?[2]usize {
    const o = r orelse return null;
    const v: usize = @intFromPtr(objc.getZig(u8, o) orelse return null);
    return .{ (v >> 31) & 0x7fff_ffff, v & 0x7fff_ffff };
}

fn rangeStart(obj: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    return position((bounds(obj) orelse [2]usize{ 0, 0 })[0]);
}

fn rangeEnd(obj: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    return position((bounds(obj) orelse [2]usize{ 0, 0 })[1]);
}

fn rangeEmpty(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const b = bounds(obj) orelse return objc.YES;
    return b[0] == b[1];
}

// The field's text, and offsets in UTF-16 and bytes.
fn text(obj: objc.Object) []const u8 {
    const s = objc.getZig(Surface, obj) orelse return "";
    if (s.dead) return "";
    const f = s.ctx.focused_text orelse return "";
    return f.text;
}

fn u16Of(t: []const u8, byte: usize) usize {
    return @intCast(cf.utf16Offset(t, byte));
}

fn byteOf(t: []const u8, u: usize) usize {
    return cf.byteOffset(t, @intCast(u));
}

fn len16(obj: objc.Object) usize {
    const t = text(obj);
    return u16Of(t, t.len);
}

/// Runs the operations as one frame, the edits UIKit made itself.
fn run(obj: objc.Object, ops: []const @import("../ui/context.zig").TextOp) void {
    const s = Surface.enter(obj) orelse return;
    defer s.leave();
    for (ops) |op| s.keys.ops.append(s.gpa, op) catch return;
    s.ctx.input.ops = s.keys.ops.items;
    s.keys.text.editing = true;
    s.frame();
    if (s.dead) return;
    s.keys.text.editing = false;
    s.ctx.input.ops = &.{};
    s.keys.ops.clearRetainingCapacity();
    _ = s.keys.arena.reset(.retain_capacity);
}

fn dupe(obj: objc.Object, str: []const u8) []const u8 {
    const s = objc.getZig(Surface, obj) orelse return "";
    return s.keys.arena.allocator().dupe(u8, str) catch "";
}

fn textInRange(obj: objc.Object, _: objc.SEL, r: ?objc.Object) callconv(.c) ?objc.Object {
    const b = bounds(r) orelse return null;
    const t = text(obj);
    return objc.nsString(t[byteOf(t, b[0])..byteOf(t, b[1])]);
}

fn replaceRange(obj: objc.Object, _: objc.SEL, r: ?objc.Object, str: ?objc.Object) callconv(.c) void {
    const b = bounds(r) orelse return;
    const t = text(obj);
    const new = dupe(obj, objc.fromNSString(str));
    run(obj, &.{ .{ .select = .{ .anchor = byteOf(t, b[0]), .caret = byteOf(t, b[1]) } }, .{ .insert = new } });
}

fn selectedTextRange(obj: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    const s = objc.getZig(Surface, obj) orelse return null;
    const f = s.ctx.focused_text orelse return null;
    return range(u16Of(f.text, f.anchor), u16Of(f.text, f.caret));
}

fn setSelectedTextRange(obj: objc.Object, _: objc.SEL, r: ?objc.Object) callconv(.c) void {
    const b = bounds(r) orelse return;
    const t = text(obj);
    run(obj, &.{.{ .select = .{ .anchor = byteOf(t, b[0]), .caret = byteOf(t, b[1]) } }});
}

fn markedTextRange(obj: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    const s = objc.getZig(Surface, obj) orelse return null;
    const f = s.ctx.focused_text orelse return null;
    const m = f.marked orelse return null;
    return range(u16Of(f.text, m[0]), u16Of(f.text, m[1]));
}

fn setMarkedText(obj: objc.Object, _: objc.SEL, str: ?objc.Object, sel: NSRange) callconv(.c) void {
    const t = dupe(obj, objc.fromNSString(str));
    const n16: usize = u16Of(t, t.len);
    const loc = if (sel.location == not_found) n16 else @min(sel.location, n16);
    const end = @min(loc + sel.length, n16);
    const a = byteOf(t, loc);
    run(obj, &.{.{ .set_marked = .{ .text = t, .sel_start = a, .sel_len = byteOf(t, end) - a } }});
}

fn unmarkText(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    run(obj, &.{.unmark});
}

fn beginning(_: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    return position(0);
}

fn endOfDocument(obj: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    return position(len16(obj));
}

fn rangeFrom(_: objc.Object, _: objc.SEL, a: ?objc.Object, b: ?objc.Object) callconv(.c) ?objc.Object {
    return range(offsetOf(a) orelse return null, offsetOf(b) orelse return null);
}

fn moved(obj: objc.Object, p: ?objc.Object, by: objc.NSInteger) ?objc.Object {
    const at: isize = @intCast(offsetOf(p) orelse return null);
    const to = at + by;
    if (to < 0 or to > len16(obj)) return null;
    return position(@intCast(to));
}

fn positionOffset(obj: objc.Object, _: objc.SEL, p: ?objc.Object, by: objc.NSInteger) callconv(.c) ?objc.Object {
    return moved(obj, p, by);
}

/// UITextLayoutDirection: right 2, left 3, up 4, down 5. A line up or down
/// in one line is its start or end.
fn positionDirection(obj: objc.Object, _: objc.SEL, p: ?objc.Object, dir: objc.NSInteger, by: objc.NSInteger) callconv(.c) ?objc.Object {
    return switch (dir) {
        3 => moved(obj, p, -by),
        4 => position(0),
        5 => position(len16(obj)),
        else => moved(obj, p, by),
    };
}

fn compare(_: objc.Object, _: objc.SEL, a: ?objc.Object, b: ?objc.Object) callconv(.c) objc.NSInteger {
    const x = offsetOf(a) orelse 0;
    const y = offsetOf(b) orelse 0;
    return if (x < y) -1 else if (x > y) 1 else 0;
}

fn offsetFrom(_: objc.Object, _: objc.SEL, a: ?objc.Object, b: ?objc.Object) callconv(.c) objc.NSInteger {
    const x: isize = @intCast(offsetOf(a) orelse 0);
    const y: isize = @intCast(offsetOf(b) orelse 0);
    return y - x;
}

fn inputDelegate(obj: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    const s = objc.getZig(Surface, obj) orelse return null;
    return s.keys.text.delegate;
}

fn setInputDelegate(obj: objc.Object, _: objc.SEL, d: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    // Weak, as UIKit's own views keep it.
    s.keys.text.delegate = d;
}

fn tokenizer(obj: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    const s = objc.getZig(Surface, obj) orelse return null;
    if (s.keys.text.tokenizer == null) {
        const t = objc.alloc("UITextInputStringTokenizer");
        s.keys.text.tokenizer = objc.msg(objc.Object, t, "initWithTextInput:", .{obj});
    }
    return s.keys.text.tokenizer;
}

fn farthest(_: objc.Object, _: objc.SEL, r: ?objc.Object, dir: objc.NSInteger) callconv(.c) ?objc.Object {
    const b = bounds(r) orelse return null;
    return position(if (dir == 3 or dir == 4) b[0] else b[1]);
}

fn extending(obj: objc.Object, _: objc.SEL, p: ?objc.Object, dir: objc.NSInteger) callconv(.c) ?objc.Object {
    const at = offsetOf(p) orelse return null;
    if (dir == 3 or dir == 4) return range(at -| 1, at);
    return range(at, @min(at + 1, len16(obj)));
}

fn writingDirection(_: objc.Object, _: objc.SEL, _: ?objc.Object, _: objc.NSInteger) callconv(.c) objc.NSInteger {
    return 0; // NSWritingDirectionLeftToRight
}

fn setWritingDirection(_: objc.Object, _: objc.SEL, _: objc.NSInteger, _: ?objc.Object) callconv(.c) void {}

/// The caret, in the hidden view's space (it sits at the view's origin):
/// where the candidate bar and the dictation glow go.
fn firstRect(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) objc.CGRect {
    const s = objc.getZig(Surface, obj) orelse return .{};
    const f = s.ctx.focused_text orelse return .{};
    const r = f.caret_rect;
    return .{ .origin = .{ .x = r.x, .y = r.y }, .size = .{ .width = r.w, .height = r.h } };
}

fn selectionRects(_: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) objc.Object {
    return objc.msg(objc.Object, objc.class("NSArray"), "array", .{});
}

fn closest(obj: objc.Object, _: objc.SEL, _: objc.CGPoint) callconv(.c) ?objc.Object {
    const s = objc.getZig(Surface, obj) orelse return null;
    const f = s.ctx.focused_text orelse return null;
    return position(u16Of(f.text, f.caret));
}

fn closestWithin(_: objc.Object, _: objc.SEL, _: objc.CGPoint, r: ?objc.Object) callconv(.c) ?objc.Object {
    return position((bounds(r) orelse return null)[0]);
}

fn nothingAt(_: objc.Object, _: objc.SEL, _: objc.CGPoint) callconv(.c) ?objc.Object {
    return null;
}

fn nothing(_: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    return null;
}

fn ignore(_: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {}

fn canPerform(obj: objc.Object, _: objc.SEL, action: objc.SEL, _: ?objc.Object) callconv(.c) objc.BOOL {
    const s = objc.getZig(Surface, obj) orelse return objc.NO;
    const f = s.ctx.focused_text orelse return objc.NO;
    const selected = f.caret != f.anchor and !s.ctx.focused_password;
    if (action == objc.sel("copy:") or action == objc.sel("cut:")) return selected;
    if (action == objc.sel("selectAll:")) return f.text.len > 0;
    if (action == objc.sel("paste:")) {
        const pb = objc.msg(objc.Object, objc.class("UIPasteboard"), "generalPasteboard", .{});
        return objc.msg(objc.BOOL, pb, "hasStrings", .{});
    }
    return objc.NO;
}

fn copyAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    run(obj, &.{.{ .command = .copy }});
}

fn cutAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    run(obj, &.{.{ .command = .cut }});
}

fn selectAllAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    run(obj, &.{.{ .command = .select_all }});
}

fn pasteAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const pb = objc.msg(objc.Object, objc.class("UIPasteboard"), "generalPasteboard", .{});
    run(obj, &.{.{ .insert = dupe(obj, objc.fromNSString(objc.msg(?objc.Object, pb, "string", .{}))) }});
}

fn snapshot(s: *Surface) Snapshot {
    const f = s.ctx.focused_text orelse return .{};
    return .{ .id = f.id, .len = f.text.len, .hash = std.hash.Wyhash.hash(0, f.text), .caret = f.caret, .anchor = f.anchor };
}

/// After a frame: text or a selection the field changed itself (the app
/// set it, a tap moved the caret) is news to the keyboard, which would
/// otherwise correct or compose against old text.
pub fn afterFrame(s: *Surface) void {
    const now = snapshot(s);
    const was = s.keys.text.told;
    if (std.meta.eql(now, was)) return;
    s.keys.text.told = now;
    if (s.keys.text.editing) return;
    const d = s.keys.text.delegate orelse return;
    const v = s.keys.input orelse return;
    if (now.hash != was.hash or now.id != was.id) {
        objc.msg(void, d, "textWillChange:", .{v});
        objc.msg(void, d, "textDidChange:", .{v});
    } else {
        objc.msg(void, d, "selectionWillChange:", .{v});
        objc.msg(void, d, "selectionDidChange:", .{v});
    }
}
