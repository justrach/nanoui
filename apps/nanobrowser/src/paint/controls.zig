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
    if (n.isTag("progress") or n.isTag("meter")) return bar(c, b, x, y, opacity);
    if (n.isTag("input")) {
        if (is(n, "checkbox")) return check(c, b, x, y, opacity, false);
        if (is(n, "radio")) return check(c, b, x, y, opacity, true);
        if (is(n, "range")) return range(c, b, x, y, opacity);
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
        .placeholder_color = ink(st).alpha(0.45),
    });
    if (r.focused and p.doc.focus != n) p.doc.focus = n;
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
    const blue = ui.Color.hex(0x0a84ff);
    const w = @min(b.w, b.h);
    const i = c.open(.{
        .absolute = true,
        .offset = .{ .x = x, .y = y },
        .width = .{ .px = w },
        .height = .{ .px = w },
        .opacity = opacity,
        .radius = if (round) w / 2 else 3,
        .corner_circular = true,
        .border = if (on) blue else ui.Color.hex(0x8c8c8c),
        .background = if (on) blue else ui.Color.white,
        .align_items = .center,
        .justify = .center,
    }, null);
    defer c.end();
    _ = i;
    if (!on) return;
    if (round) {
        const d = w * 0.4;
        _ = c.leaf(.{ .width = .{ .px = d }, .height = .{ .px = d }, .radius = d / 2, .corner_circular = true, .background = ui.Color.white }, .none, null);
    } else ui.icon(c, "checkmark", .{ .size = w * 0.72, .weight = .bold, .color = ui.Color.white });
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
        .padding = .{ .left = b.padding.left + b.border.left + 2, .right = 6 },
        .gap = 4,
        .control = true,
    }, null);
    defer c.end();
    _ = c.leaf(.{ .grow = 1, .clip = true }, .{ .text = .{ .str = shown, .style = replay.textStyle(box.fontOf(st)), .color = ink(st) } }, null);
    ui.icon(c, "chevron.up.chevron.down", .{ .size = @max(9, st.font_size * 0.7), .color = ink(st).alpha(0.6) });
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
    track(c, x, y, b.w, b.h, opacity, t);
}

fn range(c: *ui.Context, b: *const box.Box, x: f32, y: f32, opacity: f32) void {
    const n = b.node.?;
    const lo = attrNumber(n, "min", 0);
    const hi = attrNumber(n, "max", 100);
    const v = if (n.value) |s| std.fmt.parseFloat(f32, s) catch lo else attrNumber(n, "value", (lo + hi) / 2);
    const t = std.math.clamp((v - lo) / @max(hi - lo, 0.0001), 0, 1);
    const h: f32 = 4;
    track(c, x, y + (b.h - h) / 2, b.w, h, opacity, t);
    const d: f32 = @min(b.h, 16);
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x + (b.w - d) * t, .y = y + (b.h - d) / 2 }, .width = .{ .px = d }, .height = .{ .px = d }, .radius = d / 2, .corner_circular = true, .background = ui.Color.white, .border = ui.Color.hex(0x8c8c8c), .opacity = opacity }, .none, null);
}

fn track(c: *ui.Context, x: f32, y: f32, w: f32, h: f32, opacity: f32, t: f32) void {
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = w }, .height = .{ .px = h }, .radius = h / 2, .corner_circular = true, .background = ui.Color.hex(0xe0e0e0), .opacity = opacity }, .none, null);
    if (t > 0) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = w * t }, .height = .{ .px = h }, .radius = h / 2, .corner_circular = true, .background = ui.Color.hex(0x0a84ff), .opacity = opacity }, .none, null);
}
