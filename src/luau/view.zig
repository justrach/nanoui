//! Inert trees become native boxes; only native motion schedules frames.
const ui = @import("nanoui").ui;
const Node = @import("tree.zig").Node;

/// Draw under a host-owned box. Keys are scoped beneath that host, so two
/// instances of a script don't share animation state. The host owns input,
/// clipping and visibility. No script can create controls or capture events.
pub fn draw(c: *ui.Context, node: Node) void {
    ui.key(c, node.id);
    const frame = if (node.motion) |m| ui.motion.frame(c, .{
        .target = .{ .x = m.x, .y = m.y },
        .transition = if (m.spring)
            .{ .spring = .{ .stiffness = m.stiffness, .damping = m.damping } }
        else
            .{ .tween = .{ .duration = m.duration, .ease = .ease_out } },
    }) else ui.motion.Frame{};
    var box = ui.div(c).column().gap(node.gap).offset(node.x, node.y).opacity(node.opacity).rounded(node.radius);
    if (node.kind == .row) box = box.row();
    if (node.kind == .layer or node.kind == .rect) box = box.absolute();
    if (node.width > 0) box = box.w(node.width);
    if (node.height > 0) box = box.h(node.height);
    if (node.kind == .rect) box = box.bg(ui.Color.hex(node.color));
    box = box.motion(frame);
    defer box.end();
    if (node.kind == .text) ui.text(c, node.text, .{ .size = node.size, .color = ui.Color.hex(node.color) });
    for (node.children) |child| draw(c, child);
}
