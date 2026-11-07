//! Boxes and effects drawn as Chromium draws them, pixels and geometry asserted:
//! whole pages from `data:` addresses through the browser, in a Tester.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const util = @import("../web/tests_util.zig");
const testing = std.testing;
const Run = util.Run;

test {
    _ = @import("tests_motion.zig");
    _ = @import("tests_pointer.zig");
    _ = @import("tests_scrolling.zig");
    _ = @import("tests_canvas.zig");
    _ = @import("tests_resize.zig");
    _ = @import("tests_sheets.zig");
    _ = @import("tests_forms.zig");
}

pub fn page(r: *Run, body: []const u8) !void {
    const gpa = testing.allocator;
    const src = try std.fmt.allocPrint(gpa, "<!doctype html><html><head><style>html,body{{margin:0;background:#fff}}</style></head><body>{s}", .{body});
    defer gpa.free(src);
    try r.html(src);
    r.t.frame();
    r.t.frame();
}

/// Where the page's rectangle starts in the window.
fn origin(r: *Run) [2]f32 {
    return r.page().origin;
}

/// BGRA at (x, y) of the page.
pub fn pixel(r: *Run, x: f32, y: f32) ![4]u8 {
    const gpa = testing.allocator;
    const o = origin(r);
    const shown = try r.t.render(gpa);
    defer shown.deinit(gpa);
    const px: usize = @intFromFloat((o[0] + x) * r.t.scale);
    const py: usize = @intFromFloat((o[1] + y) * r.t.scale);
    return shown.bytes[(py * shown.width + px) * 4 ..][0..4].*;
}

pub fn isRed(p: [4]u8) bool {
    return p[2] > 200 and p[1] < 60 and p[0] < 60;
}
pub fn isBlue(p: [4]u8) bool {
    return p[0] > 200 and p[1] < 60 and p[2] < 60;
}
pub fn isGreen(p: [4]u8) bool {
    return p[1] > 110 and p[0] < 60 and p[2] < 60;
}
pub fn isWhite(p: [4]u8) bool {
    return p[0] > 235 and p[1] > 235 and p[2] > 235;
}

pub fn expectEqJs(r: *Run, src: []const u8, want: []const u8) !void {
    return r.expectJs(src, want);
}

fn expectAt(r: *Run, x: f32, y: f32, comptime is: fn ([4]u8) bool, what: []const u8) !void {
    const p = try pixel(r, x, y);
    if (!is(p)) {
        std.debug.print("\nat {d},{d}: wanted {s}, got BGRA {any}\n", .{ x, y, what, p });
        return error.TestFailed;
    }
}

test "stacking: what's positioned in a box with no z-index stacks with its context" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    // Apple's hero: the copy is z-index 2 in a positioned box with none; a picture after that box must not cover it.
    try page(&r,
        \\<div style='position:relative'><div id=copy style='position:relative;z-index:2;width:50px;height:50px;background:#f00'></div></div>
        \\<div id=pic style='position:absolute;left:0;top:0;width:100px;height:100px;background:#00f'></div>
    );
    try expectAt(&r, 25, 25, isRed, "the copy, over the later picture");
    try expectAt(&r, 75, 75, isBlue, "the picture");
    try r.expectJs("document.elementFromPoint(25, 25).id", "copy");
    // With a z-index of its own, or `isolation`, it is a context and holds it in.
    try page(&r,
        \\<div style='position:relative;z-index:0'><div style='position:relative;z-index:2;width:50px;height:50px;background:#f00'></div></div>
        \\<div style='position:absolute;left:0;top:0;width:100px;height:100px;background:#00f'></div>
    );
    try expectAt(&r, 25, 25, isBlue, "held in by its context");
    try page(&r,
        \\<div style='isolation:isolate'><div style='position:relative;z-index:2;width:50px;height:50px;background:#f00'></div></div>
        \\<div style='position:absolute;left:0;top:0;width:100px;height:100px;background:#00f'></div>
    );
    try expectAt(&r, 25, 25, isBlue, "isolated");
    // A negative z-index goes under a box with none, but not under its context's own background.
    try page(&r,
        \\<div style='position:relative;z-index:0;background:#00f;width:100px;height:100px'><div style='position:relative;width:60px;height:60px'><div style='position:absolute;z-index:-1;width:50px;height:50px;background:#f00'></div></div></div>
    );
    try expectAt(&r, 25, 25, isRed, "over the context's background");
}

test "@property: Tailwind's rings and borders, which read registered starting values" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r,
        \\<style>@property --tw-ring { syntax: "*"; inherits: false; initial-value: 0 0 #0000 }
        \\@property --tw-shadow { syntax: "*"; inherits: false; initial-value: 0 0 #0000 }
        \\@property --tw-border-style { syntax: "*"; inherits: false; initial-value: solid }
        \\@property --kept { syntax: "<color>"; inherits: true; initial-value: #00f }
        \\.ring { --tw-ring: 0 0 0 4px #f00; box-shadow: var(--tw-ring), var(--tw-shadow) }
        \\.line { border-bottom: 4px; border-bottom-style: var(--tw-border-style); border-bottom-color: #f00; height: 10px }
        \\.kept { background: var(--kept) }</style>
        \\<div class=ring style='position:absolute;left:20px;top:20px;width:40px;height:40px'><div class=ring style='--tw-ring:0 0 #0000;width:20px;height:20px'></div></div>
        \\<div class=ring style='position:absolute;left:100px;top:20px;width:40px;height:40px'><div id=child style='width:20px;height:20px;box-shadow:var(--tw-ring)'></div></div>
        \\<div class=line style='position:absolute;left:200px;top:0;width:40px'></div>
        \\<div class=kept style='position:absolute;left:300px;top:0;width:40px;height:40px'></div>
    );
    try expectAt(&r, 18, 40, isRed, "the ring");
    try expectAt(&r, 40, 50, isWhite, "the box");
    // Not inherited: what the parent set doesn't reach its child.
    try expectAt(&r, 122, 40, isWhite, "no ring on the child");
    try expectAt(&r, 220, 12, isRed, "a border whose style is registered");
    try expectAt(&r, 320, 20, isBlue, "a registered color with no declaration");
}

test "corners of their own: a box round on one side only" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<div style='position:absolute;left:10px;top:10px;width:100px;height:60px;background:#f00;border-radius:30px 0 0 30px'></div>");
    // The right corners are square, the left ones cut.
    try expectAt(&r, 108, 12, isRed, "square top right");
    try expectAt(&r, 108, 67, isRed, "square bottom right");
    try expectAt(&r, 12, 12, isWhite, "cut top left");
    try expectAt(&r, 12, 67, isWhite, "cut bottom left");
    try expectAt(&r, 15, 40, isRed, "the left's middle");
}

test "elliptical corners and percentages" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<div style='position:absolute;left:0;top:0;width:200px;height:50px;background:#f00;border-radius:50%'></div>");
    // An ellipse: filled through its middle, its corner gone, more gone than a pill's.
    try expectAt(&r, 100, 25, isRed, "its middle");
    try expectAt(&r, 2, 25, isRed, "its left end");
    try expectAt(&r, 20, 3, isWhite, "above the curve near its end");
    try expectAt(&r, 100, 3, isRed, "the top of its middle");
    // Radii past the box shrink: a pill.
    try page(&r, "<div style='position:absolute;left:0;top:0;width:200px;height:50px;background:#00f;border-radius:999px'></div>");
    try expectAt(&r, 2, 2, isWhite, "the pill's corner");
    try expectAt(&r, 30, 2, isBlue, "the pill's top");
}

test "a rounded border follows its corners" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<div style='position:absolute;left:0;top:0;width:100px;height:60px;box-sizing:border-box;border:4px solid #f00;border-radius:20px'></div>");
    try expectAt(&r, 2, 2, isWhite, "outside the corner");
    try expectAt(&r, 50, 2, isRed, "the top side");
    try expectAt(&r, 50, 30, isWhite, "inside");
    // On the curve: the corner's center is 20, 20 and its radius 20 to 16.
    try expectAt(&r, 7, 7, isRed, "the corner's curve");
}

test "a CSS triangle: mitered sides" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<div style='position:absolute;left:0;top:0;width:0;height:0;border-left:40px solid transparent;border-right:40px solid transparent;border-bottom:40px solid #f00'></div>");
    // Its point at the top middle, wide at its foot.
    try expectAt(&r, 40, 38, isRed, "low in the middle");
    try expectAt(&r, 5, 38, isRed, "near the foot's left");
    try expectAt(&r, 75, 38, isRed, "near the foot's right");
    try expectAt(&r, 5, 5, isWhite, "beside the point");
    try expectAt(&r, 75, 5, isWhite, "beside the point");
    try expectAt(&r, 40, 8, isRed, "near the point");
}

test "sides of different colors meet on the diagonal" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<div style='position:absolute;left:0;top:0;width:60px;height:60px;box-sizing:border-box;border:20px solid;border-color:#f00 #00f'></div>");
    try expectAt(&r, 30, 5, isRed, "the top");
    try expectAt(&r, 5, 30, isBlue, "the left");
    // Either side of the top left's diagonal.
    try expectAt(&r, 15, 5, isRed, "above the diagonal");
    try expectAt(&r, 5, 15, isBlue, "below the diagonal");
}

test "dashed, double and 3D borders" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<div style='position:absolute;left:0;top:0;width:200px;height:40px;box-sizing:border-box;border:6px dashed #f00'></div>");
    // A dash at each end of a side, and a gap somewhere between.
    var gaps: u32 = 0;
    var dashes: u32 = 0;
    var x: f32 = 12;
    while (x < 190) : (x += 2) {
        const p = try pixel(&r, x, 3);
        if (isRed(p)) dashes += 1;
        if (isWhite(p)) gaps += 1;
    }
    try testing.expect(dashes > 10);
    try testing.expect(gaps > 10);
    try page(&r, "<div style='position:absolute;left:0;top:0;width:100px;height:100px;box-sizing:border-box;border:9px double #f00'></div>");
    try expectAt(&r, 50, 1, isRed, "the outer line");
    try expectAt(&r, 50, 4, isWhite, "between the lines");
    try expectAt(&r, 50, 7, isRed, "the inner line");
    try page(&r, "<div style='position:absolute;left:0;top:0;width:100px;height:100px;box-sizing:border-box;border:8px inset #808080'></div>");
    const top = try pixel(&r, 50, 4);
    const bottom = try pixel(&r, 50, 96);
    try testing.expect(top[0] < bottom[0]);
}

test "several shadows, a ring, and shadows inside" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<div style='position:absolute;left:30px;top:30px;width:60px;height:60px;box-shadow:0 0 0 4px #f00, 0 0 0 8px #00f'></div>");
    try expectAt(&r, 28, 60, isRed, "the first ring, nearest");
    try expectAt(&r, 24, 60, isBlue, "the second ring");
    try expectAt(&r, 18, 60, isWhite, "past them");
    try expectAt(&r, 60, 60, isWhite, "not under the box");
    try page(&r, "<div style='position:absolute;left:10px;top:10px;width:100px;height:100px;background:#fff;box-shadow:inset 0 0 0 5px #f00, inset 10px 0 0 0 #00f'></div>");
    try expectAt(&r, 12, 60, isRed, "the inset ring");
    try expectAt(&r, 17, 60, isBlue, "the offset inset, within");
    try expectAt(&r, 60, 60, isWhite, "the middle");
    // A blurred inset: dark at the edge, clear in the middle.
    try page(&r, "<div style='position:absolute;left:10px;top:10px;width:100px;height:100px;box-shadow:inset 0 0 20px #000'></div>");
    const edge = try pixel(&r, 12, 60);
    const mid = try pixel(&r, 60, 60);
    try testing.expect(edge[1] < 170);
    try testing.expect(mid[1] > 240);
}

test "text-shadow, and an outline's offset" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<div style='position:absolute;left:10px;top:10px;font-size:40px;color:#fff;text-shadow:2px 2px 0 #f00'>MMM</div>");
    var red: u32 = 0;
    var y: f32 = 10;
    while (y < 60) : (y += 2) {
        var x: f32 = 10;
        while (x < 100) : (x += 2) {
            if (isRed(try pixel(&r, x, y))) red += 1;
        }
    }
    try testing.expect(red > 10);
    try page(&r, "<div style='position:absolute;left:20px;top:20px;width:40px;height:40px;outline:2px solid #f00;outline-offset:4px'></div>");
    try expectAt(&r, 15, 40, isRed, "the outline, off the box");
    try expectAt(&r, 18, 40, isWhite, "its offset");
}

test "hidden: clip, clip-path and visibility take no clicks and show nothing" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r,
        \\<div style='position:absolute;left:0;top:0;width:50px;height:50px;background:#0f0'>base</div>
        \\<div id=a style='position:absolute;left:0;top:0;width:50px;height:50px;background:#f00;clip:rect(0 0 0 0)'></div>
        \\<div id=b style='position:absolute;left:0;top:0;width:50px;height:50px;background:#f00;clip-path:inset(50%)'></div>
        \\<div id=c style='position:absolute;left:0;top:0;width:50px;height:50px;background:#f00;visibility:hidden'></div>
        \\<div id=d style='position:absolute;left:100px;top:0;width:50px;height:50px;background:#f00;clip-path:circle(50%)'></div>
        \\<div id=e style='position:absolute;left:200px;top:0;width:50px;height:50px;background:#f00;clip-path:polygon(0 0,100% 0,0 100%)'></div>
    );
    try expectAt(&r, 25, 25, isGreen, "what's under them");
    try r.expectJs("document.elementFromPoint(25, 25).textContent", "base");
    // Through the circle's corner to nothing; on it, it.
    try expectAt(&r, 102, 2, isWhite, "a circle's corner");
    try expectAt(&r, 125, 25, isRed, "a circle's middle");
    try r.expectJs("document.elementFromPoint(125, 25).id", "d");
    try r.expectJs("document.elementFromPoint(102, 2).tagName", "HTML");
    // A polygon is drawn as itself, and hit as itself.
    try expectAt(&r, 205, 5, isRed, "inside the triangle");
    try expectAt(&r, 245, 45, isWhite, "beyond its long side");
    try r.expectJs("document.elementFromPoint(205, 5).id", "e");
    try r.expectJs("document.elementFromPoint(245, 45).tagName", "HTML");
}

test "transforms turn all a box holds, and geometry and the pointer follow" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<div id=a style='position:absolute;left:50px;top:50px;width:100px;height:20px;background:#f00;transform:rotate(90deg)'><div id=in style='margin-left:80px;width:20px;height:20px;background:#00f'></div></div>");
    // Tall now, about its middle (100, 60): x 90 to 110, y 10 to 110. The child, at its right end, is at the bottom.
    try expectAt(&r, 100, 20, isRed, "top of the turned box");
    try expectAt(&r, 100, 100, isBlue, "what it holds, turned with it");
    try expectAt(&r, 60, 60, isWhite, "where it was laid out");
    try r.expectJs("Math.round(a.getBoundingClientRect().height)", "100");
    try r.expectJs("Math.round(a.getBoundingClientRect().left)", "90");
    try r.expectJs("Math.round(document.getElementById('in').getBoundingClientRect().top)", "90");
    try r.expectJs("document.elementFromPoint(100, 20).id", "a");
    try r.expectJs("document.elementFromPoint(100, 100).id", "in");
    try r.expectJs("document.elementFromPoint(60, 60).tagName", "HTML");
}

test "scale, skew, matrix and origin, nested" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<div style='position:absolute;left:0;top:0;width:50px;height:50px;background:#f00;transform-origin:0 0;transform:scale(2,3)'></div><div style='position:absolute;left:200px;top:0;width:50px;height:50px;background:#00f;transform-origin:0 0;transform:skewX(45deg)'></div>");
    try expectAt(&r, 95, 145, isRed, "scaled, far corner");
    try expectAt(&r, 105, 20, isWhite, "scaled, past its width");
    try expectAt(&r, 245, 40, isBlue, "skewed, sheared along");
    try expectAt(&r, 205, 40, isWhite, "skewed, left behind");
    // Nested: moved by the outer, doubled by the inner.
    try page(&r, "<div style='position:absolute;left:0;top:0;width:10px;height:10px;transform:translate(100px,0)'><div style='width:10px;height:10px;background:#f00;transform-origin:0 0;transform:matrix(2,0,0,2,0,0)'></div></div>");
    try expectAt(&r, 115, 15, isRed, "the inner, doubled, moved");
    try expectAt(&r, 5, 5, isWhite, "where it started");
    // 3D functions flatten; the separate properties compose.
    try page(&r, "<div style='position:absolute;left:0;top:0;width:10px;height:10px;background:#f00;transform:translate3d(20px,30px,50px)'></div><div style='position:absolute;left:100px;top:0;width:10px;height:10px;background:#00f;translate:20px 30px;scale:2;transform-origin:0 0'></div>");
    try expectAt(&r, 25, 35, isRed, "translate3d");
    try expectAt(&r, 135, 45, isBlue, "translate and scale");
}

test "a span isn't transformed, and `fixed` is held by what's transformed" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<span id=s style='transform:translateX(100px);background:#f00;color:#f00'>hello</span>");
    try r.expectJs("Math.round(s.getBoundingClientRect().left)", "0");
    try expectAt(&r, 3, 5, isRed, "still at its place");
}

test "gradients: hard stops, pixel stops, repeating, and tiles" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<div style='position:absolute;left:0;top:0;width:200px;height:100px;background:linear-gradient(90deg,#f00 50%,#00f 50%)'></div>");
    try expectAt(&r, 99, 50, isRed, "just left of the hard stop");
    try expectAt(&r, 101, 50, isBlue, "just right of it");
    // In pixels: the stop is at 20px whatever the box.
    try page(&r, "<div style='position:absolute;left:0;top:0;width:200px;height:50px;background:linear-gradient(90deg,#f00 20px,#00f 20px)'></div>");
    try expectAt(&r, 18, 25, isRed, "before 20px");
    try expectAt(&r, 22, 25, isBlue, "after 20px");
    // Repeating every 20px.
    try page(&r, "<div style='position:absolute;left:0;top:0;width:200px;height:50px;background:repeating-linear-gradient(90deg,#f00 0,#f00 10px,#00f 10px,#00f 20px)'></div>");
    try expectAt(&r, 5, 25, isRed, "");
    try expectAt(&r, 15, 25, isBlue, "");
    try expectAt(&r, 125, 25, isRed, "a period on");
    try expectAt(&r, 135, 25, isBlue, "a period on");
    // A small tile over a big box stays sharp.
    try page(&r, "<div style='position:absolute;left:0;top:0;width:400px;height:200px;background:linear-gradient(90deg,#f00 50%,#00f 50%);background-size:10px 10px'></div>");
    try expectAt(&r, 2, 2, isRed, "");
    try expectAt(&r, 7, 2, isBlue, "");
    try expectAt(&r, 302, 192, isRed, "tiles on");
    try expectAt(&r, 307, 192, isBlue, "tiles on");
}

test "background layers each have their own size, position and origin" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<div style='position:absolute;left:0;top:0;width:100px;height:100px;background:linear-gradient(#f00,#f00) 0 0/20px 20px no-repeat,linear-gradient(#00f,#00f) 100% 100%/20px 20px no-repeat'></div>");
    try expectAt(&r, 10, 10, isRed, "the first layer, top left");
    try expectAt(&r, 90, 90, isBlue, "the second, bottom right");
    try expectAt(&r, 50, 50, isWhite, "between");
    // From the padding box by default; the content box when asked.
    try page(&r, "<div style='position:absolute;left:0;top:0;width:100px;height:100px;box-sizing:border-box;border:10px solid transparent;background:linear-gradient(90deg,#f00 50%,#00f 50%) no-repeat;background-size:20px 20px'></div>");
    try expectAt(&r, 14, 14, isRed, "inside the border, the tile's left");
    try expectAt(&r, 24, 14, isBlue, "the tile's right");
    try expectAt(&r, 5, 5, isWhite, "no tile on the border");
}

test "filters adjust colors, and fade; drop-shadow gives a shadow" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<div style='position:absolute;left:0;top:0;width:40px;height:40px;background:#f00;filter:invert(1)'></div><div style='position:absolute;left:50px;top:0;width:40px;height:40px;background:#f00;filter:grayscale(1)'></div><div style='position:absolute;left:100px;top:0;width:40px;height:40px;background:#f00;filter:opacity(0)'></div><div style='position:absolute;left:150px;top:0;width:40px;height:40px;background:#f00;filter:drop-shadow(10px 0 0 #00f)'></div>");
    const inv = try pixel(&r, 20, 20);
    try testing.expect(inv[2] < 30 and inv[1] > 220 and inv[0] > 220);
    const gray = try pixel(&r, 70, 20);
    try testing.expect(@abs(@as(i32, gray[0]) - gray[2]) < 8);
    try expectAt(&r, 120, 20, isWhite, "opacity 0");
    try expectAt(&r, 170, 20, isRed, "the box");
    try expectAt(&r, 195, 20, isBlue, "its shadow");
}

test "a blurred fill is soft-edged and backdrop-filter blurs what's behind" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<div style='position:absolute;left:50px;top:50px;width:100px;height:100px;background:#f00;filter:blur(10px)'></div>");
    const mid = try pixel(&r, 100, 100);
    const edge = try pixel(&r, 50, 100);
    const out = try pixel(&r, 35, 100);
    try testing.expect(isRed(mid));
    try testing.expect(edge[1] > 90 and edge[1] < 170);
    try testing.expect(out[1] > 180 and out[1] < 250);
    try page(&r, "<div style='position:absolute;left:0;top:0;width:100px;height:200px;background:#000'></div><div style='position:absolute;left:50px;top:50px;width:100px;height:100px;backdrop-filter:blur(10px)'></div>");
    const across = try pixel(&r, 100, 100);
    try testing.expect(across[1] > 60 and across[1] < 200);
}

test "gradient text: layers composite, and sizes and positions count" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    // Apple's: a see-through sheen above a color, the sheen's tile moved off the text.
    try page(&r, "<div style='position:absolute;left:0;top:0;width:300px;font-size:40px;background-image:linear-gradient(90deg,#f000,#f000),linear-gradient(90deg,#00f,#00f);-webkit-background-clip:text;background-clip:text;color:transparent'>MMMMMMMMMMMM</div>");
    var blue: u32 = 0;
    var y: f32 = 0;
    while (y < 50) : (y += 2) {
        var x: f32 = 0;
        while (x < 200) : (x += 2) {
            if (isBlue(try pixel(&r, x, y))) blue += 1;
        }
    }
    try testing.expect(blue > 20);
    // What's inside a span takes it from the block around it.
    try page(&r, "<div style='position:absolute;left:0;top:0;width:300px;font-size:40px;background:linear-gradient(#f00,#f00);-webkit-background-clip:text;color:transparent'><span>MMMM</span></div>");
    var red: u32 = 0;
    y = 0;
    while (y < 50) : (y += 2) {
        var x: f32 = 0;
        while (x < 200) : (x += 2) {
            if (isRed(try pixel(&r, x, y))) red += 1;
        }
    }
    try testing.expect(red > 20);
}

test "gradient text: each glyph takes the gradient's color where it is" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try page(&r, "<div style='position:absolute;left:0;top:0;width:300px;font-size:40px;background:linear-gradient(90deg,#f00,#00f);-webkit-background-clip:text;-webkit-text-fill-color:transparent'>MMMMMMMMMMMM</div>");
    var left_red: u32 = 0;
    var right_blue: u32 = 0;
    var y: f32 = 0;
    while (y < 50) : (y += 2) {
        var x: f32 = 0;
        while (x < 60) : (x += 2) {
            const p = try pixel(&r, x, y);
            if (p[2] > 200 and p[0] < 110) left_red += 1;
        }
        x = 240;
        while (x < 300) : (x += 2) {
            const p = try pixel(&r, x, y);
            if (p[0] > 200 and p[2] < 110) right_blue += 1;
        }
    }
    try testing.expect(left_red > 10);
    try testing.expect(right_blue > 10);
    // Not painted as a box behind it.
    try expectAt(&r, 1, 49, isWhite, "the box's corner under the text");
}
