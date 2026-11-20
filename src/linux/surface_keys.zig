//! Keyboard and input-method handling for a Linux surface (extracted from
//! `surface.zig` to keep both files small and focused).
const std = @import("std");
const gtk = @import("gtk.zig");
const ui = @import("../ui/ui.zig");
const ctx_mod = @import("../ui/context.zig");
const Surface = @import("surface.zig").Surface;

fn of(data: ?*anyopaque) *Surface {
    return @ptrCast(@alignCast(data));
}

/// GDK key values of the keys that are not text.
fn keyOf(keyval: c_uint) ?ctx_mod.Key {
    return switch (keyval) {
        0xff08 => .backspace,
        0xffff => .delete,
        0xff51 => .left,
        0xff52 => .up,
        0xff53 => .right,
        0xff54 => .down,
        0xff50 => .home,
        0xff57 => .end,
        0xff0d, 0xff8d => .enter,
        0xff09, 0xfe20 => .tab,
        0xff1b => .escape,
        0xff55 => .page_up,
        0xff56 => .page_down,
        0xffbe...0xffc9 => @fromBackingInt(@intCast(@backingInt(ctx_mod.Key.f1) + (keyval - 0xffbe))),
        else => null,
    };
}

pub fn onKey(_: *gtk.Widget, e: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    var keyval: c_uint = 0;
    var state: c_uint = 0;
    _ = gtk.v3.gdk_event_get_keyval(e, &keyval);
    _ = gtk.v3.gdk_event_get_state(e, &state);
    return @intFromBool(keyPress(of(data), keyval, state, e));
}

/// A key pressed; true if it was taken. GTK 3 passes its event for the
/// input method; GTK 4's sends typed text to `typed` itself.
pub fn keyPress(s: *Surface, keyval: c_uint, state: c_uint, e: ?*gtk.Event) bool {
    const g = &gtk.api;
    const in = &s.ctx.input;
    in.shift = state & gtk.shift_mask != 0;
    in.cmd = false;
    const ctrl = state & gtk.control_mask != 0;
    const alt = state & gtk.alt_mask != 0;
    in.ctrl = ctrl;
    in.alt = alt;
    const key = keyOf(keyval);
    // Key combinations go to the menus' accelerators, then the view.
    const special: ?u21 = if (key) |k| switch (k) {
        .up => ui.Shortcut.up,
        .down => ui.Shortcut.down,
        .left => ui.Shortcut.left,
        .right => ui.Shortcut.right,
        .tab => ui.Shortcut.tab,
        .escape => ui.Shortcut.escape,
        .enter => ui.Shortcut.enter,
        else => null,
    } else null;
    const cp: u21 = @intCast(g.gdk_keyval_to_unicode(keyval));
    const base: u21 = special orelse if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
    if (base != 0 and (ctrl or alt or (special != null and (base == ui.Shortcut.up or base == ui.Shortcut.down or base == ui.Shortcut.tab or base == ui.Shortcut.escape)))) {
        const sc: ui.Shortcut = .{ .key = base, .ctrl = ctrl, .alt = alt, .shift = in.shift };
        if (s.window.app.accelerator(sc)) return true;
        if (ctrl and s.ctx.focused_text != null and editShortcut(s, base)) return true;
        s.ctx.shortcut_taken = false;
        in.shortcut = sc;
        s.frame();
        in.shortcut = null;
        if (s.ctx.shortcut_taken) return true;
    }
    if (key) |k| {
        in.key = k;
        s.frame();
        return true;
    }
    if (ctrl) return false;
    s.committed.clearRetainingCapacity();
    const ev = e orelse return false;
    if (gtk.v3.gtk_im_context_filter_keypress(s.im, ev) == 0 and cp >= 0x20 and cp != 0x7f) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return false;
        s.committed.appendSlice(s.gpa, buf[0..n]) catch {};
    }
    if (s.committed.items.len == 0) return true;
    in.chars = s.committed.items;
    s.frame();
    return true;
}

/// Ctrl+C, X, V and A in a text field: copy, cut, paste, select all.
fn editShortcut(s: *Surface, key: u21) bool {
    const op: ctx_mod.TextOp = switch (key) {
        'c' => .{ .command = .copy },
        'x' => .{ .command = .cut },
        'a' => .{ .command = .select_all },
        'v' => {
            const pasted = @import("desktop.zig").clipboard.readText(s.gpa) catch return true;
            // No text: the view may take Ctrl+V for something else (an image).
            const t = pasted orelse return false;
            defer s.gpa.free(t);
            for (t) |*ch| if (ch.* == '\n' or ch.* == '\r') {
                ch.* = ' ';
            };
            var ops = [1]ctx_mod.TextOp{.{ .insert = t }};
            s.ctx.input.ops = &ops;
            s.frame();
            s.ctx.input.ops = &.{};
            return true;
        },
        else => return false,
    };
    var ops = [1]ctx_mod.TextOp{op};
    s.ctx.input.ops = &ops;
    s.frame();
    s.ctx.input.ops = &.{};
    return true;
}
