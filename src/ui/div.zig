//! Elements in GPUI's manner: a box styled by a chain of small methods,
//! as GPUI's `div().flex().gap_2().bg(...)`, over nanoui's `Style`.
//!
//!     const card = ui.div(c).column().p(16).gap(8).bg(th.surface).rounded(12).shadowMd().hover(th.surface_hover);
//!     defer card.end();
//!     if (card.clicked()) s.open = !s.open;
//!     ui.text(c, "Settings", .{ .weight = .semibold });
//!
//! Style methods come first, then children, then `end`.
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const Color = types.Color;

pub const Div = struct {
    c: *Context,
    index: u32,

    fn style(d: Div) *types.Style {
        return &d.c.node(d.index).style;
    }

    fn set(d: Div, comptime field: []const u8, v: anytype) Div {
        @field(d.style(), field) = v;
        return d;
    }

    // Direction and spacing.
    pub fn row(d: Div) Div {
        return d.set("direction", .row);
    }
    pub fn column(d: Div) Div {
        return d.set("direction", .column);
    }
    pub fn gap(d: Div, v: f32) Div {
        return d.set("gap", v);
    }
    pub fn p(d: Div, v: f32) Div {
        return d.set("padding", types.Edges.all(v));
    }
    pub fn px(d: Div, v: f32) Div {
        const s = d.style();
        s.padding.left = v;
        s.padding.right = v;
        return d;
    }
    pub fn py(d: Div, v: f32) Div {
        const s = d.style();
        s.padding.top = v;
        s.padding.bottom = v;
        return d;
    }
    pub fn pt(d: Div, v: f32) Div {
        d.style().padding.top = v;
        return d;
    }
    pub fn pb(d: Div, v: f32) Div {
        d.style().padding.bottom = v;
        return d;
    }
    pub fn pl(d: Div, v: f32) Div {
        d.style().padding.left = v;
        return d;
    }
    pub fn pr(d: Div, v: f32) Div {
        d.style().padding.right = v;
        return d;
    }
    /// Sets the padding to the safe area (`Context.safe_area`), keeping
    /// content clear of what the system draws over the window: zero on
    /// the desktop. It replaces the padding set before, as `p` does.
    pub fn safeArea(d: Div) Div {
        return d.set("padding", d.c.safe_area);
    }

    // Size.
    pub fn w(d: Div, v: f32) Div {
        return d.set("width", types.Length{ .px = v });
    }
    pub fn h(d: Div, v: f32) Div {
        return d.set("height", types.Length{ .px = v });
    }
    pub fn size(d: Div, width: f32, height: f32) Div {
        return d.w(width).h(height);
    }
    pub fn wFull(d: Div) Div {
        return d.set("width", @as(types.Length, .fill));
    }
    pub fn hFull(d: Div) Div {
        return d.set("height", @as(types.Length, .fill));
    }
    pub fn sizeFull(d: Div) Div {
        return d.wFull().hFull();
    }
    pub fn grow(d: Div) Div {
        return d.set("grow", 1);
    }
    pub fn minW(d: Div, v: f32) Div {
        return d.set("min_width", v);
    }
    pub fn maxW(d: Div, v: f32) Div {
        return d.set("max_width", v);
    }
    pub fn maxH(d: Div, v: f32) Div {
        return d.set("max_height", v);
    }

    // Alignment.
    pub fn itemsStart(d: Div) Div {
        return d.set("align_items", .start);
    }
    pub fn itemsCenter(d: Div) Div {
        return d.set("align_items", .center);
    }
    pub fn itemsEnd(d: Div) Div {
        return d.set("align_items", .end);
    }
    pub fn itemsStretch(d: Div) Div {
        return d.set("align_items", .stretch);
    }
    pub fn justifyCenter(d: Div) Div {
        return d.set("justify", .center);
    }
    pub fn justifyEnd(d: Div) Div {
        return d.set("justify", .end);
    }
    pub fn justifyBetween(d: Div) Div {
        return d.set("justify", .space_between);
    }
    /// Centers children both ways.
    pub fn center(d: Div) Div {
        return d.itemsCenter().justifyCenter();
    }

    // Looks.
    pub fn bg(d: Div, color: Color) Div {
        return d.set("background", @as(?Color, color));
    }
    pub fn border(d: Div, color: Color) Div {
        return d.set("border", @as(?Color, color));
    }
    pub fn borderW(d: Div, v: f32) Div {
        return d.set("border_width", v);
    }
    pub fn rounded(d: Div, v: f32) Div {
        return d.set("radius", v);
    }
    pub fn roundedFull(d: Div) Div {
        return d.set("radius", 1e4);
    }
    pub fn shadow(d: Div, s: types.Shadow) Div {
        return d.set("shadow", @as(?types.Shadow, s));
    }
    /// The border in dashes, as GPUI's `border_dashed`.
    pub fn dashed(d: Div) Div {
        return d.set("border_dashed", true);
    }
    /// Layered shadows, after `shadow`: `.shadows(&ui.Shadow.lg)`.
    pub fn shadows(d: Div, list: []const types.Shadow) Div {
        return d.set("shadows", list);
    }
    pub fn shadowSm(d: Div) Div {
        return d.shadow(.{ .color = d.c.theme.shadow.alpha(0.6), .blur = 3, .y = 1 });
    }
    pub fn shadowMd(d: Div) Div {
        return d.shadow(.{ .color = d.c.theme.shadow, .blur = 12, .y = 4 });
    }
    pub fn shadowLg(d: Div) Div {
        return d.shadow(.{ .color = d.c.theme.shadow.alpha(1.4), .blur = 32, .y = 12 });
    }
    /// Liquid Glass instead of a background: `.glass(.{})`, or tinted as
    /// a prominent button, `.glass(.{ .tint = th.accent })`.
    pub fn glass(d: Div, g: types.Glass) Div {
        return d.set("glass", @as(?types.Glass, g));
    }
    pub fn opacity(d: Div, v: f32) Div {
        return d.set("opacity", v);
    }

    // Overflow and position.
    pub fn clip(d: Div) Div {
        return d.set("clip", true);
    }
    pub fn scrollY(d: Div) Div {
        return d.set("scroll", true);
    }
    /// How a scrolling box shows its bar: `.always`, or `.{ .overlay = color }`
    /// to show it only while the box scrolls, as touch platforms do.
    pub fn scrollbar(d: Div, v: types.Scrollbar) Div {
        return d.set("scrollbar", v);
    }
    pub fn absolute(d: Div) Div {
        return d.set("absolute", true);
    }
    pub fn offset(d: Div, x: f32, y: f32) Div {
        return d.set("offset", types.Point{ .x = x, .y = y });
    }
    /// Placed from the window's top left (with `absolute`).
    pub fn fixed(d: Div) Div {
        _ = d.set("absolute", true);
        return d.set("fixed", true);
    }
    /// Drawn above lower layers, unclipped by its parents (an overlay).
    pub fn layer(d: Div, v: u8) Div {
        return d.set("layer", v);
    }
    pub fn scale(d: Div, v: f32) Div {
        return d.set("scale", v);
    }
    /// Takes a `ui.motion` frame: its offset, scale and opacity, and the
    /// size, radius and background it animates. Last, so what it animates
    /// wins over what was set before.
    pub fn motion(d: Div, f: @import("motion/motion.zig").Frame) Div {
        f.apply(d.style());
        if (f.gestures) d.c.node(d.index).interactive = true;
        return d;
    }

    // Interaction.

    /// A control: its texts do not select (see `Style.control`).
    pub fn control(d: Div) Div {
        return d.set("control", true);
    }

    /// The background eases toward `color` while the pointer is over it.
    pub fn hover(d: Div, color: Color) Div {
        const it = d.c.interact(d.index, .{});
        const t = d.c.animate(it.id, 0x484f56, if (it.hovered) 1 else 0, 18);
        const base = d.style().background orelse color.alpha(0);
        d.style().background = base.mix(color, t);
        return d;
    }

    pub fn interaction(d: Div) ctx_mod.Interaction {
        return d.c.interact(d.index, .{});
    }

    /// Clicked in this frame: changes made now show in this frame.
    pub fn clicked(d: Div) bool {
        const it = d.c.interact(d.index, .{});
        if (it.clicked) d.c.changed = true;
        return it.clicked;
    }

    /// Asked for its context menu in this frame: a right-click (or a
    /// Control-click on the Mac) on it or inside it.
    pub fn secondaryClicked(d: Div) bool {
        const it = d.c.interact(d.index, .{});
        if (it.secondary_clicked) d.c.changed = true;
        return it.secondary_clicked;
    }

    pub fn hovered(d: Div) bool {
        return d.c.interact(d.index, .{}).hovered;
    }

    pub fn end(d: Div) void {
        d.c.end();
    }

    /// The box's id: scroll-linked motion and tests name it this way.
    pub fn id(d: Div) u64 {
        return d.c.node(d.index).id;
    }
};

/// Opens a box; style it with the chain, add children, then `end`.
pub fn div(c: *Context) Div {
    return .{ .c = c, .index = c.open(.{}, null) };
}
