//! One frame of native UI, shared by windows (`Surface`) and the headless
//! `Tester`: build the view (again while interactions change state), lay
//! it out, paint it into instances, and update what the pointer is over.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const text = @import("text.zig");
const layout = @import("layout.zig");
const paint = @import("paint.zig");
const selection = @import("selection.zig");
const tooltip = @import("tooltip.zig");
const Theme = @import("theme.zig").Theme;
const Context = @import("context.zig").Context;
const View = @import("ui.zig").View;
const now = @import("clock.zig").now;

pub const Result = struct {
    /// The box under a still pointer changed: another frame should follow.
    hot_changed: bool,
};

pub fn run(c: *Context, view: View, ts: *text.TextSystem, instances: *std.ArrayList(gpu.Instance), size: types.Size, scale: f32, theme: Theme, dt: f32, time: f64) Result {
    c.dt = dt;
    c.time = time;
    c.size = size;
    c.scale = scale;
    c.theme = theme;
    c.animating = false;
    c.frame_in = null;
    ts.setFamilies(theme.font, theme.mono_font);
    ts.beginFrame();

    const t0 = now();
    if (c.input.pressed) c.selection.pressed = true;
    c.copy_done = false;
    c.copy_requested = false;
    for (c.input.ops) |op| if (op == .command and op.command == .copy) {
        c.copy_requested = true;
    };
    c.noteModality();
    c.begin();
    var passes: u32 = 0;
    while (true) : (passes += 1) {
        view.build(view.ptr, c);
        if (c.stack.items.len == 1) tooltip.flush(c);
        if (c.stack.items.len != 1)
            std.debug.panic("nanoui: {d} box(es) left open: every column, row, card, scroll and pressable needs an end", .{c.stack.items.len - 1});
        if (!c.changed or passes >= 3) break;
        c.rebuild();
    }

    // Copy with no field's selection to take: the page's selection.
    if (c.copy_requested and !c.copy_done and c.selection.text.items.len > 0) c.clipboard.write(c.clipboard.ctx, c.selection.text.items);

    const t1 = now();
    c.scroll_moved.clearRetainingCapacity();
    _ = layout.measure(c, 0, size.w);
    layout.arrange(c, 0, .{ .w = size.w, .h = size.h });
    if (c.pixel_snap) layout.snapToPixels(c);
    c.rects.clearRetainingCapacity();
    for (c.nodes.items) |n| c.rects.put(c.gpa, n.id, n.rect) catch {};

    const t2 = now();
    ts.images.reset_during_frame = false;
    selection.beginPaint(c);
    paint.paint(c, instances);
    if (ts.atlas.reset_during_frame or ts.images.reset_during_frame) {
        // An atlas filled up and was reset: earlier sprites are stale.
        c.next_hits.clearRetainingCapacity();
        selection.beginPaint(c);
        paint.paint(c, instances);
    }
    selection.afterPaint(c);
    const t3 = now();
    c.stats = .{
        .build_ms = (t1 - t0) * 1000,
        .layout_ms = (t2 - t1) * 1000,
        .paint_ms = (t3 - t2) * 1000,
        .passes = passes + 1,
        .nodes = c.nodes.items.len,
        .instances = instances.items.len,
    };
    const hot_before = c.hot;
    c.commitHits();
    c.finish();
    return .{ .hot_changed = c.hot != hot_before };
}
