//! The benchmark scenes, nanoui's side; mygo/zz_nanoui_hillclimb_test.go
//! builds the same ones with mygo, and clay.zig with Clay. Each frame changes what it shows, as an
//! animation would, so every frame does all its work.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Scene = enum { boxes, text, scroll, list, dashboard, springs, letters };

pub const State = struct {
    scene: Scene,
    frame: usize = 0,
    time: f32 = 0,

    pub fn view(s: *State, c: *ui.Context) void {
        switch (s.scene) {
            .boxes => boxes(s, c),
            .text => text(s, c),
            .scroll => scroll(s, c),
            .list => list(s, c),
            .dashboard => dashboard(s, c),
            .springs => springs(s, c),
            .letters => letters(s, c),
        }
    }
};

fn boxes(s: *State, c: *ui.Context) void {
    const t = s.time;
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(10), .gap = 4 });
    defer ui.end(c);
    for (0..20) |r| {
        ui.row(c, .{ .gap = 4 });
        defer ui.end(c);
        for (0..30) |col| {
            const i: f32 = @floatFromInt(r * 30 + col);
            _ = c.leaf(.{
                .width = .{ .px = 24 },
                .height = .{ .px = 24 },
                .radius = 6,
                .background = hsl(@mod(t * 60 + i * 3, 360)),
                .shadow = .{ .color = .{ .a = 0.2 }, .blur = 4, .y = 2 },
                .offset = .{ .y = 6 * @sin(t * 3 + i * 0.1) },
            }, .none, null);
        }
    }
}

fn text(s: *State, c: *ui.Context) void {
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(10), .gap = 6 });
    defer ui.end(c);
    for (0..15) |r| {
        ui.row(c, .{ .gap = 4 });
        defer ui.end(c);
        for (0..20) |col| {
            const i = r * 20 + col;
            ui.column(c, .{ .width = .{ .px = 40 } });
            defer ui.end(c);
            ui.textf(c, .{ .size = 13 }, "{d}", .{(s.frame * 7 + i * 13) % 10000});
        }
    }
}

fn scroll(s: *State, c: *ui.Context) void {
    const row_h = 28;
    const rows = 1000;
    const offset = @mod(s.time * 600, row_h * rows - 640);
    ui.column(c, .{ .width = .fill, .height = .fill, .clip = true });
    defer ui.end(c);
    ui.column(c, .{ .width = .fill, .offset = .{ .y = -offset } });
    defer ui.end(c);
    for (0..rows) |i| {
        ui.row(c, .{ .width = .fill, .height = .{ .px = row_h }, .padding = .xy(12, 0), .gap = 8, .align_items = .center });
        defer ui.end(c);
        ui.textf(c, .{ .size = 13 }, "Row {d} — a line of a long list", .{i});
        ui.spacer(c);
        ui.textf(c, .{ .size = 12 }, "{d}", .{i * 7 % 100});
    }
}

/// A virtual list of 100 000 rows, scrolled to another row each frame.
fn list(s: *State, c: *ui.Context) void {
    const rows = 100_000;
    const row = (s.frame * 3) % (rows - 40);
    var it = ui.list(c, .{ .count = rows, .row_height = 28, .scroll_to = @as(f32, @floatFromInt(row)) * 28 });
    while (it.next()) |i| {
        ui.row(c, .{ .width = .fill, .height = .{ .px = 28 }, .padding = .xy(12, 0), .gap = 8, .align_items = .center });
        defer ui.end(c);
        ui.textf(c, .{ .size = 13 }, "Row {d} — a line of a long list", .{i});
        ui.spacer(c);
        ui.textf(c, .{ .size = 12 }, "{d}", .{i * 7 % 100});
    }
    it.end();
}

fn dashboard(s: *State, c: *ui.Context) void {
    const t = s.time;
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(16), .gap = 12 });
    defer ui.end(c);
    for (0..3) |r| {
        ui.row(c, .{ .gap = 12 });
        defer ui.end(c);
        for (0..4) |col| {
            const i = r * 4 + col;
            const v = 0.5 + 0.5 * @sin(t * 2 + @as(f32, @floatFromInt(i)));
            ui.column(c, .{
                .width = .{ .px = 200 },
                .padding = .all(14),
                .gap = 8,
                .radius = 12,
                .background = .white,
                .shadow = .{ .color = .{ .a = 0.12 }, .blur = 16, .y = 4 },
            });
            defer ui.end(c);
            ui.textf(c, .{ .size = 13 }, "Metric {d}", .{i});
            ui.textf(c, .{ .size = 28, .weight = .bold }, "{d}", .{@as(u32, @intFromFloat(v * 1000))});
            ui.row(c, .{ .width = .{ .px = 172 }, .height = .{ .px = 6 }, .radius = 3, .background = .hex(0xe0e0e5) });
            _ = c.leaf(.{ .width = .{ .px = 172 * v }, .height = .{ .px = 6 }, .radius = 3, .background = .hex(0x0a84ff) }, .none, null);
            ui.end(c);
            ui.textf(c, .{ .size = 11 }, "updated {d}s ago", .{s.frame % 60});
        }
    }
}

/// 2 000 boxes whose targets move every frame, through `ui.motion`.
fn springs(s: *State, c: *ui.Context) void {
    const t = s.time;
    const root = ui.div(c).column().sizeFull().p(8).gap(2);
    defer root.end();
    for (0..40) |r| {
        const row = ui.div(c).row().gap(2);
        defer row.end();
        for (0..50) |col| {
            const n = r * 50 + col;
            const i: f32 = @floatFromInt(n);
            ui.keyInt(c, n);
            const f = ui.motion.frame(c, .{
                .target = .{
                    .y = 4 * @sin(t * 3 + i * 0.1),
                    .background = hsl(@mod(t * 60 + i * 3, 360)),
                },
                .transition = .{ .spring = .{} },
            });
            const box = ui.div(c).w(14).h(14).rounded(3).motion(f);
            box.end();
        }
    }
}

fn letters(s: *State, c: *ui.Context) void {
    const root = ui.div(c).column().sizeFull().p(16).gap(10);
    defer root.end();
    const lines = [_][]const u8{
        "Springs keep their speed when the target turns",
        "Tweens ease from where they are, not from the start",
        "Presence waits for a box to leave before it is gone",
        "Layout glides a shuffled row to its new place",
        "Letters enter one after another, then sit still",
    };
    const round = s.frame / 45;
    for (lines, 0..) |line, i| {
        ui.key(c, c.print("L{d}-{d}", .{ i, round }));
        const wrap = ui.div(c);
        defer wrap.end();
        ui.motion.letters(c, line, .{ .size = 16 }, .{
            .unit = .letters,
            .enter = .{ .y = 8, .opacity = 0 },
            .stagger_each = 0.012,
            .transition = .{ .tween = .{ .duration = 0.25, .ease = .ease_out } },
        });
    }
}

pub fn hsl(h: f32) ui.Color {
    const sat: f32 = 0.7;
    const l: f32 = 0.55;
    const k = struct {
        fn f(n: f32, hh: f32, ss: f32, ll: f32) f32 {
            const kk = @mod(n + hh / 30, 12);
            const a = ss * @min(ll, 1 - ll);
            return ll - a * @max(-1, @min(@min(kk - 3, 9 - kk), 1));
        }
    }.f;
    return .{ .r = k(0, h, sat, l), .g = k(8, h, sat, l), .b = k(4, h, sat, l) };
}
