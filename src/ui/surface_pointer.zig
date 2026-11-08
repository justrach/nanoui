//! The macOS surface's pointer: the cursor the view asked for (an app's
//! own, `ui.makeCursor`, included). `surface.zig` keeps the rest.
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
