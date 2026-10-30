//! A tour of the native UI toolkit: layout, text, every widget and motion,
//! drawn by nanoui (with Metal on macOS and iOS, OpenGL or its CPU renderer
//! elsewhere).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const phone = @import("phone.zig");

const Item = struct { title: [64]u8, len: usize, done: bool };

const Gallery = struct {
    page: usize = 0,
    /// On a phone: the page is open, pushed over the list of pages.
    open: bool = false,
    notifications: bool = true,
    dark_glass: bool = false,
    sync: bool = true,
    volume: f32 = 0.6,
    speed: f32 = 3,
    clicks: u32 = 0,
    name: ui.TextBuffer = .{},
    task: ui.TextBuffer = .{},
    filter: ui.TextBuffer = .{},
    items: [64]Item = undefined,
    count: usize = 0,
    /// The last few frames' times, and the rate read from them: `fps` follows
    /// the frame as it is drawn, and falls when the app goes idle, because idle
    /// frames really are slower coming.
    fps_samples: [8]f32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    fps_at: usize = 0,
    fps: f32 = 0,
    /// Wait for the display's refresh when presenting. Off, the frame rate is
    /// the renderer's own.
    vsync: bool = true,
    motion: @import("motion.zig").Demo = .{},
    kit: @import("kit.zig").Demo = .{},
    glass: @import("glass.zig").Demo = .{},

    fn add(g: *Gallery, title: []const u8) void {
        if (g.count == g.items.len or title.len == 0) return;
        var it: Item = .{ .title = undefined, .len = @min(title.len, 64), .done = false };
        @memcpy(it.title[0..it.len], title[0..it.len]);
        g.items[g.count] = it;
        g.count += 1;
    }

    fn view(g: *Gallery, c: *ui.Context) void {
        // The rate from the last few frames' own gaps, refreshed every frame:
        // a frame drawn now is in the number now. `c.dt` is the real gap
        // between frames, and it reads low while the app sits idle, which is
        // the truth of it.
        g.fps_samples[g.fps_at] = c.frame_time;
        g.fps_at = (g.fps_at + 1) % g.fps_samples.len;
        var total: f32 = 0;
        for (g.fps_samples) |s| total += s;
        g.fps = if (total > 0) @as(f32, @floatFromInt(g.fps_samples.len)) / total else 0;
        c.vsync = g.vsync;
        if (phone.compact(c)) return phone.view(g, c);
        ui.row(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);
        g.sidebar(c);
        g.content(c);
    }

    /// The page shown, beside the sidebar or pushed on a phone.
    pub fn content(g: *Gallery, c: *ui.Context) void {
        if (g.page == 3) return g.bigList(c);
        if (g.page == 4) return g.glass.view(c);
        if (g.page == 5) return g.motion.page(c);
        if (g.page == 6) return g.kit.view(c);
        ui.scroll(c, .{ .grow = 1, .width = .fill, .height = .fill, .padding = .all(if (phone.compact(c)) 16 else 28), .gap = 20 });
        defer ui.end(c);
        switch (g.page) {
            0 => g.controls(c),
            1 => g.tasks(c),
            2 => g.typography(c),
            else => g.bigList(c),
        }
    }

    fn sidebar(g: *Gallery, c: *ui.Context) void {
        const th = c.theme;
        ui.column(c, .{
            .width = .{ .px = 200 },
            .height = .fill,
            .padding = .{ .top = 44, .left = 12, .right = 12, .bottom = 12 },
            .gap = 4,
            .background = th.surface.alpha(0.6),
            .border = th.border,
            .border_width = 0,
        });
        defer ui.end(c);
        ui.text(c, "nanoui", .{ .size = 18, .weight = .bold });
        ui.label(c, c.print("Zig 0.17 · {s}", .{c.renderer}));
        _ = c.leaf(.{ .height = .{ .px = 12 } }, .none, null);
        for (phone.pages, 0..) |p, i| {
            const selected = g.page == i;
            // GPUI's way: a box styled by a chain of methods.
            var item = ui.div(c).row().wFull().px(10).py(7).gap(8).itemsCenter().rounded(7);
            item = if (selected) item.bg(th.accent) else item.hover(th.surface_hover);
            defer item.end();
            if (item.clicked()) g.page = i;
            const fg = if (selected) th.accent_text else th.text;
            ui.icon(c, p[1], .{ .size = 14, .frame = 18, .color = fg });
            ui.text(c, p[0], .{ .weight = .medium, .color = fg });
        }
        ui.spacer(c);
        ui.label(c, c.print("{d} frames", .{c.frame}));
        ui.label(c, c.print("{d:.0} fps", .{g.fps}));
    }

    fn controls(g: *Gallery, c: *ui.Context) void {
        ui.heading(c, "Controls");
        ui.card(c, .{ .width = .fill, .gap = 14 });
        {
            defer ui.end(c);
            ui.text(c, "Buttons", .{ .weight = .semibold });
            ui.row(c, .{ .gap = 8, .align_items = .center });
            defer ui.end(c);
            if (ui.button(c, "Primary", .{ .variant = .primary }).clicked) g.clicks += 1;
            if (ui.button(c, "Secondary", .{}).clicked) g.clicks += 1;
            if (ui.button(c, "Ghost", .{ .variant = .ghost }).clicked) g.clicks += 1;
            if (phone.compact(c)) {
                // Two rows: a phone is too narrow for one.
                ui.end(c);
                ui.row(c, .{ .gap = 8, .align_items = .center });
            }
            if (ui.button(c, "Delete", .{ .variant = .danger }).clicked) g.clicks = 0;
            _ = ui.button(c, "Disabled", .{ .disabled = true });
            ui.badge(c, c.print("{d} clicks", .{g.clicks}), c.theme.accent);
        }
        ui.card(c, .{ .width = .fill, .gap = 14 });
        {
            defer ui.end(c);
            ui.text(c, "Toggles", .{ .weight = .semibold });
            _ = ui.toggle(c, "Notifications", &g.notifications);
            _ = ui.toggle(c, "Sync over cellular", &g.sync);
            _ = ui.checkbox(c, "Remember me", &g.dark_glass);
            _ = ui.checkbox(c, "V-Sync", &g.vsync);
        }
        ui.card(c, .{ .width = .fill, .gap = 12 });
        {
            defer ui.end(c);
            ui.text(c, "Sliders and progress", .{ .weight = .semibold });
            const slider_w: f32 = if (phone.compact(c)) 170 else 240;
            ui.row(c, .{ .gap = 12, .align_items = .center });
            ui.text(c, "Volume", .{ .color = c.theme.muted });
            _ = ui.slider(c, &g.volume, .{ .width = .{ .px = slider_w } });
            ui.textf(c, .{ .mono = true, .size = 12 }, "{d:.0}%", .{g.volume * 100});
            ui.end(c);
            ui.progress(c, g.volume, .{ .px = if (phone.compact(c)) 280 else 340 });
            ui.row(c, .{ .gap = 12, .align_items = .center });
            ui.text(c, "Speed", .{ .color = c.theme.muted });
            _ = ui.slider(c, &g.speed, .{ .min = 1, .max = 10, .width = .{ .px = slider_w } });
            ui.textf(c, .{ .mono = true, .size = 12 }, "{d:.1}×", .{g.speed});
            ui.end(c);
        }
        ui.card(c, .{ .width = .fill, .gap = 12 });
        {
            defer ui.end(c);
            ui.text(c, "Text field", .{ .weight = .semibold });
            ui.row(c, .{ .gap = 8, .align_items = .center });
            _ = ui.textField(c, &g.name, .{ .placeholder = "Your name" });
            ui.end(c);
            const name = g.name.text();
            ui.text(c, if (name.len == 0) "Type to be greeted." else c.print("Hello, {s}!", .{name}), .{ .color = c.theme.muted });
        }
    }

    fn tasks(g: *Gallery, c: *ui.Context) void {
        ui.heading(c, "Tasks");
        ui.row(c, .{ .gap = 8, .align_items = .center });
        const r = ui.textField(c, &g.task, .{ .placeholder = "Something to do", .width = .{ .px = if (phone.compact(c)) 240 else 300 } });
        const add_clicked = ui.button(c, "Add", .{ .variant = .primary }).clicked;
        ui.end(c);
        if (r.submitted or add_clicked) {
            g.add(std.mem.trim(u8, g.task.text(), " "));
            g.task.clear();
        }
        var left: usize = 0;
        for (g.items[0..g.count]) |it| left += @intFromBool(!it.done);
        ui.label(c, c.print("{d} of {d} left", .{ left, g.count }));
        ui.card(c, .{ .width = .fill, .padding = .xy(16, 6), .gap = 0 });
        defer ui.end(c);
        var remove: ?usize = null;
        for (g.items[0..g.count], 0..) |*it, i| {
            if (i > 0) ui.divider(c);
            ui.key(c, c.print("task-{d}", .{@intFromPtr(it)}));
            ui.row(c, .{ .width = .fill, .padding = .xy(0, 8), .align_items = .center, .gap = 8 });
            defer ui.end(c);
            _ = ui.checkbox(c, it.title[0..it.len], &it.done);
            ui.spacer(c);
            if (it.done) ui.badge(c, "done", c.theme.success);
            if (ui.button(c, "Remove", .{ .variant = .ghost, .size = 12 }).clicked) remove = i;
        }
        if (remove) |i| {
            std.mem.copyForwards(Item, g.items[i .. g.count - 1], g.items[i + 1 .. g.count]);
            g.count -= 1;
        }
        if (g.count == 0) ui.text(c, "Nothing to do.", .{ .color = c.theme.muted });
    }

    /// Ten thousand rows, filtered as you type: only those in view are built.
    fn bigList(g: *Gallery, c: *ui.Context) void {
        const th = c.theme;
        ui.column(c, .{ .grow = 1, .height = .fill, .padding = .{ .top = 28, .left = 28, .right = 28 }, .gap = 12 });
        defer ui.end(c);
        ui.heading(c, "List");
        ui.row(c, .{ .gap = 8, .align_items = .center });
        ui.icon(c, "magnifyingglass", .{ .color = th.muted });
        _ = ui.textField(c, &g.filter, .{ .placeholder = "Filter 10 000 rows", .width = .{ .px = 280 } });
        ui.end(c);
        // The rows that match, as indices into the 10 000.
        var matches: std.ArrayList(u16) = .empty;
        const f = g.filter.text();
        for (0..10_000) |i| {
            if (f.len == 0 or std.mem.indexOf(u8, c.print("Item {d}", .{i}), f) != null)
                matches.append(c.alloc(), @intCast(i)) catch break;
        }
        ui.label(c, c.print("{d} rows · a virtual list builds only those in view", .{matches.items.len}));
        var rows = ui.list(c, .{ .count = matches.items.len, .row_height = 36, .gap = 0 });
        while (rows.next()) |i| {
            const n = matches.items[i];
            const row = ui.div(c).row().wFull().h(36).px(12).gap(10).itemsCenter().rounded(6).hover(th.surface_hover);
            defer row.end();
            ui.icon(c, if (n % 3 == 0) "star.fill" else "doc.text", .{ .size = 13, .frame = 18, .color = if (n % 3 == 0) th.accent else th.muted });
            ui.textf(c, .{}, "Item {d}", .{n});
            ui.spacer(c);
            ui.textf(c, .{ .size = 12, .color = th.muted, .mono = true }, "#{x:0>4}", .{n});
        }
        rows.end();
    }

    fn typography(_: *Gallery, c: *ui.Context) void {
        ui.heading(c, "Typography");
        ui.card(c, .{ .width = .fill, .gap = 10, .max_width = 640 });
        defer ui.end(c);
        ui.text(c, "Large Title", .{ .size = 30, .weight = .bold });
        ui.text(c, "Title, semibold", .{ .size = 20, .weight = .semibold });
        ui.text(c, "Body text in the system font, at 14 points.", .{});
        ui.text(c, "const mono = \"monospaced, for code\";", .{ .mono = true, .size = 13 });
        ui.text(c, "Unicode: naïve café — 日本語 — Ελληνικά — ✓ ★ →", .{});
        ui.divider(c);
        ui.text(c, "Text wraps to the width its box gets. Resize the window to watch these lines break " ++
            "again: layout runs every frame, measured with CoreText, and each line is rasterized once into a " ++
            "glyph atlas at the display's scale, then drawn as textured quads by one instanced Metal draw " ++
            "call together with every rectangle, border and shadow on screen.", .{ .wrap = true, .color = c.theme.muted });
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Gallery" });
    defer app.destroy();
    var g: Gallery = .{};
    g.add("Write a UI toolkit in Zig");
    g.add("Draw it with Metal");
    g.add("Ship it");
    g.items[1].done = true;
    _ = try app.newWindow(.{
        .title = "Gallery",
        .width = 900,
        .height = 640,
        .min_width = 600,
        .min_height = 400,
        .title_bar = .hidden,
        .content = .{ .view = .init(&g, Gallery.view) },
    });
    try app.run();
}
