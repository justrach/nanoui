//! Two panes that keep clear of a foldable's fold: side by side when the
//! fold runs top to bottom (book, or flat with `wide` set), one above the
//! other when it runs across (laptop), so no text lands in the band. The
//! band itself is left empty. Occlusions (a camera, the Duo's system strip
//! on the right of the flat inner screen) pad the panes they cover.
//!
//!     const p = ui.panes(c, .{});
//!     list(s, c); // the first pane
//!     if (p.second()) detail(s, c); // only when there are two
//!     p.end();
//!
//! Place it where it spans the window (a full-bleed window's root): the
//! fold is where it is on the screen, whatever the pane's parent. The
//! panes keep inside the safe area themselves (an inset on the right
//! belongs to the trailing pane, not to both), so what is in them sees
//! none left, and each pane clips what overflows it, out of the band.
const std = @import("std");
const types = @import("types.zig");
const Context = @import("context.zig").Context;
const device = @import("device.zig");
const div_mod = @import("div.zig");

pub const Options = struct {
    /// With no fold to follow: `.first` shows the first pane alone; `.wide`
    /// splits a wide screen (the Duo open flat, an iPad) side by side at
    /// `ratio`; `.always` splits at `ratio` on any screen.
    without_fold: enum { first, wide, always } = .wide,
    ratio: f32 = 0.5,
    /// Points between the panes when no fold sets the gap.
    gap: f32 = 0,
    /// Drawn in the band (null: nothing, the band shows the window's background).
    band: ?types.Color = null,
};

pub const Panes = struct {
    c: *Context,
    split: device.Split,
    /// Both panes are shown: call `second` for the trailing one.
    two: bool,
    stacked: bool,
    gap: f32,
    band: ?types.Color,
    /// The safe area outside, given back by `end`.
    safe_area: types.Edges,

    /// Closes the first pane and opens the second; false (nothing opened)
    /// when there is one pane.
    pub fn second(p: Panes) bool {
        if (!p.two) return false;
        p.c.end();
        const g = div_mod.div(p.c);
        if (p.stacked) _ = g.wFull().h(p.gap) else _ = g.hFull().w(p.gap);
        if (p.band) |b| _ = g.bg(b);
        g.end();
        const s = div_mod.div(p.c).column().grow().clip();
        if (p.stacked) _ = s.wFull() else _ = s.hFull();
        return true;
    }

    pub fn end(p: Panes) void {
        p.c.end(); // the open pane
        p.c.end(); // the container
        p.c.safe_area = p.safe_area;
    }
};

pub fn panes(c: *Context, opts: Options) Panes {
    const d = &c.device;
    var split = d.split();
    if (split == .none) switch (opts.without_fold) {
        .first => {},
        .wide => if (d.wide() or c.size.w >= 600) {
            split = .{ .side_by_side = .{ .leading = c.size.w * opts.ratio - opts.gap / 2, .gap = opts.gap } };
        },
        .always => split = .{ .side_by_side = .{ .leading = c.size.w * opts.ratio - opts.gap / 2, .gap = opts.gap } },
    };
    const box = div_mod.div(c).sizeFull();
    // Where it was last frame: the fold is in the window's points.
    const at = c.rects.get(box.id()) orelse types.Rect{ .w = c.size.w, .h = c.size.h };
    const occ = d.occlusion(at);
    const safe = c.safe_area;
    const pad: types.Edges = .{ .top = @max(occ.top, safe.top), .left = @max(occ.left, safe.left), .bottom = @max(occ.bottom, safe.bottom), .right = @max(occ.right, safe.right) };
    c.safe_area = .{};
    _ = box.pt(pad.top).pb(pad.bottom).pl(pad.left).pr(pad.right);
    var p: Panes = .{ .c = c, .split = split, .two = split != .none, .stacked = split == .stacked, .gap = 0, .band = opts.band, .safe_area = safe };
    switch (split) {
        .none => {
            _ = box.column();
            _ = div_mod.div(c).column().sizeFull().clip();
        },
        .side_by_side => |s| {
            _ = box.row();
            p.gap = s.gap;
            const lead = @max(0, s.leading - at.x - pad.left);
            _ = div_mod.div(c).column().hFull().w(lead).clip();
        },
        .stacked => |s| {
            _ = box.column();
            p.gap = s.gap;
            const top = @max(0, s.top - at.y - pad.top);
            _ = div_mod.div(c).column().wFull().h(top).clip();
        },
    }
    return p;
}
