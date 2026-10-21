//! Shared-element transitions, as Motion's `layoutId` and gpui-motion's
//! `SharedLayout`: boxes that share a key glide from where the last one
//! was drawn to where this one is laid out, even under another parent.
const motion = @import("motion.zig");
const Context = @import("../context.zig").Context;
const std = @import("std");

/// Presence plus a parent-independent layout id: the next box (keyed
/// `key`) while `show`, entering from `m.initial`; when it next appears
/// elsewhere it starts where it was. Draw it only when this returns a frame.
pub fn share(c: *Context, key: []const u8, show: bool, m: motion.Motion) ?motion.Frame {
    var mm = m;
    mm.layout = true;
    const f = motion.present(c, key, show, mm) orelse return null;
    var out = f;
    out.layout = idOf(key);
    const tr = if (c.reduced_motion) @as(@import("channel.zig").Transition, .instant) else m.transition;
    if (c.motion.get(c.gpa, out.layout, c.frame)) |got| {
        got.state.layout_transition = tr;
    }
    return out;
}

/// The layout id boxes of `key` share (paint's `layout_motion`).
pub fn idOf(key: []const u8) u64 {
    var h = std.hash.Wyhash.init(0x7368617265);
    h.update(key);
    return h.final();
}

test "share keys hash the same wherever they sit" {
    try std.testing.expectEqual(idOf("chip"), idOf("chip"));
    try std.testing.expect(idOf("chip") != idOf("other"));
}
