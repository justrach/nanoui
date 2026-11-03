//! Selecting text as a terminal or a page lets you: in a box styled
//! `selectable`, a press on its text starts a selection, a drag extends it
//! across lines and boxes in reading order, and Copy (⌘C, or the Edit menu)
//! takes it, unless the focused text field has a selection of its own.
//! A drag is not a click. Paint finds where the pointer is in the text and
//! draws the highlight; the frame after updates the ends.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const text_mod = @import("text.zig");

pub const Point = struct { id: u64, at: usize };

pub const Selection = struct {
    anchor: ?Point = null,
    focus: ?Point = null,
    dragging: bool = false,
    /// The pointer moved the selection since it was pressed: its release
    /// is not a click.
    moved: bool = false,
    /// A press this frame, to be resolved after paint.
    pressed: bool = false,
    /// The press was on a text field, which selects in itself.
    blocked: bool = false,
    /// Where the pointer is in the text, found by this frame's paint.
    hit: ?Point = null,
    hit_word: ?[2]usize = null,
    hit_line: ?[2]usize = null,
    hit_str: []const u8 = "",
    /// The end of the last line above the pointer, if it is between lines.
    below: ?Point = null,
    /// Selectable texts in reading order: last frame's, and this one's.
    order: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    next_order: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// The selected text as last painted, for Copy.
    text: std.ArrayList(u8) = .empty,
    last_id: u64 = 0,
    /// Where selectable lines were painted, for the pointer's cursor
    /// between frames.
    lines: std.ArrayList(types.Rect) = .empty,
    /// The tree index of the box under the pointer that takes it (a
    /// button, a pill over the text), if any: texts before it in the tree
    /// are under it, and the pointer is not on them.
    cover: ?u32 = null,

    pub fn deinit(s: *Selection, gpa: std.mem.Allocator) void {
        s.order.deinit(gpa);
        s.next_order.deinit(gpa);
        s.text.deinit(gpa);
        s.lines.deinit(gpa);
    }

    pub fn clear(s: *Selection) void {
        s.anchor = null;
        s.focus = null;
        s.text.clearRetainingCapacity();
    }

    fn before(s: *const Selection, a: Point, b: Point) bool {
        const oa = s.order.get(a.id) orelse return false;
        const ob = s.order.get(b.id) orelse return false;
        return oa < ob or (oa == ob and a.at < b.at);
    }

    /// The selected bytes of text `id` (`len` long), or null.
    fn range(s: *const Selection, id: u64, len: usize) ?[2]usize {
        var lo = s.anchor orelse return null;
        var hi = s.focus orelse return null;
        if (s.before(hi, lo)) std.mem.swap(Point, &lo, &hi);
        const o = s.order.get(id) orelse return null;
        const olo = s.order.get(lo.id) orelse return null;
        const ohi = s.order.get(hi.id) orelse return null;
        if (o < olo or o > ohi) return null;
        const from = if (o == olo) lo.at else 0;
        const to = if (o == ohi) hi.at else len;
        if (to <= from) return null;
        return .{ from, to };
    }
};

/// Called by paint for each line `[start, end)` of selectable text `id`,
/// laid out as `lay` at (x, y), `lh` high, in a box spanning `bx`…`bx_end`:
/// notes where the pointer is, draws the highlight, gathers the text.
pub fn line(c: anytype, out: *std.ArrayList(gpu.Instance), id: u64, index: u32, str: []const u8, start: usize, end: usize, lay: text_mod.Layout, x: f32, y: f32, lh: f32, bx: f32, bx_end: f32, clip4: [4]f32) void {
    const s = &c.selection;
    const count: u32 = @intCast(s.next_order.count());
    if (s.next_order.getOrPut(c.gpa, id) catch null) |g| if (!g.found_existing) {
        g.value_ptr.* = count;
    };
    // Where the pointer finds the line: a little past its box's sides.
    const area: types.Rect = .{ .x = bx - 6, .y = y, .w = bx_end - bx + 12, .h = lh };
    // Under a box drawn over it, the line is not there for the pointer
    // (unless a selection is being dragged across).
    const covered = if (s.cover) |k| index < k and !s.dragging else false;
    if (!covered) s.lines.append(c.gpa, area) catch {};
    const m = c.input.mouse;
    if (!covered and area.contains(m)) {
        const at = start + indexAt(lay, m.x - x, end - start);
        s.hit = .{ .id = id, .at = at };
        const te = @import("textedit.zig");
        const word_at = if (at > start and (at >= end or !te.isWordByte(str[at])) and te.isWordByte(str[at - 1])) at - 1 else at;
        s.hit_word = .{ te.prevWord(str, word_at), te.nextWord(str, word_at) };
        s.hit_line = .{ start, end };
        s.hit_str = str;
        // Over text that selects: the text cursor, as over a text field.
        c.cursor_text = true;
    } else if (y + lh <= m.y) s.below = .{ .id = id, .at = end };
    const r = s.range(id, str.len) orelse return;
    const a = @max(r[0], start);
    const b = @min(r[1], end);
    if (b <= a and !(r[0] <= start and r[1] > end)) return;
    const x0 = x + xAt(lay, a - start);
    // A selection running on past the line's end takes its newline too.
    const x1 = if (b >= end and r[1] > end) x + lay.width + 4 else x + xAt(lay, b - start);
    if (x1 > x0) out.append(c.gpa, .{
        .rect = .{ x0, y, x1 - x0, lh },
        .color = gpu.color4(c.theme.accent.alpha(0.28)),
        .clip = clip4,
    }) catch {};
    if (s.text.items.len > 0 and s.last_id != 0) s.text.append(c.gpa, '\n') catch {};
    s.text.appendSlice(c.gpa, str[a..b]) catch {};
    s.last_id = id;
}

fn xAt(lay: text_mod.Layout, at: usize) f32 {
    for (lay.glyphs) |g| if (g.index >= at) return g.x;
    return lay.width;
}

/// The byte nearest `x` in the line.
fn indexAt(lay: text_mod.Layout, x: f32, len: usize) usize {
    var best: usize = 0;
    var best_d: f32 = @abs(x);
    for (lay.glyphs, 0..) |g, i| {
        const next_x = if (i + 1 < lay.glyphs.len) lay.glyphs[i + 1].x else lay.width;
        const next_at: usize = if (i + 1 < lay.glyphs.len) lay.glyphs[i + 1].index else len;
        const d = @abs(x - next_x);
        if (d < best_d) {
            best_d = d;
            best = next_at;
        }
        _ = g;
    }
    return best;
}

/// Before paint: the gathered text starts over.
pub fn beginPaint(c: anytype) void {
    const s = &c.selection;
    s.text.clearRetainingCapacity();
    s.lines.clearRetainingCapacity();
    s.next_order.clearRetainingCapacity();
    s.hit = null;
    s.hit_word = null;
    s.hit_line = null;
    s.hit_str = "";
    s.below = null;
    s.cover = null;
    if (c.hot != 0) {
        if (c.hot_index < c.nodes.items.len and c.nodes.items[c.hot_index].id == c.hot) {
            s.cover = c.hot_index;
        } else for (c.nodes.items, 0..) |n, i| if (n.id == c.hot) {
            s.cover = @intCast(i);
            break;
        };
    }
}

/// After paint: a press starts a selection (or clears it), a drag moves
/// its end; and this frame's reading order becomes the one compared.
pub fn afterPaint(c: anytype) void {
    const s = &c.selection;
    std.mem.swap(std.AutoHashMapUnmanaged(u64, u32), &s.order, &s.next_order);
    if (s.pressed) {
        s.pressed = false;
        s.moved = false;
        if (s.hit != null and !s.blocked) {
            const h = s.hit.?;
            if (c.input.click_count >= 3 and s.hit_line != null) {
                const hl = s.hit_line.?;
                s.anchor = .{ .id = h.id, .at = hl[0] };
                s.focus = .{ .id = h.id, .at = hl[1] };
                s.text.clearRetainingCapacity();
                s.text.appendSlice(c.gpa, s.hit_str[hl[0]..hl[1]]) catch {};
                c.animating = true;
            } else if (c.input.click_count == 2 and s.hit_word != null) {
                const hw = s.hit_word.?;
                s.anchor = .{ .id = h.id, .at = hw[0] };
                s.focus = .{ .id = h.id, .at = hw[1] };
                s.text.clearRetainingCapacity();
                s.text.appendSlice(c.gpa, s.hit_str[hw[0]..hw[1]]) catch {};
                c.animating = true;
            } else {
                s.anchor = h;
                s.focus = h;
            }
            s.dragging = true;
        } else if (!s.blocked) s.clear();
    } else if (s.dragging and c.input.down) {
        if (s.hit orelse s.below) |p| if (s.focus == null or !std.meta.eql(p, s.focus.?)) {
            s.focus = p;
            if (s.anchor != null and !std.meta.eql(p, s.anchor.?)) s.moved = true;
            c.animating = true;
        };
    }
    if (!c.input.down) s.dragging = false;
    // While selecting, the text cursor wherever the pointer goes.
    if (s.dragging) c.cursor_text = true;
}
