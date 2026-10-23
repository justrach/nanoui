//! Layout and the basic widgets: boxes, text, buttons, checkboxes, toggles,
//! sliders, progress bars, segmented controls. Every widget is made of
//! boxes, styled from the theme and animated toward its state.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const Interaction = ctx_mod.Interaction;
const Color = types.Color;
const Style = types.Style;

/// Gives the next box a key, so its id (and its animations, scroll, caret)
/// follow it when boxes before it come and go: items of lists.
pub fn key(c: *Context, k: []const u8) void {
    c.next_key = k;
}

pub fn column(c: *Context, style: Style) void {
    var s = style;
    s.direction = .column;
    _ = c.open(s, null);
}

pub fn row(c: *Context, style: Style) void {
    var s = style;
    s.direction = .row;
    _ = c.open(s, null);
}

/// Closes the box `column`, `row`, `card`, `scroll` or `pressable` opened.
pub fn end(c: *Context) void {
    c.end();
}

/// A box that reports the pointer: open it, read the interaction, add
/// children, then `end`. `hover` replaces the background while hovered.
pub fn pressable(c: *Context, style: Style, hover: ?Color) Interaction {
    const i = c.open(style, null);
    const it = c.interact(i, .{});
    if (hover) |h| {
        const t = c.animate(it.id, 0, if (it.hovered) 1 else 0, 18);
        const base = style.background orelse h.alpha(0);
        c.node(i).style.background = base.mix(h, t);
    }
    return it;
}

/// A surface for grouping: background, rounded corners, a soft shadow.
pub fn card(c: *Context, style: Style) void {
    var s = style;
    if (s.background == null) s.background = c.theme.surface;
    if (s.radius == 0) s.radius = 12;
    if (s.shadow == null) s.shadow = .{ .color = c.theme.shadow, .blur = 16, .y = 4 };
    if (std.meta.eql(s.padding, types.Edges{})) s.padding = .all(16);
    _ = c.open(s, null);
}

/// A box whose children scroll vertically.
pub fn scroll(c: *Context, style: Style) void {
    var s = style;
    s.scroll = true;
    s.direction = .column;
    _ = c.open(s, null);
}

/// Takes the free room along its parent's main axis.
pub fn spacer(c: *Context) void {
    _ = c.leaf(.{ .grow = 1 }, .none, null);
}

pub fn divider(c: *Context) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = c.theme.border }, .none, null);
}

pub fn text(c: *Context, str: []const u8, style: types.TextStyle) void {
    const color = style.color orelse c.theme.text;
    const width: types.Length = if (style.wrap) .fill else .auto;
    _ = c.leaf(.{ .width = width }, .{ .text = .{ .str = str, .style = style, .color = color } }, null);
}

/// Text whose byte ranges `spans` have colors of their own (ANSI output,
/// syntax highlighting).
pub fn richText(c: *Context, str: []const u8, spans: []const types.Span, style: types.TextStyle) void {
    const color = style.color orelse c.theme.text;
    const width: types.Length = if (style.wrap) .fill else .auto;
    _ = c.leaf(.{ .width = width }, .{ .text = .{ .str = str, .style = style, .color = color, .spans = spans } }, null);
}

pub fn textf(c: *Context, style: types.TextStyle, comptime fmt: []const u8, args: anytype) void {
    text(c, c.print(fmt, args), style);
}

pub const IconOptions = struct {
    size: f32 = 16,
    /// A square box the symbol is centered in, so symbols of different
    /// widths line up; the symbol's own size when null.
    frame: ?f32 = null,
    weight: types.Weight = .regular,
    color: ?Color = null,
    /// Turned clockwise about its centre, in radians (SwiftUI's
    /// `rotationEffect`); laid out as if it were not.
    rotation: f32 = 0,
};

/// An SF Symbol: `ui.icon(c, "star.fill", .{ .color = c.theme.accent })`.
pub fn icon(c: *Context, name: []const u8, opts: IconOptions) void {
    const style: Style = if (opts.frame) |f| .{ .width = .{ .px = f }, .height = .{ .px = f }, .rotation = opts.rotation } else .{ .rotation = opts.rotation };
    _ = c.leaf(style, .{ .icon = .{ .name = name, .size = opts.size, .weight = opts.weight, .color = opts.color orelse c.theme.text } }, null);
}

pub const ImageOptions = struct {
    /// Names the picture: the same key is decoded once.
    key: []const u8,
    /// The encoded picture (PNG; on macOS anything ImageIO reads), kept by
    /// the caller while it is shown.
    bytes: []const u8,
    /// The most room it takes, in points; it keeps its proportions and is
    /// never drawn larger than its pixels at `scale`.
    max_width: f32 = 480,
    max_height: f32 = 360,
    radius: f32 = 8,
    opacity: f32 = 1,
    /// Pixels a point the picture was made at: 2 for a Retina screenshot,
    /// 1 for most pictures on the web (a badge).
    scale: f32 = 2,
    /// Draws only the picture's shape, in this color: a monochrome mark (a
    /// logo) that follows the theme.
    tint: ?types.Color = null,
};

/// A picture; false (and nothing drawn) if it can't be decoded.
pub fn image(c: *Context, opts: ImageOptions) bool {
    const k = @import("images.zig").Images.key(opts.key);
    // Sized from the picture's header; decoded at device size and packed only when drawn.
    const e = c.text.images.info(k, opts.bytes) orelse return false;
    const w: f32 = @as(f32, @floatFromInt(e.width)) / @max(opts.scale, 0.5);
    const h: f32 = @as(f32, @floatFromInt(e.height)) / @max(opts.scale, 0.5);
    const s = @min(1, @min(opts.max_width / @max(w, 1), opts.max_height / @max(h, 1)));
    _ = c.leaf(.{ .width = .{ .px = @round(w * s) }, .height = .{ .px = @round(h * s) }, .radius = opts.radius }, .{ .image = .{ .key = k, .bytes = opts.bytes, .opacity = opts.opacity, .tint = opts.tint } }, null);
    return true;
}

/// A texture the app gives this frame (`gpu.Texture`: a video's frame, as
/// often as it changes), in a box of `style` (which sizes and places it),
/// the part `uv` (0 to 1) of it shown, its corners rounded by the style.
pub fn texture(c: *Context, style: types.Style, source: @import("gpu.zig").Texture, uv: [4]f32, opacity: f32) void {
    const slot: u32 = @intCast(c.textures.items.len);
    c.textures.append(c.gpa, source) catch return;
    _ = c.leaf(style, .{ .texture = .{ .slot = slot, .uv = uv, .opacity = opacity } }, null);
}

pub fn heading(c: *Context, str: []const u8) void {
    text(c, str, .{ .size = 22, .weight = .bold });
}

pub fn label(c: *Context, str: []const u8) void {
    text(c, str, .{ .size = 13, .color = c.theme.muted });
}

pub const ButtonVariant = enum { primary, secondary, ghost, danger };

pub const ButtonOptions = struct {
    variant: ButtonVariant = .secondary,
    width: types.Length = .auto,
    size: f32 = 14,
    disabled: bool = false,
    /// An SF Symbol shown before the title (alone if the title is empty).
    icon: []const u8 = "",
};

pub fn button(c: *Context, title: []const u8, opts: ButtonOptions) Interaction {
    const th = c.theme;
    const i = c.open(.{
        .direction = .row,
        .width = opts.width,
        .padding = .xy(opts.size, opts.size * 0.5),
        .radius = 8,
        .align_items = .center,
        .justify = .center,
        .opacity = if (opts.disabled) 0.45 else 1,
        .control = true,
    }, null);
    defer c.end();
    var it = c.interact(i, .{});
    c.addA11y(i, .button, if (title.len > 0) title else opts.icon, "", false, !opts.disabled);
    if (opts.disabled) {
        it.clicked = false;
        it.hovered = false;
        it.pressed = false;
    }
    const hover = c.animate(it.id, 0, if (it.hovered) 1 else 0, 20);
    const press = c.animate(it.id, 1, if (it.pressed) 1 else 0, 30);
    const n = c.node(i);
    var fg = th.text;
    switch (opts.variant) {
        .primary, .danger => {
            const base = if (opts.variant == .primary) th.accent else th.danger;
            n.style.background = base.mix(th.accent_hover, hover * 0.6).mix(Color.black, press * 0.15);
            fg = th.accent_text;
        },
        .secondary => {
            n.style.background = th.surface.mix(th.surface_hover, hover).mix(th.border, press * 0.5);
            n.style.border = th.border;
            n.style.shadow = .{ .color = th.shadow.alpha(0.5), .blur = 2, .y = 1 };
        },
        .ghost => {
            n.style.background = th.surface_hover.alpha(hover).mix(th.border, press * 0.5);
        },
    }
    n.style.offset.y = press * 0.5;
    n.style.gap = opts.size * 0.4;
    if (it.clicked) c.changed = true;
    if (opts.icon.len > 0) icon(c, opts.icon, .{ .size = opts.size, .weight = .medium, .color = fg });
    if (title.len > 0) text(c, title, .{ .size = opts.size, .weight = .medium, .color = fg });
    return it;
}

/// A checkbox and its label; returns true when toggled.
pub fn checkbox(c: *Context, title: []const u8, value: *bool) bool {
    const th = c.theme;
    const it = pressable(c, .{ .direction = .row, .gap = 8, .align_items = .center, .control = true }, null);
    defer c.end();
    c.addA11y(c.stack.items[c.stack.items.len - 1], .checkbox, title, "", value.*, true);
    if (it.clicked) {
        value.* = !value.*;
        c.changed = true;
    }
    const t = c.animate(it.id, 0, if (value.*) 1 else 0, 22);
    const hover = c.animate(it.id, 1, if (it.hovered) 1 else 0, 20);
    _ = c.open(.{
        .width = .{ .px = 18 },
        .height = .{ .px = 18 },
        .radius = 5,
        .background = th.surface.mix(th.surface_hover, hover * (1 - t)).mix(th.accent, t),
        .border = th.border.mix(th.accent, t),
        .align_items = .center,
        .justify = .center,
    }, null);
    if (t > 0.01) _ = c.leaf(.{ .opacity = t, .offset = .{ .y = -0.5 } }, .{ .text = .{
        .str = "✓",
        .style = .{ .size = 12, .weight = .bold },
        .color = th.accent_text,
    } }, null);
    c.end();
    text(c, title, .{});
    return it.clicked;
}

/// A switch and its label; returns true when toggled.
pub fn toggle(c: *Context, title: []const u8, value: *bool) bool {
    const th = c.theme;
    const it = pressable(c, .{ .direction = .row, .gap = 10, .align_items = .center, .control = true }, null);
    defer c.end();
    c.addA11y(c.stack.items[c.stack.items.len - 1], .switch_toggle, title, "", value.*, true);
    if (it.clicked) {
        value.* = !value.*;
        c.changed = true;
    }
    const t = c.animate(it.id, 0, if (value.*) 1 else 0, 16);
    _ = c.open(.{
        .direction = .row,
        .width = .{ .px = 40 },
        .height = .{ .px = 24 },
        .radius = 12,
        .padding = .{ .left = 2 + t * 16, .top = 2 },
        .background = th.track.mix(th.success, t),
    }, null);
    _ = c.leaf(.{
        .width = .{ .px = 20 },
        .height = .{ .px = 20 },
        .radius = 10,
        .background = th.knob,
        .shadow = .{ .color = .{ .a = 0.25 }, .blur = 3, .y = 1 },
    }, .none, null);
    c.end();
    text(c, title, .{});
    return it.clicked;
}

pub const SliderOptions = struct {
    min: f32 = 0,
    max: f32 = 1,
    width: types.Length = .{ .px = 200 },
};

/// A slider over `value`; returns true while it changes it.
pub fn slider(c: *Context, value: *f32, opts: SliderOptions) bool {
    const th = c.theme;
    const knob: f32 = 18;
    const i = c.open(.{ .direction = .row, .width = opts.width, .height = .{ .px = 22 }, .align_items = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .slider, "Slider", c.print("{d:.2}", .{value.*}), false, true);
    var changed = false;
    if (it.pressed) if (it.rect) |r| {
        const t = std.math.clamp((c.input.mouse.x - r.x - knob / 2) / @max(1, r.w - knob), 0, 1);
        const v = opts.min + t * (opts.max - opts.min);
        if (v != value.*) {
            value.* = v;
            changed = true;
            c.changed = true;
        }
    };
    const t = std.math.clamp((value.* - opts.min) / (opts.max - opts.min), 0, 1);
    const hover = c.animate(it.id, 0, if (it.hovered or it.pressed) 1 else 0, 20);
    _ = c.leaf(.{ .grow = t, .height = .{ .px = 4 }, .radius = 2, .background = th.accent }, .none, null);
    _ = c.leaf(.{
        .width = .{ .px = knob },
        .height = .{ .px = knob },
        .radius = knob / 2,
        .background = th.knob,
        .border = th.border.mix(th.accent, hover),
        .shadow = .{ .color = .{ .a = 0.2 + 0.1 * hover }, .blur = 3 + 2 * hover, .y = 1 },
    }, .none, null);
    _ = c.leaf(.{ .grow = 1 - t, .height = .{ .px = 4 }, .radius = 2, .background = th.track }, .none, null);
    return changed;
}

/// A bar filled to `value`, between 0 and 1, easing toward it.
pub fn progress(c: *Context, value: f32, width: types.Length) void {
    const th = c.theme;
    const id = c.peekId(null);
    const t = c.animate(id, 0, std.math.clamp(value, 0, 1), 10);
    _ = c.open(.{ .direction = .row, .width = width, .height = .{ .px = 6 }, .radius = 3, .background = th.track }, null);
    defer c.end();
    _ = c.leaf(.{ .grow = t, .radius = 3, .height = .fill, .background = th.accent }, .none, null);
    _ = c.leaf(.{ .grow = 1 - t }, .none, null);
}

/// One choice out of `options`; returns true when the choice changes.
pub fn segmented(c: *Context, options: []const []const u8, selected: *usize) bool {
    const th = c.theme;
    _ = c.open(.{ .direction = .row, .padding = .all(2), .radius = 9, .background = th.track, .gap = 2 }, null);
    defer c.end();
    var changed = false;
    for (options, 0..) |opt, idx| {
        const it = pressable(c, .{ .padding = .xy(14, 5), .radius = 7, .align_items = .center, .control = true }, null);
        defer c.end();
        c.addA11y(c.stack.items[c.stack.items.len - 1], .radio_button, opt, "", selected.* == idx, true);
        if (it.clicked and selected.* != idx) {
            selected.* = idx;
            changed = true;
            c.changed = true;
        }
        const t = c.animate(it.id, 0, if (selected.* == idx) 1 else 0, 20);
        const hover = c.animate(it.id, 1, if (it.hovered) 1 else 0, 20);
        const n = c.node(c.stack.items[c.stack.items.len - 1]);
        n.style.background = th.surface.alpha(t + hover * 0.35 * (1 - t));
        if (t > 0.01) n.style.shadow = .{ .color = th.shadow.alpha(t), .blur = 3, .y = 1 };
        text(c, opt, .{ .size = 13, .weight = if (selected.* == idx) .semibold else .regular });
    }
    return changed;
}

/// A key combination drawn as a key cap: `ui.kbd(c, ui.keys.label("⌘P"))`.
pub fn kbd(c: *Context, str: []const u8) void {
    const th = c.theme;
    _ = c.open(.{ .padding = .xy(5, 1), .radius = 4, .background = th.text.alpha(0.06), .border = th.text.alpha(0.12), .min_width = 18, .align_items = .center }, null);
    defer c.end();
    text(c, str, .{ .size = 10.5, .weight = .medium, .color = th.muted });
}

/// A small rounded label.
pub fn badge(c: *Context, str: []const u8, color: Color) void {
    _ = c.open(.{ .padding = .xy(8, 2), .radius = 10, .background = color.alpha(0.15) }, null);
    defer c.end();
    text(c, str, .{ .size = 11, .weight = .semibold, .color = color });
}
