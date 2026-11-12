//! What layout gives paint: a tree of boxes with their used geometry, in CSS
//! pixels from the document's top left, scrolling aside (paint subtracts the
//! offsets). The whole tree lives in one arena and is thrown away by the next
//! layout. Knows nothing of nanoui: text is measured through `Measurer`.
const std = @import("std");
const dom = @import("../dom.zig");
const style = @import("../css/style.zig");

pub const Style = style.Style;

pub const Size = struct { w: f32 = 0, h: f32 = 0 };
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(r: Rect, x: f32, y: f32) bool {
        return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
    }
};
pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn horizontal(e: Edges) f32 {
        return e.left + e.right;
    }

    pub fn vertical(e: Edges) f32 {
        return e.top + e.bottom;
    }
};

/// What text is drawn in; `fontOf` makes one from a style.
pub const Font = struct {
    size: f32 = 16,
    weight: u16 = 400,
    italic: bool = false,
    mono: bool = false,
    serif: bool = false,
    /// The family list: comma separated, generics resolved.
    family: []const u8 = "",
    /// `font-stretch`, in percent.
    stretch: u16 = 100,
    tabular: bool = false,
    /// CSS turns off standard ligatures when letters are spaced.
    ligatures: bool = true,
    /// True when `family` names a page-scoped `@font-face` (`@<id>/...`).
    scoped: bool = false,
    hash: u64 = 0,

    pub inline fn isScoped(font: Font) bool {
        return font.scoped or (font.hash == 0 and std.mem.indexOfScalar(u8, font.family, '@') != null);
    }

    pub fn key(font: Font) u64 {
        if (font.hash != 0) return font.hash;
        return computeFontHash(font);
    }

    pub fn wordKey(font: Font, text: []const u8) u64 {
        const fk = font.key();
        if (text.len <= 8) {
            var w: u64 = 0;
            for (text, 0..) |b, i| w |= @as(u64, b) << @intCast(i * 8);
            var x = fk ^ (w *% 0x9E3779B97F4A7C15) ^ (@as(u64, text.len) *% 0x517CC1B727220A95);
            x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
            x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
            return x ^ (x >> 31);
        }
        return std.hash.Wyhash.hash(fk, text);
    }
};

fn computeFontHash(font: Font) u64 {
    const bits: u64 = @as(u32, @bitCast(font.size));
    const flags: u64 = @intFromBool(font.italic) |
        (@as(u64, @intFromBool(font.mono)) << 1) |
        (@as(u64, @intFromBool(font.serif)) << 2) |
        (@as(u64, @intFromBool(font.tabular)) << 3) |
        (@as(u64, @intFromBool(font.ligatures)) << 4) |
        (@as(u64, font.weight) << 8) |
        (@as(u64, font.stretch) << 24) |
        (bits << 32);
    const h = if (font.family.len == 0)
        flags *% 0x9E3779B97F4A7C15 ^ 0xBF58476D1CE4E5B9
    else
        std.hash.Wyhash.hash(flags, font.family);
    return if (h == 0) 1 else h;
}

pub const Metrics = struct {
    ascent: f32 = 12.8,
    descent: f32 = 3.2,
    gap: f32 = 0,
    /// The height of its lowercase; 0 when it's not known, half an em being near.
    x_height: f32 = 0,
};

/// The host's fonts and pictures. `width` is called a great deal: the caller
/// keeps it cheap (a cache by text and font).
pub const Measurer = struct {
    ctx: *anyopaque,
    width: *const fn (ctx: *anyopaque, text: []const u8, font: Font) f32,
    metrics: *const fn (ctx: *anyopaque, font: Font) Metrics,
    /// An element's picture's own size in CSS pixels (`<img>`, `<svg>`,
    /// `<canvas>`, `<video>`); null while unknown (not arrived, or broken).
    /// A picture's own size; a negative `w`: it has none, and `h` is its shape
    /// (width over height), as an SVG with only a viewBox.
    image: *const fn (ctx: *anyopaque, node: *dom.Node) ?Size,
    widths: ?*std.AutoHashMapUnmanaged(u64, f32) = null,
    widths_gpa: ?std.mem.Allocator = null,
    shared_ok: bool = false,
};

pub const Kind = enum {
    /// A block container (a block, inline-block, flex or grid item, cell, …).
    block,
    /// A span of the inline flow: its `frags` are its pieces on each line.
    inline_box,
    /// A flex or grid container.
    flex,
    grid,
    table,
    table_row_group,
    table_row,
    table_cell,
    table_caption,
    /// `<img>`, `<svg>`, `<canvas>`, `<video>`, `<iframe>`, `<object>`: drawn by paint in its content rect.
    replaced,
    /// `<input>`, `<select>`, `<textarea>`, `<progress>`, `<meter>`: drawn by paint with `controls.zig`.
    control,
};

/// One line's worth of one text, ready to draw.
pub const TextRun = struct {
    /// Whitespace collapsed and text-transform applied, in the tree's arena.
    text: []const u8,
    /// The text node it came from, and the byte offset in the node's data of
    /// the run's first byte when `text` is a plain slice of it (else null):
    /// for selection and find. Null node for generated text (`::before`, a
    /// list's marker, a button's value).
    node: ?*dom.Node = null,
    start: ?u32 = null,
    /// The left edge of its first glyph, and the baseline.
    x: f32,
    baseline: f32,
    w: f32,
    font: Font,
    /// The computed style of the box it is in: color, decorations, spacing.
    style: *const Style,
    /// The line box it is on: for hit testing and selection highlights.
    line_top: f32 = 0,
    line_h: f32 = 0,
    /// `letter-spacing`, `word-spacing` and `text-align: justify` spread its glyphs:
    /// paint adds this after each byte's character, this after each space.
    spacing: f32 = 0,
    word_spacing: f32 = 0,
};

/// What gen hands the inline passes: an inline box's or block's content in
/// order, before text is broken into pieces.
pub const Entry = struct {
    tag: Tag,
    /// `box`: the box. Otherwise the box is found from where the entry sits.
    box: ?*Box = null,
    /// `text`: the text node. `generated`: null.
    node: ?*dom.Node = null,
    /// `text`, `generated`: the characters.
    text: []const u8 = "",
    /// The style of the element the characters are in.
    style: ?*const Style = null,

    pub const Tag = enum { box, text, generated, br, wbr, bullet };
};

/// One unbreakable thing on an inline formatting context's way: what line
/// breaking walks, kept from one layout of the box to the next.
pub const Piece = struct {
    tag: Tag,
    /// `word`, `space`: what it draws (a slice of the text node's data when `plain`).
    text: []const u8 = "",
    /// Its advance: measured for text, set by each layout for boxes.
    w: f32 = 0,
    /// The box it is in (text), or the box it is (open, close, atom, float, abs).
    box: *Box,
    node: ?*dom.Node = null,
    style: *const Style,
    font: Font = .{},
    /// `text` starts at this byte of `node.data`.
    start: u32 = 0,
    plain: bool = false,
    /// A break is allowed after it.
    brk: bool = false,
    /// A space that is kept at the start of a line (`pre-wrap`).
    preserved: bool = false,
    /// A space that offers a line break.
    wraps: bool = true,
    /// A space that is one byte of the text around it, so a run can go on through it.
    sliced: bool = false,

    pub const Tag = enum { word, space, tab, newline, open, close, atom, float, abs, opp, bullet };
};

/// What layout remembers on a box between its passes.
pub const Notes = struct {
    /// Border-box min-content and max-content widths, memoized.
    intrinsic_known: bool = false,
    min_w: f32 = 0,
    max_w: f32 = 0,
    /// The same from its content alone, its own `width` and limits aside.
    content_min: f32 = 0,
    content_max: f32 = 0,
    /// The arguments and result of the layout the box's insides are in.
    state_valid: bool = false,
    state_w: f32 = 0,
    state_h: f32 = -1,
    state_edges: f32 = 0,
    state_out_w: f32 = 0,
    state_out_h: f32 = 0,
    /// The last auto-height result, whatever has been laid out since.
    measure_valid: bool = false,
    measure_w: f32 = 0,
    measure_edges: f32 = 0,
    measure_h: f32 = 0,
    /// The height of its content box's content, whatever its own height is.
    auto_h: f32 = 0,
    /// Baselines from the top of the border box, when it has lines.
    first_baseline: ?f32 = null,
    last_baseline: ?f32 = null,
    /// A block container with inline content: `pieces` is that content.
    inline_root: bool = false,
    entries: []const Entry = &.{},
    pieces: []Piece = &.{},
    /// How many runs and frags the current inline layout gave it.
    run_count: u32 = 0,
    frag_count: u32 = 0,
    /// `align` and `nowrap` attributes inherited from above.
    text_align: ?style.TextAlign = null,
    nowrap: bool = false,
    /// Its content is centered vertically in a definite height (`<button>`).
    center_v: bool = false,
    /// How far its content has been moved down by `center_v` or a cell's `vertical-align`.
    shift_y: f32 = 0,
    /// Auto width means fit-content, even as a block (`<button>`).
    shrink: bool = false,
    /// A list item's marker.
    marker_text: []const u8 = "",
    has_marker: bool = false,
    /// `::marker`'s style, when it has one; the box's otherwise.
    marker_style: ?*const Style = null,
    /// `list-style-type: "text"` and `::marker { content }`: nothing between it and the content.
    marker_no_gap: bool = false,
    /// A flex or grid container's absolute child's static position: the space it
    /// is aligned in and how far along it, each 0 to 1. Zero space: it stays at
    /// where the container put it.
    static_w: f32 = 0,
    static_h: f32 = 0,
    static_fx: f32 = 0,
    static_fy: f32 = 0,
    /// The right and bottom of positioned boxes for which it is the
    /// containing block, in page coordinates.
    extra_r: f32 = 0,
    extra_b: f32 = 0,
    /// A subgrid: the tracks it has from the grid around it, -1 for one not sized
    /// yet, and the gaps between them there.
    sub_cols: ?[]const f32 = null,
    sub_rows: ?[]const f32 = null,
    sub_col_gap: f32 = 0,
    sub_row_gap: f32 = 0,
    /// A table's analysed grid (`table.zig`).
    table: ?*anyopaque = null,
    /// Clean-subtree layout cache state (`layout/cache.zig`).
    cache_gen: u32 = 0,
    reusable: bool = false,
    flow_reusable: bool = false,
    adopted: bool = false,
    advances_list_counter: bool = false,
    bad_subtree: bool = false,
    uncontained_abs: bool = false,
    unscoped_li: bool = false,
    has_float: bool = false,
    no_top_collapse: bool = false,
    no_bottom_collapse: bool = false,
    in_text_align: ?style.TextAlign = null,
    in_nowrap: bool = false,
    cached_style: ?*const Style = null,
    old_style: ?*const Style = null,
    cached_page_x: f32 = 0,
    cached_page_y: f32 = 0,
    cached_flow_cw: f32 = -1,
    cached_flow_ch: f32 = -2,
    cached_out_w: f32 = 0,
    cached_out_h: f32 = 0,
};

pub const Box = struct {
    kind: Kind,
    /// The element; null for anonymous boxes (their `style` is inherited
    /// from the parent's with non-inherited properties reset).
    node: ?*dom.Node = null,
    style: *const Style,
    parent: ?*Box = null,
    first_child: ?*Box = null,
    last_child: ?*Box = null,
    next: ?*Box = null,

    /// The border box.
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    margin: Edges = .{},
    border: Edges = .{},
    padding: Edges = .{},

    /// The lines of inline content this box holds, in order. Text in a span
    /// is on the span's box; the block around it has what is directly in it.
    runs: []const TextRun = &.{},
    /// An inline box's border boxes, one for each line it is on; `x`..`h`
    /// above are their union.
    frags: []const Rect = &.{},
    /// The right and bottom of everything in it that isn't clipped by a box
    /// inside, from the padding box's top left: over `w`/`h` it scrolls
    /// (when `style.scrolls()`), or is clipped.
    content_w: f32 = 0,
    content_h: f32 = 0,
    /// A list item's marker: a bullet shape (`disc`, `circle`, `square`) drawn
    /// here, or a counter's text among `runs`.
    marker: ?Rect = null,
    /// Out of flow (absolute or fixed): painted with its stacking level but
    /// positioned against its containing block, already worked out above.
    positioned: bool = false,
    /// A `::before` or `::after`.
    pseudo: bool = false,
    /// Layout's own notes; nothing for paint.
    lay: Notes = .{},

    pub fn contentRect(b: *const Box) Rect {
        return .{
            .x = b.x + b.border.left + b.padding.left,
            .y = b.y + b.border.top + b.padding.top,
            .w = @max(0, b.w - b.border.horizontal() - b.padding.horizontal()),
            .h = @max(0, b.h - b.border.vertical() - b.padding.vertical()),
        };
    }

    pub fn paddingRect(b: *const Box) Rect {
        return .{
            .x = b.x + b.border.left,
            .y = b.y + b.border.top,
            .w = @max(0, b.w - b.border.horizontal()),
            .h = @max(0, b.h - b.border.vertical()),
        };
    }

    pub fn borderRect(b: *const Box) Rect {
        return .{ .x = b.x, .y = b.y, .w = b.w, .h = b.h };
    }

    pub fn append(b: *Box, child: *Box) void {
        child.parent = b;
        if (b.last_child) |l| l.next = child else b.first_child = child;
        b.last_child = child;
    }
};

pub fn fontOf(s: *const Style) Font {
    var f: Font = .{
        .size = s.font_size,
        .weight = s.font_weight,
        .italic = s.italic,
        .mono = s.mono,
        .serif = s.serif,
        .family = s.font_family,
        .stretch = s.font_stretch,
        .tabular = s.tabular,
        .ligatures = s.letter_spacing == 0,
        .scoped = std.mem.indexOfScalar(u8, s.font_family, '@') != null,
    };
    f.hash = computeFontHash(f);
    return f;
}

/// The result of a layout.
pub const Tree = struct {
    /// The initial containing block's box: the root element's parent.
    root: *Box,
    /// The document's scrollable size (over the viewport's, the page scrolls).
    doc_w: f32,
    doc_h: f32,
    /// The canvas's color: the root's background, else the body's (CSS's propagation).
    canvas: style.Color = .transparent,
    /// `overflow: hidden` on the root or body: scripts may scroll it, people may not.
    locked: bool = false,
};
