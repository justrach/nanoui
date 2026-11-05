//! What a page came to, as one JSON object an element, for comparing against
//! another browser (`tools/compare.mjs`): where each element is and the styles
//! that decide how it looks. Reads only what the last frame left, so it can run
//! after the window is gone. `NANOBROWSER_DUMP=path` writes it on the way out.
const std = @import("std");
const dom = @import("dom.zig");
const layout = @import("layout/layout.zig");
const css = @import("css/style.zig");
const Page = @import("page.zig").Page;

fn str(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try out.append(a, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        0...0x1f => try out.append(a, ' '),
        else => try out.append(a, ch),
    };
    try out.append(a, '"');
}

fn color(k: css.Color) [4]u32 {
    return .{ byte(k.r), byte(k.g), byte(k.b), byte(k.a) };
}

fn byte(v: f32) u32 {
    return @intFromFloat(std.math.clamp(v, 0, 1) * 255 + 0.5);
}

/// The element's own place among its parent's: `div[3]`, by tag, from 1.
fn nthOfTag(n: *const dom.Node) usize {
    var i: usize = 1;
    var at = n.prev;
    while (at) |k| : (at = k.prev) {
        if (k.kind == .element and std.mem.eql(u8, k.tag, n.tag)) i += 1;
    }
    return i;
}

fn path(out: *std.ArrayList(u8), a: std.mem.Allocator, n: *const dom.Node) std.mem.Allocator.Error!void {
    if (n.parentElement()) |p| {
        try path(out, a, p);
        try out.append(a, '/');
    }
    try out.print(a, "{s}[{d}]", .{ n.tag, nthOfTag(n) });
}

/// `NANOBROWSER_EVAL`: a script's answer about the finished page, on stderr.
pub fn eval(p: *Page, source: []const u8) void {
    const w = p.js orelse return;
    w.enter();
    defer w.leave();
    const v = w.vm.eval(source, "NANOBROWSER_EVAL") catch {
        std.debug.print("eval threw: {s}\n", .{w.vm.exceptionString()});
        return;
    };
    std.debug.print("eval: {s}\n", .{w.vm.toStringSlice(v) catch "?"});
}

/// The whole document, one line an element.
pub fn write(gpa: std.mem.Allocator, p: *Page, file: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    var at = p.doc.node.first_child;
    while (at) |n| : (at = n.nextInTree(p.doc.node)) {
        if (n.kind != .element) continue;
        try out.appendSlice(a, "{\"path\":\"");
        try path(&out, a, n);
        try out.appendSlice(a, "\",\"id\":");
        try str(&out, a, n.attr("id") orelse "");
        try out.appendSlice(a, ",\"cls\":");
        try str(&out, a, n.attr("class") orelse "");
        const r = layout.rectOf(n);
        if (r) |x| try out.print(a, ",\"x\":{d:.2},\"y\":{d:.2},\"w\":{d:.2},\"h\":{d:.2}", .{ x.x, x.y, x.w, x.h });
        if (n.computed) |s| {
            const fg = color(s.color);
            const bg = color(s.background);
            try out.print(a, ",\"display\":\"{s}\",\"position\":\"{s}\",\"fontSize\":{d:.2},\"fontWeight\":{d},\"color\":[{d},{d},{d},{d}],\"bg\":[{d},{d},{d},{d}]", .{
                @tagName(s.display), @tagName(s.position), s.font_size, s.font_weight, fg[0], fg[1], fg[2], fg[3], bg[0], bg[1], bg[2], bg[3],
            });
        }
        if (n.computed) |s| {
            try out.print(a, ",\"opacity\":{d:.3},\"visibility\":\"{s}\",\"z\":{d},\"transform\":{},\"filters\":{d},\"blur\":{d:.1},\"anims\":{d},\"clipPath\":{},\"radius\":[{d},{d},{d},{d}],\"radiusPct\":[{d},{d}],\"radiusY\":[{d},{d}]", .{ s.opacity, @tagName(s.visibility), s.z_index orelse 0, s.hasTransform(), s.filters.len, s.backdrop_blur, s.animations.len, s.clip_path != null, s.radius[0], s.radius[1], s.radius[2], s.radius[3], s.radius_pct[0], s.radius_pct[1], s.radius_y[0], s.radius_y[1] });
        }
        try out.appendSlice(a, "}\n");
    }
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = out.items });
}
