//! `getComputedStyle`: a property's computed value written as text. Lengths
//! are computed, not used: `auto` stays `auto` where the used size is layout's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../dom.zig");
const style = @import("style.zig");
const prop = @import("prop.zig");
const vars = @import("vars.zig");
const tk = @import("tokenizer.zig");
const cascade = @import("cascade.zig");
const transform_mod = @import("transform.zig");

const Style = style.Style;
const Len = style.Len;
const Color = style.Color;
const P = std.fmt.allocPrint;

fn kw(a: Allocator, v: anytype) Allocator.Error![]const u8 {
    const raw = @tagName(v);
    var name: []const u8 = raw;
    if (name.len > 0 and name[name.len - 1] == '_') name = name[0 .. name.len - 1];
    const out = try a.dupe(u8, name);
    for (out) |*c| {
        if (c.* == '_') c.* = '-';
    }
    return out;
}

fn paintText(a: Allocator, p: style.SvgPaint, current: Color) Allocator.Error![]const u8 {
    return switch (p.kind) {
        .none => "none",
        .current => try colorWords(a, current),
        .color => try colorWords(a, p.color),
        .url => try P(a, "url(\"#{s}\")", .{p.url}),
    };
}

fn colorWords(a: Allocator, c: Color) Allocator.Error![]const u8 {
    const b = struct {
        fn f(v: f32) u32 {
            return @intFromFloat(std.math.clamp(v, 0, 1) * 255 + 0.5);
        }
    }.f;
    if (c.a >= 1) return P(a, "rgb({d}, {d}, {d})", .{ b(c.r), b(c.g), b(c.b) });
    return P(a, "rgba({d}, {d}, {d}, {d})", .{ b(c.r), b(c.g), b(c.b), c.a });
}

fn pxText(a: Allocator, v: f32) Allocator.Error![]const u8 {
    return P(a, "{d}px", .{v});
}

fn lenText(a: Allocator, l: Len) Allocator.Error![]const u8 {
    switch (l.kind) {
        .length => {},
        else => return kw(a, l.kind),
    }
    if (l.pct != 0 and l.px != 0) return P(a, "calc({d}% + {d}px)", .{ l.pct, l.px });
    if (l.pct != 0) return P(a, "{d}%", .{l.pct});
    return pxText(a, l.px);
}

fn colorText(a: Allocator, c: Color) Allocator.Error![]const u8 {
    const b = struct {
        fn f(x: f32) u32 {
            return @intFromFloat(@round(std.math.clamp(x, 0, 1) * 255));
        }
    }.f;
    if (c.a >= 1) return P(a, "rgb({d}, {d}, {d})", .{ b(c.r), b(c.g), b(c.b) });
    return P(a, "rgba({d}, {d}, {d}, {d})", .{ b(c.r), b(c.g), b(c.b), c.a });
}

fn borderText(a: Allocator, x: style.Border) Allocator.Error![]const u8 {
    return P(a, "{d}px {s} {s}", .{ x.width, try kw(a, x.style), try colorText(a, x.color) });
}

fn boolWord(a: bool, yes: []const u8, no: []const u8) []const u8 {
    return if (a) yes else no;
}

fn decoration(a: Allocator, s: *const Style) Allocator.Error![]const u8 {
    if (!s.underline and !s.line_through and !s.overline) return "none";
    var parts: std.ArrayList(u8) = .empty;
    if (s.underline) try parts.appendSlice(a, "underline ");
    if (s.overline) try parts.appendSlice(a, "overline ");
    if (s.line_through) try parts.appendSlice(a, "line-through ");
    return std.mem.trimEnd(u8, parts.items, " ");
}

fn customValue(a: Allocator, n: *const dom.Node, name: []const u8) ?[]const u8 {
    const raw = n.css_vars orelse return null;
    const scope: *const vars.Scope = @ptrCast(@alignCast(raw));
    const v = scope.get(name, std.hash.Fnv1a_32.hash(name)) orelse return null;
    return tk.serialize(a, v) catch null;
}

pub fn get(e: *cascade.Engine, n: *dom.Node, name: []const u8) ?[]const u8 {
    const a = e.genArena();
    if (n.style_generation != e.generation) return null;
    const s = n.computed orelse return null;
    if (name.len > 2 and name[0] == '-' and name[1] == '-') return customValue(a, n, name);
    var buf: [48]u8 = undefined;
    if (name.len > buf.len) return null;
    const low = std.ascii.lowerString(&buf, name);
    const p = prop.lookup(low) orelse return null;
    return text(a, s, p) catch null;
}

fn text(a: Allocator, s: *const Style, p: prop.Prop) Allocator.Error!?[]const u8 {
    return switch (p) {
        .display => if (s.flow_root) "flow-root" else try kw(a, s.display),
        .position => try kw(a, s.position),
        .float => try kw(a, s.float),
        .clear => try kw(a, s.clear),
        .box_sizing => try kw(a, s.box_sizing),
        .visibility => try kw(a, s.visibility),
        .opacity => try P(a, "{d}", .{s.opacity}),
        .z_index => if (s.z_index) |z| try P(a, "{d}", .{z}) else "auto",
        .overflow => try P(a, "{s} {s}", .{ try kw(a, s.overflow_x), try kw(a, s.overflow_y) }),
        .overflow_x => try kw(a, s.overflow_x),
        .overflow_y => try kw(a, s.overflow_y),
        .cursor => try kw(a, s.cursor),
        .pointer_events => boolWord(s.pointer_events, "auto", "none"),
        .width => try lenText(a, s.width),
        .height => try lenText(a, s.height),
        .min_width => try lenText(a, s.min_width),
        .min_height => try lenText(a, s.min_height),
        .max_width => try lenText(a, s.max_width),
        .max_height => try lenText(a, s.max_height),
        .aspect_ratio => if (s.aspect_ratio > 0) try P(a, "{d}", .{s.aspect_ratio}) else "auto",
        .margin_top => try lenText(a, s.margin_top),
        .margin_right => try lenText(a, s.margin_right),
        .margin_bottom => try lenText(a, s.margin_bottom),
        .margin_left => try lenText(a, s.margin_left),
        .padding_top => try lenText(a, s.padding_top),
        .padding_right => try lenText(a, s.padding_right),
        .padding_bottom => try lenText(a, s.padding_bottom),
        .padding_left => try lenText(a, s.padding_left),
        .top => try lenText(a, s.top),
        .right => try lenText(a, s.right),
        .bottom => try lenText(a, s.bottom),
        .left => try lenText(a, s.left),
        .border_top => try borderText(a, s.border_top),
        .border_right => try borderText(a, s.border_right),
        .border_bottom => try borderText(a, s.border_bottom),
        .border_left => try borderText(a, s.border_left),
        .border_top_width => try pxText(a, s.border_top.width),
        .border_right_width => try pxText(a, s.border_right.width),
        .border_bottom_width => try pxText(a, s.border_bottom.width),
        .border_left_width => try pxText(a, s.border_left.width),
        .border_top_style => try kw(a, s.border_top.style),
        .border_right_style => try kw(a, s.border_right.style),
        .border_bottom_style => try kw(a, s.border_bottom.style),
        .border_left_style => try kw(a, s.border_left.style),
        .border_top_color => try colorText(a, s.border_top.color),
        .border_right_color => try colorText(a, s.border_right.color),
        .border_bottom_color => try colorText(a, s.border_bottom.color),
        .border_left_color => try colorText(a, s.border_left.color),
        .outline => try borderText(a, s.outline),
        .color => try colorText(a, s.color),
        .background_color => try colorText(a, s.background),
        .background_image => if (s.background_image.len > 0)
            try P(a, "url(\"{s}\")", .{s.background_image})
        else if (s.background_gradient != null) "linear-gradient" else "none",
        .font_size => try pxText(a, s.font_size),
        .font_weight => try P(a, "{d}", .{s.font_weight}),
        .font_style => boolWord(s.italic, "italic", "normal"),
        .font_family => try @import("font_family.zig").shown(a, s.font_family),
        .line_height => if (s.line_height > 0) try pxText(a, s.line_height) else "normal",
        .letter_spacing => if (s.letter_spacing != 0) try pxText(a, s.letter_spacing) else "normal",
        .word_spacing => try pxText(a, s.word_spacing),
        .text_align => try kw(a, s.text_align),
        .text_indent => try lenText(a, s.text_indent),
        .white_space => try kw(a, s.white_space),
        .text_transform => try kw(a, s.text_transform),
        .list_style_type => try kw(a, s.list_style),
        .list_style_position => boolWord(s.list_inside, "inside", "outside"),
        .direction => boolWord(s.rtl, "rtl", "ltr"),
        .text_decoration, .text_decoration_line => try decoration(a, s),
        .vertical_align => try kw(a, s.vertical_align),
        .flex_direction => try kw(a, s.flex_direction),
        .flex_wrap => try kw(a, s.flex_wrap),
        .flex_grow => try P(a, "{d}", .{s.flex_grow}),
        .flex_shrink => try P(a, "{d}", .{s.flex_shrink}),
        .flex_basis => try lenText(a, s.flex_basis),
        .order => try P(a, "{d}", .{s.order}),
        .justify_content => try kw(a, s.justify_content),
        .justify_items => try kw(a, s.justify_items),
        .justify_self => try kw(a, s.justify_self),
        .align_items => try kw(a, s.align_items),
        .align_self => try kw(a, s.align_self),
        .align_content => try kw(a, s.align_content),
        .row_gap => try lenText(a, s.row_gap),
        .column_gap => if (s.column_gap.kind == .auto) "normal" else try lenText(a, s.column_gap),
        .border_collapse => boolWord(s.border_collapse, "collapse", "separate"),
        .object_fit => try kw(a, s.object_fit),
        .transform => if (s.transform != null) blk: {
            // What it comes to without a box: percentages count for nothing.
            const m = transform_mod.of(s, 0, 0) orelse break :blk "none";
            break :blk try P(a, "matrix({d}, {d}, {d}, {d}, {d}, {d})", .{ m.a, m.b, m.c, m.d, m.e, m.f });
        } else "none",
        .animation_name => blk: {
            if (s.animations.len == 0) break :blk "none";
            var out: std.ArrayList(u8) = .empty;
            for (s.animations, 0..) |x, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.appendSlice(a, x.name);
            }
            break :blk out.items;
        },
        .animation_duration => if (s.animations.len > 0) try P(a, "{d}s", .{s.animations[0].duration}) else "0s",
        .animation_delay => if (s.animations.len > 0) try P(a, "{d}s", .{s.animations[0].delay}) else "0s",
        .transition_duration => if (s.transitions.len > 0) try P(a, "{d}s", .{s.transitions[0].duration}) else "0s",
        .transition_delay => if (s.transitions.len > 0) try P(a, "{d}s", .{s.transitions[0].delay}) else "0s",
        .transition_property => if (s.transitions.len > 0) s.transitions[0].name else "none",
        .box_shadow => if (s.shadows.len > 0) try P(a, "{s} {d}px {d}px {d}px {d}px", .{ try colorText(a, s.shadows[0].color), s.shadows[0].x, s.shadows[0].y, s.shadows[0].blur, s.shadows[0].spread }) else "none",
        .filter => if (s.filters.len > 0) "filter" else "none",
        .clip_path => if (s.clip_path != null) "shape" else "none",
        .appearance => boolWord(s.appearance_none, "none", "auto"),
        .object_position => try P(a, "{d}% {d}%", .{ s.object_x, s.object_y }),
        .fill => try paintText(a, s.svg.fill, s.color),
        .stroke => try paintText(a, s.svg.stroke, s.color),
        .stroke_width => try pxText(a, s.svg.stroke_width),
        .content => try P(a, "\"{s}\"", .{s.content}),
        else => null,
    };
}
