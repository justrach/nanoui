//! The first-launch welcome: four cards on a binder ring, each turned over
//! like a page to show the next (`Style.turn`), the words beside them, and
//! on the last the real location ask with "Not now". Shown until it is
//! finished once (kv "onboarded"); `SGBUS_FRESH=1` shows it again.
//! The motion follows onboarding.md: the turn on a 110/19 spring about the
//! ring, the next card rising on 300/18 after 120 ms, the headline's words
//! staggered by 30 ms, the dots and the arrow growing into a pill. With
//! reduced motion it crossfades in 200 ms.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Spring = ui.motion.Spring;

const deg: f32 = std.math.pi / 180.0;
const paper: ui.Color = .hex(0xFBFBF9);
const ink: ui.Color = .hex(0x111111);
const gray: ui.Color = .hex(0x6E6E73);
const card_w: f32 = 290;
const card_h: f32 = 330;
/// The ring, in points from the card's top left: the turn's pivot.
const ring: [2]f32 = .{ 14, 32 };

const turn_spring: Spring = .{ .stiffness = 110, .damping = 19 };
const rise_spring: Spring = .{ .stiffness = 300, .damping = 18 };
const pill_spring: Spring = .{ .stiffness = 300, .damping = 26 };

const Step = struct {
    head: []const u8,
    sub: []const u8,
    picture: []const u8,
    key: []const u8,
    /// The picture's own ground, which fills the card around it.
    ground: ui.Color,
};

const steps = [_]Step{
    .{ .head = "Know when your bus come.", .sub = "Live arrivals for every stop. Refreshed every 15 s, no need to chase.", .picture = @embedFile("assets/bus.jpg"), .key = "ob-bus", .ground = .hex(0x468C4C) },
    .{ .head = "Star your usual stops.", .sub = "Home, office, kopitiam. One tap and they are all there.", .picture = @embedFile("assets/stop.jpg"), .key = "ob-stop", .ground = .hex(0x005EE6) },
    .{ .head = "From here to anywhere.", .sub = "Bus and MRT in one plan, with the walk in between.", .picture = @embedFile("assets/card.jpg"), .key = "ob-card", .ground = .hex(0xFE892D) },
    .{ .head = "Can relax, we find your stop.", .sub = "Share your location and we show the stops around you. It stays on your phone.", .picture = @embedFile("assets/pin.jpg"), .key = "ob-pin", .ground = .hex(0xFAC122) },
};

pub const Answer = enum { none, allow, later };

pub const Onboarding = struct {
    step: u8 = 0,
    prev: u8 = 0,
    /// When the step last changed (the context's clock).
    since: f64 = -10,
    landed: bool = true,
    answer: Answer = .none,
    /// The nearest stop's code, for the line under the last card.
    nearest: []const u8 = "83139",

    pub fn go(o: *Onboarding, c: *ui.Context, to: u8) void {
        if (to == o.step or to >= steps.len) return;
        o.prev = o.step;
        o.step = to;
        o.since = c.time;
        o.landed = false;
        nanoui.haptics.selection();
    }

    /// The welcome, filling the window. `answer` is set once it is done.
    pub fn view(o: *Onboarding, c: *ui.Context) void {
        if (!o.landed and c.time - o.since > 0.55) {
            o.landed = true;
            nanoui.haptics.impact(.light);
        }
        if (c.device.split() == .none and c.size.w < 600) return o.single(c);
        const root = ui.div(c).column().sizeFull().bg(paper);
        defer root.end();
        const sa = c.safe_area;
        const p = ui.panes(c, .{ .ratio = 0.5, .without_fold = .wide });
        // Words, dots and arrow left of the fold; the deck in the right pane.
        o.words(c, .{ .top = sa.top + 8, .left = 32, .right = 32, .bottom = 24 }, paneWidth(c) - 64);
        if (p.second()) {
            const right = ui.div(c).column().sizeFull().itemsCenter().justifyCenter();
            o.deck(c);
            right.end();
        }
        p.end();
    }

    fn paneWidth(c: *ui.Context) f32 {
        return switch (c.device.split()) {
            .side_by_side => |s| s.leading,
            else => c.size.w * 0.5,
        };
    }

    /// One pane (a phone, the Duo folded): words over the deck.
    fn single(o: *Onboarding, c: *ui.Context) void {
        const sa = c.safe_area;
        const root = ui.div(c).column().sizeFull().bg(paper).pt(sa.top + 8).pb(@max(sa.bottom, 16)).pl(sa.left + 28).pr(sa.right + 24);
        defer root.end();
        o.skip(c);
        o.headline(c, c.size.w - sa.left - sa.right - 56);
        const mid = ui.div(c).column().wFull().grow().itemsCenter().justifyCenter();
        o.deck(c);
        mid.end();
        o.controls(c);
    }

    fn words(o: *Onboarding, c: *ui.Context, pad: ui.Edges, width: f32) void {
        const col = ui.div(c).column().sizeFull().pt(pad.top).pl(pad.left).pr(pad.right).pb(pad.bottom);
        defer col.end();
        o.skip(c);
        const mid = ui.div(c).column().wFull().grow().justifyCenter();
        o.headline(c, width);
        mid.end();
        o.controls(c);
    }

    fn skip(o: *Onboarding, c: *ui.Context) void {
        const row = ui.div(c).row().wFull().h(36).justifyEnd().itemsCenter();
        defer row.end();
        if (o.step + 1 < steps.len) {
            const b = ui.div(c).px(8).py(6);
            ui.text(c, "Skip", .{ .size = 17, .weight = .medium, .color = gray });
            if (b.clicked()) o.go(c, steps.len - 1);
            b.end();
        }
    }

    /// The headline (serif 40, its words rising in turn) and the line under it.
    fn headline(o: *Onboarding, c: *ui.Context, width: f32) void {
        const box = ui.div(c).column().wFull().gap(14).pt(8);
        defer box.end();
        const t = c.time - o.since;
        const fresh = o.prev != o.step and t < 0.6;
        const reduced = c.reduced_motion or c.reduce_motion;
        if (fresh and !reduced) {
            // The old headline drifts up and fades in 180 ms, over the new.
            const out: f32 = @floatCast(std.math.clamp(t / 0.18, 0, 1));
            const old = ui.div(c).absolute().offset(0, 8 - 24 * out).column().gap(14).opacity(1 - out);
            lines(c, steps[o.prev].head, width, o.since, false);
            old.end();
            if (out < 1) c.animationFrame();
        }
        lines(c, steps[o.step].head, width, o.since, !reduced and o.prev != o.step);
        const sub_in: f32 = if (reduced or o.prev == o.step) 1 else rise(c, o.since, 0.2, Spring.snappy);
        const sub = ui.div(c).wFull().opacity(std.math.clamp(sub_in, 0, 1)).offset(0, 12 * (1 - sub_in));
        ui.text(c, steps[o.step].sub, .{ .size = 15, .color = gray, .wrap = true, .leading = 1.3 });
        sub.end();
    }

    /// Dots bottom left, the arrow (or "Allow location" pill) bottom right.
    fn controls(o: *Onboarding, c: *ui.Context) void {
        const last = o.step + 1 == steps.len;
        if (last) {
            const note = ui.div(c).wFull().pb(10);
            ui.text(c, c.print("Nearest stop maybe {s}, but we check first lah.", .{o.nearest}), .{ .size = 13, .color = gray });
            note.end();
        }
        const row = ui.div(c).row().wFull().h(64).itemsCenter().justifyBetween();
        defer row.end();
        {
            const dots = ui.div(c).row().gap(6).itemsCenter();
            for (0..steps.len) |i| {
                c.next_key = steps[i].key;
                const on = i == o.step;
                const w = ui.motion.number(c, "dot", if (on) 18 else 6, .{ .spring = Spring.snappy });
                const d = ui.div(c).w(w).h(6).roundedFull().bg(if (on) ink else .hex(0xD6D6D9));
                if (d.clicked() and i < o.step) o.go(c, @intCast(i));
                d.end();
            }
            dots.end();
        }
        const right = ui.div(c).row().gap(14).itemsCenter();
        defer right.end();
        if (last) {
            const later = ui.div(c).px(6).py(8);
            ui.text(c, "Not now", .{ .size = 16, .weight = .medium, .color = gray });
            if (later.clicked()) o.answer = .later;
            later.end();
        }
        const goal: f32 = if (last) 166 else 56;
        const w = if (c.reduced_motion or c.reduce_motion) goal else ui.motion.number(c, "arrow", goal, .{ .spring = pill_spring });
        const b = ui.div(c).w(w).h(56).roundedFull().bg(ink).itemsCenter().justifyCenter().shadowMd().clip();
        if (w > 120) {
            ui.text(c, "Allow location", .{ .size = 16, .weight = .semibold, .color = .white, .truncate = .fade });
        } else ui.text(c, "→", .{ .size = 22, .weight = .semibold, .color = .white });
        if (b.clicked()) {
            if (last) o.answer = .allow else o.go(c, o.step + 1);
        }
        b.end();
    }

    /// The four cards, the top one on the ring, the rest peeking out below.
    fn deck(o: *Onboarding, c: *ui.Context) void {
        const box = ui.div(c).size(card_w + 40, card_h + 40);
        defer box.end();
        const t = c.time - o.since;
        const reduced = c.reduced_motion or c.reduce_motion;
        const fade: f32 = @floatCast(std.math.clamp(t / 0.2, 0, 1));
        if (reduced and fade < 1) c.animationFrame();
        // Back to front: the card furthest down first, a turning card last.
        var i: usize = steps.len;
        while (i > 0) {
            i -= 1;
            const was: f32 = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(o.prev));
            const now: f32 = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(o.step));
            if (reduced) {
                // A crossfade: the card leaving fades, the rest are in place.
                if (now < 0 and was < 0) continue;
                const k = @max(now, 0);
                const a: f32 = if (now < 0) 1 - fade else if (was < 0) fade else 1;
                if (a > 0.01) o.card(c, i, k, a);
                continue;
            }
            const turning = now < 0 or was < 0;
            const p: f32 = if (was == now) 1 else if (turning) rise(c, o.since, 0, turn_spring) else rise(c, o.since, 0.12, rise_spring);
            const k = was + (now - was) * p;
            if (k > 3.5) continue;
            o.card(c, i, k, 1);
        }
        // The metal ring the cards hang on.
        const rx = 20 + ring[0] - 15;
        const ry = 20 + ring[1] - 15;
        ui.div(c).absolute().offset(rx, ry).size(30, 30).roundedFull().border(.hex(0x9A9AA0)).borderW(5).shadowSm().end();
        ui.div(c).absolute().offset(rx + 2, ry + 2).size(26, 26).roundedFull().border(.hex(0xE4E4E8)).borderW(2).end();
    }

    /// Card `i` at deck position `k`: 0 on top, 1, 2, 3 peeking out below
    /// (+6, +4 pt and +3° each), -1 turned over (-112° about the ring).
    fn card(o: *Onboarding, c: *ui.Context, i: usize, k: f32, alpha: f32) void {
        const s = steps[i];
        const over = std.math.clamp(-k, 0, 1);
        const below = @max(k, 0);
        const angle = -112 * deg * over;
        // The front darkens as it turns from the light, and is gone by 92%.
        const opacity = alpha * (1 - std.math.clamp((over - 0.72) / 0.2, 0, 1));
        if (opacity <= 0.01) return;
        c.next_key = s.key;
        var d = ui.div(c).absolute().offset(20 + 6 * below - 30 * over, 20 + 4 * below).size(card_w, card_h).rounded(34).bg(s.ground).clip()
            .pivot(ring[0] / card_w, ring[1] / card_h).rotate((-6 + 3 * below - 8 * over) * deg).scale(1 - 0.03 * @min(below, 1)).opacity(opacity);
        if (over > 0) d = d.turn(angle, 1100);
        if (below < 0.5) _ = d.shadowLg();
        if (d.clicked() and k > -0.5 and k < 0.5 and i + 1 < steps.len) o.go(c, @intCast(i + 1));
        defer d.end();
        {
            const front = ui.div(c).absolute().offset(0, 0).sizeFull().face(.front).itemsCenter().justifyCenter();
            _ = ui.image(c, .{ .key = s.key, .bytes = s.picture, .max_width = card_w, .max_height = card_h, .radius = 0, .scale = 2 });
            front.end();
        }
        if (over > 0) {
            ui.div(c).absolute().offset(0, 0).sizeFull().bg(.hex(0x000000)).opacity(0.38 * @sin(over * std.math.pi / 2)).face(.front).end();
            ui.div(c).absolute().offset(0, 0).sizeFull().bg(s.ground).face(.back).end();
        }
    }
};

/// 0 to 1 (and a little past) on `spring`, `delay` s after `since`.
fn rise(c: *ui.Context, since: f64, delay: f64, spring: Spring) f32 {
    const t = c.time - since - delay;
    if (t < 2.5) c.animationFrame();
    if (t <= 0) return 0;
    if (t >= 2.5) return 1;
    return @floatCast(1 - spring.matrix(t)[0]);
}

/// The headline in lines that fit `width`, each word its own box so it can
/// rise in turn (30 ms apart, on Spring.snappy after 120 ms).
fn lines(c: *ui.Context, text: []const u8, width: f32, since: f64, moving: bool) void {
    const style: ui.TextStyle = .{ .size = 40, .serif = true, .color = ink };
    const space = c.text.width(" ", style);
    const col = ui.div(c).column().gap(0);
    defer col.end();
    var it = std.mem.splitScalar(u8, text, ' ');
    var n: usize = 0;
    var used: f32 = 0;
    var row: ?ui.Div = null;
    while (it.next()) |word| : (n += 1) {
        const w = c.text.width(word, style);
        if (row == null or used + space + w > width) {
            if (row) |r| r.end();
            row = ui.div(c).row().gap(space).h(43);
            used = w;
        } else used += space + w;
        const p: f32 = if (moving) rise(c, since, 0.12 + ui.motion.stagger(n, 0.03), Spring.snappy) else 1;
        const b = ui.div(c).offset(0, 24 * (1 - p)).opacity(std.math.clamp(p, 0, 1));
        ui.text(c, word, style);
        b.end();
    }
    if (row) |r| r.end();
}
