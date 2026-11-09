//! What shows a state rather than takes input: tags, badges, avatars (and
//! a stack of them), alerts, skeletons that breathe while content loads,
//! spinners, progress bars (and the indeterminate kind), progress rings, a
//! separator and an empty state.
const std = @import("std");
const ui = @import("../ui/ui.zig");
const kit = @import("kit.zig");
const Color = ui.Color;

pub const TagOptions = struct {
    status: kit.Status = .neutral,
    /// Its own color, over the status's.
    color: ?Color = null,
    outline: bool = false,
    pill: bool = false,
    icon: []const u8 = "",
    size: kit.Size = .sm,
};

/// A small labelled chip.
pub fn tag(c: *ui.Context, label: []const u8, opts: TagOptions) void {
    const t = kit.tokens(c);
    const col = opts.color orelse if (opts.status == .neutral) t.foreground else kit.statusColor(t, opts.status);
    const size = opts.size.text() - 1;
    var d = ui.div(c).row().gap(4).itemsCenter().px(size * 0.6).py(size * 0.18).rounded(if (opts.pill) 99 else 5);
    d = if (opts.outline) d.border(col.alpha(0.5)) else d.bg(col.alpha(if (opts.status == .neutral and opts.color == null) 0.08 else 0.14));
    defer d.end();
    if (opts.icon.len > 0) ui.icon(c, opts.icon, .{ .size = size, .color = col });
    ui.text(c, label, .{ .size = size, .weight = .medium, .color = col });
}

/// A count (or a dot, for 0 and `dot`) for the corner of what was just
/// drawn: call it right after the box it marks, inside the same parent,
/// which should be `relative` to it (a row or a small box). Over `max`, "max+".
pub fn badge(c: *ui.Context, count: u32, opts: struct { dot: bool = false, max: u32 = 99, color: ?Color = null, x: f32 = 0, y: f32 = 0 }) void {
    const t = kit.tokens(c);
    const col = opts.color orelse t.danger;
    if (opts.dot or count == 0) {
        const dot = ui.div(c).absolute().offset(opts.x - 3, opts.y - 3).w(9).h(9).roundedFull().bg(col).border(t.background).borderW(1.5);
        dot.end();
        return;
    }
    const label = if (count > opts.max) c.print("{d}+", .{opts.max}) else c.print("{d}", .{count});
    const d = ui.div(c).absolute().offset(opts.x - 8, opts.y - 8).h(17).px(5).roundedFull().bg(col).border(t.background).borderW(1.5).center();
    defer d.end();
    ui.text(c, label, .{ .size = 10, .weight = .bold, .color = .white });
}

/// A person: their picture, else their initials on a color their name
/// picks, in a circle `size` points across.
pub fn avatar(c: *ui.Context, opts: struct { name: []const u8 = "", image: ?[]const u8 = null, size: f32 = 32, ring: ?Color = null }) void {
    const t = kit.tokens(c);
    var d = ui.div(c).w(opts.size).h(opts.size).roundedFull().center().clip();
    if (opts.ring) |r| d = d.border(r).borderW(2);
    defer d.end();
    if (opts.image) |png| {
        _ = ui.image(c, .{ .key = opts.name, .source = .{ .encoded = png }, .max_width = opts.size, .max_height = opts.size, .radius = opts.size / 2 });
        return;
    }
    const hues = [_]u24{ 0xe8453c, 0xe8833c, 0xc9a227, 0x3fae5a, 0x16a3a3, 0x2f6fd0, 0x6d4fd0, 0xb447a8 };
    const pick = std.hash.Wyhash.hash(0, opts.name) % hues.len;
    c.node(d.index).style.background = if (opts.name.len == 0) t.surface_hover else Color.hex(hues[pick]);
    var buf: [8]u8 = undefined;
    // Into the frame's memory: text is drawn after this returns.
    ui.text(c, c.print("{s}", .{initials(&buf, opts.name)}), .{ .size = opts.size * 0.4, .weight = .semibold, .color = if (opts.name.len == 0) t.muted else .white });
}

/// Up to two initials: the first letters of the first and last words.
pub fn initials(buf: []u8, name: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, name, " -_.");
    const first = it.next() orelse return "?";
    var last: ?[]const u8 = null;
    while (it.next()) |w| last = w;
    var n: usize = 0;
    buf[n] = std.ascii.toUpper(first[0]);
    n += 1;
    if (last) |l| {
        buf[n] = std.ascii.toUpper(l[0]);
        n += 1;
    }
    return buf[0..n];
}

/// Avatars overlapping, with "+n" for those past `max`.
pub fn avatarGroup(c: *ui.Context, names: []const []const u8, opts: struct { size: f32 = 28, max: usize = 4 }) void {
    const t = kit.tokens(c);
    const r = ui.div(c).row().itemsCenter();
    defer r.end();
    const shown = @min(names.len, opts.max);
    for (names[0..shown], 0..) |name, i| {
        ui.key(c, c.print("av-{d}", .{i}));
        const slot = ui.div(c).offset(-@as(f32, @floatFromInt(i)) * opts.size * 0.22, 0);
        defer slot.end();
        avatar(c, .{ .name = name, .size = opts.size, .ring = t.background });
    }
    if (names.len > shown) {
        const more = ui.div(c).offset(-@as(f32, @floatFromInt(shown)) * opts.size * 0.22, 0).w(opts.size).h(opts.size).roundedFull().center().bg(t.surface_hover).border(t.background).borderW(2);
        defer more.end();
        ui.text(c, c.print("+{d}", .{names.len - shown}), .{ .size = opts.size * 0.36, .weight = .semibold, .color = t.muted });
    }
}

/// A message in a box tinted by its status; true when its ✕ was clicked.
pub fn alert(c: *ui.Context, opts: struct { status: kit.Status = .info, title: []const u8 = "", description: []const u8 = "", closable: bool = false, banner: bool = false }) bool {
    const t = kit.tokens(c);
    const col = kit.statusColor(t, opts.status);
    var d = ui.div(c).row().wFull().gap(10).itemsStart().p(12).bg(col.alpha(0.08)).border(col.alpha(0.35));
    d = if (opts.banner) d.rounded(0) else d.rounded(t.radius);
    defer d.end();
    ui.icon(c, kit.statusIcon(opts.status), .{ .size = 15, .color = col });
    var closed = false;
    {
        // Growing, not zero-wide: wrapped text gives back what the row lacks.
        const body = ui.div(c).column().grow().gap(3);
        defer body.end();
        if (opts.title.len > 0) ui.text(c, opts.title, .{ .size = 13, .weight = .semibold, .color = t.foreground });
        if (opts.description.len > 0) ui.text(c, opts.description, .{ .size = 12.5, .color = t.muted, .wrap = true });
    }
    if (opts.closable) closed = kit.iconButton(c, "xmark", .{ .size = .xs }).clicked;
    return closed;
}

/// A placeholder that breathes where content will be.
pub fn skeleton(c: *ui.Context, opts: struct { width: ui.Length = .fill, height: f32 = 14, radius: f32 = 6, circle: bool = false }) void {
    const t = kit.tokens(c);
    const f = ui.motion.keyframes(c, .{ .values = &.{ .{ .opacity = 1 }, .{ .opacity = 0.45 }, .{ .opacity = 1 } }, .duration = 1.6, .repeat = null });
    var st: ui.Style = .{ .width = opts.width, .height = .{ .px = opts.height }, .radius = if (opts.circle) opts.height / 2 else opts.radius, .background = t.surface_hover.mix(t.border, 0.4) };
    if (opts.circle) st.width = .{ .px = opts.height };
    f.apply(&st);
    _ = c.leaf(st, .none, null);
}

/// Dots in a ring, one bright running round it.
pub fn spinner(c: *ui.Context, opts: struct { size: f32 = 16, color: ?Color = null }) void {
    const t = kit.tokens(c);
    const col = opts.color orelse t.muted;
    const box = ui.div(c).w(opts.size).h(opts.size);
    defer box.end();
    const n = 8;
    const head: f32 = @floatCast(@mod(c.time * 1.25, 1) * n);
    const dot = @max(1.5, opts.size * 0.2);
    const r = (opts.size - dot) / 2;
    for (0..n) |i| {
        const a = @as(f32, @floatFromInt(i)) / n * 2 * std.math.pi;
        // Brightest at the head, fading behind it.
        const behind = @mod(head - @as(f32, @floatFromInt(i)) + n, n);
        const alpha = 0.2 + 0.8 * (1 - behind / n);
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = opts.size / 2 + r * @sin(a) - dot / 2, .y = opts.size / 2 - r * @cos(a) - dot / 2 }, .width = .{ .px = dot }, .height = .{ .px = dot }, .radius = dot / 2, .background = col.alpha(alpha) }, .none, null);
    }
    c.animationFrame();
}

/// A bar `value` (0 to 1) full, easing there; null runs back and forth
/// (indeterminate).
pub fn progress(c: *ui.Context, value: ?f32, opts: struct { status: kit.Status = .neutral, height: f32 = 6, width: ui.Length = .fill }) void {
    const t = kit.tokens(c);
    const col = if (opts.status == .neutral) t.primary else kit.statusColor(t, opts.status);
    const track = ui.div(c).h(opts.height).roundedFull().bg(t.surface_hover.mix(t.border, 0.5)).clip();
    c.node(track.index).style.width = opts.width;
    defer track.end();
    const w = (track.interaction().rect orelse ui.Rect{ .x = 0, .y = 0, .w = 200, .h = 0 }).w;
    if (value) |v| {
        const shown = ui.motion.number(c, "progress", std.math.clamp(v, 0, 1), .{ .tween = .{ .duration = 0.35 } });
        _ = c.leaf(.{ .width = .{ .px = w * shown }, .height = .fill, .radius = opts.height / 2, .background = col }, .none, null);
    } else {
        const u: f32 = @floatCast(@mod(c.time * 0.8, 1));
        const e = ui.motion.Easing.sample(.ease_in_out, u)[0];
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = -0.4 * w + 1.4 * w * e, .y = 0 }, .width = .{ .px = w * 0.4 }, .height = .fill, .radius = opts.height / 2, .background = col }, .none, null);
        c.animationFrame();
    }
}

/// A ring of dots `value` full, with a label in it (a gauge).
pub fn ring(c: *ui.Context, value: f32, opts: struct { size: f32 = 56, label: []const u8 = "", color: ?Color = null }) void {
    const t = kit.tokens(c);
    const col = opts.color orelse t.primary;
    const box = ui.div(c).w(opts.size).h(opts.size).center();
    defer box.end();
    const n: usize = @intFromFloat(@max(12, opts.size * 0.55));
    const dot = @max(2, opts.size * 0.06);
    const filled: usize = @intFromFloat(@round(std.math.clamp(value, 0, 1) * @as(f32, @floatFromInt(n))));
    const r = (opts.size - dot) / 2;
    for (0..n) |i| {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)) * 2 * std.math.pi;
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = opts.size / 2 + r * @sin(a) - dot / 2, .y = opts.size / 2 - r * @cos(a) - dot / 2 }, .width = .{ .px = dot }, .height = .{ .px = dot }, .radius = dot / 2, .background = if (i < filled) col else t.surface_hover.mix(t.border, 0.5) }, .none, null);
    }
    ui.text(c, if (opts.label.len > 0) opts.label else c.print("{d:.0}%", .{value * 100}), .{ .size = opts.size * 0.24, .weight = .semibold, .mono = true, .color = t.foreground });
}

/// A thin rule, across or (`vertical`) down.
pub fn separator(c: *ui.Context, opts: struct { vertical: bool = false, label: []const u8 = "" }) void {
    const t = kit.tokens(c);
    if (opts.vertical) {
        _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = t.border }, .none, null);
        return;
    }
    if (opts.label.len == 0) {
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = t.border }, .none, null);
        return;
    }
    const r = ui.div(c).row().wFull().gap(10).itemsCenter();
    defer r.end();
    _ = c.leaf(.{ .grow = 1, .height = .{ .px = 1 }, .background = t.border }, .none, null);
    ui.text(c, opts.label, .{ .size = 11.5, .color = t.muted });
    _ = c.leaf(.{ .grow = 1, .height = .{ .px = 1 }, .background = t.border }, .none, null);
}

/// Nothing here yet: an icon, a title, a line, and room for an action.
pub fn empty(c: *ui.Context, opts: struct { icon: []const u8 = "tray", title: []const u8 = "Nothing here", description: []const u8 = "" }) void {
    const t = kit.tokens(c);
    const d = ui.div(c).column().wFull().gap(6).py(28).itemsCenter();
    defer d.end();
    ui.icon(c, opts.icon, .{ .size = 28, .color = t.muted });
    ui.text(c, opts.title, .{ .size = 14, .weight = .semibold, .color = t.foreground });
    if (opts.description.len > 0) ui.text(c, opts.description, .{ .size = 12.5, .color = t.muted });
}

test "initials: first and last words" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("AL", initials(&buf, "ada lovelace"));
    try std.testing.expectEqualStrings("GH", initials(&buf, "Grace Brewster Hopper"));
    try std.testing.expectEqualStrings("Z", initials(&buf, "zig"));
    try std.testing.expectEqualStrings("?", initials(&buf, ""));
}
