//! Documents rendered whole: icons as icon sets write them.
const std = @import("std");
const svg = @import("svg.zig");
const testing = std.testing;

fn alphaAt(px: []const u8, w: usize, x: usize, y: usize) u8 {
    return px[(y * w + x) * 4 + 3];
}

fn ink(px: []const u8) usize {
    var n: usize = 0;
    var i: usize = 3;
    while (i < px.len) : (i += 4) n += @intFromBool(px[i] > 128);
    return n;
}

test "a stroked chevron in currentColor, fitted to the picture" {
    // Solar's alt-arrow-down: a 1.5-unit stroke with round caps and joins.
    const src =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" viewBox="0 0 24 24"><path fill="none"
        \\ stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="m19 9l-7 6l-7-6"/></svg>
    ;
    try testing.expectEqual([2]f32{ 24, 24 }, svg.size(src).?);
    const px = try svg.render(testing.allocator, src, .{ .width = 48, .height = 48, .current = .{ 1, 0, 0, 1 } });
    defer testing.allocator.free(px);
    // The tip at (12, 15) units: (24, 30) pixels. Red, premultiplied BGRA.
    try testing.expect(alphaAt(px, 48, 24, 29) > 200);
    try testing.expectEqual(@as(u8, 0), px[(29 * 48 + 24) * 4 + 0]);
    try testing.expect(px[(29 * 48 + 24) * 4 + 2] > 200);
    // Nothing filled inside the V, nothing far off.
    try testing.expectEqual(@as(u8, 0), alphaAt(px, 48, 24, 22));
    try testing.expectEqual(@as(u8, 0), alphaAt(px, 48, 2, 2));
    // About the stroke's area: two legs of √85 units, 1.5 wide, at 2 px a unit.
    const area = 2 * @sqrt(85.0) * 1.5 * 4;
    try testing.expectApproxEqAbs(@as(f32, area), @as(f32, @floatFromInt(ink(px))), area * 0.15);
}

test "groups pass their style down; evenodd cuts holes; shapes and transforms" {
    const src =
        \\<svg viewBox="0 0 20 20"><g fill="#00ff00" fill-rule="evenodd">
        \\ <path d="M2 2h16v16H2zM6 6h8v8H6z"/>
        \\ </g><circle cx="10" cy="10" r="2" fill="var(--icon-bg, #111)"/>
        \\ <rect x="0" y="0" width="2" height="2" fill="blue" transform="translate(18 18)"/></svg>
    ;
    const px = try svg.render(testing.allocator, src, .{ .width = 20, .height = 20 });
    defer testing.allocator.free(px);
    try testing.expectEqual(@as(u8, 255), px[(3 * 20 + 3) * 4 + 1]); // green ring
    try testing.expectEqual(@as(u8, 0), alphaAt(px, 20, 7, 7)); // the hole
    try testing.expectEqual(@as(u8, 0x11), px[(10 * 20 + 10) * 4 + 2]); // the fallback's #111
    try testing.expectEqual(@as(u8, 255), px[(19 * 20 + 19) * 4 + 0]); // blue, moved
}

test "a wide viewBox is centered in a square picture, and what can't be drawn isn't" {
    const src =
        \\<svg viewBox="0 0 20 10"><defs><linearGradient id="g"/></defs>
        \\<rect width="20" height="10" fill="url(#g)"/><rect width="20" height="10" fill="#fff" opacity=".5"/></svg>
    ;
    const px = try svg.render(testing.allocator, src, .{ .width = 20, .height = 20 });
    defer testing.allocator.free(px);
    try testing.expectEqual(@as(u8, 0), alphaAt(px, 20, 10, 2));
    try testing.expectEqual(@as(u8, 128), alphaAt(px, 20, 10, 10));
    try testing.expectEqual(@as(u8, 0), alphaAt(px, 20, 10, 17));
}

test "each path starts at the origin: a first relative moveto is absolute" {
    // graff's mark: a filled ring, then brackets stroked from `m12 12`.
    const src =
        \\<svg viewBox="0 0 32 32" fill="none"><path fill="currentColor" d="M2 2h4v4H2z"/>
        \\<path stroke="currentColor" stroke-width="2" d="m12 12-4 4 4 4"/></svg>
    ;
    const px = try svg.render(testing.allocator, src, .{ .width = 32, .height = 32 });
    defer testing.allocator.free(px);
    // The bracket's tip at (8, 16).
    try testing.expect(alphaAt(px, 32, 8, 16) > 200);
}
