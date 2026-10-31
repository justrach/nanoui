//! Accessibility, for every platform: what a screen reader is told about
//! a frame, and what the system asks of the view (Dynamic Type, Increase
//! Contrast, Bold Text, Reduce Motion is `Context.reduced_motion`).
//!
//! nanoui draws everything itself, so a screen reader sees nothing unless
//! the view describes it. Widgets register themselves (`Context.addA11y`:
//! buttons, toggles, sliders, fields); `tree` turns the frame into the
//! list of elements VoiceOver walks, in reading order, adding what the view
//! didn't describe: a box that takes clicks (`interact`) becomes a button
//! labeled by the text inside it, text outside any element static text,
//! large text a heading. `describe` labels a box yourself, `hide` keeps a
//! decoration out, `announce` speaks.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const Theme = @import("theme.zig").Theme;

pub const Role = enum { button, tab, text_field, splitter, slider, checkbox, switch_toggle, radio_button, group, static_text, list, row, image, menu_button, popover, link };

pub const Item = struct {
    id: u64,
    node_index: u32,
    role: Role,
    label: []const u8,
    value: []const u8 = "",
    selected: bool = false,
    enabled: bool = true,
    /// Takes AXIncrement / AXDecrement (`Context.adjustable`).
    adjustable: bool = false,
    /// What happens when it is activated ("Opens the stop"), read after a pause.
    hint: []const u8 = "",
    header: bool = false,
    /// Left out, with what is inside it (a decoration, a duplicate).
    hidden: bool = false,
};

/// What the system asks for, set by the platform before each frame, and
/// what the view asks of it, sent after the frame.
pub const Access = struct {
    /// Dynamic Type: the reader's text size over the default (1 at
    /// "Large", the iOS default; 0.82 to 3.1).
    text_scale: f32 = 1,
    /// Text follows `text_scale`; a view with a fixed layout turns it off.
    dynamic_type: bool = true,
    /// The view's own zoom (`Context.setZoom`), times `text_scale`.
    zoom: f32 = 1,
    /// Increase Contrast (iOS "Darker system colors"): stronger borders
    /// and text are wanted.
    increase_contrast: bool = false,
    bold_text: bool = false,
    /// VoiceOver (or another screen reader) is running.
    screen_reader: bool = false,
    /// To be spoken after this frame (`announce`).
    announcement: [256]u8 = undefined,
    announcement_len: usize = 0,
    /// The screen changed (`screenChanged`): VoiceOver starts again at its top.
    screen_changed: bool = false,
};

/// The zoom text is drawn at: the view's, times Dynamic Type's.
pub fn applyZoom(c: *Context) void {
    const sys: f32 = if (c.access.dynamic_type) c.access.text_scale else 1;
    c.text.setZoom(std.math.clamp(c.access.zoom * sys, 0.5, 3));
}

/// The theme with Increase Contrast's stronger text, borders and tracks
/// when the system asks for it.
pub fn themed(c: *const Context, t: Theme) Theme {
    if (!c.access.increase_contrast) return t;
    var h = t;
    h.muted = t.muted.mix(t.text, 0.6);
    h.border = t.border.mix(t.text, 0.5);
    h.track = t.track.mix(t.text, 0.35);
    return h;
}

/// Dynamic Type's size over "Large", from UIKit's content size category
/// name (UICTContentSizeCategoryXL...): body text's 17 pt at L.
pub fn textScaleOf(category: []const u8) f32 {
    const table = [_]struct { []const u8, f32 }{
        .{ "UICTContentSizeCategoryXS", 14.0 / 17.0 },
        .{ "UICTContentSizeCategoryS", 15.0 / 17.0 },
        .{ "UICTContentSizeCategoryM", 16.0 / 17.0 },
        .{ "UICTContentSizeCategoryL", 1 },
        .{ "UICTContentSizeCategoryXL", 19.0 / 17.0 },
        .{ "UICTContentSizeCategoryXXL", 21.0 / 17.0 },
        .{ "UICTContentSizeCategoryXXXL", 23.0 / 17.0 },
        .{ "UICTContentSizeCategoryAccessibilityM", 28.0 / 17.0 },
        .{ "UICTContentSizeCategoryAccessibilityL", 33.0 / 17.0 },
        .{ "UICTContentSizeCategoryAccessibilityXL", 40.0 / 17.0 },
        .{ "UICTContentSizeCategoryAccessibilityXXL", 47.0 / 17.0 },
        .{ "UICTContentSizeCategoryAccessibilityXXXL", 53.0 / 17.0 },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], category)) return e[1];
    return 1;
}

/// Speaks `message` after this frame (VoiceOver's announcement): a stop
/// starred, a bus arriving. The last one in a frame wins.
pub fn announce(c: *Context, message: []const u8) void {
    const n = @min(message.len, c.access.announcement.len);
    @memcpy(c.access.announcement[0..n], message[0..n]);
    c.access.announcement_len = n;
}

/// A new screen came (a page pushed, a sheet up): VoiceOver moves to its
/// first element instead of staying where it was.
pub fn screenChanged(c: *Context) void {
    c.access.screen_changed = true;
}

pub const Describe = struct {
    role: Role = .button,
    label: []const u8 = "",
    value: []const u8 = "",
    hint: []const u8 = "",
    selected: bool = false,
    enabled: bool = true,
    header: bool = false,
};

/// Box `index` as one element, labeled so (its text when `label` is
/// empty); what is inside it is read as part of it.
pub fn describe(c: *Context, index: u32, d: Describe) void {
    const n = c.a11y_items.items.len;
    c.addA11y(index, d.role, d.label, d.value, d.selected, d.enabled);
    if (c.a11y_items.items.len == n) return;
    const it = &c.a11y_items.items[n];
    it.hint = if (d.hint.len > 0) (c.alloc().dupe(u8, d.hint) catch d.hint) else "";
    it.header = d.header;
}

/// Box `index` and what is inside it, left out: a decoration.
pub fn hide(c: *Context, index: u32) void {
    c.a11y_items.append(c.gpa, .{ .id = c.nodes.items[index].id, .node_index = index, .role = .group, .label = "", .hidden = true }) catch {};
}

/// One element a screen reader walks, in reading order.
pub const Element = struct {
    id: u64,
    role: Role,
    label: []const u8,
    value: []const u8 = "",
    hint: []const u8 = "",
    /// Its visible part, in view points (clipped by scrolling parents).
    rect: types.Rect,
    selected: bool = false,
    enabled: bool = true,
    adjustable: bool = false,
    header: bool = false,
    /// Made by `tree`, not registered by a widget.
    implied: bool = false,
};

/// Text this size or larger, outside any element, is a heading.
pub const heading_size: f32 = 20;

/// The frame's elements in reading order (the order the view built its
/// boxes), their strings in `arena`.
pub fn tree(c: *Context, arena: std.mem.Allocator, out: *std.ArrayList(Element)) !void {
    const nodes = c.nodes.items;
    if (nodes.len == 0) return;
    const Flag = packed struct { claimed: bool = false, hidden: bool = false };
    const flags = try arena.alloc(Flag, nodes.len);
    const clips = try arena.alloc(types.Rect, nodes.len);
    const items = try arena.alloc(?u32, nodes.len);
    @memset(items, null);
    for (c.a11y_items.items, 0..) |it, k| if (it.node_index < nodes.len) {
        // The first registration of a box is its own (a field's, before an app's).
        if (items[it.node_index] == null or it.hidden) items[it.node_index] = @intCast(k);
    };
    const view: types.Rect = .{ .x = 0, .y = 0, .w = c.size.w, .h = c.size.h };
    for (nodes, 0..) |n, i| {
        var f: Flag = .{};
        var clip = view;
        if (n.parent != ctx_mod.none and n.parent < i) {
            f = flags[n.parent];
            clip = clips[n.parent];
            const p = nodes[n.parent];
            if (p.style.scroll or p.style.scroll_x or p.style.clip) clip = intersect(clip, p.rect);
        }
        if (n.style.opacity <= 0.01) f.hidden = true;
        clips[i] = clip;
        defer flags[i] = f;
        if (f.hidden or f.claimed) continue;
        const vis = intersect(clip, n.rect);
        if (items[i]) |k| {
            const it = c.a11y_items.items[k];
            if (it.hidden) {
                f.hidden = true;
                continue;
            }
            f.claimed = true;
            if (vis.w <= 0 or vis.h <= 0) continue;
            var label = if (it.label.len > 0) it.label else try textOf(c, arena, @intCast(i));
            if (label.len == 0) label = takeCaption(out, vis);
            try out.append(arena, .{ .id = it.id, .role = it.role, .label = label, .value = it.value, .hint = it.hint, .rect = vis, .selected = it.selected, .enabled = it.enabled, .adjustable = it.adjustable, .header = it.header });
            continue;
        }
        if (n.interactive and !n.style.scroll and !n.style.scroll_x and !holdsControls(c, items, @intCast(i))) {
            const label = try textOf(c, arena, @intCast(i));
            if (label.len == 0) continue;
            f.claimed = true;
            if (vis.w <= 0 or vis.h <= 0) continue;
            try out.append(arena, .{ .id = n.id, .role = .button, .label = label, .rect = vis, .implied = true });
            continue;
        }
        switch (n.content) {
            .text => |t| {
                if (vis.w <= 0 or vis.h <= 0 or std.mem.trim(u8, t.str, " \t\n").len == 0) continue;
                try out.append(arena, .{ .id = n.id, .role = .static_text, .label = t.str, .rect = vis, .header = t.style.size >= heading_size, .implied = true });
            },
            else => {},
        }
    }
}

/// The text just before an unlabeled control on its line ("Volume" left
/// of a slider) names it, and is not read twice.
fn takeCaption(out: *std.ArrayList(Element), r: types.Rect) []const u8 {
    const prev = if (out.items.len > 0) out.items[out.items.len - 1] else return "";
    const mid = prev.rect.y + prev.rect.h / 2;
    if (prev.role != .static_text or prev.header or mid < r.y or mid > r.y + r.h or prev.rect.x + prev.rect.w > r.x + 1) return "";
    _ = out.pop();
    return prev.label;
}

/// Another element inside box `i`: it is a container (a card, a page
/// that dismisses on a tap outside), not one button.
fn holdsControls(c: *Context, items: []const ?u32, i: u32) bool {
    const nodes = c.nodes.items;
    var k = nodes[i].first_child;
    while (k != ctx_mod.none) : (k = nodes[k].next) {
        if (nodes[k].interactive or items[k] != null) return true;
        if (holdsControls(c, items, k)) return true;
    }
    return false;
}

/// The text inside box `i`, its pieces joined with ", "; an icon's name
/// in words when there is no text ("Back" for a chevron.left).
pub fn textOf(c: *Context, arena: std.mem.Allocator, i: u32) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var icon: []const u8 = "";
    try collectText(c, arena, i, &buf, &icon);
    if (buf.items.len == 0) return iconWords(icon);
    return buf.items;
}

fn collectText(c: *Context, arena: std.mem.Allocator, i: u32, buf: *std.ArrayList(u8), icon: *[]const u8) !void {
    const n = c.nodes.items[i];
    if (n.style.opacity <= 0.01) return;
    switch (n.content) {
        .text => |t| {
            const s = std.mem.trim(u8, t.str, " \t\n");
            if (s.len > 0) {
                if (buf.items.len > 0) try buf.appendSlice(arena, ", ");
                try buf.appendSlice(arena, s);
            }
        },
        .icon => |ic| if (icon.len == 0) {
            icon.* = ic.name;
        },
        else => {},
    }
    var k = n.first_child;
    while (k != ctx_mod.none) : (k = c.nodes.items[k].next) try collectText(c, arena, k, buf, icon);
}

/// Common SF Symbols in words, for a button that is only an icon.
pub fn iconWords(name: []const u8) []const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "chevron.left", "Back" },    .{ "arrow.left", "Back" },        .{ "xmark", "Close" },
        .{ "plus", "Add" },              .{ "magnifyingglass", "Search" }, .{ "trash", "Delete" },
        .{ "ellipsis", "More" },         .{ "gearshape", "Settings" },     .{ "gear", "Settings" },
        .{ "star", "Favorite" },         .{ "star.fill", "Favorite" },     .{ "checkmark", "Done" },
        .{ "square.and.arrow.up", "Share" }, .{ "arrow.clockwise", "Refresh" }, .{ "line.3.horizontal", "Menu" },
        .{ "heart", "Like" },            .{ "pencil", "Edit" },            .{ "mic", "Dictate" },
    };
    var base = name;
    for (table) |e| if (std.mem.eql(u8, e[0], base)) return e[1];
    // "star.circle.fill" reads as its first word.
    if (std.mem.indexOfScalar(u8, base, '.')) |dot| base = base[0..dot];
    for (table) |e| if (std.mem.eql(u8, e[0], base)) return e[1];
    return "";
}

fn intersect(a: types.Rect, b: types.Rect) types.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}
