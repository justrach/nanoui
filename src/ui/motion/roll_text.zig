//! Rolling label morph: when a keyed short string changes, shared leading and
//! trailing extended grapheme clusters stay anchored (the trailing run glides
//! smoothly horizontally to the new width), while the changed middle graphemes
//! roll vertically out/in with ease-out quint, scale, fade, and subtle tilt.
//! Strings over 64 bytes or frames with reduced motion render directly.
const std = @import("std");
const Context = @import("../context.zig").Context;
const types = @import("../types.zig");
const motion = @import("motion.zig");
const widgets = @import("../widgets.zig");
const div_mod = @import("../div.zig");
const text_selection = @import("../text_selection.zig");

pub const Options = struct {
    duration: f32 = 0.55,
    stagger: f32 = 0.30,
};

pub const SharedEnds = struct {
    prefix: usize,
    suffix: usize,
};

/// Byte lengths of the shared leading and trailing UAX #29 extended grapheme
/// runs between `from` and `to`, guaranteed not to overlap in either string.
pub fn sharedEnds(from: []const u8, to: []const u8) SharedEnds {
    var prefix: usize = 0;
    while (prefix < from.len and prefix < to.len) {
        const a_end = text_selection.graphemeEnd(from, prefix);
        const b_end = text_selection.graphemeEnd(to, prefix);
        if (!std.mem.eql(u8, from[prefix..a_end], to[prefix..b_end])) break;
        prefix = a_end;
    }
    const nf = countGraphemes(from, prefix);
    const nt = countGraphemes(to, prefix);
    const k = @min(nf, nt);
    var fa = advanceGraphemes(from, prefix, nf - k);
    var fb = advanceGraphemes(to, prefix, nt - k);
    var candidate: ?usize = null;
    var i: usize = 0;
    while (i < k) : (i += 1) {
        const fa_end = text_selection.graphemeEnd(from, fa);
        const fb_end = text_selection.graphemeEnd(to, fb);
        if (std.mem.eql(u8, from[fa..fa_end], to[fb..fb_end])) {
            if (candidate == null) candidate = fa;
        } else {
            candidate = null;
        }
        fa = fa_end;
        fb = fb_end;
    }
    const suffix = if (candidate) |start| from.len - start else 0;
    return .{ .prefix = prefix, .suffix = suffix };
}

fn countGraphemes(s: []const u8, from_pos: usize) usize {
    var pos = from_pos;
    var n: usize = 0;
    while (pos < s.len) : (n += 1) {
        pos = text_selection.graphemeEnd(s, pos);
    }
    return n;
}

fn advanceGraphemes(s: []const u8, from_pos: usize, steps: usize) usize {
    var pos = from_pos;
    var i: usize = 0;
    while (i < steps and pos < s.len) : (i += 1) {
        pos = text_selection.graphemeEnd(s, pos);
    }
    return pos;
}

/// Draws `str`, morphing changed middle graphemes when the label under `key`
/// changes across consecutive frames.
pub fn rollText(c: *Context, key: []const u8, str: []const u8, st: types.TextStyle, opts: Options) void {
    if (str.len == 0 or str.len > 64) return widgets.text(c, str, st);
    const id = motion.scoped(c, key);
    const got = c.motion_store.getRoll(c.gpa, id, c.frame) orelse return widgets.text(c, str, st);
    const r = got.state;
    const continuous = !got.fresh and c.frame > 1 and (r.last_frame == c.frame or r.last_frame + 1 == c.frame);
    r.last_frame = c.frame;
    if (!continuous) {
        @memcpy(r.cur_buf[0..str.len], str);
        r.cur_len = @intCast(str.len);
        r.active = false;
        return widgets.text(c, str, st);
    }
    const cur = r.cur_buf[0..r.cur_len];
    if (!std.mem.eql(u8, cur, str)) {
        @memcpy(r.from_buf[0..r.cur_len], cur);
        r.from_len = r.cur_len;
        @memcpy(r.cur_buf[0..str.len], str);
        r.cur_len = @intCast(str.len);
        r.started = c.time;
        r.active = !(c.reduced_motion or c.reduce_motion);
    }
    const duration = @max(0.001, opts.duration);
    const stagger_frac = @max(0.0, opts.stagger);
    const total_span: f64 = @as(f64, duration * (1.0 + stagger_frac));
    const elapsed_f64 = @max(0.0, c.time - r.started);
    if (!r.active or c.reduced_motion or c.reduce_motion or elapsed_f64 >= total_span) {
        r.active = false;
        return widgets.text(c, str, st);
    }
    c.animationFrame();

    const from = c.alloc().dupe(u8, r.from_buf[0..r.from_len]) catch return widgets.text(c, str, st);
    const to = c.alloc().dupe(u8, str) catch str;
    const ends = sharedEnds(from, to);
    const elapsed: f32 = @floatCast(elapsed_f64);
    const resize_p = motion.catalog.resize.progress(@floatCast(@min(1.0, elapsed_f64 / motion.catalog.resize.total())));
    const width = @ceil(motion.effects.lerp(c.text.width(from, st), c.text.width(to, st), resize_p));
    const line_h = if (st.line_height > 0) st.line_height else c.text.lineHeight(st);
    const travel = st.size * 0.35;
    const base_color = st.color orelse c.theme.text;

    const box = div_mod.div(c).row().w(width).h(line_h).itemsCenter();
    defer box.end();

    if (ends.prefix > 0) {
        const p_div = div_mod.div(c).row().h(line_h).itemsCenter().absolute().offset(0, 0);
        defer p_div.end();
        widgets.text(c, to[0..ends.prefix], st);
    }

    paintRun(c, from, ends.prefix, from.len - ends.suffix, line_h, st, base_color, elapsed, duration, stagger_frac, travel, true);
    paintRun(c, to, ends.prefix, to.len - ends.suffix, line_h, st, base_color, elapsed, duration, stagger_frac, travel, false);

    if (ends.suffix > 0) {
        const from_sx = c.text.width(from[0 .. from.len - ends.suffix], st);
        const to_sx = c.text.width(to[0 .. to.len - ends.suffix], st);
        const suffix_dx = (from_sx - to_sx) * (1.0 - resize_p);
        const s_div = div_mod.div(c).row().h(line_h).itemsCenter().absolute().offset(to_sx + suffix_dx, 0);
        defer s_div.end();
        widgets.text(c, to[to.len - ends.suffix ..], st);
    }
}

fn paintRun(
    c: *Context,
    line: []const u8,
    start_byte: usize,
    end_byte: usize,
    line_h: f32,
    st: types.TextStyle,
    base_color: types.Color,
    elapsed: f32,
    duration: f32,
    stagger_frac: f32,
    travel: f32,
    outgoing: bool,
) void {
    if (start_byte >= end_byte) return;
    var count: usize = 0;
    var at_count = start_byte;
    while (at_count < end_byte) : (count += 1) {
        at_count = text_selection.graphemeEnd(line, at_count);
    }
    if (count == 0) return;

    const min_x = c.text.width(line[0..start_byte], st);
    const max_x = c.text.width(line[0..end_byte], st);
    const spread = duration * stagger_frac * @as(f32, @floatFromInt(count -| 1)) / @as(f32, @floatFromInt(count));

    var at = start_byte;
    while (at < end_byte) {
        const end = @min(end_byte, text_selection.graphemeEnd(line, at));
        const x = c.text.width(line[0..at], st);
        const cluster = line[at..end];
        at = end;
        const delay = if (max_x > min_x) spread * std.math.clamp((x - min_x) / (max_x - min_x), 0.0, 1.0) else 0.0;
        const raw_t = std.math.clamp((elapsed - delay) / duration, 0.0, 1.0);
        const p = motion.catalog.ease_out_quint.sample(raw_t)[0];
        const alpha = if (outgoing) 1.0 - p else p;
        if (alpha <= 0.005) continue;
        const dy = if (outgoing) -travel * p else travel * (1.0 - p);
        const sc = if (outgoing) motion.effects.lerp(1.0, 0.6, p) else motion.effects.lerp(0.6, 1.0, p);
        const motion_dist = if (outgoing) p else 1.0 - p;
        const rot = std.math.degreesToRadians(2.0 * motion_dist);
        const g_div = div_mod.div(c).row().h(line_h).itemsCenter().absolute().offset(x, dy).scale(sc).rotate(rot);
        defer g_div.end();
        var gst = st;
        gst.color = base_color.alpha(base_color.a * alpha);
        widgets.text(c, cluster, gst);
    }
}

test "sharedEnds keeps common grapheme prefix and suffix without overlapping" {
    const t = std.testing;
    try t.expectEqual(SharedEnds{ .prefix = 7, .suffix = 0 }, sharedEnds("Opus 5.5", "Opus 5.1"));
    try t.expectEqual(SharedEnds{ .prefix = 1, .suffix = 2 }, sharedEnds("feature/a", "fix/a"));
    try t.expectEqual(SharedEnds{ .prefix = 2, .suffix = 0 }, sharedEnds("aa", "aaa"));
    try t.expectEqual(SharedEnds{ .prefix = 0, .suffix = 0 }, sharedEnds("Low", "High"));
    // Two distinct ZWJ emoji clusters must never share an internal emoji prefix.
    try t.expectEqual(SharedEnds{ .prefix = 0, .suffix = 3 }, sharedEnds("\u{1f469}\u{200d}\u{1f4bb} v1", "\u{1f469}\u{200d}\u{1f680} v1"));
}
