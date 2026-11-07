//! The browser's colors and measures, after browse: a handful of grays that get
//! out of the page's way. Everything the browser draws is one of these.
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Palette = struct {
    ground: ui.Color,
    ink: ui.Color,
    muted: ui.Color,
    faint: ui.Color,
    hairline: ui.Color,
    /// The live tab.
    wash: ui.Color,
    /// What the pointer is on.
    hover: ui.Color,
    /// A connection nobody can read on the way, and one anybody can.
    safe: ui.Color,
    unsafe: ui.Color,
};

pub const light: Palette = .{
    .ground = .hex(0xffffff),
    .ink = .hex(0x171717),
    .muted = .hex(0x8c8c8c),
    .faint = .hex(0xd4d4d4),
    .hairline = .hex(0xe8e8e8),
    .wash = .hex(0xefefef),
    .hover = .hex(0xf6f6f6),
    .safe = .{ .r = 0.08, .g = 0.50, .b = 0.24 },
    .unsafe = .{ .r = 0.71, .g = 0.33, .b = 0.04 },
};

pub const dark: Palette = .{
    .ground = .hex(0x1c1c1c),
    .ink = .hex(0xededed),
    .muted = .hex(0x949494),
    .faint = .hex(0x525252),
    .hairline = .hex(0x333333),
    .wash = .hex(0x2d2d2d),
    .hover = .hex(0x262626),
    .safe = .{ .r = 0.29, .g = 0.87, .b = 0.50 },
    .unsafe = .{ .r = 0.98, .g = 0.75, .b = 0.14 },
};

pub fn of(c: *const ui.Context) *const Palette {
    return if (c.theme.dark) &dark else &light;
}

pub const metrics = struct {
    /// The tab strip, and the traffic lights centered in it.
    pub const strip: f32 = 52;
    pub const lights_center: f32 = 26;
    /// Where the first tab starts: past the lights, with the same air.
    pub const lights: f32 = 100;
    /// The band left when the tabs are hidden.
    pub const bare: f32 = 34;
    /// Tabs are a fixed width, so the cross always lands in the same place;
    /// they give way when there are too many.
    pub const tab_width: f32 = 186;
    pub const tab_titled: f32 = 80;
    pub const tab_min: f32 = 36;
    pub const tab_gap: f32 = 2;
    pub const tab_radius: f32 = 9;
    pub const plus: f32 = 30;
    /// Back, forward and reload at the far end of the row.
    pub const helm: f32 = 3 * 26 + 2 * 2 + 8;
    /// The address field.
    pub const field_width: f32 = 560;
    pub const field_radius: f32 = 14;
};
