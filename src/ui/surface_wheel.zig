//! A wheel event's deltas on macOS. Sideways goes to a view that takes the
//! wheel (`wants_wheel`, `input.scroll.x`): a row of tabs that pans, which
//! a trackpad swipes sideways. Main's `surface_events.scrollWheel` does the
//! same; this pin read only the vertical delta.
const objc = @import("../objc.zig");

/// Hands `event`'s sideways delta to the view, and returns the vertical
/// one, or null when the event was only sideways and is done.
pub fn sideways(s: anytype, event: objc.Object) ?f32 {
    const k: f32 = if (objc.msg(objc.BOOL, event, "hasPreciseScrollingDeltas", .{})) 1 else 12;
    const dx = k * @as(f32, @floatCast(objc.msg(f64, event, "scrollingDeltaX", .{})));
    const dy = k * @as(f32, @floatCast(objc.msg(f64, event, "scrollingDeltaY", .{})));
    if (dx == 0 or !s.ctx.wants_wheel) return dy;
    s.ctx.input.scroll.x += dx;
    if (s.display_link != null and !s.resizing) s.requestFrame() else s.frame();
    return if (dy == 0) null else dy;
}
