//! Buttons as GPUI Kit has them: a variant (default, primary, secondary,
//! danger, info, success, warning, ghost, outline, link, text), a size,
//! an icon before or after, loading (a spinner in place of the icon),
//! selected (a toggle's on), disabled, and as wide as their row; `glass`
//! makes it a pane of Liquid Glass (tinted by its variant). Hover and press
//! spring: a press gives a little, glass more, and it bounces back.
const std = @import("std");
const ui = @import("../ui/ui.zig");
const kit = @import("kit.zig");
const Color = ui.Color;

pub const Variant = enum { default, primary, secondary, danger, info, success, warning, ghost, outline, link, text };

pub const Options = struct {
    variant: Variant = .default,
    size: kit.Size = .md,
    /// SF Symbols before and after the label.
    icon: []const u8 = "",
    icon_after: []const u8 = "",
    loading: bool = false,
    disabled: bool = false,
    /// On, as a toggle button is.
    selected: bool = false,
    /// As wide as the row it's in.
    full_width: bool = false,
    /// Fully rounded ends.
    pill: bool = false,
    /// Shown when the pointer rests on it.
    tooltip: []const u8 = "",
    /// Liquid Glass instead of a fill: clear for default, ghost and text,
    /// tinted by the variant's color otherwise.
    glass: bool = false,
    /// Custom scale target while pressed (for tactile contraction on glass pills/circles).
    press_scale: ?f32 = null,
};

const Look = struct { bg: Color, fg: Color, border: ?Color = null, underline: bool = false };

fn look(t: kit.Tokens, v: Variant, selected: bool) Look {
    const solid = struct {
        fn f(base: Color, fg: Color) Look {
            return .{ .bg = base, .fg = fg };
        }
    }.f;
    return switch (v) {
        .default => .{ .bg = if (selected) t.surface_hover else t.surface, .fg = t.foreground, .border = t.border },
        .primary => solid(t.primary, t.primary_foreground),
        .secondary => .{ .bg = t.surface_hover, .fg = t.foreground },
        .danger => solid(t.danger, .white),
        .info => solid(t.info, .white),
        .success => solid(t.success, .white),
        .warning => solid(t.warning, .white),
        .ghost => .{ .bg = if (selected) t.surface_hover else t.surface_hover.alpha(0), .fg = t.foreground },
        .outline => .{ .bg = if (selected) t.primary.alpha(0.12) else t.surface.alpha(0), .fg = t.primary, .border = t.primary },
        .link => .{ .bg = t.surface.alpha(0), .fg = t.primary, .underline = true },
        .text => .{ .bg = t.surface.alpha(0), .fg = t.foreground },
    };
}

/// A button; its interaction (`clicked` once, `pressed` while held).
pub fn button(c: *ui.Context, label: []const u8, opts: Options) ui.Interaction {
    const t = kit.tokens(c);
    const size = opts.size.text();
    const h = opts.size.height();
    const plain = opts.variant == .link or opts.variant == .text;
    var d = ui.div(c).row().itemsCenter().justifyCenter().gap(size * 0.45).control();
    d = if (plain) d.px(2) else d.h(h).px(if (label.len == 0) (h - size) / 2 else size * 0.95);
    if (label.len == 0 and !plain) d = d.w(h);
    if (opts.full_width) d = d.wFull();
    d = d.rounded(if (opts.pill) h / 2 else t.radius);
    if (opts.pill) d = d.circular();
    const it = d.interaction();
    defer d.end();
    const live = !opts.disabled and !opts.loading;
    const hover = c.animate(it.id, 0, if (live and it.hovered) 1 else 0, 20);
    const press = c.animate(it.id, 1, if (live and it.pressed) 1 else 0, 30);
    const l = look(t, opts.variant, opts.selected);
    const n = c.node(d.index);
    var bg = l.bg;
    // Hover lightens solid colors and fills clear ones; a press darkens.
    if (bg.a > 0.99 and opts.variant != .default) {
        bg = bg.mix(.white, hover * 0.1).mix(.black, press * 0.12);
    } else if (!plain) {
        const fill = if (opts.variant == .outline) t.primary.alpha(0.1) else t.surface_hover;
        bg = if (bg.a < 0.01) fill.alpha(hover * fill.a) else bg.mix(t.surface_hover, hover).mix(t.border, press * 0.5);
    }
    n.style.background = bg;
    n.style.border = l.border;
    const tinted_glass = l.bg.a > 0.99 and opts.variant != .default and opts.variant != .secondary;
    const use_glass = opts.glass and !c.access.reduce_transparency;
    if (opts.variant == .default and !opts.glass) n.style.shadow = .{ .color = t.shadow.alpha(0.4), .blur = 2, .y = 1 };
    if (use_glass) {
        // The variant's color tints the glass (prominent glass); clear
        // variants stay clear, and light up under a press, as interactive
        // glass does.
        n.style.glass = .{ .tint = if (tinted_glass) l.bg.alpha(0.85 + 0.12 * press) else ui.Color.white.alpha(0.22 * press) };
        n.style.background = null;
        n.style.border = null;
    } else if (opts.glass) {
        // Reduce Transparency replaces glass refraction with an opaque surface and border.
        n.style.glass = null;
        n.style.background = if (tinted_glass) bg else if (opts.selected) t.surface_hover else t.surface;
        n.style.border = l.border orelse t.border;
    }
    // Disabled and enabled fade into each other.
    n.style.opacity = ui.motion.number(c, "opacity", if (opts.disabled) 0.45 else 1, .{ .tween = .{ .duration = 0.2, .ease = .ease_out } });
    // A spring and a bounce on release: a solid button gives under a press;
    // glass swells unless `press_scale` asks for contraction; Reduce Motion holds scale at 1.
    const pressed_to: f32 = opts.press_scale orelse if (use_glass) 1.08 else 0.965;
    const hover_to: f32 = if (use_glass and opts.press_scale == null) 1.03 else 1;
    const scale_target: f32 = if (c.reduced_motion) 1 else if (live and it.pressed) pressed_to else if (live and it.hovered) hover_to else 1;
    n.style.scale = if (c.reduced_motion) 1 else ui.motion.number(c, "scale", scale_target, .{ .spring = ui.motion.Spring.bouncy });
    var fg = if ((use_glass and n.style.glass.?.tint.a == 0) or (opts.glass and !use_glass and !tinted_glass)) t.foreground else l.fg;
    if (plain) fg = fg.mix(t.muted, hover * 0.35);
    if (opts.loading) {
        kit.spinner(c, .{ .size = size, .color = fg });
    } else if (opts.icon.len > 0) ui.icon(c, opts.icon, .{ .size = size, .weight = .medium, .color = fg });
    if (label.len > 0) ui.text(c, label, .{ .size = size, .weight = .medium, .color = fg });
    if (opts.icon_after.len > 0) ui.icon(c, opts.icon_after, .{ .size = size * 0.85, .weight = .medium, .color = fg });
    if (l.underline and hover > 0.01) {
        // The link's underline, under the label.
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 2, .y = size * 1.3 }, .width = .fill, .height = .{ .px = 1 }, .background = fg.alpha(hover) }, .none, null);
    }
    if (opts.tooltip.len > 0) kit.tooltip(c, it, opts.tooltip, .{});
    var out = it;
    if (!live) {
        out.clicked = false;
        out.pressed = false;
    }
    if (out.clicked) c.changed = true;
    return out;
}

/// A square button showing only `icon`.
pub fn iconButton(c: *ui.Context, icon: []const u8, opts: Options) ui.Interaction {
    var o = opts;
    o.icon = icon;
    if (o.variant == .default) o.variant = .ghost;
    return button(c, "", o);
}
