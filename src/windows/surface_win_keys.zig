//! A Windows surface's keys that are not text: the named keys, and the
//! combinations offered to the menus' accelerators, the text field's
//! editing shortcuts and the view (`surface.zig` hands them over); keys
//! let go (`input.key_up`), all of them when the keyboard goes elsewhere
//! (`input.keys_released`), the modifier keys alone (`mods_changed`), and
//! what Alt leaves to the system (Alt+F4, Alt+Space, the window menu).
const std = @import("std");
const w = @import("win32.zig");
const ui = @import("../ui/ui.zig");
const ctx_mod = @import("../ui/context.zig");
const ime = @import("ime.zig");
pub const names = @import("key_names.zig");
const Surface = @import("surface.zig").Surface;

/// Shift, Control and Alt as they are now; no Command off the Mac.
pub fn readMods(self: *Surface) void {
    const in = &self.ctx.input;
    in.shift = w.GetKeyState(0x10) < 0;
    in.cmd = false;
    in.ctrl = w.GetKeyState(0x11) < 0;
    in.alt = w.GetKeyState(0x12) < 0;
}

/// The keyboard went elsewhere (focus or activation lost, a menu's or a
/// dialog's modal loop): the key-ups of keys held go there, Alt's after
/// Alt+Tab among them. The next frame has `input.keys_released`, the
/// modifiers up, and Alt's gestures forgotten.
pub fn releaseKeys(self: *Surface) void {
    self.ctx.input.releaseKeys();
    self.alt_used = false;
    self.sys_taken = false;
}

fn isAlt(vk: u32) bool {
    return vk == 0x12 or vk == 0xA4 or vk == 0xA5;
}

/// WM_KEYDOWN, WM_SYSKEYDOWN, WM_KEYUP, WM_SYSKEYUP and WM_SYSCHAR; null
/// for what DefWindowProc keeps (Alt's window menu, Alt+F4, Alt+Space).
pub fn message(self: *Surface, h: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
    const vk: u32 = @truncate(wp);
    const in = &self.ctx.input;
    switch (msg) {
        // An Alt combination the view took: DefWindowProc would look its
        // character up as a menu mnemonic, find none, and beep.
        w.WM_SYSCHAR => {
            if (!self.sys_taken) return null;
            self.sys_taken = false;
            return 0;
        },
        w.WM_KEYUP, w.WM_SYSKEYUP => {
            readMods(self);
            if (names.isModifier(vk)) {
                in.mods_changed = true;
                self.frame();
                // Alt let go after a gesture with it: no window menu.
                if (msg == w.WM_SYSKEYUP and isAlt(vk) and self.alt_used) {
                    self.alt_used = false;
                    return 0;
                }
                return null;
            }
            if (!self.ime.composing) keyUp(self, vk);
            // F10's and Alt's menu handling stays the system's.
            return if (msg == w.WM_SYSKEYUP) null else 0;
        },
        else => {},
    }
    const repeat = names.isRepeat(lp);
    if (msg == w.WM_SYSKEYDOWN) self.sys_taken = false;
    if (names.isModifier(vk)) {
        // A held modifier repeats, and nothing changed.
        if (repeat) return null;
        readMods(self);
        if (isAlt(vk)) self.alt_used = false;
        in.mods_changed = true;
        self.frame();
        return null;
    }
    // Composing: the keys belong to the input method — its caret, its
    // candidates, Return to commit. Handling them here as well makes Return
    // commit and insert a newline at the same time. A *system* key is
    // another matter: Alt+F4 and its friends must keep working, so they go
    // to the default handling.
    if (self.ime.composing) return if (msg == w.WM_SYSKEYDOWN) null else 0;
    // Alt+F4 closes the window, as everywhere on Windows.
    if (msg == w.WM_SYSKEYDOWN and vk == 0x73) return null;
    if (keyDown(self, vk, repeat)) {
        if (msg == w.WM_SYSKEYDOWN and vk != 0x20) {
            self.sys_taken = true;
            self.alt_used = true;
        }
        // An arrow key or a delete moved the caret: the IME's windows
        // follow it, outside `frame` where its callbacks re-enter.
        if (self.ctx.focused_text != null) ime.follow(h, &self.ctx, self.scale, &self.ime);
        return 0;
    }
    return null;
}

/// A key let go: a frame with `input.key_up`, for keys a shortcut names.
pub fn keyUp(self: *Surface, vk: u32) void {
    const code = names.upKey(vk);
    if (code == 0) return;
    const in = &self.ctx.input;
    in.key_up = .{ .key = code, .ctrl = in.ctrl, .alt = in.alt, .shift = in.shift };
    // Restored, not cleared, as in `keyDown`: a message pumped during the
    // frame may set ops of its own.
    const prev_ops = in.ops;
    self.frame();
    in.ops = prev_ops;
    in.key_up = null;
}

/// Keys that are not text, and key combinations; true if taken. `repeat`:
/// the system's auto-repeat of a held key (`input.repeat`).
pub fn keyDown(self: *Surface, vk: u32, repeat: bool) bool {
    const in = &self.ctx.input;
    readMods(self);
    const ctrl = in.ctrl;
    const alt = in.alt;
    const key: ?ctx_mod.Key = switch (vk) {
        0x08 => .backspace,
        0x2E => .delete,
        0x25 => .left,
        0x26 => .up,
        0x27 => .right,
        0x28 => .down,
        0x24 => .home,
        0x23 => .end,
        0x0D => .enter,
        0x09 => .tab,
        0x1B => .escape,
        0x21 => .page_up,
        0x22 => .page_down,
        0x70...0x7B => @fromBackingInt(@intCast(@backingInt(ctx_mod.Key.f1) + (vk - 0x70))),
        else => null,
    };
    const S = ui.Shortcut;
    const special: ?u21 = if (key) |k| switch (k) {
        .up => S.up,
        .down => S.down,
        .left => S.left,
        .right => S.right,
        .tab => S.tab,
        .escape => S.escape,
        .enter => S.enter,
        else => null,
    } else null;
    // Letters and digits by their virtual key; other characters come as WM_CHAR.
    const base: u21 = special orelse names.letter(vk);
    const offer = base != 0 and (ctrl or alt or base == S.up or base == S.down or base == S.tab or base == S.escape);
    if (offer) {
        const sc: S = .{ .key = base, .ctrl = ctrl, .alt = alt, .shift = in.shift };
        if (self.window.app.accelerator(sc)) return true;
        in.repeat = repeat;
        if (ctrl and self.ctx.focused_text != null and editShortcut(self, base)) return true;
        self.ctx.shortcut_taken = false;
        in.shortcut = sc;
        // Restored, not cleared: building the view can pump messages (the
        // shell does), and an IME character that arrives inside the pump
        // sets its own ops — which must not be thrown away with ours.
        const prev_ops = self.ctx.input.ops;
        self.frame();
        self.ctx.input.ops = prev_ops;
        in.shortcut = null;
        in.repeat = false;
        if (self.ctx.shortcut_taken) return true;
    }
    if (key) |k| {
        in.key = k;
        in.repeat = repeat;
        self.frame();
        in.repeat = false;
        return true;
    }
    return false;
}

/// Ctrl+C, X, V and A in a text field: copy, cut, paste, select all.
fn editShortcut(self: *Surface, key: u21) bool {
    var ops: [1]ctx_mod.TextOp = undefined;
    var pasted: ?[]u8 = null;
    defer if (pasted) |p| self.gpa.free(p);
    ops[0] = switch (key) {
        'c' => .{ .command = .copy },
        'x' => .{ .command = .cut },
        'a' => .{ .command = .select_all },
        'v' => blk: {
            pasted = @import("desktop.zig").clipboard.readText(self.gpa) catch null;
            // No text: the view may take Ctrl+V for something else (an image).
            const t = pasted orelse return false;
            for (t) |*ch| if (ch.* == '\n' or ch.* == '\r') {
                ch.* = ' ';
            };
            break :blk .{ .insert = t };
        },
        else => return false,
    };
    // Restored, not cleared, for the same reason as in `keyDown`: a message
    // pumped during the frame may set ops of its own.
    const prev_ops = self.ctx.input.ops;
    self.ctx.input.ops = &ops;
    self.frame();
    self.ctx.input.ops = prev_ops;
    return true;
}
