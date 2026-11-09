//! NanoUIView's keys: key combinations offered to the view first (as
//! `input.shortcut`), Tab's focus traversal, the focused text field's
//! input system, then plain keys and typed text; the modifier keys alone;
//! Paste; and the menu bar's key equivalents held back while a view
//! captures chords (`keys.suspendMenuKeyEquivalents`).
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const textinput = @import("textinput.zig");
const input = @import("input.zig");
const keys = @import("keys.zig");
const Surface = @import("surface.zig").Surface;
const setMods = @import("surface_events.zig").setMods;

pub const methods = [_]objc.Method{
    .{ .name = "keyDown:", .imp = &keyDown, .types = "v@:@" },
    .{ .name = "flagsChanged:", .imp = &flagsChanged, .types = "v@:@" },
    .{ .name = "paste:", .imp = &paste, .types = "v@:@" },
    .{ .name = "performKeyEquivalent:", .imp = &performKeyEquivalent, .types = "c@:@" },
};

fn surfaceOf(obj: objc.Object) ?*Surface {
    return objc.getZig(Surface, obj);
}

fn keyDown(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    deliver(s, event);
}

/// While the menu's key equivalents are held back, a ⌘ chord meant for
/// the menu comes to the focused view as a key instead.
fn performKeyEquivalent(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) objc.BOOL {
    const s = surfaceOf(obj) orelse return objc.NO;
    if (keys.menu_key_equivalents_suspended) {
        const first = objc.msg(?objc.Object, s.window.nswindow, "firstResponder", .{});
        if (first != null and first.? == obj) {
            deliver(s, event);
            return objc.YES;
        }
    }
    return objc.msgSuper(objc.BOOL, obj, objc.class("NSView"), "performKeyEquivalent:", .{event});
}

/// The key a shortcut names for this event: the character without
/// modifiers (Shift+1 is '1' with Shift, not '!'), ASCII lowered;
/// function keys as AppKit's code points.
pub fn shortcutKey(event: objc.Object, code: u16, ignoring: u21, shift: bool) u21 {
    const key = input.Shortcut.keyOf(ignoring);
    // Shift is the one modifier `charactersIgnoringModifiers` keeps.
    if (!shift or ignoring >= 0xF700 or ignoring == 0x19 or ignoring < 0x20) return key;
    const plain = objc.fromNSString(objc.msg(?objc.Object, event, "charactersByApplyingModifiers:", .{@as(objc.NSUInteger, 0)}));
    if (plain.len > 0) {
        const cp = std.unicode.utf8Decode(plain[0..@min(plain.len, cf.seqLen(plain[0]))]) catch 0;
        if (cp >= 0x20) return input.Shortcut.keyOf(cp);
    }
    const ansi = keys.ansiChar(code);
    return if (ansi != 0) ansi else key;
}

/// A key press, as `keyDown:` has it.
pub fn deliver(s: *Surface, event: objc.Object) void {
    const tok = s.token();
    const code = objc.msg(u16, event, "keyCode", .{});
    const flags = objc.msg(objc.NSUInteger, event, "modifierFlags", .{});
    const in = &s.ctx.input;
    setMods(in, flags);
    // Key combinations go to the view first, which may take them; while an
    // input method composes, only ⌘'s do (↓, Space, Esc, Tab are its).
    // With no text field focused every key is offered, with its modifiers
    // (Shift+1, a bare letter, Home, F5): the app's own key bindings.
    const composing = textinput.composing(s);
    const ign = objc.fromNSString(objc.msg(?objc.Object, event, "charactersIgnoringModifiers", .{}));
    if (ign.len > 0) {
        const cp = std.unicode.utf8Decode(ign[0..@min(ign.len, cf.seqLen(ign[0]))]) catch 0;
        const key = shortcutKey(event, code, cp, in.shift);
        const special = key == 0xF700 or key == 0xF701 or key == '\t' or key == 0x1b;
        const no_field = s.ctx.focused_text == null;
        // Option too: a text field with Emacs's keys takes ⌥B, ⌥F, ⌥D.
        if (in.cmd or (!composing and (in.ctrl or in.alt or special or no_field))) {
            s.ctx.shortcut_taken = false;
            in.shortcut = .{ .key = key, .cmd = in.cmd, .ctrl = in.ctrl, .alt = in.alt, .shift = in.shift };
            s.frame();
            if (!Surface.alive(tok)) return;
            in.shortcut = null;
            if (s.ctx.shortcut_taken) return;
            if (in.cmd and !in.ctrl and !in.alt and !in.shift) switch (key) {
                'c' => return textinput.copy(s),
                'x' => return textinput.cut(s),
                'v' => return pasteText(s),
                'a' => return textinput.selectAll(s),
                else => {},
            };
        }
    }
    if (code == 48 and !composing and !in.cmd and !in.ctrl and !in.alt and !s.ctx.focused_multiline and s.ctx.focusable_ids.items.len > 0) {
        s.ctx.focusCycle(in.shift);
        s.frame();
        return;
    }
    // A focused text field gets the event through the input system:
    // accents, input methods, the system's key bindings.
    if (textinput.interpret(s, event)) return;
    in.key = keyOf(code);
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    if (in.key == null and !in.cmd and !in.ctrl) {
        const chars = objc.fromNSString(objc.msg(?objc.Object, event, "characters", .{}));
        // Printable text only: no controls, no function keys (U+F700…).
        var i: usize = 0;
        while (i < chars.len) {
            const len = cf.seqLen(chars[i]);
            const seq = chars[i..@min(chars.len, i + len)];
            const printable = seq[0] >= 0x20 and seq[0] != 0x7f and !(seq.len == 3 and seq[0] == 0xef and seq[1] >= 0x9c and seq[1] <= 0x9f);
            if (printable and n + seq.len <= buf.len) {
                @memcpy(buf[n .. n + seq.len], seq);
                n += seq.len;
            }
            i += len;
        }
    }
    in.chars = buf[0..n];
    if (in.key == null and n == 0) return;
    s.frame();
}

/// The editing key of a Mac virtual key code.
fn keyOf(code: u16) ?input.Key {
    return switch (code) {
        51 => .backspace,
        117 => .delete,
        123 => .left,
        124 => .right,
        125 => .down,
        126 => .up,
        115 => .home,
        119 => .end,
        36, 76 => .enter,
        48 => .tab,
        53 => .escape,
        116 => .page_up,
        121 => .page_down,
        122 => .f1,
        120 => .f2,
        99 => .f3,
        118 => .f4,
        96 => .f5,
        97 => .f6,
        98 => .f7,
        100 => .f8,
        101 => .f9,
        109 => .f10,
        103 => .f11,
        111 => .f12,
        else => null,
    };
}

/// The modifier keys alone: a frame with `mods_changed` (a switcher that
/// commits as Control is let go).
fn flagsChanged(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    setMods(&s.ctx.input, objc.msg(objc.NSUInteger, event, "modifierFlags", .{}));
    s.ctx.input.mods_changed = true;
    s.frame();
}

fn pasteText(s: *Surface) void {
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    const str = objc.msg(?objc.Object, pb, "stringForType:", .{objc.nsString("public.utf8-plain-text")});
    const bytes = objc.fromNSString(str);
    s.pasted.clearRetainingCapacity();
    if (s.ctx.focused_multiline) {
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] == '\r') {
                if (i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1;
                s.pasted.append(s.gpa, '\n') catch return;
            } else {
                s.pasted.append(s.gpa, bytes[i]) catch return;
            }
        }
    } else {
        s.pasted.appendSlice(s.gpa, bytes) catch return;
        for (s.pasted.items) |*ch| if (ch.* == '\n' or ch.* == '\r') {
            ch.* = ' ';
        };
    }
    textinput.paste(s, s.pasted.items);
}

fn paste(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    const tok = s.token();
    // ⌘V goes to the view first, as other shortcuts do: it may paste what
    // is not text (an image).
    s.ctx.shortcut_taken = false;
    s.ctx.input.shortcut = .{ .key = 'v', .cmd = true };
    s.frame();
    if (!Surface.alive(tok)) return;
    s.ctx.input.shortcut = null;
    if (s.ctx.shortcut_taken) return;
    pasteText(s);
}
