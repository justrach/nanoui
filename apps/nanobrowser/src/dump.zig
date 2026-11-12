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
    const pr = @import("perf_rules.zig");
    std.debug.print("prof(ms): jstask={d:.1} gc={d:.1} replay={d:.1} style={d:.1}(shared={d}/{d} cand={d} rec={d} has={d} unsh={d}/{d}) layout={d:.1}(runs={d} adopted={d} gen={d:.1} size={d:.1} fin={d:.1}) list={d:.1} svg={d:.1} html={d:.1} query={d:.1} compile={d:.1}({d}) js(calls={d} nat={d}/{d:.1}ms slow={d} ic={d} dis={d} iops={d})\n", .{
        @as(f64, @floatFromInt(pr.prof_js_task_ns)) / 1e6,
        @as(f64, @floatFromInt(pr.prof_gc_ns)) / 1e6,
        @as(f64, @floatFromInt(pr.prof_replay_ns)) / 1e6,
        @as(f64, @floatFromInt(pr.prof_style_ns)) / 1e6,
        pr.prof_style_shared,
        pr.prof_style_elems,
        pr.prof_ss_cand,
        pr.prof_ss_rec,
        pr.prof_ss_has,
        pr.prof_ss_unshare,
        pr.prof_ss_univ,
        @as(f64, @floatFromInt(pr.prof_layout_ns)) / 1e6,
        pr.prof_layout_runs,
        pr.prof_lay_adopted,
        @as(f64, @floatFromInt(pr.prof_lay_gen_ns)) / 1e6,
        @as(f64, @floatFromInt(pr.prof_lay_size_ns)) / 1e6,
        @as(f64, @floatFromInt(pr.prof_lay_fin_ns)) / 1e6,
        @as(f64, @floatFromInt(pr.prof_list_ns)) / 1e6,
        @as(f64, @floatFromInt(pr.prof_svg_ns)) / 1e6,
        @as(f64, @floatFromInt(pr.prof_html_ns)) / 1e6,
        @as(f64, @floatFromInt(pr.prof_query_ns)) / 1e6,
        @as(f64, @floatFromInt(pr.prof_compile_ns)) / 1e6,
        pr.prof_compile_calls,
        pr.prof_jit_calls,
        pr.prof_nat_calls,
        @as(f64, @floatFromInt(pr.prof_nat_ns)) / 1e6,
        pr.prof_slow_ops,
        pr.prof_ic_helpers,
        pr.prof_jit_disabled,
        pr.prof_interp_ops,
    });
    std.debug.print("  ic_detail: acc={d} miss_slot={d} prim={d} exotic={d} | ss_rej: style={d} id={d} state={d} val={d} rh={d} tag={d} | ss_miss: gen={d} pstyle={d} cousin={d} key={d}\n  slow_ops:", .{
        pr.prof_ic_acc, pr.prof_ic_miss_slot, pr.prof_ic_prim, pr.prof_ic_exotic,
        pr.prof_ss_rej_style, pr.prof_ss_rej_id, pr.prof_ss_rej_state, pr.prof_ss_rej_val, pr.prof_ss_rej_root_host, pr.prof_ss_rej_tag,
        pr.prof_ss_miss_gen, pr.prof_ss_miss_pstyle, pr.prof_ss_miss_cousin, pr.prof_ss_miss_key,
    });
    const Op = @import("js/bytecode.zig").Op;
    for (pr.prof_slow_hist, 0..) |cnt, idx| {
        if (cnt >= 50_000) std.debug.print(" {s}={d}", .{ @tagName(@as(Op, @enumFromInt(idx))), cnt });
    }
    std.debug.print("\n", .{});
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
