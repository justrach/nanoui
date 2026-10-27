//! A focused caret is solid after input, then toggles every 500 ms.
//! Only the next edge needs a frame; blur, selection and an inactive
//! window stop it altogether, rather than leaving a polling animation.
const Context = @import("context.zig").Context;

pub const Blink = struct {
    anchor: ?f64 = null,

    pub const Frame = struct { visible: bool, next: ?f32 = null };

    pub fn step(b: *Blink, now: f64, active: bool, selected: bool, composing: bool, edited: bool) Frame {
        if (!active or selected) {
            b.anchor = null;
            return .{ .visible = false };
        }
        if (b.anchor == null or edited) b.anchor = now;
        if (composing) return .{ .visible = true };
        const phase = @mod(@max(0, now - b.anchor.?), 1.0);
        const on = phase < 0.5;
        return .{ .visible = on, .next = @floatCast((if (on) @as(f64, 0.5) else 1.0) - phase) };
    }
};

pub fn shown(c: *Context, focused: bool, selected: bool, composing: bool, edited: bool) bool {
    const b = c.state(Blink, "caret-blink");
    const frame = b.step(c.time, focused and c.input.window_active, selected, composing, edited);
    if (frame.next) |wait| c.frameIn(wait);
    return frame.visible;
}
