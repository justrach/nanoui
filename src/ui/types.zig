//! Geometry, colors and styles of native UI. Units are points.
const std = @import("std");

/// The side of a turned plane a box is on (`Style.face`).
pub const Face = enum(u2) { both = 0, front = 1, back = 2 };

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Size = struct {
    w: f32 = 0,
    h: f32 = 0,
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(r: Rect, p: Point) bool {
        return p.x >= r.x and p.y >= r.y and p.x < r.x + r.w and p.y < r.y + r.h;
    }

    pub fn inset(r: Rect, e: Edges) Rect {
        return .{ .x = r.x + e.left, .y = r.y + e.top, .w = @max(0, r.w - e.left - e.right), .h = @max(0, r.h - e.top - e.bottom) };
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }

    pub const infinite: Rect = .{ .x = -1e6, .y = -1e6, .w = 2e6, .h = 2e6 };
};

pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    /// `0xRRGGBB` or, with `alpha`, any opacity.
    pub fn hex(v: u24) Color {
        return .{
            .r = @as(f32, @floatFromInt((v >> 16) & 0xff)) / 255,
            .g = @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255,
            .b = @as(f32, @floatFromInt(v & 0xff)) / 255,
        };
    }

    pub fn alpha(c: Color, a: f32) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a * a };
    }

    pub fn mix(a: Color, b: Color, t: f32) Color {
        return .{
            .r = a.r + (b.r - a.r) * t,
            .g = a.g + (b.g - a.g) * t,
            .b = a.b + (b.b - a.b) * t,
            .a = a.a + (b.a - a.a) * t,
        };
    }

    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };
    pub const black: Color = .{};
    pub const transparent: Color = .{ .a = 0 };
};

pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn all(v: f32) Edges {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    pub fn xy(x: f32, y: f32) Edges {
        return .{ .top = y, .right = x, .bottom = y, .left = x };
    }

    pub fn horizontal(e: Edges) f32 {
        return e.left + e.right;
    }

    pub fn vertical(e: Edges) f32 {
        return e.top + e.bottom;
    }
};

/// The length of a box along one axis.
pub const Length = union(enum) {
    /// As large as its content.
    auto,
    /// Exactly this many points.
    px: f32,
    /// All the room its parent gives it.
    fill,
};

pub const Direction = enum { row, column };
pub const Align = enum { start, center, end, stretch };
pub const Justify = enum { start, center, end, space_between };
pub const Weight = enum { regular, medium, semibold, bold };

pub const Shadow = struct {
    color: Color = .{ .a = 0.18 },
    blur: f32 = 12,
    x: f32 = 0,
    y: f32 = 4,
    /// Drawn outside the box only (`Kind.shadow_out`): a box that shows
    /// what is under it (a page through a stage hole) keeps its shadow.
    knockout: bool = false,
    /// Grows the shadow's box on every side before it's blurred; less than
    /// 0 shrinks it, as CSS's spread radius does.
    spread: f32 = 0,

    /// Tailwind's `shadow-lg`, as GPUI draws it: two faint layers.
    pub const lg = [_]Shadow{
        .{ .color = .{ .a = 0.1 }, .blur = 15, .y = 10, .spread = -3 },
        .{ .color = .{ .a = 0.1 }, .blur = 6, .y = 4, .spread = -4 },
    };
};

/// The style of a box, in the manner of CSS flexbox.
/// Liquid Glass, the material of macOS 26 and later (`glass.zig`): what
/// was painted under the box shows through it, frosted, bent near its
/// edges as through a lens's rim, and lit along its hairline rim.
pub const Glass = struct {
    style: Kind = .regular,
    /// Colors the glass toward this, by its alpha: a prominent button's.
    tint: Color = .transparent,

    pub const Kind = enum {
        /// Frosts and lightens (darkens, in dark mode) what shows through,
        /// so what is on it reads over anything: bars, buttons, panels.
        regular,
        /// Barely frosts or tones it: glass over photos and video.
        clear,
    };
};

pub const Pulse = struct { period: f32, scale_amp: f32, alpha_low: f32 };

/// How a scrolling box shows its bar.
pub const Scrollbar = union(enum) {
    /// While the content is taller than the box.
    always,
    /// macOS's overlay bar, in this colour: shown while the box scrolls,
    /// for 1.4 s after, then faded out over 0.26 s; held while the pointer
    /// is on its 10-point strip, where it widens from 3 to 5 points.
    overlay: Color,
};

pub const Style = struct {
    direction: Direction = .column,
    gap: f32 = 0,
    padding: Edges = .{},
    width: Length = .auto,
    height: Length = .auto,
    min_width: f32 = 0,
    min_height: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    /// At most this tall: a scrolling box is as tall as its content up to
    /// here, then scrolls (a chat's answer, a popover's list).
    max_height: f32 = std.math.inf(f32),
    /// Share of the free room along the parent's main axis.
    grow: f32 = 0,
    align_items: Align = .start,
    justify: Justify = .start,
    background: ?Color = null,
    border: ?Color = null,
    border_width: f32 = 1,
    /// Dashed: dashes twice the border's width, gaps once it, spaced evenly
    /// round the whole box (GPUI's `border_dashed`).
    border_dashed: bool = false,
    radius: f32 = 0,
    /// Circular corners instead of Apple's continuous corners.
    corner_circular: bool = false,
    shadow: ?Shadow = null,
    /// More shadows under the box, after `shadow`: layered ones.
    shadows: []const Shadow = &.{},
    /// Filled with Liquid Glass instead of a background.
    glass: ?Glass = null,
    /// Children are clipped to the box and scroll vertically.
    scroll: bool = false,
    /// A scrolling box's bar: always there while there's more to see, or
    /// an overlay that shows while it scrolls and fades away after.
    scrollbar: Scrollbar = .always,
    /// Overall opacity of the box and its content.
    opacity: f32 = 1,
    /// Moves the box after layout, without moving its siblings.
    offset: Point = .{},
    /// Glides when the layout moves it (`ui.motion`'s `layout`): its id.
    layout_motion: u64 = 0,
    /// Out of the flow: placed at its parent's content origin (plus
    /// `offset`), at its own size, over or under its siblings.
    absolute: bool = false,
    /// With `absolute`: placed from the window's top left (plus `offset`),
    /// not its parent's, unmoved by scrolling; `.fill` is the window's size.
    fixed: bool = false,
    /// Drawn above every box of a lower layer, wherever it is in the tree,
    /// and not clipped by its parents: menus, popovers, dialogs, tooltips.
    /// Its clicks come first too. 0 is the page.
    layer: u8 = 0,
    /// Children are clipped to the box.
    clip: bool = false,
    /// A scrolling box that stays at its end as its content grows, while
    /// it was at its end: logs, chats, terminals.
    follow_end: bool = false,
    /// Its texts (and its children's) can be selected with the pointer and
    /// copied, as a terminal's or a page's (`selection.zig`).
    selectable: bool = false,
    /// A single press on it moves the window, as a title bar's does (a
    /// tab strip's empty space); a double click still comes to the box.
    window_drag: bool = false,
    /// A control (a button, a toggle): its texts do not select, even in a
    /// selectable box, so the pointer is a hand all over it.
    control: bool = false,
    /// The box and everything in it drawn scaled by this around
    /// `scale_anchor` (fractions of its rect), after layout: an item
    /// entering or leaving.
    scale: f32 = 1,
    scale_anchor: Point = .{ .x = 0.5, .y = 0.5 },
    /// Children are laid out at their own widths, clipped to the box, and
    /// scroll horizontally (the wheel's x, or `Context.setScroll`).
    scroll_x: bool = false,
    /// A scrolling box shows its scroll indicator.
    scroll_bar: bool = true,
    /// The indicator shows only while the box scrolls and a moment after,
    /// as macOS's overlay scrollers.
    scroll_bar_fades: bool = false,
    /// A box whose place down its parent changes from one layout to the
    /// next (a row above it gone) springs from where it was shown to where
    /// it is, as SwiftUI animates a stack's rows; its ancestors' offsets
    /// and scrolling aside.
    settle_y: ?Spring = null,
    /// A turn in the plane (radians, clockwise), about `rotation_anchor`.
    rotation: f32 = 0,
    /// The point `rotation` and `turn` pivot about, in fractions of the
    /// rect (a card's ring near its corner, a door's hinge at its edge).
    rotation_anchor: Point = .{ .x = 0.5, .y = 0.5 },
    /// A turn about the vertical axis through `rotation_anchor` (radians):
    /// positive swings the right edge away, negative toward the viewer, as
    /// a page turns. The box and everything in it turn as one plane.
    turn: f32 = 0,
    /// How far the eye is from the screen (points) for `turn`, as Core
    /// Animation's m34 = -1/perspective: nearer is stronger. 0 is a flat
    /// projection, the turned box only narrowing.
    perspective: f32 = 0,
    /// Which side of a turned plane the box is drawn on: `front` hides
    /// once the turn shows its back (past a quarter turn), `back` shows
    /// only then, drawn mirrored, as the reverse of a card. A card with a
    /// front child and a back child turns over.
    face: Face = .both,
    spin: f32 = 0,
    pulse: ?Pulse = null,
    motion_blur: bool = false,
    group: bool = false,
};

/// A spring as SwiftUI writes one (`motion.zig`).
pub const Spring = struct { response: f32, damping: f32 };

/// Bytes [start, end) of a text drawn their own way: a color (ANSI
/// output, syntax), and for rich text a weight, italics, the monospaced
/// font (inline code), a background, an underline or a line through.
pub const Span = struct {
    start: u32,
    end: u32,
    color: ?Color = null,
    weight: ?Weight = null,
    italic: bool = false,
    mono: bool = false,
    background: ?Color = null,
    underline: bool = false,
    strike: bool = false,

    /// Whether it changes the font, so the text is shaped with its runs.
    pub fn styled(s: Span) bool {
        return s.weight != null or s.italic or s.mono;
    }
};

pub const TextStyle = struct {
    size: f32 = 14,
    weight: Weight = .regular,
    color: ?Color = null,
    /// Break lines to fit the width the parent gives.
    wrap: bool = false,
    mono: bool = false,
    italic: bool = false,
    /// Line height as a multiple of the font's (1.5 for airy prose).
    leading: f32 = 1,
    /// Line height in points (CSS's `line-height: 22px`), taking the place
    /// of `leading` when above 0; the extra room goes half above, half below.
    line_height: f32 = 0,
    /// Inline code's size (`Span.mono`) over the text's: smaller, as the
    /// monospaced font looks larger at the same size; 1 keeps it.
    mono_scale: f32 = 0.9,
    /// A line longer than its box (text that doesn't wrap): cut before an
    /// ellipsis, faded toward its end, or shortened through its middle.
    truncate: Truncate = .none,
    fade_width: f32 = 24,
    /// Glyphs fade out toward the box's right edge.
    fade: ?Fade = null,
    /// Wrapped text keeps at most this many lines (0: all of them), the
    /// last ending in "…" when text was dropped.
    max_lines: u8 = 0,
    /// Digits all as wide (monospaced numbers): counters, clocks, sizes.
    tabular: bool = false,
    /// Points added after each character (letter spacing).
    tracking: f32 = 0,
    /// The system face's rounded design (SF Rounded); others keep their own.
    rounded: bool = false,
    /// The system face's serif design (New York on Apple systems); others
    /// keep their own.
    serif: bool = false,

    /// Cut to one line that fits, at its end or in its middle.
    pub fn cuts(s: TextStyle) bool {
        return s.truncate == .ellipsis or s.truncate == .middle;
    }
};

pub const Truncate = enum { none, ellipsis, middle, fade };

/// Glyphs within `clear` points of the box's right edge are transparent;
/// they reach full opacity `ramp` points further left.
pub const Fade = struct {
    clear: f32,
    ramp: f32,
};

test "rect" {
    const r: Rect = .{ .x = 10, .y = 10, .w = 100, .h = 50 };
    try std.testing.expect(r.contains(.{ .x = 20, .y = 20 }));
    try std.testing.expect(!r.contains(.{ .x = 120, .y = 20 }));
    const i = r.intersect(.{ .x = 50, .y = 0, .w = 100, .h = 30 });
    try std.testing.expectEqual(@as(f32, 60), i.w);
    try std.testing.expectEqual(@as(f32, 20), i.h);
}
