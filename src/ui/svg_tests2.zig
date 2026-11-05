//! The SVG rasterizer's pixels: gradients, clips, masks, `use` and `symbol`,
//! group opacity, nested viewports and dashes, each small enough to reason
//! about by hand.
const std = @import("std");
const testing = std.testing;
const svg = @import("svg.zig");

const Px = struct {
    bytes: []u8,
    w: usize,

    fn at(p: Px, x: usize, y: usize) [4]u8 {
        return p.bytes[(y * p.w + x) * 4 ..][0..4].*;
    }

    fn deinit(p: Px) void {
        testing.allocator.free(p.bytes);
    }
};

fn draw(src: []const u8, w: u32, h: u32) !Px {
    return .{ .bytes = try svg.render(testing.allocator, src, .{ .width = w, .height = h, .current = .{ 0.5, 0.5, 0.5, 1 } }), .w = w };
}

fn near(a: u8, b: u8, by: u8) !void {
    if (@max(a, b) - @min(a, b) > by) {
        std.debug.print("{d} is not near {d}\n", .{ a, b });
        return error.TestFailed;
    }
}

test "a linear gradient in its bounding box, and one that inherits by href" {
    const p = try draw(
        \\<svg viewBox="0 0 100 10"><defs>
        \\<linearGradient id="a"><stop offset="0" stop-color="#f00"/><stop offset="1" stop-color="#00f"/></linearGradient>
        \\<linearGradient id="b" href="#a" x1="0" x2="0" y1="0" y2="1"/>
        \\</defs><rect width="100" height="5" fill="url(#a)"/><rect y="5" width="100" height="5" fill="url(#b)"/></svg>
    , 100, 10);
    defer p.deinit();
    const left = p.at(1, 2);
    try testing.expect(left[2] > 240 and left[0] < 15);
    const right = p.at(98, 2);
    try testing.expect(right[0] > 240 and right[2] < 15);
    // Inherited stops, down the box rather than across it: the same across.
    try near(p.at(10, 5)[2], p.at(90, 5)[2], 2);
    try testing.expect(p.at(50, 9)[0] > 100);
}

test "a gradient in user space, transformed; a radial one with stops by style" {
    const p = try draw(
        \\<svg viewBox="0 0 100 100"><defs>
        \\<linearGradient id="a" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="100" y2="0" gradientTransform="scale(.5)"><stop stop-color="#000"/><stop offset="1" stop-color="#fff"/></linearGradient>
        \\<radialGradient id="r" cx=".5" cy=".5" r=".5"><stop style="stop-color:#ff0000"/><stop offset="1" style="stop-color:#0000ff;stop-opacity:0"/></radialGradient>
        \\</defs><rect width="100" height="40" fill="url(#a)"/><circle cx="50" cy="70" r="30" fill="url(#r)"/></svg>
    , 100, 100);
    defer p.deinit();
    // Scaled by a half: it's white from the middle on.
    try testing.expect(p.at(60, 20)[0] > 250);
    try near(p.at(25, 20)[0], 128, 8);
    try testing.expect(p.at(50, 70)[2] > 240);
    try testing.expect(p.at(50, 41)[3] < 30);
}

test "a paint whose url names nothing is its fallback, or none" {
    const p = try draw(
        \\<svg viewBox="0 0 2 1"><rect width="1" height="1" fill="url(#gone) #0f0"/><rect x="1" width="1" height="1" fill="url(#gone)"/></svg>
    , 2, 1);
    defer p.deinit();
    try testing.expect(p.at(0, 0)[1] > 250);
    try testing.expectEqual(@as(u8, 0), p.at(1, 0)[3]);
}

test "currentColor is the color property's, and the caller's until one says" {
    const p = try draw(
        \\<svg viewBox="0 0 2 1"><rect width="1" height="1" fill="currentColor"/><g color="#ff0000"><rect x="1" width="1" height="1" fill="currentColor"/></g></svg>
    , 2, 1);
    defer p.deinit();
    try near(p.at(0, 0)[2], 128, 1);
    try testing.expect(p.at(1, 0)[2] > 250 and p.at(1, 0)[1] < 5);
}

test "a clip path cuts a group; another's rule and transform are its own" {
    const p = try draw(
        \\<svg viewBox="0 0 20 20"><defs><clipPath id="c"><rect width="10" height="20"/></clipPath>
        \\<clipPath id="d" clipPathUnits="objectBoundingBox"><rect width=".5" height="1"/></clipPath></defs>
        \\<g clip-path="url(#c)"><rect width="20" height="10" fill="#f00"/></g>
        \\<rect y="10" width="20" height="10" fill="#00f" clip-path="url(#d)"/></svg>
    , 20, 20);
    defer p.deinit();
    try testing.expect(p.at(5, 5)[2] > 250);
    try testing.expectEqual(@as(u8, 0), p.at(15, 5)[3]);
    try testing.expect(p.at(5, 15)[0] > 250);
    try testing.expectEqual(@as(u8, 0), p.at(15, 15)[3]);
}

test "a mask by luminance and by alpha" {
    const p = try draw(
        \\<svg viewBox="0 0 20 20"><defs><mask id="m"><rect width="10" height="20" fill="#fff"/><rect x="10" width="10" height="20" fill="#808080"/></mask>
        \\<mask id="a" style="mask-type:alpha"><rect width="10" height="20" fill="#000"/></mask></defs>
        \\<rect width="20" height="10" fill="#f00" mask="url(#m)"/><rect y="10" width="20" height="10" fill="#00f" mask="url(#a)"/></svg>
    , 20, 20);
    defer p.deinit();
    try testing.expectEqual(@as(u8, 255), p.at(5, 5)[3]);
    try near(p.at(15, 5)[3], 128, 3);
    try testing.expectEqual(@as(u8, 255), p.at(5, 15)[3]);
    try testing.expectEqual(@as(u8, 0), p.at(15, 15)[3]);
}

test "group opacity is the group's: what overlaps inside it doesn't show through" {
    const p = try draw(
        \\<svg viewBox="0 0 10 10"><g opacity=".5"><rect width="10" height="10" fill="#f00"/><rect width="10" height="10" fill="#00f"/></g></svg>
    , 10, 10);
    defer p.deinit();
    const c = p.at(5, 5);
    try near(c[3], 128, 1);
    try near(c[0], 128, 1); // all blue, at half
    try testing.expectEqual(@as(u8, 0), c[2]);
    // A fill and stroke with opacity likewise.
    const q = try draw(
        \\<svg viewBox="0 0 10 10"><rect x="2" y="2" width="6" height="6" fill="#f00" stroke="#00f" stroke-width="4" opacity=".5"/></svg>
    , 10, 10);
    defer q.deinit();
    try testing.expectEqual(@as(u8, 0), q.at(3, 3)[2]);
}

test "use of a shape moves it and it inherits from the use" {
    const p = try draw(
        \\<svg viewBox="0 0 20 10"><defs><rect id="r" width="10" height="10"/></defs>
        \\<use href="#r" fill="#f00"/><use xlink:href="#r" x="10" fill="#00f"/></svg>
    , 20, 10);
    defer p.deinit();
    try testing.expect(p.at(5, 5)[2] > 250);
    try testing.expect(p.at(15, 5)[0] > 250);
}

test "use of a symbol fits its viewBox and clips to its viewport; a loop ends" {
    const p = try draw(
        \\<svg viewBox="0 0 20 20"><symbol id="s" viewBox="0 0 10 10"><rect x="-10" width="30" height="5" fill="#0f0"/></symbol>
        \\<use href="#s" width="10" height="10"/><g id="loop"><use href="#loop"/></g></svg>
    , 20, 20);
    defer p.deinit();
    try testing.expect(p.at(5, 2)[1] > 250);
    // Clipped at the symbol's viewport, though the rect goes on.
    try testing.expectEqual(@as(u8, 0), p.at(15, 2)[3]);
    try testing.expectEqual(@as(u8, 0), p.at(5, 7)[3]);
}

test "preserveAspectRatio: none stretches, xMin puts it first, slice covers" {
    const stretch = try draw(
        \\<svg viewBox="0 0 10 10" preserveAspectRatio="none"><rect width="10" height="10" fill="#f00"/></svg>
    , 40, 10);
    defer stretch.deinit();
    try testing.expect(stretch.at(35, 5)[3] == 255);
    const first = try draw(
        \\<svg viewBox="0 0 10 10" preserveAspectRatio="xMinYMid"><rect width="10" height="10" fill="#f00"/></svg>
    , 40, 10);
    defer first.deinit();
    try testing.expect(first.at(5, 5)[3] == 255);
    try testing.expectEqual(@as(u8, 0), first.at(35, 5)[3]);
    const middle = try draw(
        \\<svg viewBox="0 0 10 10"><rect width="10" height="10" fill="#f00"/></svg>
    , 40, 10);
    defer middle.deinit();
    try testing.expectEqual(@as(u8, 0), middle.at(5, 5)[3]);
    try testing.expect(middle.at(20, 5)[3] == 255);
    const slice = try draw(
        \\<svg viewBox="0 0 10 10" preserveAspectRatio="xMidYMid slice"><rect width="10" height="5" fill="#f00"/></svg>
    , 40, 10);
    defer slice.deinit();
    // Scaled by four, its middle in view: the top half's edge is at the middle.
    try testing.expect(slice.at(20, 2)[3] == 255);
    try testing.expectEqual(@as(u8, 0), slice.at(20, 8)[3]);
}

test "a nested svg is its own viewport, and percentages are of it" {
    const p = try draw(
        \\<svg viewBox="0 0 40 20"><svg x="20" width="20" height="20" viewBox="0 0 10 10"><rect width="100%" height="50%" fill="#00f"/></svg></svg>
    , 40, 20);
    defer p.deinit();
    try testing.expect(p.at(30, 5)[0] > 250);
    try testing.expectEqual(@as(u8, 0), p.at(30, 15)[3]);
    try testing.expectEqual(@as(u8, 0), p.at(10, 5)[3]);
}

test "dashes leave gaps; a stretched viewBox stretches the stroke" {
    const p = try draw(
        \\<svg viewBox="0 0 20 4"><line x1="0" y1="2" x2="20" y2="2" stroke="#000" stroke-width="4" stroke-dasharray="4 4"/></svg>
    , 20, 4);
    defer p.deinit();
    try testing.expectEqual(@as(u8, 255), p.at(2, 2)[3]);
    try testing.expectEqual(@as(u8, 0), p.at(6, 2)[3]);
    try testing.expectEqual(@as(u8, 255), p.at(10, 2)[3]);
    const q = try draw(
        \\<svg viewBox="0 0 10 10" preserveAspectRatio="none"><line x1="5" y1="0" x2="5" y2="10" stroke="#000" stroke-width="2"/></svg>
    , 40, 10);
    defer q.deinit();
    // Two units wide is eight pixels here, not the average of the two scales.
    try testing.expectEqual(@as(u8, 255), q.at(17, 5)[3]);
    try testing.expectEqual(@as(u8, 0), q.at(15, 5)[3]);
}

test "a document's own style sheet" {
    const p = try draw(
        \\<svg viewBox="0 0 2 1"><style><![CDATA[.a{fill:#f00}]]></style><style>rect.b{fill:#00f}</style><rect class="a" width="1" height="1"/><rect class="b" x="1" width="1" height="1"/></svg>
    , 2, 1);
    defer p.deinit();
    try testing.expect(p.at(0, 0)[2] > 250);
    try testing.expect(p.at(1, 0)[0] > 250);
}

test "hidden things don't draw, and one shown under a hidden group does" {
    const p = try draw(
        \\<svg viewBox="0 0 3 1"><rect display="none" width="1" height="1"/><g visibility="hidden"><rect x="1" width="1" height="1"/><rect x="2" width="1" height="1" visibility="visible"/></g></svg>
    , 3, 1);
    defer p.deinit();
    try testing.expectEqual(@as(u8, 0), p.at(0, 0)[3]);
    try testing.expectEqual(@as(u8, 0), p.at(1, 0)[3]);
    try testing.expectEqual(@as(u8, 255), p.at(2, 0)[3]);
}

test "a big picture with many small shapes costs what they cover" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "<svg viewBox='0 0 2000 2000'>");
    for (0..2000) |i| try src.print(testing.allocator, "<circle cx='{d}' cy='{d}' r='3'/>", .{ i, i });
    try src.appendSlice(testing.allocator, "</svg>");
    const p = try draw(src.items, 2000, 2000);
    defer p.deinit();
    try testing.expectEqual(@as(u8, 255), p.at(1000, 1000)[3]);
    try testing.expectEqual(@as(u8, 0), p.at(10, 1000)[3]);
}
