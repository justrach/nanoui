//! Pull to refresh: how far a scrolling box is pulled down past its top,
//! and one `true` when it is let go past `threshold`. It reads the box's
//! rubber-band overscroll, which touches (iOS) and trackpads make, and
//! holds no memory of its own beyond the struct the caller keeps.
//!
//!     const list = ui.div(c).column().scrollY();
//!     if (s.pull.update(c, list.id())) s.refresh();
//!     // draw s.pull.progress() as an indicator above the rows
//!     list.end();
const std = @import("std");
const Context = @import("../context.zig").Context;

pub const Pull = struct {
    /// Points to pull before letting go refreshes.
    threshold: f32 = 64,
    /// Pulled this far, points, as of the last `update`.
    distance: f32 = 0,
    /// Past the threshold with the finger still down.
    armed: bool = false,

    /// Call once a frame for the scrolling box `id`; true the frame it is
    /// let go past the threshold.
    pub fn update(p: *Pull, c: *Context, id: u64) bool {
        const over = c.overscroll.get(id) orelse 0;
        p.distance = @max(0, -over);
        if (c.scroll_holding) {
            p.armed = p.distance >= p.threshold;
            return false;
        }
        if (!p.armed) return false;
        p.armed = false;
        return true;
    }

    /// 0 to 1 toward the threshold.
    pub fn progress(p: Pull) f32 {
        return std.math.clamp(p.distance / p.threshold, 0, 1);
    }
};
