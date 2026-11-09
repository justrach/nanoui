//! A Windows surface's keys that are not text: the named keys, and the
//! combinations offered to the menus' accelerators, the text field's
//! editing shortcuts and the view (`surface.zig` hands them over).
const std = @import("std");
const w = @import("win32.zig");
const ui = @import("../ui/ui.zig");
const ctx_mod = @import("../ui/context.zig");
const Surface = @import("surface.zig").Surface;

/// Keys that are not text, and key combinations; true if taken.
pub fn keyDown(self: *Surface, vk: u32) bool {
    const in = &self.ctx.input;
    const ctrl = w.GetKeyState(0x11) < 0;
    const alt = w.GetKeyState(0x12) < 0;
    in.shift = w.GetKeyState(0x10) < 0;
    in.cmd = false;
    in.ctrl = ctrl;
    in.alt = alt;
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
    const letter: u21 = if ((vk >= 'A' and vk <= 'Z') or (vk >= '0' and vk <= '9')) std.ascii.toLower(@intCast(vk)) else switch (vk) {
        0xBC => ',',
        0xBE => '.',
        0xBF => '/',
        0xDB => '[',
        0xDD => ']',
        0xDC => '\\',
        0xBD => '-',
        0xBB => '=',
        0x20 => ' ',
        else => 0,
    };
    const base: u21 = special orelse letter;
    const offer = base != 0 and (ctrl or alt or base == S.up or base == S.down or base == S.tab or base == S.escape);
    if (offer) {
        const sc: S = .{ .key = base, .ctrl = ctrl, .alt = alt, .shift = in.shift };
        if (self.window.app.accelerator(sc)) return true;
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
        if (self.ctx.shortcut_taken) return true;
    }
    if (key) |k| {
        in.key = k;
        self.frame();
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
