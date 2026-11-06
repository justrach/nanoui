//! A box's computed style: what the cascade (`cascade.zig`) gives layout and
//! paint. Every relative unit but percentages is resolved to CSS pixels.
const std = @import("std");
pub const fx = @import("effects.zig");
const svg_style = @import("svg_style.zig");

/// sRGB, gamma encoded: each part 0 to 1.
pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,
    pub const transparent: Color = .{ .a = 0 };
};

/// A length, a percentage or both (`calc(100% - 20px)`); `auto`, `none` and
/// the content keywords where those mean something.
pub const Len = struct {
    kind: Kind = .length,
    px: f32 = 0,
    /// Percent of the reference (50 for 50%).
    pct: f32 = 0,

    /// `min()`, `max()` and `clamp()` over percentages, decided when the reference
    /// is known. `px` and `pct` then hold what the viewport's width would decide,
    /// for readers with no reference.
    math: ?*const Math = null,

    /// `stretch`: fill the containing block, margins taken off. `fit_content` with
    /// `px` or `pct` set is the function: `fit-content(200px)`.
    pub const Kind = enum { length, auto, none, min_content, max_content, fit_content, stretch };
    pub const auto: Len = .{ .kind = .auto };
    pub const none: Len = .{ .kind = .none };
    pub const zero: Len = .{};

    pub fn of(px: f32) Len {
        return .{ .px = px };
    }

    pub fn isLength(l: Len) bool {
        return l.kind == .length;
    }

    /// Against `ref`; `ifAuto` for anything not a length.
    pub fn resolve(l: Len, ref: f32, if_auto: f32) f32 {
        return if (l.kind == .length) l.at(ref) else if_auto;
    }

    /// The value against a reference of `ref`.
    pub fn at(l: Len, ref: f32) f32 {
        if (l.math) |m| return m.at(ref);
        return l.px + l.pct * ref / 100;
    }

    /// Whether the value depends on its reference.
    pub fn hasPct(l: Len) bool {
        return l.pct != 0 or l.math != null;
    }
};

/// A comparison that a percentage keeps open until layout, or a sum or multiple
/// of one. `args` may hold more of the same.
pub const Math = struct {
    op: Op,
    args: []const Len,
    scale: f32 = 1,

    pub const Op = enum { min, max, add };

    pub fn at(m: *const Math, ref: f32) f32 {
        var v: f32 = if (m.args.len > 0) m.args[0].at(ref) else 0;
        if (m.args.len > 1) for (m.args[1..]) |x| {
            const o = x.at(ref);
            v = switch (m.op) {
                .min => @min(v, o),
                .max => @max(v, o),
                .add => v + o,
            };
        };
        return v * m.scale;
    }
};

pub const Display = enum {
    none,
    contents,
    block,
    inline_,
    inline_block,
    flex,
    inline_flex,
    grid,
    inline_grid,
    list_item,
    table,
    inline_table,
    table_caption,
    table_row_group,
    table_header_group,
    table_footer_group,
    table_row,
    table_cell,
    table_column,
    table_column_group,
};
pub const ContainerType = enum { normal, inline_size, size };
pub const Position = enum { static, relative, absolute, fixed, sticky };
pub const Float = enum { none, left, right };
pub const Clear = enum { none, left, right, both };
pub const BoxSizing = enum { content_box, border_box };
pub const Overflow = enum { visible, hidden, clip, scroll, auto };
pub const TextAlign = enum { start, end, left, right, center, justify };
pub const WhiteSpace = enum { normal, nowrap, pre, pre_wrap, pre_line };
pub const TextTransform = enum { none, uppercase, lowercase, capitalize };
pub const VerticalAlign = enum { baseline, top, middle, bottom, text_top, text_bottom, sub, super };
pub const ListStyle = enum { none, disc, circle, square, decimal, decimal_leading_zero, lower_alpha, upper_alpha, lower_roman, upper_roman, lower_greek };
pub const Visibility = enum { visible, hidden, collapse };
pub const BorderStyle = enum { none, hidden, solid, dashed, dotted, double, groove, ridge, inset, outset };
pub const Cursor = enum { auto, default, pointer, text, not_allowed, grab, col_resize, row_resize };
pub const FlexDirection = enum { row, row_reverse, column, column_reverse };
pub const FlexWrap = enum { nowrap, wrap, wrap_reverse };
pub const Justify = enum { normal, start, end, center, space_between, space_around, space_evenly, stretch };
pub const Align = enum { auto, normal, start, end, center, stretch, baseline, space_between, space_around, space_evenly };
pub const ObjectFit = enum { fill, contain, cover, none, scale_down };
pub const BackgroundSize = enum { auto, cover, contain };
pub const BackgroundRepeat = enum { repeat, no_repeat, repeat_x, repeat_y };
pub const BackgroundOrigin = enum { padding_box, border_box, content_box };

pub const Border = struct {
    width: f32 = 0,
    style: BorderStyle = .none,
    color: Color = .{},
};

pub const Shadow = struct {
    x: f32 = 0,
    y: f32 = 0,
    blur: f32 = 0,
    spread: f32 = 0,
    color: Color = .{ .a = 0 },
    inset: bool = false,
};

/// One stop of a gradient; positions are 0 to 1 of its line, plus `px` pixels
/// along it, evenly spread when not written (`known` false: with pixels about,
/// only the box can say where).
pub const GradientStop = struct { color: Color, at: f32, px: f32 = 0, known: bool = true };
pub const Gradient = struct {
    /// Degrees, CSS's: 180 runs top to bottom. A conic gradient's start.
    angle: f32 = 180,
    /// A corner named (`to top right`): the angle follows the box's shape.
    /// -1 or 1 along each axis; 0, 0 when an angle was written.
    to_x: i8 = 0,
    to_y: i8 = 0,
    stops: []const GradientStop = &.{},
    shape: GradientShape = .linear,
    repeating: bool = false,
    /// A stop's position has pixels in it, or isn't known until there's a box.
    has_px: bool = false,
    /// Radial and conic: the center, 0 to 1 across the box, plus pixels.
    cx: f32 = 0.5,
    cy: f32 = 0.5,
    cx_px: f32 = 0,
    cy_px: f32 = 0,
    /// Radial: its radii, where the last stop falls: fractions of the box's
    /// width and height (kept for what has no box at hand), or the
    /// lengths and extent below when one was written.
    rx: f32 = 0.7071,
    ry: f32 = 0.7071,
    circle: bool = false,
    extent: GradientExtent = .farthest_corner,
    size_x: ?Len = null,
    size_y: ?Len = null,
};
pub const GradientShape = enum { linear, radial, conic };
pub const GradientExtent = enum { closest_side, farthest_side, closest_corner, farthest_corner };

/// Which of a box's edges a background stops at. `text`: its glyphs, which
/// the cascade turns into colored text (nanoui has no text masks).
pub const BackgroundClip = enum { border_box, padding_box, content_box, text };

/// A background layer under the first: its own size and position come from the
/// `bg_*` lists of its style, by its place among the layers.
pub const BackgroundLayer = struct {
    url: []const u8 = "",
    gradient: ?Gradient = null,
    clip: BackgroundClip = .border_box,
};

/// What a `background-size` value says.
pub const BgSize = struct { kind: BackgroundSize = .auto, x: Len = .auto, y: Len = .auto };
/// What a `background-position` value says.
pub const BgPos = struct { x_pct: f32 = 0, x_px: f32 = 0, y_pct: f32 = 0, y_px: f32 = 0 };

/// A track of `grid-template-columns`/`rows`.
pub const Track = struct {
    kind: Kind = .auto,
    /// `fixed`: pixels and percent. `fr`: the share. `minmax`: the least
    /// (`px`, `pct`) with `fr` for the most, as a share, when it is one.
    px: f32 = 0,
    pct: f32 = 0,
    fr: f32 = 0,
    /// `minmax`: a fixed most when it is not a share (`minmax(1px, 200px)`);
    /// `max_px` is negative when there is none.
    max_px: f32 = -1,
    max_pct: f32 = 0,
    /// `minmax`: the least was `auto` or `min-content` rather than a length.
    min_auto: bool = false,
    /// `fixed`, `minmax`'s least, and `minmax`'s most when they are open comparisons.
    math: ?*const Math = null,
    max_math: ?*const Math = null,
    /// `fit-content(limit)`: as `auto`, its most capped at this (`px`, `pct`).
    fit: bool = false,
    pub const Kind = enum { auto, fixed, fr, minmax, min_content, max_content };
};

/// `repeat(auto-fill|auto-fit, track)`: the track fitted as many times as room allows.
pub const TrackList = struct {
    tracks: []const Track = &.{},
    /// Index in `tracks` of the repeated group when auto-repeated; -1 for none.
    auto_repeat: i16 = -1,
    /// How many tracks the auto-repeated group has.
    repeat_len: u16 = 1,
    /// `auto-fit`: repeated tracks with nothing in them collapse. `auto-fill` otherwise.
    auto_fit: bool = false,
    /// Lines named in brackets (`[content-start] 1fr [content-end]`).
    names: []const LineName = &.{},
    /// `subgrid`: the tracks are those of the grid around it, where it has one.
    subgrid: bool = false,
};

/// A named grid line, 1-based, counting an auto-repeat as one track.
pub const LineName = struct { name: []const u8, line: i16 };

/// A rectangle of `grid-template-areas`, in 1-based lines.
pub const GridArea = struct { name: []const u8, col0: i16, col1: i16, row0: i16, row1: i16 };

/// `grid-column`/`grid-row`: 1-based lines, 0 for auto, `span` for how many.
/// `start_name`, `end_name`: lines or areas named instead of numbered.
pub const GridPlace = struct { start: i16 = 0, end: i16 = 0, span: u16 = 1, start_name: []const u8 = "", end_name: []const u8 = "" };

/// `transform`'s functions: `effects.zig`.
pub const Transform = fx.Transform;

pub const SvgPaint = svg_style.SvgPaint;
pub const SvgCap = svg_style.SvgCap;
pub const SvgJoin = svg_style.SvgJoin;
pub const Svg = svg_style.Svg;

/// One step of `counter-reset`, `counter-increment` or `counter-set`.
pub const CounterOp = struct { name: []const u8, value: i32 };

/// A piece of `content`: text, or a counter's value when the box is made.
pub const ContentPart = union(enum) {
    text: []const u8,
    counter: Counter,

    pub const Counter = struct {
        name: []const u8,
        kind: ListStyle = .decimal,
        /// `counters(name, sep)`: every nested value, joined by this.
        sep: ?[]const u8 = null,
    };
};

pub const Style = struct {
    display: Display = .inline_,
    /// `display: flow-root`: `display` says `block` (or `inline_block`) and
    /// the box holds its floats.
    flow_root: bool = false,
    position: Position = .static,
    float: Float = .none,
    clear: Clear = .none,
    box_sizing: BoxSizing = .content_box,
    visibility: Visibility = .visible,
    opacity: f32 = 1,
    z_index: ?i32 = null,
    overflow_x: Overflow = .visible,
    overflow_y: Overflow = .visible,
    cursor: Cursor = .auto,
    pointer_events: bool = true,

    width: Len = .auto,
    height: Len = .auto,
    min_width: Len = .auto,
    min_height: Len = .auto,
    max_width: Len = .none,
    max_height: Len = .none,
    aspect_ratio: f32 = 0,
    /// `aspect-ratio: auto <ratio>`: a picture's own shape wins over it.
    aspect_auto: bool = false,
    /// `container-type`, and `container-name`'s names.
    container_type: ContainerType = .normal,
    container_names: []const []const u8 = &.{},
    /// `contain: size` and `inline-size`: what's inside doesn't size the box.
    contain_size: bool = false,
    contain_inline_size: bool = false,
    /// `contain: layout` or `paint`: a formatting context of its own.
    contain_flow: bool = false,
    margin_top: Len = .zero,
    margin_right: Len = .zero,
    margin_bottom: Len = .zero,
    margin_left: Len = .zero,
    padding_top: Len = .zero,
    padding_right: Len = .zero,
    padding_bottom: Len = .zero,
    padding_left: Len = .zero,
    top: Len = .auto,
    right: Len = .auto,
    bottom: Len = .auto,
    left: Len = .auto,

    border_top: Border = .{},
    border_right: Border = .{},
    border_bottom: Border = .{},
    border_left: Border = .{},
    /// One radius for each corner (top left, top right, bottom right, bottom
    /// left), in pixels; percentages in `radius_pct`, of the box's width.
    radius: [4]f32 = .{ 0, 0, 0, 0 },
    radius_pct: [4]f32 = .{ 0, 0, 0, 0 },
    /// The corners' vertical radii, after a `/` or as the second value of a
    /// corner's property: percentages of the box's height.
    radius_y: [4]f32 = .{ 0, 0, 0, 0 },
    radius_y_pct: [4]f32 = .{ 0, 0, 0, 0 },
    outline: Border = .{},
    outline_offset: f32 = 0,

    background: Color = .transparent,
    background_image: []const u8 = "",
    background_gradient: ?Gradient = null,
    /// The first layer's clip, and the layers under it, topmost first.
    background_clip: BackgroundClip = .border_box,
    background_more: []const BackgroundLayer = &.{},
    background_size: BackgroundSize = .auto,
    background_repeat: BackgroundRepeat = .repeat,
    /// As `background-position`'s percentages (0 to 100).
    background_x: f32 = 0,
    background_y: f32 = 0,
    /// `background-position`'s pixel part, added to the percentages' result.
    background_x_px: f32 = 0,
    background_y_px: f32 = 0,
    /// `background-size` given as lengths (`background_size` stays `auto`).
    background_size_x: Len = .auto,
    background_size_y: Len = .auto,
    background_origin: BackgroundOrigin = .padding_box,
    /// `background-attachment: fixed`.
    background_fixed: bool = false,
    /// Comma lists, when they have more than one value: each layer takes its
    /// own, by its place among the layers, repeating as CSS says. Empty: every
    /// layer has what the single fields above say.
    bg_sizes: []const BgSize = &.{},
    bg_positions: []const BgPos = &.{},
    bg_repeats: []const BackgroundRepeat = &.{},
    bg_clips: []const BackgroundClip = &.{},
    bg_origins: []const BackgroundOrigin = &.{},
    bg_fixed: []const bool = &.{},
    /// The first shadow that shows outside the box, and all of them, the
    /// topmost first, inset ones too.
    shadow: ?Shadow = null,
    shadows: []const Shadow = &.{},
    object_fit: ObjectFit = .fill,
    /// `object-position`, as `background_x` and the rest are: the default is
    /// the middle.
    object_x: f32 = 50,
    object_y: f32 = 50,
    object_x_px: f32 = 0,
    object_y_px: f32 = 0,
    svg: Svg = .{},
    transform: ?Transform = null,
    /// The `translate`, `rotate` and `scale` properties.
    translate_x: Len = .zero,
    translate_y: Len = .zero,
    rotate: f32 = 0,
    scale_x: f32 = 1,
    scale_y: f32 = 1,
    transform_origin_x: Len = .{ .pct = 50 },
    transform_origin_y: Len = .{ .pct = 50 },
    /// `clip` (absolute boxes only) and `clip-path`.
    clip_rect: ?fx.ClipRect = null,
    clip_path: ?fx.ClipPath = null,
    filters: []const fx.Filter = &.{},
    /// `backdrop-filter: blur()`'s radius, pixels; 0 for none.
    backdrop_blur: f32 = 0,
    /// `isolation: isolate`, a blend mode, `will-change` or `contain` that
    /// makes it a stacking context, whatever else it is.
    makes_context: bool = false,
    /// `appearance: none`: the author's CSS draws the control.
    appearance_none: bool = false,
    /// What `animation-*` and `transition-*` wrote, and what they come to
    /// (`properties_motion.zig`).
    anim_raw: ?*const @import("properties_motion.zig").AnimRaw = null,
    trans_raw: ?*const @import("properties_motion.zig").TransRaw = null,
    animations: []const fx.Animation = &.{},
    transitions: []const fx.Transition = &.{},

    // Inherited.
    color: Color = .{},
    /// `-webkit-text-fill-color`: what glyphs fill with, over `color`.
    text_fill: ?Color = null,
    /// `text-shadow`, the topmost first.
    text_shadows: []const Shadow = &.{},
    /// `accent-color`: a control's checked part.
    accent: ?Color = null,
    /// `::placeholder`'s color.
    placeholder: ?Color = null,
    font_size: f32 = 16,
    font_weight: u16 = 400,
    italic: bool = false,
    mono: bool = false,
    /// A serif family (Georgia, Times, `serif`); sans otherwise. `mono` wins.
    serif: bool = false,
    /// `font-family` was the bare generic `monospace`: the 13px default applies.
    mono_generic: bool = false,
    /// The size came from an absolute length, not a keyword or the default's
    /// proportion: changing to or from `monospace` then leaves it alone.
    font_size_abs: bool = false,
    /// The family list text draws from: comma separated, generics resolved
    /// (`font_family.zig`). What Chromium calls the standard font until set.
    font_family: []const u8 = @import("font_family.zig").standard,
    /// `font-stretch`, in percent.
    font_stretch: u16 = 100,
    /// `font-variant-numeric: tabular-nums`.
    tabular: bool = false,
    /// `normal` when 0; else the used line height, in pixels.
    line_height: f32 = 0,
    /// The multiplier when `line-height` was a number: children recompute
    /// `line_height` from it with their own font size. 0 otherwise.
    line_height_factor: f32 = 0,
    letter_spacing: f32 = 0,
    word_spacing: f32 = 0,
    text_align: TextAlign = .start,
    /// `text-align: -webkit-center` and its HTML forms. Already applied to block
    /// children as auto margins; layout need not look at it.
    center_children: bool = false,
    text_indent: Len = .zero,
    white_space: WhiteSpace = .normal,
    text_transform: TextTransform = .none,
    list_style: ListStyle = .disc,
    list_inside: bool = false,
    rtl: bool = false,
    inherited_visibility: Visibility = .visible,
    /// `border-collapse: collapse`.
    border_collapse: bool = false,
    /// `border-spacing`'s horizontal value, in pixels; `border_spacing_y` the
    /// vertical one (equal unless two values were written). The UA sheet gives tables 2.
    border_spacing: f32 = 0,
    border_spacing_y: f32 = 0,
    /// `word-break: break-all`.
    word_break_all: bool = false,
    /// `line-break: anywhere`.
    line_break_anywhere: bool = false,
    /// `overflow-wrap: anywhere|break-word`, `word-break: break-word`.
    overflow_wrap_anywhere: bool = false,
    /// `caption-side: bottom`.
    caption_bottom: bool = false,
    tab_size: f32 = 8,
    /// `color-scheme` asked for dark and the viewport is dark.
    dark_scheme: bool = false,
    // Not inherited, propagated over boxes in the inline flow.
    underline: bool = false,
    line_through: bool = false,
    overline: bool = false,
    text_decoration_color: ?Color = null,
    vertical_align: VerticalAlign = .baseline,
    text_overflow_ellipsis: bool = false,
    /// `table-layout: fixed`.
    table_fixed: bool = false,

    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .nowrap,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    flex_basis: Len = .auto,
    order: i32 = 0,
    justify_content: Justify = .normal,
    justify_items: Align = .normal,
    justify_self: Align = .auto,
    align_items: Align = .normal,
    align_self: Align = .auto,
    align_content: Align = .normal,
    row_gap: Len = .zero,
    /// `auto` is `normal`: nothing in flex and grid, 1em between columns.
    column_gap: Len = .auto,
    grid_template_columns: TrackList = .{},
    grid_template_rows: TrackList = .{},
    grid_auto_rows: Track = .{},
    grid_auto_columns: Track = .{},
    grid_column: GridPlace = .{},
    grid_row: GridPlace = .{},
    /// `grid-auto-flow: column`.
    grid_auto_flow_column: bool = false,
    /// `grid-auto-flow: dense`.
    grid_auto_flow_dense: bool = false,
    grid_areas: []const GridArea = &.{},
    /// `mask-image`: the box's background shows through this picture's shape.
    mask_image: []const u8 = "",

    /// `::before`/`::after`'s text: its `content` decoded.
    content: []const u8 = "",
    /// `content` holding counters: what to build the text from, `content` then unused.
    content_parts: []const ContentPart = &.{},
    counter_reset: []const CounterOp = &.{},
    counter_increment: []const CounterOp = &.{},
    counter_set: []const CounterOp = &.{},
    /// `list-style-type: "text"`.
    list_style_text: ?[]const u8 = null,
    /// `::marker { content: none }` and the like: no marker shows.
    marker_hidden: bool = false,
    /// `text-wrap: balance`.
    text_balance: bool = false,
    /// `column-count`, 0 for auto; `column-width`, 0 for auto.
    column_count: u16 = 0,
    column_width: f32 = 0,
    /// `column-span: all`.
    column_span_all: bool = false,
    /// `column-rule`: drawn by paint between the columns when it can.
    scroll_margin_top: f32 = 0,
    scroll_padding_top: f32 = 0,
    /// `overflow: hidden` here is the viewport's: people can't scroll the page.
    locks_viewport: bool = false,
    /// The root said `overflow` itself, so the body's stays the body's. Kept apart
    /// because the root's own values are made `visible` once the viewport has them.
    root_overflow: bool = false,
    /// In an `inert` subtree: takes no input and no focus.
    inert: bool = false,
    /// `content-visibility: hidden`.
    content_hidden: bool = false,
    /// `position: absolute` here was block-level before it was positioned: its
    /// static position is under the line it's in, not on it.
    was_block: bool = false,

    pub fn isFlex(s: *const Style) bool {
        return s.display == .flex or s.display == .inline_flex;
    }

    pub fn isGrid(s: *const Style) bool {
        return s.display == .grid or s.display == .inline_grid;
    }

    pub fn isInlineLevel(s: *const Style) bool {
        return switch (s.display) {
            .inline_, .inline_block, .inline_flex, .inline_grid, .inline_table => true,
            else => false,
        };
    }

    pub fn isOutOfFlow(s: *const Style) bool {
        return s.position == .absolute or s.position == .fixed;
    }

    /// Whether any transform applies; a containing block for what's in it.
    pub fn hasTransform(s: *const Style) bool {
        return s.transform != null or s.rotate != 0 or s.scale_x != 1 or s.scale_y != 1 or s.translate_x.px != 0 or s.translate_x.pct != 0 or s.translate_y.px != 0 or s.translate_y.pct != 0;
    }

    pub fn clips(s: *const Style) bool {
        return s.overflow_x != .visible or s.overflow_y != .visible;
    }

    pub fn scrolls(s: *const Style) bool {
        return s.overflow_y == .scroll or s.overflow_y == .auto;
    }
};
