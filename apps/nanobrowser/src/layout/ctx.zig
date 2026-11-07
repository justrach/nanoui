//! What every layout pass shares: the measurer, the viewport, and the sums on
//! a box's edges and specified sizes. Every number from a style goes through
//! `clean`, so garbage in a style cannot grow into NaN or infinity.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const intrinsic = @import("intrinsic.zig");

pub const Allocator = std.mem.Allocator;
pub const Error = Allocator.Error;
pub const Box = box.Box;
pub const Style = css.Style;
pub const Len = css.Len;

/// Above this, a length is treated as this: well within `f32`'s range when summed.
const limit: f32 = 1e7;

pub const Ctx = struct {
    arena: Allocator,
    m: box.Measurer,
    vw: f32,
    vh: f32,
    quirks: bool = false,
    /// The anonymous block style last made, and what it was made from.
    anon_from: ?*const Style = null,
    anon_block: ?*const Style = null,
    /// The metrics last asked for: fonts come in long runs.
    last_font: box.Font = .{ .size = -1 },
    last_metrics: box.Metrics = .{},

    pub fn metrics(c: *Ctx, font: box.Font) box.Metrics {
        if (std.meta.eql(font, c.last_font)) return c.last_metrics;
        const m = c.m.metrics(c.m.ctx, font);
        c.last_font = font;
        c.last_metrics = .{ .ascent = clean(m.ascent), .descent = clean(m.descent), .gap = clean(m.gap), .x_height = clean(m.x_height) };
        return c.last_metrics;
    }

    pub fn width(c: *Ctx, text: []const u8, font: box.Font) f32 {
        return clean(c.m.width(c.m.ctx, text, font));
    }

    /// The style of an anonymous box in one of `parent`: inherited properties
    /// from it, the rest as initial.
    pub fn anonStyle(c: *Ctx, parent: *const Style, display: css.Display) Error!*const Style {
        if (display == .block and c.anon_from == parent) return c.anon_block.?;
        const s = try c.arena.create(Style);
        s.* = inheritFrom(parent);
        s.display = display;
        if (display == .block) {
            c.anon_from = parent;
            c.anon_block = s;
        }
        return s;
    }

    /// The line height a style asks for, 0 being the font's own.
    pub fn lineHeight(c: *Ctx, s: *const Style) f32 {
        const lh = clean(s.line_height);
        if (lh > 0) return lh;
        const m = c.metrics(box.fontOf(s));
        return m.ascent + m.descent + m.gap;
    }
};

fn inheritFrom(p: *const Style) Style {
    var s: Style = .{};
    s.color = p.color;
    s.font_size = p.font_size;
    s.font_weight = p.font_weight;
    s.italic = p.italic;
    s.mono = p.mono;
    s.serif = p.serif;
    s.mono_generic = p.mono_generic;
    s.font_family = p.font_family;
    s.font_size_abs = p.font_size_abs;
    s.font_stretch = p.font_stretch;
    s.tabular = p.tabular;
    s.line_height = p.line_height;
    s.line_height_factor = p.line_height_factor;
    s.letter_spacing = p.letter_spacing;
    s.word_spacing = p.word_spacing;
    s.text_align = p.text_align;
    s.text_indent = p.text_indent;
    s.white_space = p.white_space;
    s.text_transform = p.text_transform;
    s.list_style = p.list_style;
    s.list_inside = p.list_inside;
    s.rtl = p.rtl;
    s.inherited_visibility = p.inherited_visibility;
    s.visibility = p.inherited_visibility;
    s.border_collapse = p.border_collapse;
    s.border_spacing = p.border_spacing;
    s.border_spacing_y = p.border_spacing_y;
    s.word_break_all = p.word_break_all;
    s.line_break_anywhere = p.line_break_anywhere;
    s.overflow_wrap_anywhere = p.overflow_wrap_anywhere;
    s.caption_bottom = p.caption_bottom;
    s.tab_size = p.tab_size;
    s.text_balance = p.text_balance;
    s.list_style_text = p.list_style_text;
    s.dark_scheme = p.dark_scheme;
    s.underline = p.underline;
    s.line_through = p.line_through;
    s.overline = p.overline;
    s.text_decoration_color = p.text_decoration_color;
    s.cursor = p.cursor;
    s.pointer_events = p.pointer_events;
    return s;
}

/// NaN to zero, and anything huge to the limit.
pub fn clean(v: f32) f32 {
    if (v != v) return 0;
    return std.math.clamp(v, -limit, limit);
}

/// A length against `ref`; zero for what is not a length.
pub fn len(l: Len, ref: f32) f32 {
    if (l.kind != .length) return 0;
    if (l.math != null) return clean(l.at(ref));
    return clean(clean(l.px) + clean(l.pct) * ref / 100);
}

pub fn borderWidth(b: css.Border) f32 {
    if (b.style == .none or b.style == .hidden) return 0;
    return @max(0, clean(b.width));
}

pub const EdgeSet = struct { margin: box.Edges, border: box.Edges, padding: box.Edges };

/// A style's edges against a containing block's width; auto margins are zero.
pub fn edgesOf(s: *const Style, cw: f32) EdgeSet {
    return .{
        .margin = .{
            .top = len(s.margin_top, cw),
            .right = len(s.margin_right, cw),
            .bottom = len(s.margin_bottom, cw),
            .left = len(s.margin_left, cw),
        },
        .border = .{
            .top = borderWidth(s.border_top),
            .right = borderWidth(s.border_right),
            .bottom = borderWidth(s.border_bottom),
            .left = borderWidth(s.border_left),
        },
        .padding = .{
            .top = @max(0, len(s.padding_top, cw)),
            .right = @max(0, len(s.padding_right, cw)),
            .bottom = @max(0, len(s.padding_bottom, cw)),
            .left = @max(0, len(s.padding_left, cw)),
        },
    };
}

/// Fills in a box's edges.
pub fn setEdges(b: *Box, cw: f32) void {
    const e = edgesOf(b.style, cw);
    b.margin = e.margin;
    b.border = e.border;
    b.padding = e.padding;
}

pub fn bpH(b: *const Box) f32 {
    return b.border.horizontal() + b.padding.horizontal();
}

pub fn bpV(b: *const Box) f32 {
    return b.border.vertical() + b.padding.vertical();
}

pub fn bpTop(b: *const Box) f32 {
    return b.border.top + b.padding.top;
}

pub fn bpLeft(b: *const Box) f32 {
    return b.border.left + b.padding.left;
}

/// The border-box width `l` asks for, or null for auto (and for a percentage
/// of an unknown width).
pub fn specW(c: *Ctx, b: *Box, l: Len, cw: ?f32, bp: f32) Error!?f32 {
    switch (l.kind) {
        .auto, .none => return null,
        .length => {
            if (l.hasPct() and cw == null) return null;
            const v = @max(0, len(l, cw orelse 0));
            return if (b.style.box_sizing == .border_box) @max(v, bp) else v + bp;
        },
        .min_content => return (try intrinsic.of(c, b)).min,
        .max_content => return (try intrinsic.of(c, b)).max,
        .fit_content => {
            const i = try intrinsic.of(c, b);
            const room = if (cw) |w| w - b.margin.horizontal() else i.max;
            return @min(i.max, @max(i.min, room));
        },
        .stretch => {
            const w = cw orelse return null;
            return @max(bp, w - b.margin.horizontal());
        },
    }
}

/// The border-box height `l` asks for; null for auto and for a percentage of
/// an indefinite height. The content keywords act as auto; `stretch` fills a
/// definite height.
pub fn specH(b: *const Box, l: Len, ch: ?f32, bp: f32) ?f32 {
    if (l.kind == .stretch) {
        const h = ch orelse return null;
        return @max(bp, h - b.margin.vertical());
    }
    if (l.kind != .length) return null;
    if (l.hasPct() and ch == null) return null;
    const v = @max(0, len(l, ch orelse 0));
    return if (b.style.box_sizing == .border_box) @max(v, bp) else v + bp;
}

pub fn clampW(c: *Ctx, b: *Box, w: f32, cw: ?f32, bp: f32) Error!f32 {
    var out = w;
    if (try specW(c, b, b.style.max_width, cw, bp)) |m| out = @min(out, m);
    if (try specW(c, b, b.style.min_width, cw, bp)) |m| out = @max(out, m);
    return @max(out, bp);
}

pub fn clampH(b: *const Box, h: f32, ch: ?f32, bp: f32) f32 {
    var out = h;
    if (specH(b, b.style.max_height, ch, bp)) |m| out = @min(out, m);
    if (specH(b, b.style.min_height, ch, bp)) |m| out = @max(out, m);
    return @max(out, bp);
}

/// The border-box height `aspect-ratio` gives a box of border-box width `w`.
pub fn aspectH(b: *const Box, w: f32) f32 {
    const ratio = clean(b.style.aspect_ratio);
    if (b.style.box_sizing == .border_box) return @max(w / ratio, bpV(b));
    return @max(0, w - bpH(b)) / ratio + bpV(b);
}

/// The border-box width `aspect-ratio` gives a box of border-box height `h`.
pub fn aspectW(b: *const Box, h: f32) f32 {
    const ratio = clean(b.style.aspect_ratio);
    if (b.style.box_sizing == .border_box) return @max(h * ratio, bpH(b));
    return @max(0, h - bpV(b)) * ratio + bpH(b);
}

/// Whether `aspect-ratio`'s height gives way to what's inside (§ automatic minimum).
pub fn aspectGrows(b: *const Box) bool {
    return !b.style.clips() and b.style.min_height.kind == .auto;
}

/// Whether the box's content is a formatting context of its own, so floats
/// and margins stay on one side of its edge. Buttons are, as `center_v` marks them.
pub fn isBfcRoot(b: *const Box) bool {
    if (b.kind != .block) return true;
    const s = b.style;
    if (s.float != .none or s.isOutOfFlow() or s.flow_root or b.lay.center_v) return true;
    if (s.container_type != .normal or s.contain_flow or s.contain_size or s.contain_inline_size) return true;
    if (s.column_count > 0 or s.column_width > 0) return true;
    if (s.overflow_x != .visible or s.overflow_y != .visible) return true;
    if (s.display == .inline_block) return true;
    if (b.parent) |p| {
        if (p.kind == .flex or p.kind == .grid) return true;
        if (p.parent == null) return true; // The root element's margins do not collapse.
    }
    return false;
}

/// Moves what a box holds down by `dy`: runs, children in flow, its marker.
/// Coordinates inside it are relative to it, so this is one level's work.
pub fn shiftContents(b: *Box, dy: f32) void {
    if (dy == 0) return;
    b.lay.shift_y += dy;
    const runs: []box.TextRun = @constCast(b.runs);
    for (runs) |*r| {
        r.baseline += dy;
        r.line_top += dy;
    }
    if (b.marker) |*m| m.y += dy;
    if (b.lay.first_baseline) |*v| v.* += dy;
    if (b.lay.last_baseline) |*v| v.* += dy;
    var k = b.first_child;
    while (k) |x| : (k = x.next) shiftInline(x, dy);
}

/// Inline boxes' insides are relative to the block they are in: they move too.
fn shiftInline(x: *Box, dy: f32) void {
    x.y += dy;
    if (x.kind != .inline_box) return;
    const runs: []box.TextRun = @constCast(x.runs);
    for (runs) |*r| {
        r.baseline += dy;
        r.line_top += dy;
    }
    const frags: []box.Rect = @constCast(x.frags);
    for (frags) |*r| r.y += dy;
    var k = x.first_child;
    while (k) |y| : (k = y.next) shiftInline(y, dy);
}
