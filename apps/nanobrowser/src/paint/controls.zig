//! Form controls, drawn by nanoui: text fields and text areas are its own
//! fields, so typing, selection, input methods and the clipboard all work;
//! checkboxes, radios, selects and bars are boxes. Each keeps its state on its
//! element (`Node.value`, `checked`, `selected`), where scripts read it too.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const dom = @import("../dom.zig");
const box = @import("../layout/box.zig");
const replay = @import("replay.zig");
const input = @import("../page_input.zig");
const web = @import("../web/web.zig");
const Page = @import("../page.zig").Page;
const replay_box = @import("replay_box.zig");

/// What a control's checked part is, unless `accent-color` says.
const default_accent = ui.Color.hex(0x0075ff);
const edge = ui.Color.hex(0x767676);
const track_ground = ui.Color.hex(0xefefef);
const track_edge = ui.Color.hex(0xb2b2b2);

fn accent(st: *const box.Style) ui.Color {
    return if (st.accent) |k| replay.color(k) else default_accent;
}

fn ink(st: *const box.Style) ui.Color {
    return replay.color(st.color);
}

fn is(n: *const dom.Node, kind: []const u8) bool {
    return std.ascii.eqlIgnoreCase(n.attr("type") orelse "text", kind);
}

pub fn draw(p: *Page, c: *ui.Context, b: *const box.Box, x: f32, y: f32, opacity: f32) void {
    const n = b.node orelse return;
    if (n.isTag("textarea")) return field(p, c, b, x, y, opacity, true);
    if (n.isTag("select")) return select(c, b, x, y, opacity);
    // `appearance: none`: what the author's CSS drew is all there is, its text aside.
    const own = b.style.appearance_none;
    if (n.isTag("progress") or n.isTag("meter")) return if (own) {} else bar(c, b, x, y, opacity);
    if (n.isTag("input")) {
        if (is(n, "checkbox")) return if (own) {} else check(c, b, x, y, opacity, false);
        if (is(n, "radio")) return if (own) {} else check(c, b, x, y, opacity, true);
        if (is(n, "range")) return if (own) {} else range(c, b, x, y, opacity);
        return field(p, c, b, x, y, opacity, false);
    }
}

/// The element's editor, made the first time it is drawn.
fn editorOf(p: *Page, n: *dom.Node) ?*ui.TextBuffer {
    if (n.editor) |e| {
        const buf: *ui.TextBuffer = @ptrCast(@alignCast(e));
        // A script set the value since.
        if (n.value) |v| if (!std.mem.eql(u8, buf.text(), v)) buf.set(v);
        return buf;
    }
    const buf = p.gpa.create(ui.TextBuffer) catch return null;
    p.editors.append(p.gpa, buf) catch {
        p.gpa.destroy(buf);
        return null;
    };
    buf.* = .{};
    const initial = n.value orelse if (n.isTag("textarea")) (n.textContent(p.arena()) catch "") else n.attr("value") orelse "";
    buf.set(initial);
    buf.want_caret = null;
    n.editor = buf;
    return buf;
}

fn field(p: *Page, c: *ui.Context, b: *const box.Box, x: f32, y: f32, opacity: f32, multi: bool) void {
    const n = b.node.?;
    const buf = editorOf(p, n) orelse return;
    const st = b.style;
    const content = b.contentRect();
    const dx = content.x - b.x;
    const dy = content.y - b.y;
    const line = c.text.lineHeight(replay.textStyle(box.fontOf(st)));
    // Keyed by its element, as the field in it is: what is drawn before it
    // comes and goes (its own `:focus` shadow), and the field keeps the keys.
    c.next_key_int = @intFromPtr(n);
    _ = c.open(.{
        .absolute = true,
        .offset = .{ .x = x + dx, .y = y + (if (multi) dy else dy + @max(0, (content.h - line) / 2) - 2) },
        .width = .{ .px = content.w },
        .height = .{ .px = if (multi) content.h else line + 4 },
        .opacity = opacity,
        .clip = true,
        .control = true,
    }, null);
    defer c.end();
    c.next_key_int = @intFromPtr(n);
    if (web.takeFocusRequest(p, n) or p.field_pressed == n) c.focus = c.peekId(null);
    if (p.field_pressed == n) p.field_pressed = null;
    const lines: f32 = @max(1, content.h / @max(line, 1));
    const r = ui.textField(c, buf, .{
        .placeholder = n.attr("placeholder") orelse "",
        .width = .fill,
        .size = st.font_size,
        .bare = true,
        .password = is(n, "password"),
        .multiline = multi,
        .max_lines = @intFromFloat(@min(lines, 1000)),
        .color = ink(st),
        .placeholder_color = if (st.placeholder) |k| replay.color(k) else ui.Color.hex(0x757575),
    });
    if (r.focused and p.field_focus != n) {
        p.field_focus = n;
        if (p.doc.focus != n) {
            const old = p.doc.focus;
            p.doc.focus = n;
            web.focusChanged(p, old, n);
        }
    } else if (!r.focused and p.field_focus == n) {
        p.field_focus = null;
        if (p.doc.focus == n) {
            p.doc.focus = null;
            web.focusChanged(p, n, null);
        }
    }
    if (r.changed) {
        n.value = p.arena().dupe(u8, buf.text()) catch n.value;
        web.simpleEvent(p, n, "input");
    }
    if (r.submitted and !multi) {
        web.simpleEvent(p, n, "change");
        if (input.formOf(n)) |form| input.submit(p, form, null);
    }
}

fn check(c: *ui.Context, b: *const box.Box, x: f32, y: f32, opacity: f32, round: bool) void {
    const n = b.node.?;
    const on = input.isChecked(n);
    const blue = accent(b.style);
    const w = @min(b.w, b.h);
    const line = @max(1, w * 0.08);
    const face: ui.Style = .{
        .absolute = true,
        .offset = .{ .x = x, .y = y },
        .width = .{ .px = w },
        .height = .{ .px = w },
        .opacity = opacity,
        .radius = if (round) w / 2 else w * 0.2,
        .corner_circular = true,
        .border = if (on) blue else edge,
        .border_width = line,
        // A checked box is all its accent; a radio keeps white between ring and dot.
        .background = if (on and !round) blue else ui.Color.white,
    };
    _ = c.leaf(face, .none, null);
    if (!on) return;
    if (round) {
        const d = w * 0.5;
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x + (w - d) / 2, .y = y + (w - d) / 2 }, .width = .{ .px = d }, .height = .{ .px = d }, .radius = d / 2, .corner_circular = true, .background = blue, .opacity = opacity }, .none, null);
        return;
    }
    const cv = replay_box.newCanvas(c, .{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = w }, .height = .{ .px = w }, .opacity = opacity });
    const stroke: ui.Stroke = .{ .width = @max(1.2, w * 0.14), .color = ui.Color.white };
    const pts = c.alloc().dupe(ui.Point, &.{ .{ .x = w * 0.22, .y = w * 0.52 }, .{ .x = w * 0.42, .y = w * 0.72 }, .{ .x = w * 0.78, .y = w * 0.28 } }) catch return;
    cv.polyline(pts, stroke);
}

fn select(c: *ui.Context, b: *const box.Box, x: f32, y: f32, opacity: f32) void {
    const n = b.node.?;
    const st = b.style;
    const shown = if (input.selectedOption(n)) |o| optionText(c, o) else "";
    _ = c.open(.{
        .absolute = true,
        .offset = .{ .x = x, .y = y },
        .width = .{ .px = b.w },
        .height = .{ .px = b.h },
        .opacity = opacity,
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = b.padding.left + b.border.left + 2, .right = b.padding.right + b.border.right },
        .gap = 4,
        .control = true,
    }, null);
    defer c.end();
    _ = c.leaf(.{ .grow = 1, .clip = true }, .{ .text = .{ .str = shown, .style = replay.textStyle(box.fontOf(st)), .color = ink(st) } }, null);
    if (st.appearance_none) return;
    // The little chevron Chromium's menu lists end in.
    const side: f32 = 16;
    const cv = replay_box.newCanvas(c, .{ .width = .{ .px = side }, .height = .{ .px = side } });
    const pts = c.alloc().dupe(ui.Point, &.{ .{ .x = 4, .y = 6.5 }, .{ .x = 8, .y = 10.5 }, .{ .x = 12, .y = 6.5 } }) catch return;
    cv.polyline(pts, .{ .width = 1.5, .color = ink(st) });
}

fn optionText(c: *ui.Context, o: *dom.Node) []const u8 {
    if (o.attr("label")) |l| return l;
    const raw = o.textContent(c.alloc()) catch return "";
    return std.mem.trim(u8, raw, " \t\r\n");
}

/// The open `<select>`'s options, over the page.
pub fn selectList(p: *Page, c: *ui.Context, rect: box.Rect) void {
    const n = p.open_select orelse return;
    const r = @import("../layout/layout.zig").rectOf(n) orelse return;
    const l = if (p.list) |*x| x else return;
    const sx = l.clips[1].scroll_x;
    const sy = l.clips[1].scroll_y;
    _ = c.open(.{
        .absolute = true,
        .offset = .{ .x = r.x - sx, .y = r.y + r.h - sy + 2 },
        .min_width = r.w,
        .max_height = @max(80, rect.h / 2),
        .scroll = true,
        .padding = .all(4),
        .radius = 8,
        .background = if (c.theme.dark) ui.Color.hex(0x2d2d2d) else ui.Color.white,
        .border = if (c.theme.dark) ui.Color.hex(0x333333) else ui.Color.hex(0xe8e8e8),
        .shadow = .{ .color = .{ .a = 0.16 }, .blur = 18, .y = 6 },
        .layer = 1,
        .control = true,
    }, null);
    defer c.end();
    const shown = input.selectedOption(n);
    var at = n.first_child;
    while (at) |o| : (at = o.nextInTree(n)) {
        if (!o.isTag("option")) continue;
        c.next_key_int = @intFromPtr(o);
        const it = ui.pressable(c, .{ .width = .fill, .padding = .xy(10, 5), .radius = 5, .control = true, .background = if (o == shown) c.theme.surface_hover else null }, c.theme.surface_hover);
        defer c.end();
        ui.text(c, optionText(c, o), .{ .size = 13, .color = c.theme.text });
        if (it.clicked) {
            var other = n.first_child;
            while (other) |k| : (other = k.nextInTree(n)) if (k.isTag("option")) {
                k.selected = k == o;
            };
            p.open_select = null;
            c.changed = true;
            web.simpleEvent(p, n, "input");
            web.simpleEvent(p, n, "change");
        }
    }
}

fn attrNumber(n: *const dom.Node, name: []const u8, or_else: f32) f32 {
    const s = n.attr(name) orelse return or_else;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, s, " ")) catch or_else;
}

fn bar(c: *ui.Context, b: *const box.Box, x: f32, y: f32, opacity: f32) void {
    const n = b.node.?;
    const lo = attrNumber(n, "min", 0);
    const hi = attrNumber(n, "max", 1);
    const v = attrNumber(n, "value", if (n.isTag("progress")) 0 else lo);
    const t = std.math.clamp((v - lo) / @max(hi - lo, 0.0001), 0, 1);
    const fill = if (n.isTag("meter")) ui.Color.hex(0x107c10) else accent(b.style);
    track(c, x, y, b.w, b.h, opacity, t, fill);
}

fn range(c: *ui.Context, b: *const box.Box, x: f32, y: f32, opacity: f32) void {
    const n = b.node.?;
    const lo = attrNumber(n, "min", 0);
    const hi = attrNumber(n, "max", 100);
    const v = if (n.value) |s| std.fmt.parseFloat(f32, s) catch lo else attrNumber(n, "value", (lo + hi) / 2);
    const t = std.math.clamp((v - lo) / @max(hi - lo, 0.0001), 0, 1);
    const h: f32 = 8;
    const blue = accent(b.style);
    track(c, x, y + (b.h - h) / 2, b.w, h, opacity, t, blue);
    const d: f32 = @min(b.h, 16);
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x + (b.w - d) * t, .y = y + (b.h - d) / 2 }, .width = .{ .px = d }, .height = .{ .px = d }, .radius = d / 2, .corner_circular = true, .background = blue, .opacity = opacity }, .none, null);
}

fn track(c: *ui.Context, x: f32, y: f32, w: f32, h: f32, opacity: f32, t: f32, fill: ui.Color) void {
    const round = @min(h / 2, 8);
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = w }, .height = .{ .px = h }, .radius = round, .corner_circular = true, .background = track_ground, .border = track_edge, .opacity = opacity }, .none, null);
    if (t > 0) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = @max(w * t, 2 * round) }, .height = .{ .px = h }, .radius = round, .corner_circular = true, .background = fill, .opacity = opacity }, .none, null);
}
