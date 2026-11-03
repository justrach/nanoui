//! Keys on iOS: a hardware keyboard's presses (UIKey) and the software
//! keyboard's text. The view is the first responder, so a keyboard's keys
//! reach it, and offers them as on the Mac: combinations to the menus'
//! accelerators and the view first, then keys and typed text. While a text
//! field has the focus, a hidden view taking text (UIKeyInput) becomes the
//! first responder instead, which brings up the software keyboard; its
//! text and Delete become the field's text operations. Its frame tells how
//! much of the view the keyboard covers (`Context.safe_area`).
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("../ui/cf.zig");
const ctx_mod = @import("../ui/context.zig");
const ui = @import("../ui/ui.zig");
const Surface = @import("surface.zig").Surface;
const Key = @import("../ui/input.zig").Key;
const textinput = @import("textinput.zig");

extern "c" const UIKeyboardWillChangeFrameNotification: objc.Object;
extern "c" const UIKeyboardFrameEndUserInfoKey: objc.Object;

pub const State = struct {
    /// The hidden view the software keyboard types into.
    input: ?objc.Object = null,
    /// The text field the keyboard was brought up for (0: none).
    keyboard_for: u64 = 0,
    /// The keyboard's height when the caret was last scrolled above it.
    revealed_over: f32 = 0,
    ops: std.ArrayList(ctx_mod.TextOp) = .empty,
    arena: std.heap.ArenaAllocator,
    pasted: std.ArrayList(u8) = .empty,
    text: textinput.State = .{},

    pub fn init(gpa: std.mem.Allocator) State {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(st: *State, gpa: std.mem.Allocator) void {
        st.ops.deinit(gpa);
        st.pasted.deinit(gpa);
        st.text.deinit();
        st.arena.deinit();
    }
};

/// The surface's view's methods: first responder, presses, the keyboard.
pub const view_methods = [_]objc.Method{
    .{ .name = "canBecomeFirstResponder", .imp = &yes, .types = "B@:" },
    .{ .name = "pressesBegan:withEvent:", .imp = &pressesBegan, .types = "v@:@@" },
    .{ .name = "pressesEnded:withEvent:", .imp = &pressesEnded, .types = "v@:@@" },
    .{ .name = "pressesCancelled:withEvent:", .imp = &pressesCancelled, .types = "v@:@@" },
    .{ .name = "keyboardChanged:", .imp = &keyboardChanged, .types = "v@:@" },
};

const input_methods = [_]objc.Method{
    .{ .name = "canBecomeFirstResponder", .imp = &yes, .types = "B@:" },
    .{ .name = "pressesBegan:withEvent:", .imp = &pressesBegan, .types = "v@:@@" },
    .{ .name = "pressesEnded:withEvent:", .imp = &pressesEnded, .types = "v@:@@" },
    .{ .name = "pressesCancelled:withEvent:", .imp = &pressesCancelled, .types = "v@:@@" },
    .{ .name = "hasText", .imp = &hasText, .types = "B@:" },
    .{ .name = "insertText:", .imp = &insertText, .types = "v@:@" },
    .{ .name = "deleteBackward", .imp = &deleteBackward, .types = "v@:" },
    // Corrections replace what they correct (UITextInput), but not in a
    // password, which is also hidden from screenshots and dictation.
    .{ .name = "autocorrectionType", .imp = &traitNoInPassword, .types = "q@:" },
    .{ .name = "spellCheckingType", .imp = &traitNoInPassword, .types = "q@:" },
    .{ .name = "autocapitalizationType", .imp = &capitalization, .types = "q@:" },
    .{ .name = "isSecureTextEntry", .imp = &secure, .types = "B@:" },
} ++ textinput.methods;

pub fn attach(s: *Surface) void {
    const cls = objc.defineClass(.{
        .name = "NanoUIKeyInput",
        .superclass = "UIView",
        .protocols = &.{ "UIKeyInput", "UITextInputTraits", "UITextInput" },
        .methods = &input_methods,
    });
    const v = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "initWithFrame:", .{objc.CGRect{}});
    objc.setZig(v, s);
    objc.msg(void, v, "setUserInteractionEnabled:", .{objc.NO});
    objc.msg(void, s.uiview, "addSubview:", .{v});
    s.keys.input = v;
    const center = objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{});
    objc.msg(void, center, "addObserver:selector:name:object:", .{ s.uiview, objc.sel("keyboardChanged:"), UIKeyboardWillChangeFrameNotification, @as(?objc.Object, null) });
}

pub fn detach(s: *Surface) void {
    const center = objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{});
    objc.msg(void, center, "removeObserver:", .{s.uiview});
    const v = s.keys.input orelse return;
    s.keys.text.delegate = null;
    objc.setZig(v, null);
    if (objc.msg(objc.BOOL, v, "isFirstResponder", .{})) _ = objc.msg(objc.BOOL, v, "resignFirstResponder", .{});
    objc.msg(void, v, "removeFromSuperview", .{});
    objc.release(v);
    s.keys.input = null;
}

/// The view takes a keyboard's keys, unless a field has the keyboard.
pub fn takeKeys(s: *Surface) void {
    const v = s.keys.input orelse return;
    if (objc.msg(objc.BOOL, v, "isFirstResponder", .{})) return;
    _ = objc.msg(objc.BOOL, s.uiview, "becomeFirstResponder", .{});
}

/// After a frame: a newly focused field brings up the keyboard, and the
/// keyboard goes when no field has the focus.
pub fn syncFocus(s: *Surface) void {
    textinput.afterFrame(s);
    reveal(s);
    const want: u64 = if (s.ctx.focused_text) |f| f.id else 0;
    if (want == s.keys.keyboard_for) return;
    const was = s.keys.keyboard_for;
    s.keys.keyboard_for = want;
    const v = s.keys.input orelse return;
    if (want != 0) {
        // Another field: its traits (a password's) come with the keyboard.
        if (was != 0 and objc.msg(objc.BOOL, v, "isFirstResponder", .{})) objc.msg(void, v, "reloadInputViews", .{});
        _ = objc.msg(objc.BOOL, v, "becomeFirstResponder", .{});
    } else if (objc.msg(objc.BOOL, v, "isFirstResponder", .{})) {
        _ = objc.msg(objc.BOOL, s.uiview, "becomeFirstResponder", .{});
    }
}

/// The keyboard coming up, or typing, scrolls the caret above it; a finger
/// scrolling the field away under it otherwise stays.
fn reveal(s: *Surface) void {
    const st = &s.keys;
    const f = s.ctx.focused_text orelse return;
    const kb = s.keyboard;
    if (f.id == st.keyboard_for and kb == st.revealed_over and !st.text.editing) return;
    st.revealed_over = kb;
    if (kb <= 0) return;
    if (@import("../ui/scroll.zig").revealCaret(&s.ctx, s.size.h - s.safeArea().bottom)) s.requestFrame();
}

fn push(s: *Surface, op: ctx_mod.TextOp) void {
    const st = &s.keys;
    st.ops.append(s.gpa, op) catch return;
    s.ctx.input.ops = st.ops.items;
    st.text.editing = true;
    s.frame();
    if (s.dead) return;
    st.text.editing = false;
    s.ctx.input.ops = &.{};
    st.ops.clearRetainingCapacity();
    _ = st.arena.reset(.retain_capacity);
}

fn dupe(s: *Surface, str: []const u8) []const u8 {
    return s.keys.arena.allocator().dupe(u8, str) catch "";
}

fn yes(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn password(obj: objc.Object) bool {
    const s = objc.getZig(Surface, obj) orelse return false;
    return !s.dead and s.ctx.focused_password;
}

/// UITextAutocorrectionType, UITextSpellCheckingType: default 0, no 1.
fn traitNoInPassword(obj: objc.Object, _: objc.SEL) callconv(.c) objc.NSInteger {
    return if (password(obj)) 1 else 0;
}

/// UITextAutocapitalizationType: none 0, sentences 2.
fn capitalization(obj: objc.Object, _: objc.SEL) callconv(.c) objc.NSInteger {
    return if (password(obj)) 0 else 2;
}

fn secure(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return password(obj);
}

fn hasText(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const s = objc.getZig(Surface, obj) orelse return objc.NO;
    if (s.dead) return objc.NO;
    const f = s.ctx.focused_text orelse return objc.NO;
    return f.text.len > 0;
}

fn insertText(obj: objc.Object, _: objc.SEL, str: objc.Object) callconv(.c) void {
    const s = Surface.enter(obj) orelse return;
    defer s.leave();
    const t = objc.fromNSString(str);
    // Return and Tab, as the Mac's key bindings send them.
    if (std.mem.eql(u8, t, "\n")) return push(s, .{ .command = .insert_newline });
    if (std.mem.eql(u8, t, "\t")) return push(s, .{ .command = .insert_tab });
    push(s, .{ .insert = dupe(s, t) });
}

fn deleteBackward(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    const s = Surface.enter(obj) orelse return;
    defer s.leave();
    push(s, .{ .command = .delete_backward });
}

/// UIKeyboardHIDUsage to nanoui's keys.
fn keyOf(code: objc.NSInteger) ?Key {
    return switch (code) {
        0x2A => .backspace,
        0x4C => .delete,
        0x50 => .left,
        0x4F => .right,
        0x51 => .down,
        0x52 => .up,
        0x4A => .home,
        0x4D => .end,
        0x28, 0x58 => .enter,
        0x2B => .tab,
        0x29 => .escape,
        0x4B => .page_up,
        0x4E => .page_down,
        0x3A => .f1,
        0x3B => .f2,
        0x3C => .f3,
        0x3D => .f4,
        0x3E => .f5,
        0x3F => .f6,
        0x40 => .f7,
        0x41 => .f8,
        0x42 => .f9,
        0x43 => .f10,
        0x44 => .f11,
        0x45 => .f12,
        else => null,
    };
}

fn pressesBegan(obj: objc.Object, _: objc.SEL, presses: objc.Object, event: ?objc.Object) callconv(.c) void {
    // A press the field's hidden view passed on comes up to the view: it
    // was offered already.
    if (Surface.enter(obj)) |s| {
        defer s.leave();
        if (!passedOn(s, obj)) {
            const all = objc.msg(objc.Object, presses, "allObjects", .{});
            var taken = false;
            for (0..objc.msg(objc.NSUInteger, all, "count", .{})) |i| {
                const press = objc.msg(objc.Object, all, "objectAtIndex:", .{i});
                const key = objc.msg(?objc.Object, press, "key", .{}) orelse continue;
                if (handle(s, key)) taken = true;
                if (s.dead) return;
            }
            if (taken) return;
        }
    }
    // Not ours: the system's (a field's typing, the Home screen's keys).
    objc.msgSuper(void, obj, objc.class("UIView"), "pressesBegan:withEvent:", .{ presses, event });
}

// The system sees the end of every press, taken or not, as it sees their
// beginning when nanoui doesn't take them.
fn pressesEnded(obj: objc.Object, _: objc.SEL, presses: objc.Object, event: ?objc.Object) callconv(.c) void {
    released(obj, presses, event);
    objc.msgSuper(void, obj, objc.class("UIView"), "pressesEnded:withEvent:", .{ presses, event });
}

fn pressesCancelled(obj: objc.Object, _: objc.SEL, presses: objc.Object, event: ?objc.Object) callconv(.c) void {
    released(obj, presses, event);
    objc.msgSuper(void, obj, objc.class("UIView"), "pressesCancelled:withEvent:", .{ presses, event });
}

/// Keys let go: the modifiers held are the event's, less the modifier
/// keys let go now (the event may count them still).
fn released(obj: objc.Object, presses: objc.Object, event: ?objc.Object) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.dead) return;
    setModifiers(s, if (event) |e| objc.msg(objc.NSInteger, e, "modifierFlags", .{}) else 0);
    const in = &s.ctx.input;
    const all = objc.msg(objc.Object, presses, "allObjects", .{});
    for (0..objc.msg(objc.NSUInteger, all, "count", .{})) |i| {
        const press = objc.msg(objc.Object, all, "objectAtIndex:", .{i});
        const key = objc.msg(?objc.Object, press, "key", .{}) orelse continue;
        // The left and right Control, Shift, Option and Command keys.
        switch (objc.msg(objc.NSInteger, key, "keyCode", .{})) {
            0xE0, 0xE4 => in.ctrl = false,
            0xE1, 0xE5 => in.shift = false,
            0xE2, 0xE6 => in.alt = false,
            0xE3, 0xE7 => in.cmd = false,
            else => {},
        }
    }
}

/// The modifier keys held, from UIKit's flags (a key's, an event's).
pub fn setModifiers(s: *Surface, flags: objc.NSInteger) void {
    const in = &s.ctx.input;
    in.shift = flags & (1 << 17) != 0;
    in.ctrl = flags & (1 << 18) != 0;
    in.alt = flags & (1 << 19) != 0;
    in.cmd = flags & (1 << 20) != 0;
}

fn passedOn(s: *Surface, obj: objc.Object) bool {
    const v = s.keys.input orelse return false;
    return obj != v and objc.msg(objc.BOOL, v, "isFirstResponder", .{});
}

/// A tap with a field focused: the keyboard comes back if it was put away.
pub fn tapped(s: *Surface) void {
    if (s.ctx.focused_text == null) return;
    const v = s.keys.input orelse return;
    if (!objc.msg(objc.BOOL, v, "isFirstResponder", .{})) _ = objc.msg(objc.BOOL, v, "becomeFirstResponder", .{});
}

/// One key going down; true if nanoui took it.
fn handle(s: *Surface, key: objc.Object) bool {
    const in = &s.ctx.input;
    setModifiers(s, objc.msg(objc.NSInteger, key, "modifierFlags", .{}));
    const special = keyOf(objc.msg(objc.NSInteger, key, "keyCode", .{}));
    const focused = s.ctx.focused_text != null;
    const base: u21 = if (special) |k| switch (k) {
        .up => ui.Shortcut.up,
        .down => ui.Shortcut.down,
        .left => ui.Shortcut.left,
        .right => ui.Shortcut.right,
        .tab => ui.Shortcut.tab,
        .escape => ui.Shortcut.escape,
        .enter => ui.Shortcut.enter,
        else => 0,
    } else firstChar(objc.fromNSString(objc.msg(?objc.Object, key, "charactersIgnoringModifiers", .{})));
    // As on the Mac: combinations, and the keys that move between things.
    const moves = base == ui.Shortcut.up or base == ui.Shortcut.down or base == ui.Shortcut.tab or base == ui.Shortcut.escape;
    if (base != 0 and (in.cmd or in.ctrl or (in.alt and !focused) or moves)) {
        const sc: ui.Shortcut = .{ .key = base, .cmd = in.cmd, .ctrl = in.ctrl, .alt = in.alt, .shift = in.shift };
        if (s.window.app.accelerator(sc)) return true;
        s.ctx.shortcut_taken = false;
        in.shortcut = sc;
        s.frame();
        if (s.dead) return true;
        in.shortcut = null;
        if (s.ctx.shortcut_taken) return true;
        if (in.cmd and editShortcut(s, base)) return true;
    }
    if (focused) {
        // Typed text, Return, Delete and Tab come as the field's text
        // (UIKeyInput); the keys that move the caret come here.
        const k = special orelse return false;
        switch (k) {
            .backspace, .enter, .tab => return false,
            else => {},
        }
        in.key = k;
        s.frame();
        return true;
    }
    if (in.cmd or in.ctrl) return false;
    in.key = special;
    // Printable text only: no controls.
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    if (special == null) {
        const chars = objc.fromNSString(objc.msg(?objc.Object, key, "characters", .{}));
        if (chars.len <= buf.len and chars.len > 0 and chars[0] >= 0x20 and chars[0] != 0x7f) {
            @memcpy(buf[0..chars.len], chars);
            n = chars.len;
        }
    }
    in.chars = buf[0..n];
    if (in.key == null and n == 0) return false;
    s.frame();
    if (!s.dead) in.chars = "";
    return true;
}

/// The first character of `s`, lowercase when ASCII; 0 if none.
fn firstChar(s: []const u8) u21 {
    if (s.len == 0) return 0;
    const cp = std.unicode.utf8Decode(s[0..@min(s.len, cf.seqLen(s[0]))]) catch return 0;
    return if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
}

/// ⌘C, ⌘X, ⌘V and ⌘A the view didn't take: the focused field's, or the
/// selection's copy.
fn editShortcut(s: *Surface, key: u21) bool {
    const focused = s.ctx.focused_text != null;
    switch (key) {
        'c' => push(s, .{ .command = .copy }),
        'x' => if (focused) push(s, .{ .command = .cut }) else return false,
        'a' => if (focused) push(s, .{ .command = .select_all }) else return false,
        // Not read here: iOS lets an app read what another put on the
        // pasteboard only for the system's own paste (UIKit's ⌘V calls
        // the field's `paste:`, `textinput.zig`).
        else => return false,
    }
    return true;
}

/// The keyboard moved: how much of the view's bottom it covers now.
fn keyboardChanged(obj: objc.Object, _: objc.SEL, note: objc.Object) callconv(.c) void {
    const s = Surface.enter(obj) orelse return;
    defer s.leave();
    const info = objc.msg(?objc.Object, note, "userInfo", .{}) orelse return;
    const value = objc.msg(?objc.Object, info, "objectForKey:", .{UIKeyboardFrameEndUserInfoKey}) orelse return;
    const win = objc.msg(?objc.Object, obj, "window", .{}) orelse return;
    const screen = objc.msg(objc.Object, win, "screen", .{});
    const space = objc.msg(objc.Object, screen, "coordinateSpace", .{});
    const rect = objc.msg(objc.CGRect, value, "CGRectValue", .{});
    const local = objc.msg(objc.CGRect, obj, "convertRect:fromCoordinateSpace:", .{ rect, space });
    const h = objc.msg(objc.CGRect, obj, "bounds", .{}).size.height;
    // Docked: it reaches the view's bottom. Floating or split (an iPad's),
    // it covers no edge, and nothing needs to move out of its way.
    const docked = local.size.height > 0 and local.origin.y + local.size.height >= h - 1;
    const covered = if (docked) h - local.origin.y else 0;
    s.keyboard = @floatCast(std.math.clamp(covered, 0, h));
    s.requestFrame();
}
