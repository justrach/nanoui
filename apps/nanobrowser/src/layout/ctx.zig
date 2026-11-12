//! What every layout pass shares: the measurer, the viewport, and the sums on
//! a box's edges and specified sizes. Every number from a style goes through
//! `clean`, so garbage in a style cannot grow into NaN or infinity.
const std = @import("std");
const box = @import("box.zig");
const css = @import("../css/style.zig");
const intrinsic = @import("intrinsic.zig");
const font_cache = @import("../font_cache.zig");

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
    doc: ?*@import("../dom.zig").Document = null,
    prev_gen: u32 = 0,
    /// The anonymous block style last made, and what it was made from.
    anon_from: ?*const Style = null,
    anon_block: ?*const Style = null,
    /// The metrics last asked for: fonts come in long runs.
    last_font: box.Font = .{ .size = -1 },
    last_metrics: box.Metrics = .{},
    space_font_key: u64 = 0,
    space_w: f32 = 0,
    l1_keys: [256]u64 = @splat(0),
    l1_vals: [256]f32 = @splat(0),
    kern_keys: [256]u64 = @splat(0),
    kern_vals: [256]f32 = @splat(0),

    pub fn metrics(c: *Ctx, font: box.Font) box.Metrics {
        if (std.meta.eql(font, c.last_font)) return c.last_metrics;
        const m = c.m.metrics(c.m.ctx, font);
        c.last_font = font;
        c.last_metrics = .{ .ascent = clean(m.ascent), .descent = clean(m.descent), .gap = clean(m.gap), .x_height = clean(m.x_height) };
        return c.last_metrics;
    }

    pub fn width(c: *Ctx, text: []const u8, font: box.Font) f32 {
        if (font.size <= 0) return 0;
        const is_space = text.len == 1 and text[0] == ' ';
        if (is_space and c.space_font_key == font.key()) return c.space_w;
        const k = font.wordKey(text);
        const slot: usize = @as(usize, @truncate(k)) & 255;
        if (k != 0 and c.l1_keys[slot] == k) return c.l1_vals[slot];
        if (k != 0) {
            if (c.m.shared_ok and !font.isScoped()) {
                if (font_cache.getWidth(k)) |cw| {
                    c.l1_keys[slot] = k;
                    c.l1_vals[slot] = cw;
                    if (is_space) { c.space_font_key = font.key(); c.space_w = cw; }
                    return cw;
                }
            } else if (c.m.widths) |wm| if (wm.get(k)) |cw| {
                const w = clean(cw);
                c.l1_keys[slot] = k;
                c.l1_vals[slot] = w;
                if (is_space) { c.space_font_key = font.key(); c.space_w = w; }
                return w;
            };
        }
        const w = clean(c.m.width(c.m.ctx, text, font));
        if (k != 0) {
            c.l1_keys[slot] = k;
            c.l1_vals[slot] = w;
        }
        if (is_space) {
            c.space_font_key = font.key();
            c.space_w = w;
        }
        return w;
    }

    /// Theorem 59 (`NanoUI.Speedometer3Climb.ascii_word_scan_and_persistent_kern_cache_equiv`):
    /// Caches space-kerning deltas in `c.kern_keys` and browser/page persistent width caches.
    pub fn kernSpaceDelta(c: *Ctx, tail: []const u8, head: []const u8, font: box.Font) f32 {
        if (font.mono or font.tabular or font.size <= 0) return 0;
        if (tail.len + head.len + 1 > 10) return 0;
        var k: u64 = if (tail.len == 1 and head.len == 1) blk: {
            var x = font.key() ^ ((@as(u64, tail[0]) | (@as(u64, head[0]) << 8)) *% 0x9E3779B97F4A7C15) ^ 0x4B45_524E_5350_4143;
            x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
            break :blk x ^ (x >> 31);
        } else blk: {
            var tmp: [10]u8 = undefined;
            @memcpy(tmp[0..tail.len], tail);
            tmp[tail.len] = ' ';
            @memcpy(tmp[tail.len + 1 ..][0..head.len], head);
            break :blk font.wordKey(tmp[0 .. tail.len + 1 + head.len]) ^ 0x4B45_524E_5350_4143;
        };
        if (k == 0) k = 1;
        const slot: usize = @as(usize, @truncate(k)) & 255;
        if (c.kern_keys[slot] == k) return c.kern_vals[slot];
        const use_shared = c.m.shared_ok and !font.isScoped();
        if (use_shared) {
            if (font_cache.getWidth(k)) |cached_d| {
                c.kern_keys[slot] = k;
                c.kern_vals[slot] = cached_d;
                return cached_d;
            }
        } else if (c.m.widths) |wm| if (wm.get(k)) |cached_d| {
            c.kern_keys[slot] = k;
            c.kern_vals[slot] = cached_d;
            return cached_d;
        };
        var buf: [10]u8 = undefined;
        @memcpy(buf[0..tail.len], tail);
        buf[tail.len] = ' ';
        @memcpy(buf[tail.len + 1 ..][0..head.len], head);
        const slice = buf[0 .. tail.len + 1 + head.len];
        const d = c.width(slice, font) - (c.width(tail, font) + c.width(head, font) + c.width(" ", font));
        c.kern_keys[slot] = k;
        c.kern_vals[slot] = d;
        if (use_shared) {
            font_cache.putWidth(k, d);
        } else if (c.m.widths) |wm| if (c.m.widths_gpa) |gpa| {
            if (wm.contains(font.wordKey(slice))) wm.put(gpa, k, d) catch {};
        };
        return d;
    }

    /// The style of an anonymous box in one of `parent`: inherited properties
    /// from it, the rest as initial.
    pub fn anonStyle(c: *Ctx, parent: *const Style, display: css.Display) Error!*const Style {
        if (display == .block and c.anon_from == parent) return c.anon_block.?;
        const s = try c.arena.create(Style);
        @import("../css/properties_wide.zig").inheritInto(s, parent);
        s.visibility = parent.inherited_visibility;
        s.underline = parent.underline;
        s.line_through = parent.line_through;
        s.overline = parent.overline;
        s.text_decoration_color = parent.text_decoration_color;
        s.cursor = parent.cursor;
        s.pointer_events = parent.pointer_events;
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

/// NaN to zero, and anything huge to the limit.
pub inline fn clean(v: f32) f32 {
    if (v != v) return 0;
    return std.math.clamp(v, -limit, limit);
}

/// A length against `ref`; zero for what is not a length.
pub inline fn len(l: Len, ref: f32) f32 {
    if (l.kind != .length) return 0;
    if (l.math != null) return clean(l.at(ref));
    if (l.pct == 0) return if (l.px == 0) 0 else clean(l.px);
    return clean(clean(l.px) + clean(l.pct) * ref * 0.01);
}

pub inline fn borderWidth(b: css.Border) f32 {
    if (b.style == .none or b.style == .hidden) return 0;
    return @max(0, clean(b.width));
}

pub const EdgeSet = struct { margin: box.Edges, border: box.Edges, padding: box.Edges };

/// A style's edges against a containing block's width; auto margins are zero.
pub inline fn edgesOf(s: *const Style, cw: f32) EdgeSet {
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
pub inline fn setEdges(b: *Box, cw: f32) void {
    const e = edgesOf(b.style, cw);
    b.margin = e.margin;
    b.border = e.border;
    b.padding = e.padding;
}

pub inline fn bpH(b: *const Box) f32 {
    return b.border.horizontal() + b.padding.horizontal();
}

pub inline fn bpV(b: *const Box) f32 {
    return b.border.vertical() + b.padding.vertical();
}

pub inline fn bpTop(b: *const Box) f32 {
    return b.border.top + b.padding.top;
}

pub inline fn bpLeft(b: *const Box) f32 {
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
