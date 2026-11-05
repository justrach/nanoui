//! Property tests: one value per feature, read back from the computed `Style`.
const std = @import("std");
const css = @import("css.zig");
const style = @import("style.zig");
const page = @import("tests_cascade.zig");

const expect = std.testing.expect;
const eq = std.testing.expectEqualStrings;
const Page = page.Page;

const vp: css.Viewport = .{ .width = 1000, .height = 500 };

fn near(a: f32, b: f32) !void {
    if (@abs(a - b) > 0.02) {
        std.debug.print("got {d}, want {d}\n", .{ a, b });
        return error.TestUnexpectedResult;
    }
}

/// `#x { <decl> }` inside `#o { font-size: 20px }`, with root font 10px.
fn with(decl: []const u8) !*Page {
    var buf: [1024]u8 = undefined;
    const sheet = try std.fmt.bufPrint(&buf, "html {{ font-size: 10px }} #o {{ font-size: 20px; color: #010203 }} #x {{ {s} }}", .{decl});
    return Page.make("<!doctype html><body><div id=o><div id=x data-v=attrval></div></div>", sheet, vp);
}

test "units" {
    const Case = struct { d: []const u8, want: f32 };
    const cases = [_]Case{
        .{ .d = "width: 3px", .want = 3 },
        .{ .d = "width: 2em", .want = 40 },
        .{ .d = "width: 2rem", .want = 20 },
        .{ .d = "width: 10vw", .want = 100 },
        .{ .d = "width: 10vh", .want = 50 },
        .{ .d = "width: 10vmin", .want = 50 },
        .{ .d = "width: 10vmax", .want = 100 },
        .{ .d = "width: 10dvh", .want = 50 },
        .{ .d = "width: 10svh", .want = 50 },
        .{ .d = "width: 10lvh", .want = 50 },
        .{ .d = "width: 2ch", .want = 20 },
        .{ .d = "width: 2ex", .want = 20 },
        .{ .d = "width: 3pt", .want = 4 },
        .{ .d = "width: 1pc", .want = 16 },
        .{ .d = "width: 1in", .want = 96 },
        .{ .d = "width: 2.54cm", .want = 96 },
        .{ .d = "width: 25.4mm", .want = 96 },
        .{ .d = "width: 40q", .want = 37.795 },
        .{ .d = "width: 0", .want = 0 },
        .{ .d = "font-size: 1.5em; width: 1em", .want = 30 },
        .{ .d = "font-size: 150%; width: 1em", .want = 30 },
        .{ .d = "font-size: 2rem; width: 1em", .want = 20 },
    };
    for (cases) |c| {
        const p = try with(c.d);
        defer p.done();
        try near(p.s("x").width.px, c.want);
    }
}

test "calc, min, max, clamp" {
    const Case = struct { d: []const u8, px: f32, pct: f32 };
    const cases = [_]Case{
        .{ .d = "calc(1px + 2px)", .px = 3, .pct = 0 },
        .{ .d = "calc(100% - 20px)", .px = -20, .pct = 100 },
        .{ .d = "calc(50% + 1em)", .px = 20, .pct = 50 },
        .{ .d = "calc(2 * 3px)", .px = 6, .pct = 0 },
        .{ .d = "calc(6px / 2)", .px = 3, .pct = 0 },
        .{ .d = "calc((1px + 2px) * 2)", .px = 6, .pct = 0 },
        .{ .d = "calc(100% / 3)", .px = 0, .pct = 33.333 },
        .{ .d = "calc(calc(1px + 1px) * 2)", .px = 4, .pct = 0 },
        .{ .d = "min(10px, 20px)", .px = 10, .pct = 0 },
        .{ .d = "max(10px, 20px)", .px = 20, .pct = 0 },
        .{ .d = "clamp(10px, 5px, 20px)", .px = 10, .pct = 0 },
        .{ .d = "clamp(10px, 15px, 20px)", .px = 15, .pct = 0 },
        .{ .d = "clamp(10px, 25px, 20px)", .px = 20, .pct = 0 },
        .{ .d = "min(100%, 500px)", .px = 500, .pct = 0 },
        .{ .d = "min(100%, 5000px)", .px = 0, .pct = 100 },
        .{ .d = "calc(min(10px, 20px) + 1px)", .px = 11, .pct = 0 },
        .{ .d = "calc(10vw + 1rem)", .px = 110, .pct = 0 },
    };
    for (cases) |c| {
        var buf: [128]u8 = undefined;
        const p = try with(try std.fmt.bufPrint(&buf, "width: {s}", .{c.d}));
        defer p.done();
        try near(p.s("x").width.px, c.px);
        try near(p.s("x").width.pct, c.pct);
    }
    // Invalid math leaves the property alone.
    const bad = try with("width: 7px; width: calc(1px + 1); width: calc(1px * 2px); width: calc(1px / 0)");
    defer bad.done();
    try near(bad.s("x").width.px, 7);
}

test "colors" {
    const Case = struct { v: []const u8, r: f32, g: f32, b: f32, a: f32 = 1 };
    const cases = [_]Case{
        .{ .v = "red", .r = 1, .g = 0, .b = 0 },
        .{ .v = "RebeccaPurple", .r = 0.4, .g = 0.2, .b = 0.6 },
        .{ .v = "#f00", .r = 1, .g = 0, .b = 0 },
        .{ .v = "#f008", .r = 1, .g = 0, .b = 0, .a = 0.533 },
        .{ .v = "#00ff00", .r = 0, .g = 1, .b = 0 },
        .{ .v = "#0000ff80", .r = 0, .g = 0, .b = 1, .a = 0.502 },
        .{ .v = "rgb(255, 0, 0)", .r = 1, .g = 0, .b = 0 },
        .{ .v = "rgba(255, 0, 0, .5)", .r = 1, .g = 0, .b = 0, .a = 0.5 },
        .{ .v = "rgb(255 0 0 / 50%)", .r = 1, .g = 0, .b = 0, .a = 0.5 },
        .{ .v = "rgb(100% 0% 0%)", .r = 1, .g = 0, .b = 0 },
        .{ .v = "hsl(120, 100%, 50%)", .r = 0, .g = 1, .b = 0 },
        .{ .v = "hsl(240deg 100% 50% / 0.5)", .r = 0, .g = 0, .b = 1, .a = 0.5 },
        .{ .v = "hsla(0.5turn, 100%, 50%, 1)", .r = 0, .g = 1, .b = 1 },
        .{ .v = "hwb(0 0% 0%)", .r = 1, .g = 0, .b = 0 },
        .{ .v = "hwb(0 100% 0%)", .r = 1, .g = 1, .b = 1 },
        .{ .v = "oklch(1 0 0)", .r = 1, .g = 1, .b = 1 },
        .{ .v = "oklch(0 0 0)", .r = 0, .g = 0, .b = 0 },
        .{ .v = "oklab(1 0 0)", .r = 1, .g = 1, .b = 1 },
        .{ .v = "lab(100 0 0)", .r = 1, .g = 1, .b = 1 },
        .{ .v = "lab(0 0 0)", .r = 0, .g = 0, .b = 0 },
        .{ .v = "lch(100 0 0)", .r = 1, .g = 1, .b = 1 },
        .{ .v = "color-mix(in srgb, red, blue)", .r = 0.5, .g = 0, .b = 0.5 },
        .{ .v = "color-mix(in oklab, red 25%, blue)", .r = 0.25, .g = 0, .b = 0.75 },
        .{ .v = "color(srgb 1 0 0)", .r = 1, .g = 0, .b = 0 },
        .{ .v = "light-dark(red, blue)", .r = 1, .g = 0, .b = 0 },
        .{ .v = "transparent", .r = 0, .g = 0, .b = 0, .a = 0 },
        .{ .v = "Canvas", .r = 1, .g = 1, .b = 1 },
        .{ .v = "CanvasText", .r = 0, .g = 0, .b = 0 },
    };
    for (cases) |c| {
        var buf: [128]u8 = undefined;
        const p = try with(try std.fmt.bufPrint(&buf, "background-color: {s}", .{c.v}));
        defer p.done();
        const got = p.s("x").background;
        try near(got.r, c.r);
        try near(got.g, c.g);
        try near(got.b, c.b);
        try near(got.a, c.a);
    }
    const cur = try with("border: 1px solid; outline: 1px solid; background-color: currentcolor; box-shadow: 1px 1px");
    defer cur.done();
    const s = cur.s("x");
    try near(s.border_top.color.r, 1.0 / 255.0);
    try near(s.outline.color.g, 2.0 / 255.0);
    try near(s.background.b, 3.0 / 255.0);
    try near(s.shadow.?.color.r, 1.0 / 255.0);
}

test "box shorthands" {
    const p = try with("margin: 1px 2px 3px 4px; padding: 1px 2px; inset: 5px; border: 2px solid red; border-left: thin dotted blue; border-radius: 1px 2px 3px 50%; outline: 3px dashed lime");
    defer p.done();
    const s = p.s("x");
    try near(s.margin_top.px, 1);
    try near(s.margin_right.px, 2);
    try near(s.margin_bottom.px, 3);
    try near(s.margin_left.px, 4);
    try near(s.padding_top.px, 1);
    try near(s.padding_right.px, 2);
    try near(s.padding_bottom.px, 1);
    try near(s.padding_left.px, 2);
    try near(s.top.px, 5);
    try near(s.left.px, 5);
    try near(s.border_top.width, 2);
    try expect(s.border_top.style == .solid);
    try near(s.border_top.color.r, 1);
    try near(s.border_left.width, 1);
    try expect(s.border_left.style == .dotted);
    try near(s.radius[0], 1);
    try near(s.radius[2], 3);
    try near(s.radius_pct[3], 50);
    try near(s.outline.width, 3);
    try expect(s.outline.style == .dashed);

    const q = try with("margin: 0 auto; border-width: 1px 2px; border-style: solid none; border-color: red blue; margin-inline: 3px 4px; padding-block: 5px; width: fit-content; max-width: none; min-width: auto");
    defer q.done();
    const t = q.s("x");
    try expect(t.margin_right.kind == .length and t.margin_right.px == 4);
    try near(t.margin_left.px, 3);
    try near(t.border_top.width, 1);
    // No style means no width, whatever was written.
    try near(t.border_right.width, 0);
    try near(t.border_top.color.r, 1);
    try near(t.padding_top.px, 5);
    try expect(t.width.kind == .fit_content);
    try expect(t.max_width.kind == .none);

    const r = try with("border-style: solid");
    defer r.done();
    try near(r.s("x").border_top.width, 3);
    const u = try with("border: 0; margin: auto");
    defer u.done();
    try near(u.s("x").border_top.width, 0);
    try expect(u.s("x").margin_left.kind == .auto);
}

test "background" {
    const p = try with("background: #fff url(a.png) no-repeat right 10px bottom 20% / cover fixed");
    defer p.done();
    const s = p.s("x");
    try near(s.background.r, 1);
    try eq("https://x.test/a.png", s.background_image);
    try expect(s.background_repeat == .no_repeat);
    try near(s.background_x, 100);
    try near(s.background_x_px, -10);
    try near(s.background_y, 80);
    try expect(s.background_size == .cover);

    const q = try with("background: linear-gradient(to right, red, blue 50%, lime); background-size: 10px 20px; background-position: center top");
    defer q.done();
    const t = q.s("x");
    const g = t.background_gradient.?;
    try near(g.angle, 90);
    try expect(g.stops.len == 3);
    try near(g.stops[0].at, 0);
    try near(g.stops[1].at, 0.5);
    try near(g.stops[2].at, 1);
    try near(g.stops[2].color.g, 1);
    try near(t.background_size_x.px, 10);
    try near(t.background_size_y.px, 20);
    try near(t.background_x, 50);
    try near(t.background_y, 0);

    const a = try with("background-image: linear-gradient(135deg, rgba(0,0,0,0) 0%, #000 100%), url(\"b.png\"); background-repeat: repeat-x; background-color: red; background: none");
    defer a.done();
    try expect(a.s("x").background_gradient == null);
    try near(a.s("x").background.a, 0);

    const m = try with("background: url(a.png) center/50px, linear-gradient(red, blue), yellow");
    defer m.done();
    try eq("https://x.test/a.png", m.s("x").background_image);
    try near(m.s("x").background.g, 1);
    try near(m.s("x").background.b, 0);
    const k = try with("background-position: 25% 75%");
    defer k.done();
    try near(k.s("x").background_x, 25);
    try near(k.s("x").background_y, 75);
}

test "font shorthand and families" {
    const p = try with("font: italic bold 12px/1.5 Georgia, serif");
    defer p.done();
    const s = p.s("x");
    try expect(s.italic);
    try expect(s.font_weight == 700);
    try near(s.font_size, 12);
    try near(s.line_height, 18);
    try expect(s.serif and !s.mono);

    const Case = struct { v: []const u8, mono: bool, serif: bool };
    const fam = [_]Case{
        .{ .v = "monospace", .mono = true, .serif = false },
        .{ .v = "Menlo, Consolas, monospace", .mono = true, .serif = false },
        .{ .v = "'SF Mono', sans-serif", .mono = true, .serif = false },
        .{ .v = "\"Times New Roman\", Times", .mono = false, .serif = true },
        .{ .v = "serif", .mono = false, .serif = true },
        .{ .v = "'Linux Libertine','Georgia','Times',serif", .mono = false, .serif = true },
        .{ .v = "Arial, sans-serif", .mono = false, .serif = false },
        .{ .v = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto", .mono = false, .serif = false },
        .{ .v = "Verdana, Geneva, sans-serif", .mono = false, .serif = false },
        .{ .v = "UnknownFont", .mono = false, .serif = false },
    };
    for (fam) |c| {
        var buf: [128]u8 = undefined;
        const q = try with(try std.fmt.bufPrint(&buf, "font-family: {s}", .{c.v}));
        defer q.done();
        try expect(q.s("x").mono == c.mono);
        try expect(q.s("x").serif == c.serif);
    }
    const Kw = struct { d: []const u8, size: f32 };
    const sizes = [_]Kw{
        .{ .d = "font-size: small", .size = 13 },
        .{ .d = "font-size: x-large", .size = 24 },
        .{ .d = "font-size: larger", .size = 24 },
        .{ .d = "font-size: smaller", .size = 16.67 },
        .{ .d = "font-size: 10pt", .size = 13.33 },
        .{ .d = "font: 10px x", .size = 10 },
        .{ .d = "font: 150% x", .size = 30 },
    };
    for (sizes) |c| {
        const q = try with(c.d);
        defer q.done();
        try near(q.s("x").font_size, c.size);
    }
    const w = try with("font-weight: bold");
    defer w.done();
    try expect(w.s("x").font_weight == 700);
    const w2 = try with("font-weight: 650; font-style: oblique 10deg");
    defer w2.done();
    try expect(w2.s("x").font_weight == 650);
    try expect(w2.s("x").italic);
}

test "line height resolves and inherits as written" {
    const p = try Page.make("<!doctype html><body><div id=a style='font-size:10px;line-height:2'><div id=b style='font-size:20px'></div></div><div id=c style='font-size:10px;line-height:150%'><div id=d style='font-size:20px'></div></div><div id=e style='font-size:10px;line-height:2em'><div id=f style='font-size:20px;line-height:1.5em'></div></div><div id=g style='line-height:normal'></div><div id=h style='font-size:10px;line-height:12px'></div><div id=z style='line-height:0'></div>", "", vp);
    defer p.done();
    try near(p.s("a").line_height, 20);
    try near(p.s("b").line_height, 40);
    try near(p.s("c").line_height, 15);
    try near(p.s("d").line_height, 15);
    try near(p.s("e").line_height, 20);
    try near(p.s("f").line_height, 30);
    try near(p.s("g").line_height, 0);
    try near(p.s("h").line_height, 12);
    try expect(p.s("z").line_height > 0 and p.s("z").line_height < 0.01);
}

test "flex and alignment" {
    const Case = struct { d: []const u8, g: f32, sh: f32, basis: ?f32 };
    const cases = [_]Case{
        .{ .d = "1", .g = 1, .sh = 1, .basis = 0 },
        .{ .d = "2 3", .g = 2, .sh = 3, .basis = 0 },
        .{ .d = "2 3 10px", .g = 2, .sh = 3, .basis = 10 },
        .{ .d = "1 100px", .g = 1, .sh = 1, .basis = 100 },
        .{ .d = "auto", .g = 1, .sh = 1, .basis = null },
        .{ .d = "none", .g = 0, .sh = 0, .basis = null },
        .{ .d = "0 0 auto", .g = 0, .sh = 0, .basis = null },
        .{ .d = "1 1 0%", .g = 1, .sh = 1, .basis = 0 },
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        const p = try with(try std.fmt.bufPrint(&buf, "flex: {s}", .{c.d}));
        defer p.done();
        try near(p.s("x").flex_grow, c.g);
        try near(p.s("x").flex_shrink, c.sh);
        if (c.basis) |b| {
            try near(p.s("x").flex_basis.px, b);
        } else {
            try expect(p.s("x").flex_basis.kind == .auto);
        }
    }
    const p = try with("display: flex; flex-flow: column-reverse wrap; justify-content: space-between; align-items: flex-end; align-self: center; align-content: stretch; order: -2; gap: 1px 2px; place-items: center start; place-content: space-around center; place-self: end");
    defer p.done();
    const s = p.s("x");
    try expect(s.display == .flex);
    try expect(s.flex_direction == .column_reverse);
    try expect(s.flex_wrap == .wrap);
    try expect(s.justify_content == .center);
    try expect(s.align_content == .space_around);
    try expect(s.align_items == .center);
    try expect(s.justify_items == .start);
    try expect(s.align_self == .end);
    try expect(s.justify_self == .end);
    try expect(s.order == -2);
    try near(s.row_gap.px, 1);
    try near(s.column_gap.px, 2);
}

test "grid" {
    const p = try with("display: grid; grid-template-columns: 100px 1fr minmax(0, 2fr) 25%; grid-template-rows: repeat(2, 10px auto); grid-auto-rows: minmax(50px, auto); grid-auto-columns: 2fr; grid-column: 2 / span 3; grid-row: 1 / -1");
    defer p.done();
    const s = p.s("x");
    const c = s.grid_template_columns.tracks;
    try expect(c.len == 4);
    try expect(c[0].kind == .fixed);
    try near(c[0].px, 100);
    try expect(c[1].kind == .fr);
    try near(c[1].fr, 1);
    try expect(c[2].kind == .minmax);
    try near(c[2].fr, 2);
    try near(c[3].pct, 25);
    try expect(s.grid_template_columns.auto_repeat == -1);
    try expect(s.grid_template_rows.tracks.len == 4);
    try expect(s.grid_template_rows.tracks[1].kind == .auto);
    try near(s.grid_auto_rows.px, 50);
    try near(s.grid_auto_columns.fr, 2);
    try expect(s.grid_column.start == 2 and s.grid_column.span == 3);
    try expect(s.grid_row.start == 1 and s.grid_row.end == -1);

    const f = try with("grid-template-columns: 50px repeat(auto-fill, minmax(200px, 1fr))");
    defer f.done();
    const fl = f.s("x").grid_template_columns;
    try expect(fl.tracks.len == 2);
    try expect(fl.auto_repeat == 1);
    try near(fl.tracks[1].px, 200);
    try near(fl.tracks[1].fr, 1);

    const t = try with("grid-template: \"a b\" 10px \"c d\" 2fr / 1fr 30px; grid-area: 1 / 2 / 3 / 4");
    defer t.done();
    const ts = t.s("x");
    try expect(ts.grid_template_rows.tracks.len == 2);
    try near(ts.grid_template_rows.tracks[1].fr, 2);
    try near(ts.grid_template_columns.tracks[1].px, 30);
    try expect(ts.grid_row.start == 1 and ts.grid_row.end == 3);
    try expect(ts.grid_column.start == 2 and ts.grid_column.end == 4);

    const n = try with("grid-column: span 2; grid-row-start: 3; grid-row-end: span 4; grid-template-columns: none");
    defer n.done();
    try expect(n.s("x").grid_column.start == 0 and n.s("x").grid_column.span == 2);
    try expect(n.s("x").grid_row.start == 3 and n.s("x").grid_row.span == 4);
    try expect(n.s("x").grid_template_columns.tracks.len == 0);
    const fc = try with("grid-template-columns: fit-content(300px) [name] 1fr [end]");
    defer fc.done();
    try expect(fc.s("x").grid_template_columns.tracks.len == 2);
}

test "text, lists, overflow, misc" {
    const p = try with("text-align: center; text-decoration: underline line-through red; text-transform: uppercase; white-space: pre-wrap; letter-spacing: 2px; word-spacing: 1em; text-indent: 10%; vertical-align: middle; text-overflow: ellipsis; list-style: square inside; overflow: hidden scroll; cursor: pointer; pointer-events: none; opacity: 50%; z-index: 3; visibility: hidden; position: sticky; float: right; clear: both; box-sizing: border-box; object-fit: cover; aspect-ratio: 16 / 9; direction: rtl; border-collapse: collapse; border-spacing: 1px 2px; table-layout: fixed; caption-side: bottom; word-break: break-all; overflow-wrap: anywhere; tab-size: 4");
    defer p.done();
    const s = p.s("x");
    try expect(s.text_align == .center);
    try expect(s.underline and s.line_through and !s.overline);
    try near(s.text_decoration_color.?.r, 1);
    try expect(s.text_transform == .uppercase);
    try expect(s.white_space == .pre_wrap);
    try near(s.letter_spacing, 2);
    try near(s.word_spacing, 20);
    try near(s.text_indent.pct, 10);
    try expect(s.vertical_align == .middle);
    try expect(s.text_overflow_ellipsis);
    try expect(s.list_style == .square and s.list_inside);
    try expect(s.overflow_x == .hidden and s.overflow_y == .scroll);
    try expect(s.cursor == .pointer and !s.pointer_events);
    try near(s.opacity, 0.5);
    try expect(s.z_index.? == 3);
    try expect(s.visibility == .hidden and s.inherited_visibility == .hidden);
    try expect(s.position == .sticky and s.float == .right and s.clear == .both);
    try expect(s.box_sizing == .border_box and s.object_fit == .cover);
    try near(s.aspect_ratio, 16.0 / 9.0);
    try expect(s.rtl);
    try expect(s.border_collapse and s.table_fixed and s.caption_bottom);
    try near(s.border_spacing, 1);
    try near(s.border_spacing_y, 2);
    try expect(s.word_break_all and s.overflow_wrap_anywhere);
    try near(s.tab_size, 4);
    try expect(s.display == .block);

    const q = try with("overflow: hidden visible");
    defer q.done();
    try expect(q.s("x").overflow_y == .auto);
    const c = try with("display: flow-root; text-decoration: none; list-style: none; word-break: break-word");
    defer c.done();
    try expect(c.s("x").display == .block and c.s("x").flow_root);
    try expect(c.s("x").list_style == .none);
    try expect(c.s("x").overflow_wrap_anywhere and !c.s("x").word_break_all);
    const two = try with("display: inline flex");
    defer two.done();
    try expect(two.s("x").display == .inline_flex);
}

test "inherited properties reach children" {
    const p = try Page.make("<!doctype html><body><div id=a style='color:red;font-size:20px;font-weight:700;font-style:italic;font-family:monospace;letter-spacing:1px;text-align:right;white-space:pre;text-transform:uppercase;list-style:square;direction:rtl;visibility:hidden;cursor:pointer;border-collapse:collapse;border-spacing:3px;word-break:break-all;overflow-wrap:anywhere;caption-side:bottom;tab-size:2;width:9px;margin:9px;background:red;opacity:.5;border:1px solid'><span id=k></span></div>", "", vp);
    defer p.done();
    const s = p.s("k");
    try near(s.color.r, 1);
    try near(s.font_size, 20);
    try expect(s.font_weight == 700 and s.italic and s.mono);
    try near(s.letter_spacing, 1);
    try expect(s.text_align == .right and s.white_space == .pre and s.text_transform == .uppercase);
    try expect(s.list_style == .square and s.rtl and s.visibility == .hidden and s.inherited_visibility == .hidden);
    try expect(s.cursor == .pointer and s.border_collapse);
    try near(s.border_spacing, 3);
    try expect(s.word_break_all and s.overflow_wrap_anywhere and s.caption_bottom);
    try near(s.tab_size, 2);
    // And these do not.
    try expect(s.width.kind == .auto);
    try near(s.margin_top.px, 0);
    try near(s.background.a, 0);
    try near(s.opacity, 1);
    try near(s.border_top.width, 0);
}

test "transform and shadow" {
    const p = try with("transform: translate(1px, 50%) translateX(2px) translateY(3px) rotate(45deg) scale(2); box-shadow: 1px 2px 3px 4px red, 9px 9px blue");
    defer p.done();
    const s = p.s("x");
    const t = s.transform.?;
    try expect(t.ops.len == 5);
    try near(t.ops[0].translate.y.pct, 50);
    try near(t.ops[1].translate.x.px, 2);
    try near(t.ops[3].rotate, 45);
    try near(t.ops[4].scale[1], 2);
    try expect(s.shadows.len == 2);
    const sh = s.shadow.?;
    try near(sh.x, 1);
    try near(sh.y, 2);
    try near(sh.blur, 3);
    try near(sh.spread, 4);
    try near(sh.color.r, 1);
    const n = try with("transform: translateX(1px); transform: none; box-shadow: 1px 1px; box-shadow: none");
    defer n.done();
    try expect(n.s("x").transform == null);
    try expect(n.s("x").shadow == null);
    // Tailwind's empty ring layers come before the real shadow.
    const tw = try with("--a: 0 0 #0000; --b: 0 1px 2px rgb(0 0 0 / 0.5); box-shadow: var(--a), var(--a), var(--b)");
    defer tw.done();
    try near(tw.s("x").shadow.?.y, 1);
    try near(tw.s("x").shadow.?.color.a, 0.5);
    const ins = try with("box-shadow: inset 0 0 1px red, 2px 2px blue");
    defer ins.done();
    try near(ins.s("x").shadow.?.x, 2);
}

test "fallback declarations and vendor forms" {
    const p = try with("display: block; display: -webkit-box; color: rgb(1,2,3); color: nonsense(1); width: 1px; width: 1foo; height: 1px; height: 1; text-align: -webkit-center; -webkit-box-shadow: 1px 1px red; margin: 1px 2px 3px 4px 5px; top: 1px; top: red");
    defer p.done();
    const s = p.s("x");
    try expect(s.display == .block);
    try near(s.color.r, 1.0 / 255.0);
    try near(s.width.px, 1);
    try near(s.height.px, 1);
    try expect(s.text_align == .center);
    try expect(s.shadow != null);
    try near(s.margin_top.px, 0);
    try near(s.top.px, 1);
}

test "background layers, clips and gradient shapes" {
    const eqc = std.testing.expectEqual;
    const b = try with("background: linear-gradient(red, red) padding-box, linear-gradient(blue, blue) border-box");
    defer b.done();
    try eqc(style.BackgroundClip.padding_box, b.s("x").background_clip);
    try eqc(@as(usize, 1), b.s("x").background_more.len);
    try eqc(style.BackgroundClip.border_box, b.s("x").background_more[0].clip);
    const r = try with("background: radial-gradient(closest-side, red, transparent)");
    defer r.done();
    try eqc(style.GradientShape.radial, r.s("x").background_gradient.?.shape);
    try near(r.s("x").background_gradient.?.rx, 0.5);
    const at = try with("background-image: radial-gradient(circle at 25% 0, red, blue)");
    defer at.done();
    try near(at.s("x").background_gradient.?.cx, 0.25);
    try near(at.s("x").background_gradient.?.cy, 0);
    const k = try with("background-image: conic-gradient(from 90deg, red, blue)");
    defer k.done();
    try eqc(style.GradientShape.conic, k.s("x").background_gradient.?.shape);
    try near(k.s("x").background_gradient.?.angle, 90);
    const text = try with("background: linear-gradient(red, blue); -webkit-background-clip: text; color: transparent");
    defer text.done();
    try expect(text.s("x").background_gradient != null);
    try expect(text.s("x").background_clip == .text);
    const many = try with("background-image: url(a.png), url(b.png), url(c.png)");
    defer many.done();
    try eqc(@as(usize, 2), many.s("x").background_more.len);
}
