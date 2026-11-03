//! The screen a window is on, beyond its size: a foldable's posture and
//! hinge, the bands and cut-outs UIKit reserves (a fold, a camera, a
//! system strip), size classes and orientation. Filled by the platform
//! before each frame (iOS 27.1's `-[UIView reservedRegionsOfKind:]` and
//! `UIHingeInteraction`); elsewhere it stays `.none` with no regions, so a
//! view written for a foldable runs as it would on a phone or a desktop.
//!
//!     switch (c.device.posture()) {
//!         .book, .flat => twoPanes(s, c),
//!         else => onePane(s, c),
//!     }
const std = @import("std");
const types = @import("types.zig");
const Rect = types.Rect;
const Edges = types.Edges;

/// How a foldable is held, as the app sees it.
pub const Posture = enum {
    /// Not a foldable, or nothing is known (desktops, phones, iOS before 27.1).
    none,
    /// Closed: the app is on the outer display.
    folded,
    /// Open flat: one big screen, no band to avoid.
    flat,
    /// Half open with the fold running top to bottom, held like a book.
    book,
    /// Half open with the fold running across, the bottom half on a table.
    laptop,
};

/// `UIHingeStatus`.
pub const HingeStatus = enum(u8) { unknown = 0, closed = 1, partially_open = 2, fully_open = 3 };

/// UIKit's size classes (`UIUserInterfaceSizeClass`).
pub const SizeClass = enum { unspecified, compact, regular };

pub const Orientation = enum { portrait, landscape };

/// A part of the screen the system keeps: `.division` splits the screen
/// (a fold's band), `.occlusion` covers it (a camera, a system strip).
pub const Region = struct {
    kind: enum { division, occlusion },
    /// In the window's points.
    rect: Rect,
    /// Room UIKit asks to leave around it.
    margins: Edges = .{},
    active: bool = true,
};

/// Where a split puts its panes, in the window's points.
pub const Split = union(enum) {
    /// One screen, nothing to avoid.
    none,
    /// The fold runs top to bottom: a leading pane `leading` wide, a band
    /// `gap` wide, then the trailing pane.
    side_by_side: struct { leading: f32, gap: f32 },
    /// The fold runs across: a top pane `top` high, a band, the bottom pane.
    stacked: struct { top: f32, gap: f32 },
};

pub const max_regions = 8;

pub const Device = struct {
    hinge: HingeStatus = .unknown,
    /// Degrees, 0 closed to 180 flat, when the hinge reports it.
    hinge_angle: ?f32 = null,
    /// The platform has the fold APIs and a hinge to report.
    foldable: bool = false,
    horizontal: SizeClass = .unspecified,
    vertical: SizeClass = .unspecified,
    orientation: Orientation = .portrait,
    /// The window's size in points, as the regions were read.
    size: types.Size = .{},
    regions: [max_regions]Region = undefined,
    region_count: usize = 0,
    /// The rotation hook: true for the frame after the orientation flipped.
    rotated: bool = false,
    /// True for the frame after the posture changed (fold, unfold, tilt).
    posture_changed: bool = false,
    last_posture: Posture = .none,

    pub fn list(d: *const Device) []const Region {
        return d.regions[0..d.region_count];
    }

    /// The fold's band now, if one divides the screen.
    pub fn fold(d: *const Device) ?Rect {
        for (d.list()) |r| if (r.kind == .division and r.active and r.rect.w > 0 and r.rect.h > 0) return r.rect;
        return null;
    }

    pub fn posture(d: *const Device) Posture {
        return classify(d.foldable, d.hinge, d.size, d.fold());
    }

    pub fn split(d: *const Device) Split {
        return splitOf(d.fold());
    }

    /// What occlusions (a camera, a system strip) cover of `rect`, as
    /// insets from the edge each is nearest.
    pub fn occlusion(d: *const Device, rect: Rect) Edges {
        return occlusionInsets(d.list(), rect);
    }

    /// The window is wide enough for two columns (`regular` width).
    pub fn wide(d: *const Device) bool {
        return if (d.horizontal == .unspecified) d.size.w >= 600 else d.horizontal == .regular;
    }

    /// How far the app recedes as the hinge closes, 0 (open) to 1: none
    /// above 110 degrees, all of it by 20, eased (smoothstep). After the
    /// Duo harness's recede: scale by `1 - 0.06 * r`, dim by `0.4 * r`.
    pub fn recede(d: *const Device) f32 {
        const a = d.hinge_angle orelse return 0;
        if (!d.wide()) return 0;
        return recedeAt(a);
    }

    /// Records what the platform read: sets `rotated` and `posture_changed`.
    pub fn settle(d: *Device, previous: Orientation) void {
        d.rotated = d.orientation != previous;
        const p = d.posture();
        d.posture_changed = p != d.last_posture;
        d.last_posture = p;
    }
};

/// The posture from what the platform knows. A band taller than wide is
/// a book's fold; wider than tall, a laptop's. No band: flat when the
/// screen is wide (the inner display), folded when it is narrow (the outer).
pub fn classify(foldable: bool, hinge: HingeStatus, size: types.Size, band: ?Rect) Posture {
    if (band) |b| return if (b.h > b.w) .book else .laptop;
    if (!foldable) return .none;
    if (hinge == .closed) return .folded;
    return if (@min(size.w, size.h) >= 600) .flat else .folded;
}

pub fn splitOf(band: ?Rect) Split {
    const b = band orelse return .none;
    if (b.h > b.w) return .{ .side_by_side = .{ .leading = b.x, .gap = b.w } };
    return .{ .stacked = .{ .top = b.y, .gap = b.h } };
}

pub fn occlusionInsets(regions: []const Region, rect: Rect) Edges {
    var e: Edges = .{};
    for (regions) |r| {
        if (r.kind != .occlusion or !r.active) continue;
        const o = r.rect;
        const x0 = @max(o.x, rect.x);
        const y0 = @max(o.y, rect.y);
        const x1 = @min(o.x + o.w, rect.x + rect.w);
        const y1 = @min(o.y + o.h, rect.y + rect.h);
        if (x1 <= x0 or y1 <= y0) continue;
        // The edge it is nearest: its distance from each of rect's edges.
        const left = x1 - rect.x;
        const right = rect.x + rect.w - x0;
        const top = y1 - rect.y;
        const bottom = rect.y + rect.h - y0;
        const m = @min(@min(left, right), @min(top, bottom));
        if (m == left) e.left = @max(e.left, left + r.margins.right) else if (m == right) e.right = @max(e.right, right + r.margins.left) else if (m == top) e.top = @max(e.top, top + r.margins.bottom) else e.bottom = @max(e.bottom, bottom + r.margins.top);
    }
    return e;
}

pub fn recedeAt(angle: f32) f32 {
    const t = std.math.clamp((110 - angle) / 90, 0, 1);
    return t * t * (3 - 2 * t);
}

test "classify: the Duo's postures from its real geometry" {
    // Outer display 466x678, closed.
    try std.testing.expectEqual(Posture.folded, classify(true, .closed, .{ .w = 466, .h = 678 }, null));
    // Inner 951x669 open flat: no band.
    try std.testing.expectEqual(Posture.flat, classify(true, .fully_open, .{ .w = 951, .h = 669 }, null));
    // Book: a 40 pt band at x 455.7.
    const book: Rect = .{ .x = 455.7, .y = 0, .w = 40, .h = 669 };
    try std.testing.expectEqual(Posture.book, classify(true, .partially_open, .{ .w = 951, .h = 669 }, book));
    // Laptop: rotated, the band runs across.
    const lap: Rect = .{ .x = 0, .y = 455.7, .w = 669, .h = 40 };
    try std.testing.expectEqual(Posture.laptop, classify(true, .partially_open, .{ .w = 669, .h = 951 }, lap));
    // Not a foldable.
    try std.testing.expectEqual(Posture.none, classify(false, .unknown, .{ .w = 393, .h = 852 }, null));
}

test "splitOf and occlusion insets" {
    const s = splitOf(.{ .x = 455.7, .y = 0, .w = 40, .h = 669 });
    try std.testing.expectApproxEqAbs(@as(f32, 455.7), s.side_by_side.leading, 0.01);
    try std.testing.expectEqual(@as(f32, 40), s.side_by_side.gap);
    const t = splitOf(.{ .x = 0, .y = 455.7, .w = 669, .h = 40 });
    try std.testing.expectEqual(@as(f32, 40), t.stacked.gap);
    try std.testing.expect(splitOf(null) == .none);
    // A strip on the right edge pads the right.
    const strip = [_]Region{.{ .kind = .occlusion, .rect = .{ .x = 881, .y = 0, .w = 70, .h = 669 } }};
    const e = occlusionInsets(&strip, .{ .x = 0, .y = 0, .w = 951, .h = 669 });
    try std.testing.expectEqual(@as(f32, 70), e.right);
    try std.testing.expectEqual(@as(f32, 0), e.left);
    // A pane left of it is not covered.
    try std.testing.expectEqual(@as(f32, 0), occlusionInsets(&strip, .{ .x = 0, .y = 0, .w = 455, .h = 669 }).right);
}

test "recede eases from 110 to 20 degrees" {
    try std.testing.expectEqual(@as(f32, 0), recedeAt(150));
    try std.testing.expectEqual(@as(f32, 1), recedeAt(10));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), recedeAt(65), 0.001);
}
