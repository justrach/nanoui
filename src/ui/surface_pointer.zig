//! The macOS surface's pointer and focus after a frame: the cursor the
//! view asked for (an app's own, `ui.makeCursor`, included), the keyboard
//! for a box newly focused, and the help under the pointer
//! (`surface.zig` keeps the rest).
const std = @import("std");
const objc = @import("../objc.zig");
const ctx_mod = @import("context.zig");
const Surface = @import("surface.zig").Surface;

pub fn updateCursor(self: *Surface) void {
    if (self.transparent and self.ctx.inStageHoleAt(self.ctx.input.mouse)) {
        self.cursor_dirty = true;
        return;
    }
    const want: ctx_mod.Cursor = self.ctx.cursor orelse if (self.ctx.cursor_text) .text else if (self.ctx.cursor_hand) .hand else .arrow;
    const custom = if (want == .custom) self.ctx.custom_cursor else null;
    if (want == self.cursor and custom == self.custom_cursor and !self.cursor_dirty) return;
    self.cursor = want;
    self.custom_cursor = custom;
    self.cursor_dirty = false;
    self.applyCursor();
}

pub fn applyCursor(self: *Surface) void {
    if (self.cursor == .custom) if (self.custom_cursor) |cur| {
        return objc.msg(void, @as(objc.Object, @ptrCast(cur)), "set", .{});
    };
    const name = @import("surface_cursor.zig").name(self.cursor);
    objc.msg(void, objc.msg(objc.Object, objc.class("NSCursor"), name, .{}), "set", .{});
}

/// After a frame: a box newly focused takes the keyboard for the view
/// (`focusNext` while a page had it), and the hot box's help shows.
pub fn afterFocus(self: *Surface) void {
    const c = &self.ctx;
    if (c.focus != 0) {
        const first = objc.msg(?objc.Object, self.window.nswindow, "firstResponder", .{});
        if (first == null or first.? != self.nsview) _ = objc.msg(objc.BOOL, self.window.nswindow, "makeFirstResponder:", .{self.nsview});
    } else if (self.last_focus != 0 and c.focus == 0) {
        const first = objc.msg(?objc.Object, self.window.nswindow, "firstResponder", .{});
        if (first != null and first.? == self.nsview and c.selection.hit == null and !c.selection.dragging and c.selection.text.items.len == 0) {
            if (self.keys_released) |kr| kr.func(kr.ctx, self);
        }
    }
    self.last_focus = c.focus;
    self.refreshTip();
}

/// Shows the help under the pointer: after a frame, and on a move
/// within one box onto a marker with its own.
pub fn refreshTip(self: *Surface) void {
    const tip = self.ctx.hotHelp();
    const same = if (tip) |t| (if (self.tip) |old| std.mem.eql(u8, t, old) else false) else self.tip == null;
    if (same) return;
    if (self.tip) |old| self.gpa.free(old);
    self.tip = if (tip) |t| self.gpa.dupe(u8, t) catch null else null;
    objc.msg(void, self.nsview, "setToolTip:", .{if (self.tip) |t| objc.nsString(t) else @as(?objc.Object, null)});
}
