//! SVG documents to pixels (`ui.svg`): `svg` (nested too, with `viewBox` and
//! `preserveAspectRatio`), `g`, `use`, `symbol`, `path`, `rect`, `circle`,
//! `ellipse`, `line`, `polyline` and `polygon`; fills (nonzero, evenodd) and
//! strokes (width, caps, joins, miter limit, dashes) in colors or linear and
//! radial gradients; group opacity, clip paths and masks; `transform`,
//! `style="…"` and a document's own `<style>`, inherited down groups. Colors
//! are every CSS spelling, `var(--x, fallback)` and `currentColor`, which is
//! the `color` property's and otherwise the caller's. What it doesn't draw:
//! text, `image`, patterns, markers, filters and `foreignObject`.
const std = @import("std");
const geom = @import("svg_geom.zig");
const svg_path = @import("svg_path.zig");
const raster = @import("svg_raster.zig");
const style = @import("svg_style.zig");
const render_mod = @import("svg_render.zig");
const colors = @import("svg_colors.zig");
const tags = @import("svg_tags.zig");

pub const Options = struct {
    /// The picture's size in pixels; the document's viewBox is fitted in
    /// it, centered, keeping its proportions, unless it says otherwise.
    width: u32,
    height: u32,
    /// `currentColor`, straight RGBA from 0 to 1, until a `color` says.
    current: [4]f32 = .{ 0, 0, 0, 1 },
};

/// The document's own size: its viewBox's, else its width and height.
pub fn size(src: []const u8) ?[2]f32 {
    var it: tags.Tags = .{ .s = src };
    while (it.next()) |tag| if (tag.kind != .close and std.mem.eql(u8, tag.name, "svg")) {
        if (render_mod.viewBox(tag)) |b| return .{ b[2], b[3] };
        const w = style.length(tag.attr("width") orelse "", 0) orelse return null;
        const h = style.length(tag.attr("height") orelse "", 0) orelse return null;
        return .{ w, h };
    };
    return null;
}

/// The document drawn into premultiplied BGRA, `width` × `height`.
pub fn render(gpa: std.mem.Allocator, src: []const u8, opts: Options) ![]u8 {
    const w: usize = opts.width;
    const h: usize = opts.height;
    if (w == 0 or h == 0 or w * h > 8192 * 8192) return error.BadSize;
    const r = try render_mod.Renderer.init(gpa, src, w, h, opts.current);
    defer r.deinit();
    if (!try r.run()) return error.NotSvg;
    return r.bytes(gpa);
}

/// A color's RGBA, straight, from 0 to 1.
pub fn color(v: []const u8) ?[4]f32 {
    return colors.parse(v);
}

test {
    _ = geom;
    _ = svg_path;
    _ = raster;
    _ = style;
    _ = colors;
    _ = tags;
    _ = @import("svg_paint.zig");
    _ = @import("svg_tests.zig");
    _ = @import("svg_tests2.zig");
}
