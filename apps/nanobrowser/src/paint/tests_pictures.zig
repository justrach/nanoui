//! Inline SVG and pictures, as pages show them: `data:` pages through the whole
//! browser, read back as rendered pixels.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const util = @import("../web/tests_util.zig");
const testing = std.testing;
const Run = util.Run;

const Pixels = @typeInfo(@typeInfo(@TypeOf(ui.Tester.render)).@"fn".return_type.?).error_union.payload;

/// What's on the page: the browser's window, pixels at (x, y) of the page.
const Shot = struct {
    px: Pixels,
    ox: usize,
    oy: usize,
    scale: usize,

    fn at(s: Shot, x: usize, y: usize) [4]u8 {
        return s.px.bytes[((s.oy + y * s.scale) * s.px.width + s.ox + x * s.scale) * 4 ..][0..4].*;
    }

    fn isRed(s: Shot, x: usize, y: usize) bool {
        const c = s.at(x, y);
        return c[2] > 200 and c[1] < 60 and c[0] < 60;
    }

    fn isGreen(s: Shot, x: usize, y: usize) bool {
        const c = s.at(x, y);
        return c[1] > 100 and c[2] < 60 and c[0] < 60;
    }

    fn isBlue(s: Shot, x: usize, y: usize) bool {
        const c = s.at(x, y);
        return c[0] > 200 and c[1] < 60 and c[2] < 60;
    }

    fn isWhite(s: Shot, x: usize, y: usize) bool {
        const c = s.at(x, y);
        return c[0] > 240 and c[1] > 240 and c[2] > 240;
    }

    fn deinit(s: Shot) void {
        s.px.deinit(testing.allocator);
    }
};

/// Where the page starts in the window, found by a marker the page puts at its
/// corner: the shell's chrome is above and beside it.
fn shot(r: *Run) !Shot {
    r.settle();
    r.spin(0.02);
    r.settle();
    const px = try r.t.render(testing.allocator);
    const scale: usize = @intFromFloat(r.t.scale);
    const origin = r.page().origin;
    return .{ .px = px, .ox = @as(usize, @intFromFloat(origin[0])) * scale, .oy = @as(usize, @intFromFloat(origin[1])) * scale, .scale = scale };
}

fn start(r: *Run, source: []const u8) !void {
    try r.start();
    try r.html(source);
}

const body = "<!doctype html><body style='margin:0;background:#fff'>";

test "currentColor is the element's color, however the page sets it" {
    var r: Run = undefined;
    try start(&r, body ++
        \\<style>.a{color:#ff0000}.b{fill:#0000ff}</style>
        \\<svg class=a viewBox="0 0 10 10" style="position:absolute;left:0;top:0;width:20px;height:20px"><rect width="10" height="10" fill="currentColor"/></svg>
        \\<svg class=b viewBox="0 0 10 10" style="position:absolute;left:30px;top:0;width:20px;height:20px"><rect width="10" height="10"/></svg>
        \\<svg viewBox="0 0 10 10" style="position:absolute;left:60px;top:0;width:20px;height:20px;color:#00ff00"><path style="fill:currentColor" d="M0 0H10V10H0z"/></svg>
    );
    defer r.stop();
    const s = try shot(&r);
    defer s.deinit();
    try testing.expect(s.isRed(10, 10));
    try testing.expect(s.isBlue(40, 10));
    try testing.expect(s.isGreen(70, 10));
}

test "a viewBox alone doesn't size it: it fills its parent, as Chromium does" {
    var r: Run = undefined;
    try start(&r, body ++
        \\<div id=w style="width:24px;height:24px"><svg id=a viewBox="0 -960 960 960"><path d="M0 0V-960H960V0z" fill="#f00"/></svg></div>
        \\<div style="width:200px"><svg id=b viewBox="0 0 24 12"></svg></div>
        \\<div style="width:200px"><svg id=c></svg></div>
        \\<div style="display:inline-block"><svg id=d viewBox="0 0 24 12"></svg></div>
        \\<div style="display:flex;width:400px"><svg id=e viewBox="0 0 24 12"></svg></div>
        \\<div style="font-size:20px"><svg id=f width="1em" height="1em" viewBox="0 0 24 24"></svg></div>
        \\<div style="width:200px"><svg id=g width="50%" viewBox="0 0 24 24"></svg></div>
    );
    defer r.stop();
    try util.table(&r, &.{
        .{ .js = "a.getBoundingClientRect().width + 'x' + a.getBoundingClientRect().height", .want = "24x24" },
        .{ .js = "b.getBoundingClientRect().width + 'x' + b.getBoundingClientRect().height", .want = "200x100" },
        .{ .js = "c.getBoundingClientRect().width + 'x' + c.getBoundingClientRect().height", .want = "300x150" },
        .{ .js = "d.getBoundingClientRect().width + 'x' + d.getBoundingClientRect().height", .want = "0x0" },
        .{ .js = "e.getBoundingClientRect().width + 'x' + e.getBoundingClientRect().height", .want = "400x200" },
        .{ .js = "f.getBoundingClientRect().width + 'x' + f.getBoundingClientRect().height", .want = "20x20" },
        .{ .js = "g.getBoundingClientRect().width + 'x' + g.getBoundingClientRect().height", .want = "100x100" },
    });
    // The icon is drawn in its 24, not as a block 960 wide over the page.
    const s = try shot(&r);
    defer s.deinit();
    try testing.expect(s.isRed(12, 12));
    try testing.expect(s.isWhite(40, 12));
}

test "sprites that are only holders draw nothing, and their use draws" {
    var r: Run = undefined;
    try start(&r, body ++
        \\<svg style="display:none"><symbol id="hid" viewBox="0 0 10 10"><rect width="10" height="10"/></symbol></svg>
        \\<svg width="0" height="0" style="position:absolute"><defs><symbol id="zero" viewBox="0 0 10 10"><rect width="10" height="10" fill="#0f0"/></symbol></defs></svg>
        \\<svg hidden width=50 height=50><rect width="50" height="50"/></svg>
        \\<svg viewBox="0 0 10 10" fill="#f00" style="position:absolute;left:0;top:100px;width:20px;height:20px"><use href="#hid"/></svg>
        \\<svg viewBox="0 0 10 10" style="position:absolute;left:30px;top:100px;width:20px;height:20px"><use xlink:href="#zero"/></svg>
    );
    defer r.stop();
    const s = try shot(&r);
    defer s.deinit();
    // Nothing where the holders are.
    try testing.expect(s.isWhite(5, 5));
    try testing.expect(s.isWhite(25, 25));
    // Inherited through the use, from a sprite under display:none.
    try testing.expect(s.isRed(10, 110));
    try testing.expect(s.isGreen(40, 110));
}

test "a gradient and a clip path from another svg in the document" {
    var r: Run = undefined;
    try start(&r, body ++
        \\<svg width=0 height=0 style="position:absolute"><linearGradient id="g"><stop stop-color="#0000ff"/><stop offset="1" stop-color="#0000ff"/></linearGradient><clipPath id="c"><rect width="5" height="10"/></clipPath></svg>
        \\<svg viewBox="0 0 10 10" style="position:absolute;left:0;top:0;width:20px;height:20px"><rect width="10" height="10" fill="url(#g)" clip-path="url(#c)"/></svg>
    );
    defer r.stop();
    const s = try shot(&r);
    defer s.deinit();
    try testing.expect(s.isBlue(4, 10));
    try testing.expect(s.isWhite(15, 10));
}

test "stylesheets reach descendants: strokes, opacity, display" {
    var r: Run = undefined;
    try start(&r, body ++
        \\<style>.line{stroke:#ff0000;stroke-width:10;fill:none}.gone{display:none}.half{opacity:.5}svg rect.x{fill:#00ff00}</style>
        \\<svg viewBox="0 0 40 10" style="position:absolute;left:0;top:0;width:40px;height:10px">
        \\<path class=line d="M0 5H10"/><rect class=gone x=10 width=10 height=10 /><rect class=x x=20 width=10 height=10 /><rect class=half x=30 width=10 height=10 fill="#000"/></svg>
    );
    defer r.stop();
    const s = try shot(&r);
    defer s.deinit();
    try testing.expect(s.isRed(5, 5));
    try testing.expect(s.isWhite(15, 5));
    try testing.expect(s.isGreen(25, 5));
    const half = s.at(35, 5);
    try testing.expect(half[0] > 110 and half[0] < 145);
}

test "scripts changing an svg or its color draw it again" {
    var r: Run = undefined;
    try start(&r, body ++
        \\<div id=box style="color:#ff0000"><svg id=i viewBox="0 0 10 10" style="position:absolute;left:0;top:0;width:20px;height:20px"><rect id=rc width="10" height="10" fill="currentColor"/></svg></div>
    );
    defer r.stop();
    {
        const s = try shot(&r);
        defer s.deinit();
        try testing.expect(s.isRed(10, 10));
    }
    _ = try r.eval("box.style.color = '#0000ff'; 0");
    {
        const s = try shot(&r);
        defer s.deinit();
        try testing.expect(s.isBlue(10, 10));
    }
    _ = try r.eval("rc.setAttribute('fill', '#00ff00'); 0");
    {
        const s = try shot(&r);
        defer s.deinit();
        try testing.expect(s.isGreen(10, 10));
    }
    // Replaced whole, as an icon component does.
    _ = try r.eval("i.innerHTML = '<rect width=\"10\" height=\"10\" fill=\"#ff0000\"/>'; 0");
    {
        const s = try shot(&r);
        defer s.deinit();
        try testing.expect(s.isRed(10, 10));
    }
}

test "a custom element that makes its svg with scripts, as yt-icon does" {
    var r: Run = undefined;
    try start(&r, body ++
        \\<div style="color:#ff0000"><my-icon style="display:block;position:absolute;left:0;top:0;width:20px;height:20px"></my-icon></div>
        \\<script>
        \\customElements.define('my-icon', class extends HTMLElement { connectedCallback() {
        \\  const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        \\  s.setAttribute('viewBox', '0 0 10 10');
        \\  s.setAttribute('style', 'display:block;width:100%;height:100%;fill:currentcolor');
        \\  const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
        \\  p.setAttribute('d', 'M0 0H10V10H0z');
        \\  s.appendChild(p);
        \\  this.appendChild(s);
        \\}});
        \\</script>
    );
    defer r.stop();
    const s = try shot(&r);
    defer s.deinit();
    try testing.expect(s.isRed(10, 10));
}

const data_svg = "data:image/svg+xml,";

test "an external svg in an img and in a background" {
    var r: Run = undefined;
    const rect = "%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'%3E%3Crect width='10' height='10' fill='%23ff0000'/%3E%3C/svg%3E";
    try start(&r, body ++ "<img id=a src=\"" ++ data_svg ++ rect ++ "\" style='position:absolute;left:0;top:0;width:20px;height:20px'>" ++
        "<div style=\"position:absolute;left:30px;top:0;width:45px;height:20px;background:url(&quot;" ++ data_svg ++ rect ++ "&quot;) 0 0/15px 20px repeat-x\"></div>" ++
        "<div style=\"position:absolute;left:0;top:30px;width:40px;height:20px;background:url(&quot;" ++ data_svg ++ rect ++ "&quot;) no-repeat\"></div>");
    defer r.stop();
    const s = try shot(&r);
    defer s.deinit();
    try testing.expect(s.isRed(10, 10));
    // Tiled across, not once.
    try testing.expect(s.isRed(35, 10));
    try testing.expect(s.isRed(50, 10));
    try testing.expect(s.isRed(70, 10));
    // A shape with no size of its own fits the box whole: 20 of the 40 wide,
    // centered by nothing, at the corner its position says.
    try testing.expect(s.isRed(10, 40));
    try testing.expect(s.isWhite(30, 40));
    try r.expectJs("a.naturalWidth", "10");
}

/// A PNG `w` × `h` of stripes one pixel wide, as a data: address.
fn stripesUrl(a: std.mem.Allocator, w: u32, h: u32) ![]const u8 {
    const raw = try a.alloc(u8, @as(usize, w) * h * 4);
    defer a.free(raw);
    for (0..h) |y| for (0..w) |x| {
        const v: u8 = if (x % 2 == 0) 255 else 0;
        raw[(y * w + x) * 4 ..][0..4].* = .{ v, v, v, 255 };
    };
    const png = try ui.png.encode(a, .{ .bytes = raw, .width = w, .height = h });
    defer a.free(png);
    const enc = std.base64.standard.Encoder;
    const out = try a.alloc(u8, enc.calcSize(png.len) + 22);
    @memcpy(out[0..22], "data:image/png;base64,");
    _ = enc.encode(out[22..], png);
    return out;
}

test "a picture a window wide at 2x keeps its pixels" {
    const gpa = testing.allocator;
    const url = try stripesUrl(gpa, 1600, 8);
    defer gpa.free(url);
    const src = try std.fmt.allocPrint(gpa, body ++ "<img src=\"{s}\" style=\"display:block;width:800px;height:4px\">", .{url});
    defer gpa.free(src);
    var r: Run = undefined;
    r.b = .{ .gpa = gpa };
    try r.b.init();
    try r.t.init(gpa, ui.View.init(&r.b, @import("../shell/browser.zig").Browser.view), .{ .width = 900, .height = 600, .scale = 2 });
    defer r.stop();
    try r.html(src);
    const s = try shot(&r);
    defer s.deinit();
    // Neighbouring pixels of the window are neighbouring columns of the picture.
    const row = (s.oy + 2) * s.px.width;
    const a = s.px.bytes[(row + s.ox + 800) * 4];
    const b = s.px.bytes[(row + s.ox + 801) * 4];
    try testing.expect((a > 230 and b < 25) or (a < 25 and b > 230));
}

test "srcset's density sets the natural size; a source for another size is passed over" {
    const gpa = testing.allocator;
    const url = try stripesUrl(gpa, 40, 20);
    defer gpa.free(url);
    const src = try std.fmt.allocPrint(gpa, body ++
        \\<img id=a srcset="{s} 2x">
        \\<picture><source media="(min-width: 5000px)" srcset="data:,no"><source type="image/x-nothing" srcset="data:,no"><source id=s srcset="{s} 1x"><img id=b src="data:,no"></picture>
        \\<img id=c src="{s}" style="width:100px;height:20px;object-fit:none;object-position:left">
    , .{ url, url, url });
    defer gpa.free(src);
    var r: Run = undefined;
    try start(&r, src);
    defer r.stop();
    try util.table(&r, &.{
        .{ .js = "a.getBoundingClientRect().width", .want = "20" },
        .{ .js = "a.naturalWidth", .want = "20" },
        .{ .js = "b.getBoundingClientRect().width", .want = "40" },
    });
}

test "a lazy picture is asked for near the window, not before" {
    const gpa = testing.allocator;
    const url = try stripesUrl(gpa, 4, 4);
    defer gpa.free(url);
    const src = try std.fmt.allocPrint(gpa, body ++
        \\<img id=near loading=lazy src="{s}" width=4 height=4>
        \\<div style="height:5000px"></div>
        \\<img id=far loading=lazy src="{s}" width=4 height=4 alt=x>
    , .{ url, url });
    defer gpa.free(src);
    var r: Run = undefined;
    try start(&r, src);
    defer r.stop();
    r.settle();
    try r.expectJs("near.currentSrc.length > 0", "true");
    try r.expectJs("far.currentSrc.length", "0");
    _ = try r.eval("window.scrollTo(0, 4800); 0");
    r.settle();
    r.t.frame();
    try r.waitJs("far.currentSrc.length > 0");
}

test "object-position and object-fit none show the part they say" {
    // Left half red, right half blue, shown at its own size in a narrow box.
    const svg = "%3Csvg xmlns='http://www.w3.org/2000/svg' width='40' height='10'%3E%3Crect width='20' height='10' fill='%23ff0000'/%3E%3Crect x='20' width='20' height='10' fill='%230000ff'/%3E%3C/svg%3E";
    var r: Run = undefined;
    try start(&r, body ++ "<img src=\"" ++ data_svg ++ svg ++ "\" style='position:absolute;left:0;top:0;width:20px;height:10px;object-fit:none;object-position:left'>" ++
        "<img src=\"" ++ data_svg ++ svg ++ "\" style='position:absolute;left:30px;top:0;width:20px;height:10px;object-fit:none;object-position:right'>");
    defer r.stop();
    const s = try shot(&r);
    defer s.deinit();
    try testing.expect(s.isRed(15, 5));
    try testing.expect(s.isBlue(35, 5));
}
