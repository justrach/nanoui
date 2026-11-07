//! Which scroller a wheel moves: the innermost under the pointer that can still go
//! the way the wheel mostly points, else the page. So a carousel doesn't catch a
//! scroll down, nor a list at its end.
const List = @import("display.zig").List;

pub fn scrollerAt(l: *const List, x: f32, y: f32, dx: f32, dy: f32) u32 {
    var i = l.clips.len;
    while (i > 2) {
        i -= 1;
        const c = l.clips[i];
        if (c.scrolls and c.visible.contains(x, y) and canMove(l, @intCast(i), dx, dy)) return @intCast(i);
    }
    return 1;
}

/// Whether it can go that way (negative: on down or right). `hidden` is for scripts.
pub fn canMove(l: *const List, i: u32, dx: f32, dy: f32) bool {
    const c = l.clips[i];
    const m = l.maxScroll(i);
    if (@abs(dy) >= @abs(dx)) return c.wheel_y and ((dy < 0 and c.scroll_y < m[1]) or (dy > 0 and c.scroll_y > 0));
    return c.wheel_x and ((dx < 0 and c.scroll_x < m[0]) or (dx > 0 and c.scroll_x > 0));
}
