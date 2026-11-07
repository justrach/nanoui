//! SVG's computed properties, part of a computed `Style`.
const Color = @import("style.zig").Color;

/// What an SVG shape is painted with. `current` follows the element's `color`
/// where it's used, not where it was written.
pub const SvgPaint = struct {
    kind: Kind = .none,
    color: Color = .{},
    /// `url(#id)`'s id.
    url: []const u8 = "",
    /// The color after a `url()`, when it names nothing usable (`url(#a) red`).
    url_fallback: ?Color = null,
    pub const Kind = enum { none, current, color, url };
};

pub const SvgCap = enum { butt, round, square };
pub const SvgJoin = enum { miter, round, bevel };

/// SVG's properties, on every element: a `fill` on a page's body reaches the
/// icons inside it. The first group inherits.
pub const Svg = struct {
    fill: SvgPaint = .{ .kind = .color },
    stroke: SvgPaint = .{},
    stroke_width: f32 = 1,
    fill_opacity: f32 = 1,
    stroke_opacity: f32 = 1,
    fill_evenodd: bool = false,
    clip_evenodd: bool = false,
    cap: SvgCap = .butt,
    join: SvgJoin = .miter,
    miter_limit: f32 = 4,
    dash: []const f32 = &.{},
    dash_offset: f32 = 0,
    stroke_first: bool = false,
    // Not inherited.
    stop_color: SvgPaint = .{ .kind = .color },
    stop_opacity: f32 = 1,
    /// The ids of `clip-path: url(#a)` and `mask: url(#a)`.
    clip_path: []const u8 = "",
    mask: []const u8 = "",
    /// `transform` as written, for the rasterizer to read.
    transform: []const u8 = "",
    non_scaling_stroke: bool = false,

    /// What a child starts from.
    pub fn inherited(s: Svg) Svg {
        var out = s;
        out.stop_color = .{ .kind = .color };
        out.stop_opacity = 1;
        out.clip_path = "";
        out.mask = "";
        out.transform = "";
        out.non_scaling_stroke = false;
        return out;
    }
};
