//! A decorative timeline rail beside ordinary native content.
const ui = @import("../ui/ui.zig");
const kit = @import("kit.zig");

pub const Options = struct {
    /// Row height in points, at least the dot's 8 points.
    height: f32 = 56,
    /// Omit the connector above the dot.
    first: bool = false,
    /// Omit the connector below the dot. Set both for a single item.
    last: bool = false,
    /// Dot color; the connectors use it at 35% opacity. Defaults to primary.
    color: ?ui.Color = null,
    /// A static, lightly tinted background; does not take input.
    selected: bool = false,
};

/// Opens a full-width horizontal row with a 24-point leading rail and an
/// 8-point gap. Add content, then call `end`. The dot is centered vertically;
/// consecutive rows in a column with zero gap have continuous connectors.
/// Nothing clips or takes input: content can select text and host controls.
/// Give repeated items stable `ui.key`s, as with any list of native widgets.
///
///     const item = kit.timelineItem(c, .{ .first = true });
///     defer item.end();
///     const body = ui.div(c).column().grow().gap(4);
///     defer body.end();
///     ui.text(c, "Package prepared", .{});
///     ui.text(c, "Ready for collection", .{ .color = c.theme.muted });
pub fn timelineItem(c: *ui.Context, opts: Options) ui.Div {
    const t = kit.tokens(c);
    const col = opts.color orelse t.primary;
    const height = @max(8, opts.height);
    const half = (height - 8) / 2;
    var row = ui.div(c).row().wFull().h(height).gap(8).itemsCenter();
    if (opts.selected) row = row.bg(col.alpha(0.08));
    {
        const rail = ui.div(c).w(24).minW(24).h(height);
        defer rail.end();
        if (!opts.first and half > 0) {
            const above = ui.div(c).absolute().offset(11, 0).w(2).h(half).bg(col.alpha(0.35));
            above.end();
        }
        if (!opts.last and half > 0) {
            const below = ui.div(c).absolute().offset(11, half + 8).w(2).h(half).bg(col.alpha(0.35));
            below.end();
        }
        const dot = ui.div(c).absolute().offset(8, half).size(8, 8).roundedFull().circular().bg(col);
        dot.end();
    }
    return row;
}
