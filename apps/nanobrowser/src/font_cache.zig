//! Browser-wide 2-way associative width and line-metrics cache for unscoped
//! (`!font.isScoped()`) system/installed fonts across pages and iframes, plus
//! the `Fonts` measurer adapter handed to layout and display-list building.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const dom = @import("dom.zig");
const box = @import("layout/box.zig");
const lctx = @import("layout/ctx.zig");
const replay = @import("paint/replay.zig");
const webfonts = @import("webfonts.zig");
const Page = @import("page.zig").Page;

const w_mask: usize = 65535;
const m_mask: usize = 4095;

var cur_zoom: f32 = 1;
var cur_unscoped_gen: u64 = 0;
var w_keys: [w_mask + 1]u64 = @splat(0);
var w_vals: [w_mask + 1]f32 = @splat(0);
var m_keys: [m_mask + 1]u64 = @splat(0);
var m_vals: [m_mask + 1]box.Metrics = @splat(.{});

pub inline fn syncZoom(zoom: f32) void {
    const ug = ui.unscopedFontGeneration();
    if (zoom == cur_zoom and ug == cur_unscoped_gen) return;
    cur_zoom = zoom;
    cur_unscoped_gen = ug;
    @memset(&w_keys, 0);
    @memset(&m_keys, 0);
}

pub inline fn getWidth(k: u64) ?f32 {
    if (k == 0) return null;
    const s0: usize = @as(usize, @truncate(k)) & w_mask;
    if (w_keys[s0] == k) return w_vals[s0];
    const s1: usize = s0 ^ 1;
    if (w_keys[s1] == k) return w_vals[s1];
    return null;
}

pub inline fn putWidth(k: u64, w: f32) void {
    if (k == 0) return;
    const s0: usize = @as(usize, @truncate(k)) & w_mask;
    if (w_keys[s0] == 0 or w_keys[s0] == k) {
        w_keys[s0] = k;
        w_vals[s0] = w;
        return;
    }
    const s1: usize = s0 ^ 1;
    w_keys[s1] = w_keys[s0];
    w_vals[s1] = w_vals[s0];
    w_keys[s0] = k;
    w_vals[s0] = w;
}

pub inline fn getMetrics(k: u64) ?box.Metrics {
    if (k == 0) return null;
    const s0: usize = @as(usize, @truncate(k)) & m_mask;
    if (m_keys[s0] == k) return m_vals[s0];
    const s1: usize = s0 ^ 1;
    if (m_keys[s1] == k) return m_vals[s1];
    return null;
}

pub inline fn putMetrics(k: u64, m: box.Metrics) void {
    if (k == 0) return;
    const s0: usize = @as(usize, @truncate(k)) & m_mask;
    if (m_keys[s0] == 0 or m_keys[s0] == k) {
        m_keys[s0] = k;
        m_vals[s0] = m;
        return;
    }
    const s1: usize = s0 ^ 1;
    m_keys[s1] = m_keys[s0];
    m_vals[s1] = m_vals[s0];
    m_keys[s0] = k;
    m_vals[s0] = m;
}

/// A font's line metrics as Chromium has them: each rounded to whole pixels, and on
/// the Mac the ascent of the three classic faces raised to match their Windows
/// counterparts (`FontMetrics::AscentDescentWithHacks`).
pub fn lineMetrics(c: *ui.Context, style: ui.TextStyle) box.Metrics {
    const m = c.text.font(style);
    var ascent = @round(m.ascent);
    const descent = @round(m.descent);
    if (builtin.os.tag == .macos) {
        var buf: [64]u8 = undefined;
        const name = c.text.familyName(style, &buf);
        if (std.mem.eql(u8, name, "Times") or std.mem.eql(u8, name, "Helvetica") or std.mem.eql(u8, name, "Courier")) {
            ascent += @floor((ascent + descent) * 0.15 + 0.5);
        }
    }
    return .{ .ascent = ascent, .descent = descent, .gap = @round(m.leading), .x_height = m.x_height };
}

/// What layout measures with during a frame.
pub const Fonts = struct {
    p: *Page,
    c: *ui.Context,
    space_key: u64 = 0,
    space_w: f32 = 0,
    metrics_key: u64 = 0,
    metrics_val: box.Metrics = .{},

    fn width(ctx: *anyopaque, text: []const u8, font: box.Font) f32 {
        const f: *Fonts = @ptrCast(@alignCast(ctx));
        if (font.size <= 0) return 0;
        const is_space = text.len == 1 and text[0] == ' ';
        if (is_space and f.space_key == font.key()) return f.space_w;
        const k = font.wordKey(text);
        if (!font.isScoped()) {
            if (getWidth(k)) |w| {
                if (is_space) { f.space_key = font.key(); f.space_w = w; }
                return w;
            }
            const w = lctx.clean(f.c.text.width(text, replay.textStyle(font)));
            putWidth(k, w);
            if (is_space) { f.space_key = font.key(); f.space_w = w; }
            return w;
        }
        if (f.p.widths.get(k)) |w| {
            if (is_space) { f.space_key = font.key(); f.space_w = w; }
            return w;
        }
        webfonts.need(f.p, f.c, font, text);
        const w = f.c.text.width(text, replay.textStyle(font));
        if (!f.p.faces.changed) {
            f.p.widths.put(f.p.gpa, k, w) catch {};
            if (is_space) { f.space_key = font.key(); f.space_w = w; }
        }
        return w;
    }

    fn metrics(ctx: *anyopaque, font: box.Font) box.Metrics {
        const f: *Fonts = @ptrCast(@alignCast(ctx));
        if (font.size <= 0) return .{ .ascent = 0, .descent = 0, .gap = 0 };
        const k = font.key();
        if (f.metrics_key == k) return f.metrics_val;
        if (!font.isScoped()) {
            if (getMetrics(k)) |m| { f.metrics_key = k; f.metrics_val = m; return m; }
            const m = lineMetrics(f.c, replay.textStyle(font));
            putMetrics(k, m);
            f.metrics_key = k;
            f.metrics_val = m;
            return m;
        }
        if (f.p.font_metrics.get(k)) |m| { f.metrics_key = k; f.metrics_val = m; return m; }
        webfonts.need(f.p, f.c, font, "");
        const m = lineMetrics(f.c, replay.textStyle(font));
        if (!f.p.faces.changed) { f.p.font_metrics.put(f.p.gpa, k, m) catch {}; f.metrics_key = k; f.metrics_val = m; }
        return m;
    }

    fn image(ctx: *anyopaque, node: *dom.Node) ?box.Size {
        const f: *Fonts = @ptrCast(@alignCast(ctx));
        if (node.image.len == 0) return null;
        if (replay.isSvg(node.image)) return svgNatural(node.image);
        const s = ui.imageSize(f.c, node.image_key, node.image) orelse return null;
        return .{ .w = s.w, .h = s.h };
    }

    fn svgNatural(bytes: []const u8) box.Size {
        const own = replay.svgOwn(bytes);
        if (own.size) |v| return .{ .w = v[0], .h = v[1] };
        if (own.ratio) |r| return .{ .w = -1, .h = r };
        return .{ .w = 300, .h = 150 };
    }

    pub fn measurer(f: *Fonts) box.Measurer {
        syncZoom(f.c.text.zoom);
        return .{ .ctx = f, .width = width, .metrics = metrics, .image = image, .widths = &f.p.widths, .widths_gpa = f.p.gpa, .shared_ok = true };
    }
};
