//! Anchor GTK's candidate window to the focused field's caret after layout.
const Surface = @import("surface.zig").Surface;
const gtk = @import("gtk.zig");
const context = @import("../ui/context.zig");
const Rect = @import("../ui/types.zig").Rect;

const Offset = struct { x: c_int = 0, y: c_int = 0 };

pub fn placeCandidates(s: *Surface) void {
    const field = s.ctx.focused_text orelse return;
    var offset: Offset = .{};
    if (!gtk.v4 and gtk.v3.gtk_widget_get_has_window(s.area) == 0) {
        var allocation: gtk.Rectangle = undefined;
        gtk.v3.gtk_widget_get_allocation(s.area, &allocation);
        offset = .{ .x = allocation.x, .y = allocation.y };
    }
    const rect = candidateRect(&s.ctx, field, offset);
    gtk.api.gtk_im_context_set_cursor_location(s.im, &rect);
}

pub fn candidateRect(c: *const context.Context, field: context.FocusedText, offset: Offset) gtk.Rectangle {
    var caret = field.caret_rect;
    // Text fields build against the previous layout. GTK needs the position
    // in the frame just drawn, including when a field first takes focus.
    if (c.rects.get(field.id)) |rect| {
        const prev = c.prev_rects.get(field.id) orelse Rect{};
        caret.x += rect.x - prev.x;
        caret.y += rect.y - prev.y;
        if (!c.focused_multiline) caret.y += (rect.h - prev.h) / 2;
    }
    // GTK takes logical coordinates, including on a scaled display.
    return .{
        .x = @as(c_int, @intFromFloat(@floor(caret.x))) + offset.x,
        .y = @as(c_int, @intFromFloat(@floor(caret.y))) + offset.y,
        .width = @intFromFloat(@max(1, @round(caret.w))),
        .height = @intFromFloat(@max(1, @round(caret.h))),
    };
}
