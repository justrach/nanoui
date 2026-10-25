//! Tooltips as GPUI shows them (`.tooltip(...)`, `tooltip_show_delay`):
//! once the pointer has been over a box for the delay (500 ms unless it
//! says), a small panel at the pointer, 1 point right of and below it,
//! turned to the pointer's other side where it would leave the window. A
//! press anywhere hides it until the pointer moves again; leaving the box
//! hides it. One shows at a time, drawn over everything once the view is
//! built, so it doesn't move the boxes after it.
//!
//!     const b = ui.div(c).size(24, 24).center().tooltip("Sidebar view options", .{ .delay = 0.35 });
//!     defer b.end();
//!
//! Text comes in GPUI's `text_tooltip` box (colors and type from the app,
//! the theme's otherwise); `tooltipWith` draws the app's own content.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

pub const Options = struct {
    /// Seconds the pointer is over the box before it shows: GPUI's
    /// `DEFAULT_TOOLTIP_SHOW_DELAY`, or a box's `tooltip_show_delay`.
    delay: f32 = 0.5,
    /// The box (`text_tooltip`: `surface_raised`, a `border_strong` line);
    /// null: the theme's surface and border. Null `background` and
    /// `border` with `tooltipWith` leave the box to the content.
    background: ?types.Color = null,
    border: ?types.Color = null,
    /// GPUI's border takes room: the padding is inside it.
    border_width: f32 = 1,
    padding: types.Edges = .xy(8, 6),
    radius: f32 = 6,
    max_width: f32 = 280,
    /// Tailwind's `shadow-md`, as GPUI's `shadow_md`.
    shadows: []const types.Shadow = &types.Shadow.md,
    /// The text's size, color and line (`ui_rems(11)` in the theme's text).
    text: types.TextStyle = .{ .size = 11 },
    /// Over every page, menu and popover.
    layer: u8 = 200,
    /// The box takes the theme's colors when the app gives none.
    themed: bool = true,
};

/// What draws a tooltip's content (`tooltipWith`).
pub const Draw = struct {
    ptr: *const anyopaque,
    call: *const fn (ptr: *const anyopaque, c: *Context) void,
};

pub const Request = struct {
    text: []const u8 = "",
    draw: ?Draw = null,
    /// Where the pointer was when it showed.
    at: types.Point,
    opts: Options,
};

/// This frame's tooltip (`Context.tooltip`): asked for while the view is
/// built, drawn after it; and what was drawn, for tests.
pub const Frame = struct {
    request: ?Request = null,
    /// The text of the tooltip the last build drew ("" for drawn content)
    /// and its box's id; null when none showed.
    shown: ?struct { text: []const u8, id: u64 } = null,
};

/// What a box's tooltip remembers while the pointer is over it.
const State = struct {
    /// When the pointer came onto it, or moved after a press.
    since: f64 = 0,
    seen: u64 = 0,
    shown: bool = false,
    /// A press hid it: it waits for the pointer to move from `press_at`.
    dismissed: bool = false,
    at: types.Point = .{},
    press_at: types.Point = .{},
};

const key_name = "nanoui:tooltip";

/// Whether the pointer is over box `index` (as last laid out) with
/// nothing over it: the box needn't take the pointer itself, so a tooltip
/// on an icon inside a row leaves the row's clicks alone.
pub fn pointerOver(c: *Context, index: u32) bool {
    const n = c.node(index);
    const r = c.rects.get(n.id) orelse return false;
    if (!r.contains(c.input.mouse)) return false;
    if (c.hot == 0) return true;
    // The box that takes the pointer is this one or a box it is in…
    var at = index;
    while (at != ctx_mod.none) : (at = c.node(at).parent) if (c.node(at).id == c.hot) return true;
    // …or a box inside it (its button).
    const hr = c.rects.get(c.hot) orelse return false;
    return hr.x >= r.x and hr.y >= r.y and hr.x + hr.w <= r.x + r.w and hr.y + hr.h <= r.y + r.h;
}

/// Shows `text` over the box `index` once the pointer has rested on it.
pub fn tooltip(c: *Context, index: u32, text: []const u8, opts: Options) void {
    ask(c, index, .{ .text = text, .at = .{}, .opts = opts });
}

/// Shows what `draw_fn(ptr, c)` draws over box `index`, inside the
/// tooltip's box (style it, or give null colors for a bare one).
pub fn tooltipWith(c: *Context, index: u32, ptr: anytype, comptime draw_fn: fn (@TypeOf(ptr), *Context) void, opts: Options) void {
    const P = @TypeOf(ptr);
    const d: Draw = .{ .ptr = @ptrCast(ptr), .call = struct {
        fn call(p: *const anyopaque, cx: *Context) void {
            draw_fn(@as(P, @ptrCast(@alignCast(@constCast(p)))), cx);
        }
    }.call };
    ask(c, index, .{ .draw = d, .at = .{}, .opts = opts });
}

fn ask(c: *Context, index: u32, req_in: Request) void {
    const id = c.node(index).id;
    var h = std.hash.Wyhash.init(id);
    h.update(key_name);
    const k = h.final();
    if (!pointerOver(c, index)) {
        _ = c.memory.remove(k);
        return;
    }
    const gop = c.memory.getOrPut(c.gpa, k) catch return;
    const st: *State = @ptrCast(&gop.value_ptr.bytes);
    // New, or not drawn in the last frame: the wait starts now.
    if (!gop.found_existing or st.seen + 1 < c.frame) st.* = .{ .since = c.time };
    gop.value_ptr.frame = c.frame;
    st.seen = c.frame;
    if (c.input.pressed or c.input.secondary) {
        st.* = .{ .since = c.time, .seen = c.frame, .dismissed = true, .press_at = c.input.mouse };
    }
    if (st.dismissed) {
        const m = c.input.mouse;
        if (m.x == st.press_at.x and m.y == st.press_at.y) {
            // Every move, so the one off the press point re-arms it.
            c.wants_moves = true;
            return;
        }
        st.dismissed = false;
        st.since = c.time;
    }
    if (!st.shown) {
        const waited: f32 = @floatCast(c.time - st.since);
        if (waited + 1e-4 < req_in.opts.delay) {
            c.frameIn(req_in.opts.delay - waited);
            return;
        }
        st.shown = true;
        st.at = c.input.mouse;
    }
    var req = req_in;
    req.at = st.at;
    c.tooltip.request = req;
}

/// Where GPUI puts a tooltip of `size` for the pointer at `mouse`
/// (`Window::prepaint_tooltip`): 1 point right of and below it; turned to
/// its left (above it) where it would leave the window's right (bottom)
/// edge, and at the window's edge where it wouldn't fit there either.
pub fn place(mouse: types.Point, size: types.Size, window: types.Size) types.Point {
    var at: types.Point = .{ .x = mouse.x + 1, .y = mouse.y + 1 };
    if (at.x + size.w > window.w) {
        const x = mouse.x - size.w - 1;
        at.x = if (x >= 0) x else 0;
    }
    if (at.y + size.h > window.h) {
        const y = mouse.y - size.h - 1;
        at.y = if (y >= 0) y else 0;
    }
    return at;
}

/// Draws the tooltip asked for, over the page: called once the view is
/// built, with only the root open.
pub fn flush(c: *Context) void {
    const req = c.tooltip.request orelse {
        c.tooltip.shown = null;
        return;
    };
    c.tooltip.request = null;
    const o = req.opts;
    c.next_key = key_name;
    const id = c.peekId(null);
    var pad = o.padding;
    const bw = if (o.border != null or (o.themed and o.border_width > 0)) o.border_width else 0;
    pad.left += bw;
    pad.right += bw;
    pad.top += bw;
    pad.bottom += bw;
    var text_style = o.text;
    // Its size: from the text, or as last laid out (the first frame of
    // drawn content guesses, then is placed again in the next).
    var size: types.Size = .{};
    var width: ?f32 = null;
    if (req.draw == null) {
        const inner = o.max_width - pad.horizontal();
        const natural = @ceil(c.text.width(req.text, text_style));
        const lines: f32 = if (natural > inner) blk: {
            width = o.max_width;
            text_style.wrap = true;
            break :blk @floatFromInt(@max(1, c.text.wrapAttributed(req.text, text_style, &.{}, inner).len));
        } else 1;
        size = .{ .w = width orelse natural + pad.horizontal(), .h = c.text.lineHeight(text_style) * lines + pad.vertical() };
    } else if (c.rects.get(id)) |r| {
        size = .{ .w = r.w, .h = r.h };
    } else c.frameIn(0);
    const at = place(req.at, size, c.size);
    var st: types.Style = .{
        .absolute = true,
        .fixed = true,
        .offset = at,
        .layer = o.layer,
        .padding = pad,
        .radius = o.radius,
        .max_width = o.max_width,
        .shadows = o.shadows,
        .background = o.background orelse if (o.themed) c.theme.surface else null,
        .border = o.border orelse if (o.themed) c.theme.border else null,
        .border_width = bw,
    };
    if (width) |w| st.width = .{ .px = w };
    _ = c.open(st, null);
    if (req.draw) |d| d.call(d.ptr, c) else {
        const color = text_style.color orelse c.theme.text;
        _ = c.leaf(.{ .width = if (text_style.wrap) .fill else .auto }, .{ .text = .{ .str = req.text, .style = text_style, .color = color } }, null);
    }
    c.end();
    c.tooltip.shown = .{ .text = req.text, .id = id };
}

test "a tooltip goes by the pointer, kept in the window as GPUI keeps it" {
    const win: types.Size = .{ .w = 400, .h = 300 };
    try std.testing.expectEqual(types.Point{ .x = 101, .y = 51 }, place(.{ .x = 100, .y = 50 }, .{ .w = 80, .h = 30 }, win));
    // Past the right edge: left of the pointer.
    try std.testing.expectEqual(types.Point{ .x = 269, .y = 51 }, place(.{ .x = 350, .y = 50 }, .{ .w = 80, .h = 30 }, win));
    // Past the bottom: above it.
    try std.testing.expectEqual(types.Point{ .x = 101, .y = 259 }, place(.{ .x = 100, .y = 290 }, .{ .w = 80, .h = 30 }, win));
    // Wider than room on either side: at the window's left edge.
    try std.testing.expectEqual(@as(f32, 0), place(.{ .x = 100, .y = 50 }, .{ .w = 380, .h = 30 }, win).x);
}
