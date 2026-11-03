//! Text, whichever system shapes it: CoreText on macOS and iOS (`text_mac.zig`),
//! nanoui's own TrueType reader elsewhere (`text_tt.zig`), or there too
//! when built with `-Dportable=true` (to test that path on a Mac). Both
//! give the same interface: fonts, shaped and wrapped layouts, carets, and
//! the glyph atlas.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

/// nanoui's own text and CPU renderer, not CoreText and Metal.
pub const portable = options.portable or !(builtin.os.tag == .macos or builtin.os.tag == .ios);
const impl = if (portable) @import("text_tt.zig") else @import("text_mac.zig");

pub const TextSystem = impl.TextSystem;
pub const Font = impl.Font;
pub const Glyph = impl.Glyph;
pub const Layout = impl.Layout;
pub const Line = impl.Line;
pub const Atlas = impl.Atlas;
pub const Sprite = impl.Sprite;
pub const subpixel_bins = impl.subpixel_bins;
pub const rich = impl.rich;

pub const ellipsis = "…";
const fits_head = std.math.maxInt(u32);
const max_truncates = 4096;
const max_layouts = 4096;
const max_wraps = 2048;

pub const Cut = struct {
    head: u32,
    tail: u32,
};

pub fn warmCaches(ts: *TextSystem) void {
    if (ts.layouts.capacity() < 8192) ts.layouts.ensureTotalCapacity(ts.gpa, 8192) catch {};
    if (ts.previous.capacity() < 8192) ts.previous.ensureTotalCapacity(ts.gpa, 8192) catch {};
    if (ts.wraps.current.capacity() < 4096) ts.wraps.current.ensureTotalCapacity(ts.gpa, 4096) catch {};
    if (ts.atlas.sprites.capacity() < 4096) ts.atlas.sprites.ensureTotalCapacity(ts.gpa, 4096) catch {};
    if (ts.atlas.symbols.capacity() < 512) ts.atlas.symbols.ensureTotalCapacity(ts.gpa, 512) catch {};
    if (!portable and ts.atlas.pixels.capacity < 16384) ts.atlas.pixels.ensureTotalCapacity(ts.gpa, 16384) catch {};
}

/// Retains recently shaped layouts across frames up to `max_layouts` so
/// scrolling and search filtering do not re-allocate glyph slices on steady frames.
pub fn retainLayouts(_: *TextSystem) void {}

fn cutKey(s: []const u8, style: types.TextStyle, zoom: f32, room: f32, mode: u2) u64 {
    const q_room: u64 = @intFromFloat(@round(@max(0, @min(room, 1e6)) * 2.0));
    const extra: u64 = (q_room << 2) | @as(u64, mode) | (@as(u64, @as(u32, @bitCast(zoom))) << 32) ^ 0x5452_554e_4341_5445;
    return TextSystem.key(s, style, extra);
}

// ponytail: 4096-entry flat truncation cache cleared on overflow; upgrade to segmented LRU if >4k distinct cuts/frame.
fn putCut(c: *Context, k: u64, cut: Cut) void {
    if (c.truncates.capacity() < max_truncates) c.truncates.ensureTotalCapacity(c.gpa, max_truncates) catch {};
    if (c.truncates.count() >= max_truncates) c.truncates.clearRetainingCapacity();
    c.truncates.put(c.gpa, k, cut) catch {};
}

fn xAt(lay: Layout, at: usize) f32 {
    for (lay.glyphs) |g| if (g.index >= at) return g.x;
    return lay.width;
}

fn prefixFromLayout(lay: Layout, s: []const u8, avail: f32) u32 {
    if (avail <= 0 or lay.glyphs.len == 0) return 0;
    var best: u32 = 0;
    for (lay.glyphs, 0..) |g, i| {
        const next_x = if (i + 1 < lay.glyphs.len) lay.glyphs[i + 1].x else lay.width;
        const next_idx: u32 = if (i + 1 < lay.glyphs.len) lay.glyphs[i + 1].index else @intCast(s.len);
        if (next_x <= avail) {
            if (next_idx > g.index) best = next_idx;
        } else break;
    }
    while (best > 0 and best < s.len and s[best] & 0xC0 == 0x80) best -= 1;
    return best;
}

fn computeCut(lay: Layout, el_w: f32, s: []const u8, middle: bool, room: f32) Cut {
    const avail = room - el_w - 0.5;
    if (!middle) return .{ .head = prefixFromLayout(lay, s, avail), .tail = @intCast(s.len) };
    const head = prefixFromLayout(lay, s, avail * 0.5);
    const left = avail - xAt(lay, head);
    var tail: u32 = @intCast(s.len);
    if (left > 0) {
        for (lay.glyphs) |g| {
            if (g.index >= head and lay.width - g.x <= left) {
                tail = g.index;
                break;
            }
        }
        while (tail < s.len and s[tail] & 0xC0 == 0x80) tail += 1;
    }
    return .{ .head = head, .tail = tail };
}

fn splice(c: *Context, s: []const u8, cut: Cut) []const u8 {
    const head = @min(s.len, cut.head);
    const tail = @min(s.len, @max(head, cut.tail));
    const out = c.alloc().alloc(u8, head + ellipsis.len + (s.len - tail)) catch return s;
    @memcpy(out[0..head], s[0..head]);
    @memcpy(out[head..][0..ellipsis.len], ellipsis);
    if (tail < s.len) @memcpy(out[head + ellipsis.len ..], s[tail..]);
    return out;
}

fn sliceLayout(c: *Context, lay: Layout, el: Layout, cut: Cut) ?Layout {
    var head_n: usize = 0;
    for (lay.glyphs) |g| {
        if (g.index < cut.head) head_n += 1 else break;
    }
    var tail_start: usize = lay.glyphs.len;
    for (lay.glyphs, 0..) |g, i| {
        if (g.index >= cut.tail) {
            tail_start = i;
            break;
        }
    }
    const tail_n = lay.glyphs.len - tail_start;
    const out = c.alloc().alloc(Glyph, head_n + el.glyphs.len + tail_n) catch return null;
    @memcpy(out[0..head_n], lay.glyphs[0..head_n]);
    const head_x = xAt(lay, cut.head);
    for (el.glyphs, 0..) |g, i| {
        out[head_n + i] = .{ .font = g.font, .glyph = g.glyph, .x = head_x + g.x, .y = g.y, .index = cut.head };
    }
    const tail_x = if (tail_start < lay.glyphs.len) lay.glyphs[tail_start].x else lay.width;
    const dx = head_x + el.width - tail_x;
    const di: u32 = cut.head + @as(u32, @intCast(ellipsis.len));
    for (lay.glyphs[tail_start..], 0..) |g, i| {
        out[head_n + el.glyphs.len + i] = .{
            .font = g.font,
            .glyph = g.glyph,
            .x = g.x + dx,
            .y = g.y,
            .index = g.index - cut.tail + di,
        };
    }
    return .{ .width = head_x + el.width + (lay.width - tail_x), .glyphs = out };
}

/// Cuts text box `index` to `w` points (its padding included) if it is wider.
pub fn fit(c: *Context, index: u32, w: f32) void {
    const n = c.node(index);
    const t = &n.content.text;
    if (t.str.len == 0) return;
    const room = w - n.style.padding.horizontal();
    const k = cutKey(t.str, t.style, c.text.zoom, room, if (t.style.truncate == .middle) 1 else 0);
    if (c.truncates.get(k)) |cut| {
        if (cut.head == fits_head) return;
        if (!rich.styled(t.spans)) {
            const lay = c.text.layout(t.str, t.style);
            const el = c.text.layout(ellipsis, t.style);
            t.cut_lay = sliceLayout(c, lay, el, cut);
        }
        t.str = splice(c, t.str, cut);
        return;
    }
    const lay = c.text.layout(t.str, t.style);
    if (lay.width <= room + 0.5) {
        putCut(c, k, .{ .head = fits_head, .tail = 0 });
        return;
    }
    const el = c.text.layout(ellipsis, t.style);
    const cut = computeCut(lay, el.width, t.str, t.style.truncate == .middle, room);
    putCut(c, k, cut);
    if (!rich.styled(t.spans)) t.cut_lay = sliceLayout(c, lay, el, cut);
    t.str = splice(c, t.str, cut);
}

/// Wrapped text box `index` cut to `TextStyle.max_lines`.
pub fn fitLines(c: *Context, index: u32, w: f32) void {
    const n = c.node(index);
    const t = &n.content.text;
    if (!t.style.wrap or t.lines.len == 0) return;
    const last = t.lines[t.lines.len - 1];
    if (std.mem.trim(u8, t.str[last.end..], " \t\r\n").len == 0) return;
    const sub = t.str[last.start..last.end];
    const room = w - n.style.padding.horizontal();
    const k = cutKey(sub, t.style, c.text.zoom, room, 2);
    const cut = c.truncates.get(k) orelse blk: {
        const lay = c.text.layout(sub, t.style);
        const el = c.text.layout(ellipsis, t.style);
        const computed = computeCut(lay, el.width, sub, false, room);
        putCut(c, k, computed);
        break :blk computed;
    };
    const tail = splice(c, sub, cut);
    const a = c.alloc();
    const str = a.alloc(u8, last.start + tail.len) catch return;
    const lines = a.dupe(Line, t.lines) catch return;
    @memcpy(str[0..last.start], t.str[0..last.start]);
    @memcpy(str[last.start..], tail);
    lines[lines.len - 1] = .{ .start = last.start, .end = str.len, .width = c.text.width(tail, t.style) };
    t.str = str;
    t.lines = lines;
}
