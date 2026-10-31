//! The accessibility demo's screen: what VoiceOver reads, the same on iOS
//! and macOS, from one tree (`ui.access`). Headings and loose text read
//! without anything added; a card that takes taps is described once
//! (`access.describe`), a decoration left out (`access.hide`), a star
//! spoken (`access.announce`), and a new page said (`access.screenChanged`).
const std = @import("std");
const ui = @import("nanoui").ui;
const access = ui.access;

pub const Stop = struct { name: []const u8, code: []const u8, mins: u8, starred: bool = false };

pub const Demo = struct {
    stops: [3]Stop = .{
        .{ .name = "Suntec City", .code = "02151", .mins = 2 },
        .{ .name = "Raffles Hotel", .code = "02049", .mins = 5 },
        .{ .name = "Esplanade", .code = "02059", .mins = 9 },
    },
    page: enum { stops, about } = .stops,
    note: ui.TextBuffer = .{},
    size: f32 = 0.5,
    alerts: bool = true,

    pub fn view(d: *Demo, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .gap = 12, .padding = .all(24), .scroll = true });
        defer ui.end(c);
        if (d.page == .about) return d.about(c);
        ui.text(c, "Nearby stops", .{ .size = 28, .weight = .bold });
        ui.text(c, "Tap a stop to star it.", .{ .color = c.theme.muted });
        for (&d.stops) |*s| card(c, s);
        // A decoration: VoiceOver skips it.
        const rule = ui.div(c).py(2);
        access.hide(c, rule.index);
        ui.text(c, "· · ·", .{ .color = c.theme.muted });
        rule.end();
        ui.text(c, "Settings", .{ .size = 20, .weight = .bold });
        _ = ui.checkbox(c, "Arrival alerts", &d.alerts);
        _ = ui.slider(c, &d.size, .{ .label = "Text size" });
        ui.text(c, "A note for the driver", .{});
        _ = ui.textField(c, &d.note, .{ .placeholder = "Any language: 你好, こんにちは" });
        if (ui.button(c, "About", .{}).clicked) {
            d.page = .about;
            access.screenChanged(c);
        }
    }

    fn about(d: *Demo, c: *ui.Context) void {
        ui.text(c, "About", .{ .size = 28, .weight = .bold });
        ui.text(c, "Drawn by nanoui, read by VoiceOver.", .{});
        if (ui.button(c, "Back", .{}).clicked) {
            d.page = .stops;
            access.screenChanged(c);
        }
    }
};

/// A stop: one element, read as a sentence, that stars when pressed.
fn card(c: *ui.Context, s: *Stop) void {
    const box = ui.div(c).row().gap(12).px(14).py(10).rounded(12).bg(c.theme.surface).control();
    if (box.clicked()) {
        s.starred = !s.starred;
        access.announce(c, c.print("{s} {s}", .{ s.name, if (s.starred) "starred" else "unstarred" }));
    }
    access.describe(c, box.index, .{
        .label = c.print("{s}, stop {s}, next bus in {d} minutes", .{ s.name, s.code, s.mins }),
        .value = if (s.starred) "Starred" else "",
        .hint = "Stars or unstars the stop",
        .selected = s.starred,
    });
    ui.text(c, s.name, .{ .weight = .semibold });
    ui.text(c, s.code, .{ .color = c.theme.muted });
    ui.text(c, c.print("{d} min", .{s.mins}), .{});
    ui.text(c, if (s.starred) "★" else "☆", .{});
    box.end();
}
