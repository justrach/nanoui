//! Layout animation, as Motion's `layout`: when the layout moves a box (a
//! list reordered, a panel opened above it), it is drawn where it was and
//! glides to where it now is. The painter asks `shift` for each such box as
//! it draws it, so the move is seen from the first frame.
const std = @import("std");
const Context = @import("../context.zig").Context;
const types = @import("../types.zig");
const Channel = @import("channel.zig").Channel;
const Transition = @import("channel.zig").Transition;

/// The offset to draw box `id` at, laid out at `rect` this frame: from
/// where it was drawn, easing to nothing.
pub fn shift(c: *Context, id: u64, rect: types.Rect) [2]f32 {
    const l = c.motion_store.layouts.getPtr(id) orelse return .{ 0, 0 };
    l.seen = c.frame;
    const tr: Transition = if (c.reduced_motion or c.reduce_motion) .instant else l.transition;
    defer l.rect = .{ rect.x, rect.y, rect.w, rect.h };
    const was = l.rect orelse return .{ 0, 0 };
    const moved: [2]f32 = .{ was[0] - rect.x, was[1] - rect.y };
    var out: [2]f32 = undefined;
    for (&l.ch, 0..) |*ch, i| {
        if (tr == .instant) {
            // Settle an existing glide even when its destination hasn't moved.
            ch.jump(0);
        } else if (@abs(moved[i]) > 0.01) {
            // From where it shows now, plus how far the layout moved it.
            ch.sample(c.time);
            const v = ch.velocity;
            ch.* = .at(ch.value + moved[i]);
            ch.velocity = v;
            ch.retarget(0, tr, 0, c.time);
        }
        ch.sample(c.time);
        if (ch.moving) c.animationFrame();
        out[i] = @floatCast(ch.value);
    }
    return out;
}

test {
    _ = Channel;
}
