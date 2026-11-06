//! One field in the middle, and the few places and searches it thinks you mean.
//! On an empty tab it is all there is; ⌘L raises it over the page, which stays
//! there, out of the way. An address goes there, anything else is searched for
//! with the engine chosen at its right, and nothing at all makes it shiver.
const std = @import("std");
const text_search = @import("../text_search.zig");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const address = @import("address.zig");
const search = @import("search.zig");
const m = theme.metrics;

/// A place it offers, or with `search` a search for what's in `url`.
pub const Offer = struct { url: []const u8, title: []const u8, search: bool = false };

pub const Omnibox = struct {
    field: ui.TextBuffer = .{},
    /// Which offer the arrows are on (null: what was typed).
    picked: ?usize = null,
    /// When it last refused something; the shiver runs from here.
    refused_at: f64 = -10,
    refused: bool = false,
    /// It should take the keys in its next frame.
    wants_focus: bool = false,

    pub const Result = union(enum) { none, go: []const u8, search: []const u8, engine: search.Engine, dismiss, typed };

    pub fn reset(o: *Omnibox, text: []const u8) void {
        o.field.set(text);
        o.picked = null;
        o.refused = false;
        o.wants_focus = true;
    }

    pub fn refuse(o: *Omnibox, now: f64) void {
        o.refused = true;
        o.refused_at = now;
    }

    /// Draws it across the area of (`x`, `y`, `w`, `h`). `over`: raised over a page.
    pub fn view(o: *Omnibox, c: *ui.Context, x: f32, y: f32, w: f32, h: f32, over: bool, offers: []const Offer, engine: search.Engine) Result {
        const p = theme.of(c);
        var out: Result = .none;
        // The page is still there, just out of the way; a click on it dismisses.
        const scrim = c.open(.{
            .absolute = true,
            .fixed = true,
            .offset = .{ .x = x, .y = y },
            .width = .{ .px = w },
            .height = .{ .px = h },
            .background = if (over) p.ground.alpha(0.74) else p.ground,
            .layer = 2,
            .align_items = .center,
        }, "omnibox");
        defer c.end();
        if (over and c.interact(scrim, .{}).clicked) out = .dismiss;

        const field_w = @min(m.field_width, w - 48);
        const height: f32 = 50;
        // A little above center: dead center reads as low.
        const top = @max(16, (h - height) / 2 - 60);
        const since: f32 = @floatCast(c.time - o.refused_at);
        var shake: f32 = 0;
        if (since < 0.5) {
            const t = since / 0.5;
            shake = @sin(t * std.math.pi * 6) * 7 * (1 - t);
            c.animationFrame();
        }
        const box = c.open(.{
            .absolute = true,
            .offset = .{ .x = (w - field_w) / 2 + shake, .y = top },
            .width = .{ .px = field_w },
            .height = .{ .px = height },
            .padding = .xy(22, 14),
            .radius = m.field_radius,
            .background = p.ground,
            .border = if (o.refused) ui.Color.hex(0xff3b30).alpha(0.35) else p.hairline,
            .shadow = .{ .color = .{ .a = 0.06 }, .blur = 24, .y = 8 },
            .direction = .row,
            .align_items = .center,
        }, "field");
        _ = box;
        if (o.wants_focus) {
            c.focus = c.peekId("address");
            o.wants_focus = false;
        }
        ui.key(c, "address");
        const r = ui.textField(c, &o.field, .{
            .placeholder = engine.prompt(),
            .width = .fill,
            .size = 15,
            .bare = true,
            .select_all_on_focus = true,
            .color = p.ink,
            .placeholder_color = p.muted,
        });
        if (engines(c, engine)) |e| out = .{ .engine = e };
        c.end();
        if (r.changed) {
            o.refused = false;
            o.picked = null;
            out = .typed;
        }
        if (r.submitted) out = if (o.picked) |i| (if (i < offers.len) chosen(offers[i]) else Result{ .go = o.field.text() }) else .{ .go = o.field.text() };

        if (r.focused) {
            if (c.shortcut(.{ .key = ui.Shortcut.down })) o.step(1, offers.len);
            if (c.shortcut(.{ .key = ui.Shortcut.up })) o.step(-1, offers.len);
        }
        if (offers.len > 0) out = o.list(c, (w - field_w) / 2, top + height + 8, field_w, offers, out);
        return out;
    }

    /// The engines, the one in use marked. Which was clicked, if one was.
    fn engines(c: *ui.Context, in_use: search.Engine) ?search.Engine {
        const p = theme.of(c);
        var clicked: ?search.Engine = null;
        for ([_]search.Engine{ .google, .duckduckgo }) |e| {
            ui.key(c, e.name());
            const on = e == in_use;
            const it = ui.pressable(c, .{ .padding = .xy(8, 3), .radius = 7, .control = true, .background = if (on) p.wash else null }, p.hover);
            // The one in use too: either way the keys go back to the field.
            if (it.clicked) clicked = e;
            _ = c.leaf(.{}, .{ .text = .{ .str = e.name(), .style = .{ .size = 11.5 }, .color = if (on) p.ink else p.muted } }, null);
            c.end();
        }
        return clicked;
    }

    fn step(o: *Omnibox, by: i32, n: usize) void {
        if (n == 0) return;
        if (o.picked) |i| {
            const next = @as(i64, @intCast(i)) + by;
            o.picked = if (next < 0 or next >= n) null else @intCast(next);
        } else o.picked = if (by > 0) 0 else n - 1;
    }

    fn list(o: *Omnibox, c: *ui.Context, x: f32, y: f32, w: f32, offers: []const Offer, in: Result) Result {
        const p = theme.of(c);
        var out = in;
        _ = c.open(.{
            .absolute = true,
            .offset = .{ .x = x, .y = y },
            .width = .{ .px = w },
            .padding = .all(6),
            .radius = m.field_radius,
            .background = p.ground,
            .border = p.hairline,
            .shadow = .{ .color = .{ .a = 0.06 }, .blur = 24, .y = 8 },
        }, "offers");
        defer c.end();
        for (offers, 0..) |offer, i| {
            ui.key(c, offer.url);
            const it = ui.pressable(c, .{ .direction = .row, .width = .fill, .padding = .xy(12, 8), .gap = 10, .radius = 9, .align_items = .center, .control = true, .background = if (o.picked == i) p.wash else null }, p.hover);
            defer c.end();
            if (it.clicked) out = chosen(offer);
            if (offer.search) ui.icon(c, "magnifyingglass", .{ .size = 12, .frame = 16, .color = p.muted });
            _ = c.leaf(.{ .clip = true }, .{ .text = .{ .str = if (offer.search) offer.url else address.display(offer.url), .style = .{ .size = 13, .truncate = .fade }, .color = p.ink } }, null);
            if (offer.title.len > 0) _ = c.leaf(.{ .grow = 1, .clip = true }, .{ .text = .{ .str = offer.title, .style = .{ .size = 12.5, .truncate = .fade }, .color = p.muted } }, null);
        }
        return out;
    }
};

fn chosen(offer: Offer) Omnibox.Result {
    return if (offer.search) .{ .search = offer.url } else .{ .go = offer.url };
}

/// The places that begin with, or hold, what was typed: the best few of those
/// `known` lists, most recent first, into `out`.
pub fn offersFor(typed: []const u8, known: []const Offer, out: []Offer) []Offer {
    if (typed.len == 0) return out[0..0];
    var n: usize = 0;
    var i = known.len;
    while (i > 0 and n < out.len) {
        i -= 1;
        const k = known[i];
        if (startsWithIgnoreCase(address.display(k.url), typed)) {
            if (!listed(out[0..n], k)) {
                out[n] = k;
                n += 1;
            }
        }
    }
    i = known.len;
    while (i > 0 and n < out.len) {
        i -= 1;
        const k = known[i];
        if (text_search.find(k.url, 0, typed) != null or text_search.find(k.title, 0, typed) != null) {
            if (!listed(out[0..n], k)) {
                out[n] = k;
                n += 1;
            }
        }
    }
    return out[0..n];
}

fn listed(list: []const Offer, k: Offer) bool {
    for (list) |o| if (std.mem.eql(u8, o.url, k.url)) return true;
    return false;
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

test "offers: starts first, then anywhere, once each, newest first" {
    const known = [_]Offer{
        .{ .url = "https://example.com/a", .title = "Birds" },
        .{ .url = "https://wikipedia.org/Bird", .title = "Bird" },
        .{ .url = "https://example.com/b", .title = "" },
    };
    var buf: [4]Offer = undefined;
    const a = offersFor("exam", &known, &buf);
    try std.testing.expectEqual(@as(usize, 2), a.len);
    try std.testing.expectEqualStrings("https://example.com/b", a[0].url);
    const b = offersFor("bird", &known, &buf);
    try std.testing.expectEqual(@as(usize, 2), b.len);
    try std.testing.expectEqual(@as(usize, 0), offersFor("", &known, &buf).len);
}
