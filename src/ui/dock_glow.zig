//! The dock's divider light (`dock_view.Style.glow`): a hairline the
//! gutter's whole length, brightest where the pointer is (a Gaussian, with
//! a floor) and with a small bloom there, fading in and out.
const std = @import("std");
const types = @import("types.zig");
const dl = @import("dock_layout.zig");
const Context = @import("context.zig").Context;
const view = @import("dock_view.zig");
const Rect = types.Rect;

fn abs(r: Rect) types.Style {
    return .{ .absolute = true, .offset = .{ .x = r.x, .y = r.y }, .width = .{ .px = r.w }, .height = .{ .px = r.h } };
}

/// Moves the glow toward lit (a divider is `hot`) or out, and follows the
/// pointer along it. Kept whether nanoui or the app draws it.
pub fn update(c: *Context, st: *view.State, style: view.Style, hot: ?dl.DividerItem) void {
    if (hot) |d| {
        st.glow_divider = d;
        st.glow_along = if (d.axis == .row) c.input.mouse.y - st.origin.y else c.input.mouse.x - st.origin.x;
    }
    // Hovering a divider wants a frame per move, so the light follows.
    if (hot != null) c.wants_moves = true;
    const target: f32 = if (hot != null) 1 else 0;
    if (st.glow == target) return;
    if (style.glow_fade <= 0) {
        st.glow = target;
        return;
    }
    const step = @min(c.dt, 0.05) / style.glow_fade;
    st.glow = if (st.glow < target) @min(target, st.glow + step) else @max(target, st.glow - step);
    c.animationFrame();
}

pub fn draw(c: *Context, st: *view.State, style: view.Style, l: *const dl.Layout) void {
    const color = style.glow orelse return;
    if (st.glow <= 0) return;
    const was = st.glow_divider orelse return;
    // The divider as laid out this frame: a drag moves it.
    const d = for (l.dividers[0..l.divider_count]) |x| {
        if (x.split == was.split and x.index == was.index) break x;
    } else return;
    // Eased, so the light swells and settles rather than ramping.
    const k = st.glow * st.glow * (3 - 2 * st.glow);
    const vertical = d.axis == .row;
    const span_lo = if (vertical) d.rect.y else d.rect.x;
    const span = if (vertical) d.rect.h else d.rect.w;
    const mid = if (vertical) d.rect.x + d.rect.w / 2 else d.rect.y + d.rect.h / 2;
    // A hairline the gutter's whole length, lit most at the pointer and
    // fading along it (a Gaussian, drawn as short segments), with a small
    // bloom where the pointer is.
    const seg: f32 = 3;
    const width: f32 = 1.5;
    const sigma = @max(style.glow_length / 2, 1);
    const count: usize = @intFromFloat(@ceil(span / seg));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const at = span_lo + @as(f32, @floatFromInt(i)) * seg;
        const len = @min(seg, span_lo + span - at);
        const dist = (at + len / 2 - st.glow_along) / sigma;
        const a = style.glow_floor + (1 - style.glow_floor) * @exp(-dist * dist);
        const r: Rect = if (vertical)
            .{ .x = mid - width / 2, .y = at, .w = width, .h = len }
        else
            .{ .x = at, .y = mid - width / 2, .w = len, .h = width };
        var sty = abs(r);
        sty.layer = 1;
        sty.background = color.alpha(a * k);
        _ = c.open(sty, c.print("dock-glow{d}", .{i}));
        c.end();
    }
    const bloom: f32 = @min(style.glow_length * 0.35, span);
    const lo = std.math.clamp(st.glow_along - bloom / 2, span_lo, span_lo + span - bloom);
    const br: Rect = if (vertical)
        .{ .x = mid - 1, .y = lo, .w = 2, .h = bloom }
    else
        .{ .x = lo, .y = mid - 1, .w = bloom, .h = 2 };
    var bs = abs(br);
    bs.layer = 1;
    bs.radius = 1;
    bs.shadow = .{ .color = color.alpha(0.55 * k), .blur = 10, .y = 0 };
    _ = c.open(bs, "dock-glow-bloom");
    c.end();
}
