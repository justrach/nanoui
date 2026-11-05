//! `Style.transform`: a subtree's instances moved after they are made, which
//! keeps layout, painting and culling unaware of it. The renderers apply the
//! transform (`Instance.m`, `mt`) to each instance's outline; each clip stays a
//! rectangle of the window, the smallest one holding what it clipped.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const ctx_mod = @import("context.zig");

const Affine = types.Affine;

/// The rectangle a subtree is worked out in, whatever of `clip` it may reach.
pub fn clipBefore(m: Affine, clip: types.Rect) ?types.Rect {
    const inv = m.inverse() orelse return null;
    return inv.bounds(clip);
}

/// Moves what a transformed box and its subtree made: its instances, within
/// `outer`, the clip the box was given, and where the pointer finds them.
pub fn apply(items: []gpu.Instance, hits: []ctx_mod.Hit, m: Affine, outer: types.Rect) void {
    const uniform = @sqrt(@abs(m.a * m.d - m.b * m.c));
    const straight = m.b == 0 and m.c == 0;
    for (items) |*i| {
        // Glass reads the frame where it is, so it goes as its own bounds.
        if (i.kind == gpu.Kind.glass) {
            const b = m.bounds(.{ .x = i.rect[0], .y = i.rect[1], .w = i.rect[2], .h = i.rect[3] });
            i.rect = .{ b.x, b.y, b.w, b.h };
            i.radius *= uniform;
        } else {
            const n: Affine = .{ .a = i.m[0], .b = i.m[1], .c = i.m[2], .d = i.m[3], .e = i.mt[0], .f = i.mt[1] };
            const t = m.times(n);
            i.m = .{ t.a, t.b, t.c, t.d };
            i.mt = .{ t.e, t.f, 0, 0 };
        }
        const was: types.Rect = .{ .x = i.clip[0], .y = i.clip[1], .w = i.clip[2] - i.clip[0], .h = i.clip[3] - i.clip[1] };
        i.clip = gpu.clip4(m.bounds(was).intersect(outer));
        const round = gpu.clipCorners(i.clip_round);
        if (round.corners != 0) i.clip_round = if (straight) gpu.clipRound(round.radius * uniform, round.corners) else 0;
    }
    for (hits) |*h| h.rect = m.bounds(h.rect).intersect(outer);
}
