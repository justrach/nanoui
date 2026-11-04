//! nanocua's colors: the family's (nanoterm, nanomon), warm charcoal or
//! cream with amber; rust for Stop, sage for what is allowed.
const nanoui = @import("nanoui");
const Color = nanoui.ui.Color;

pub const Colors = struct {
    page: Color,
    card: Color,
    border: Color,
    text: Color,
    secondary: Color,
    accent: Color,
    red: Color,
    green: Color,
    yellow: Color,
    well: Color,
};

const white: Color = .{ .r = 1, .g = 1, .b = 1 };
const black: Color = .{};

pub fn colors(dark: bool) Colors {
    if (dark) {
        const bg = Color.hex(0x16140f);
        return .{
            .page = bg,
            .card = .hex(0x1f1c16),
            .border = bg.mix(white, 0.09),
            .text = .hex(0xedeae2),
            .secondary = .hex(0x9a9384),
            .accent = .hex(0xe8a33d),
            .red = .hex(0xd2674f),
            .green = .hex(0x7fa86b),
            .yellow = .hex(0xd9a441),
            .well = .hex(0x191712),
        };
    }
    const bg = Color.hex(0xfaf8f3);
    return .{
        .page = bg,
        .card = .hex(0xf0ece3),
        .border = bg.mix(black, 0.09),
        .text = .hex(0x1a1813),
        .secondary = .hex(0x6b6557),
        .accent = .hex(0xc77d20),
        .red = .hex(0xb14228),
        .green = .hex(0x5c7e47),
        .yellow = .hex(0x9a6e1b),
        .well = .hex(0xe9e3d6),
    };
}

pub fn ui(dark: bool) nanoui.ui.Theme {
    const k = colors(dark);
    var t = if (dark) nanoui.ui.Theme.dark_theme else nanoui.ui.Theme.light;
    t.background = k.page;
    t.text = k.text;
    t.muted = k.secondary;
    t.border = k.border;
    t.accent = k.accent;
    t.accent_hover = k.accent.mix(if (dark) white else black, 0.14);
    t.accent_text = if (dark) k.page else Color.hex(0xfffdf8);
    t.danger = k.red;
    t.success = k.green;
    return t;
}
