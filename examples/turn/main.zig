//! A card turning over like a page (`Style.turn`): it swings about a ring
//! near its top-left corner, seen in perspective, its front hidden once its
//! back shows, the turn sprung. Tap the card or "Turn".
//!
//! `TURN_AT=<degrees>` holds the card at one angle (for a still), and
//! `TURN_FLAT=1` draws it as nanoui could before `turn`: tilted in the plane only.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

const deg = std.math.pi / 180.0;
const ring_x = 14.0 / 290.0;
const ring_y = 32.0 / 330.0;

const Deck = struct {
    over: bool = false,
    hold: ?f32 = null,
    flat: bool = false,
    landed: bool = true,

    fn view(s: *Deck, c: *ui.Context) void {
        const root = ui.div(c).column().wFull().hFull().bg(.hex(0xFBFBF9)).itemsCenter().justifyCenter().gap(28);
        defer root.end();
        const goal: f32 = if (s.over) -112 * deg else 0;
        const angle = s.hold orelse ui.motion.number(c, "turn", goal, .{ .spring = .{ .stiffness = 110, .damping = 19 } });
        // The turn lands: a light tap, as a card set down.
        const near = @abs(angle - goal) < 2 * deg;
        if (near and !s.landed) nanoui.haptics.impact(.light);
        s.landed = near;
        const done = std.math.clamp(angle / (-112 * deg), 0, 1);

        const deck = ui.div(c).size(330, 370);
        {
            // The card under it, peeking out.
            ui.div(c).absolute().offset(26, 24).size(290, 330).rounded(34).bg(.hex(0x005EC4)).rotate(-3 * deg).end();
            var card = ui.div(c).absolute().offset(20 - 30 * done, 20).size(290, 330).rounded(34).bg(.hex(0x009645)).shadowMd().pivot(ring_x, ring_y);
            card = if (s.flat) card.rotate((-6 - 8 * done) * deg) else card.rotate((-6 - 8 * done) * deg).turn(angle, 1100);
            if (card.clicked()) s.over = !s.over;
            defer card.end();
            {
                const front = ui.div(c).absolute().offset(0, 0).wFull().hFull().rounded(34).face(.front).column().p(28).justifyEnd();
                defer front.end();
                ui.text(c, "Front", .{ .size = 40, .weight = .bold, .color = .white });
                ui.text(c, "Turns about the ring", .{ .size = 15, .color = .white });
            }
            // The front darkens as it turns away from the light.
            ui.div(c).absolute().offset(0, 0).wFull().hFull().rounded(34).bg(.hex(0x000000)).opacity(0.38 * @abs(@sin(angle))).face(.front).end();
            {
                const back = ui.div(c).absolute().offset(0, 0).wFull().hFull().rounded(34).bg(.hex(0x0B5A2F)).face(.back).column().p(28).justifyEnd();
                defer back.end();
                ui.text(c, "Back", .{ .size = 40, .weight = .bold, .color = .white });
            }
            // The ring the card hangs on.
            ui.div(c).absolute().offset(20 + 290 * ring_x - 12, 20 + 330 * ring_y - 12).size(24, 24).roundedFull().border(.hex(0xB8B8BC)).borderW(4).end();
        }
        deck.end();
        ui.text(c, if (s.flat) "Before: Style.rotation only, in the plane" else c.print("After: Style.turn {d:.0}°, perspective 1100 pt", .{angle / deg}), .{ .size = 15, .color = .hex(0x6E6E73) });
        if (ui.button(c, "Turn", .{ .variant = .primary, .size = 16 }).clicked) s.over = !s.over;
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Turn" });
    defer app.destroy();
    var state: Deck = .{ .flat = init.environ_map.get("TURN_FLAT") != null };
    if (init.environ_map.get("TURN_AT")) |v| state.hold = (std.fmt.parseFloat(f32, v) catch 0) * deg;
    _ = try app.newWindow(.{
        .title = "Turn",
        .width = 420,
        .height = 620,
        .content = .{ .view = .init(&state, Deck.view) },
    });
    try app.run();
}
