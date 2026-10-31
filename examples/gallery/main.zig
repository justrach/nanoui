//! A tour of the native UI toolkit: layout, text, every widget and motion,
//! drawn by nanoui (with Metal on macOS and iOS, OpenGL or its CPU renderer
//! elsewhere).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const phone = @import("phone.zig");

const Item = struct { title: [64]u8, len: usize, done: bool };

/// Which theme the gallery draws in: its own light or dark, or the system's.
pub const Appearance = enum { light, dark, system };

const Gallery = struct {
    page: usize = 0,
    /// On a phone: the page is open, pushed over the list of pages.
    open: bool = false,
    notifications: bool = true,
    /// Light, dark, or whatever the system shows (`c.theme_chosen`): the
    /// system's is the default, as the rest of the desktop has it.
    appearance: Appearance = .system,
    sync: bool = true,
    volume: f32 = 0.6,
    speed: f32 = 3,
    clicks: u32 = 0,
    name: ui.TextBuffer = .{},
    task: ui.TextBuffer = .{},
    filter: ui.TextBuffer = .{},
    items: [64]Item = undefined,
    count: usize = 0,
    /// The rows of the List page that match `filter`, as indices into the
    /// 100 000. Rebuilt only when the filter text changes: it used to be built
    /// every frame, which is 100 000 `print` allocations and appends per frame,
    /// and that is what made dragging the scrollbar stutter — the faster the
    /// frames came, the more of them paid that cost.
    matches: std.ArrayList(u32) = .empty,
    /// The filter text `matches` was built from, so an unchanged one costs a
    /// string compare instead of a rebuild.
    matches_for: std.ArrayList(u8) = .empty,
    /// Whether `matches` has ever been built. Without it the first frame
    /// compares the empty filter against the empty `matches_for`, calls them
    /// equal, and leaves the list at zero rows.
    matches_built: bool = false,
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
    /// The app, so a page can make a window of its own: the Windows page does,
    /// because a borderless or translucent window is the only way to see what
    /// those options do.
    app: ?*nanoui.App = null,
    /// The window the Windows page made, if it is open: one at a time, and the
    /// opacity slider writes to it.
    demo_window: ?*nanoui.Window = null,
    /// The demo window's options, as the page's controls set them. A slider is
    /// `f32` and a window's opacity is `f64`, so this is the slider's type and
    /// the window reads it converted.
    demo_opacity: f32 = 0.85,
    demo_borderless: bool = true,
    demo_skip_taskbar: bool = true,

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
        c.theme_chosen = switch (g.appearance) {
            .light => ui.Theme.light,
            .dark => ui.Theme.dark_theme,
            .system => null,
        };
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
        if (g.page == 6) return g.kit.view(c, &g.appearance);
        if (g.page == 7) return g.windowsContent(c);
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
            _ = ui.checkbox(c, "V-Sync", &g.vsync);
            ui.row(c, .{ .gap = 8, .align_items = .center });
            {
                defer ui.end(c);
                ui.text(c, "Theme", .{ .color = c.theme.muted });
                var choice: usize = @intFromEnum(g.appearance);
                if (ui.segmented(c, &.{ "Light", "Dark", "System" }, &choice)) {
                    g.appearance = @enumFromInt(choice);
                    c.changed = true;
                }
            }
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

    /// Rebuilds `matches` only when the filter text is not the one they were
    /// built from. That comparison is the whole point: an unchanged filter costs
    /// one `eql` per frame, and a changed one costs a single pass over the
    /// 100 000 — which is what a keystroke deserves and a frame does not.
    ///
    /// The allocations come from `std.heap.c_allocator`, not `c.alloc()`: that
    /// one is the frame's arena, reset at the start of every frame, so a list
    /// kept in it is freed while the list still points at it — which is why the
    /// count read zero on the second frame.
    fn syncMatches(g: *Gallery, c: *ui.Context) void {
        _ = c;
        const f = g.filter.text();
        if (g.matches_built and std.mem.eql(u8, g.matches_for.items, f)) return;
        g.matches_built = true;

        const gpa = std.heap.c_allocator;
        g.matches_for.clearRetainingCapacity();
        g.matches_for.appendSlice(gpa, f) catch return;
        g.matches.clearRetainingCapacity();

        // An empty filter is every row: no need to format 100 000 names to say
        // so, and that is the common case — the page opens with it empty, and a
        // scrollbar drag never touches it.
        if (f.len == 0) {
            g.matches.ensureTotalCapacity(gpa, 100_000) catch return;
            for (0..100_000) |i| g.matches.appendAssumeCapacity(@intCast(i));
            return;
        }
        // A filter is typed a character at a time, so this runs once per
        // keystroke at most; the formatted name is built into a stack buffer,
        // never allocated.
        var buf: [32]u8 = undefined;
        for (0..100_000) |i| {
            const name = std.fmt.bufPrint(&buf, "Item {d}", .{i}) catch continue;
            if (std.mem.indexOf(u8, name, f) != null) g.matches.append(gpa, @intCast(i)) catch return;
        }
    }

    /// A hundred thousand rows, filtered as you type: only those in view are
    /// built, and the matches themselves are rebuilt only when the filter text
    /// changes. Building them every frame is 100 000 formatted strings and
    /// 100 000 appends per frame, which is what made dragging the scrollbar
    /// stutter: the faster the frames came, the more of them paid it.
    fn bigList(g: *Gallery, c: *ui.Context) void {
        const th = c.theme;
        ui.column(c, .{ .grow = 1, .height = .fill, .padding = .{ .top = 28, .left = 28, .right = 28 }, .gap = 12 });
        defer ui.end(c);
        ui.heading(c, "List");
        ui.row(c, .{ .gap = 8, .align_items = .center });
        ui.icon(c, "magnifyingglass", .{ .color = th.muted });
        _ = ui.textField(c, &g.filter, .{ .placeholder = "Filter 100 000 rows", .width = .{ .px = 280 } });
        ui.end(c);
        g.syncMatches(c);
        ui.label(c, c.print("{d} rows · a virtual list builds only those in view", .{g.matches.items.len}));
        var rows = ui.list(c, .{ .count = g.matches.items.len, .row_height = 36, .gap = 0 });
        while (rows.next()) |i| {
            const n = g.matches.items[i];
            const row = ui.div(c).row().wFull().h(36).px(12).gap(10).itemsCenter().rounded(6).hover(th.surface_hover);
            defer row.end();
            ui.icon(c, if (n % 3 == 0) "star.fill" else "doc.text", .{ .size = 13, .frame = 18, .color = if (n % 3 == 0) th.accent else th.muted });
            ui.textf(c, .{}, "Item {d}", .{n});
            ui.spacer(c);
            ui.textf(c, .{ .size = 12, .color = th.muted, .mono = true }, "#{x:0>4}", .{n});
        }
        rows.end();
    }

    /// The Windows page's whole body, in the same scrolling column the other
    /// pages use: the three cards stack, they do not sit side by side.
    fn windowsContent(g: *Gallery, c: *ui.Context) void {
        ui.scroll(c, .{ .grow = 1, .width = .fill, .height = .fill, .padding = .all(if (phone.compact(c)) 16 else 28), .gap = 20 });
        defer ui.end(c);
        g.windowsPage(c);
        g.windowsOpacityCard(c);
        g.windowsNotesCard(c);
    }

    /// The window options only Windows can show: a borderless window, one that
    /// stays out of the taskbar, and one whose opacity a slider changes.
    ///
    /// The point of the page is that a person can see the result. Nothing about
    /// `decorations`, `skip_taskbar` or `opacity` is visible from the main
    /// window, so the page makes a second one and changes it live.
    fn windowsPage(g: *Gallery, c: *ui.Context) void {
        const th = c.theme;
        ui.heading(c, "Windows");
        ui.text(c, "A second window, made with the options below.", .{ .color = th.muted });
        ui.card(c, .{ .width = .fill, .gap = 12 });
        defer ui.end(c);
        ui.text(c, "Window", .{ .weight = .semibold });
        ui.textf(c, .{ .size = 12, .color = th.muted }, "decorations = {s}   skip_taskbar = {s}   opacity = {d:.2}", .{
            if (g.demo_borderless) "false (borderless)" else "true",
            if (g.demo_skip_taskbar) "true" else "false",
            g.demo_opacity,
        });
        if (ui.button(c, if (g.demo_window == null) "Open" else "Close", .{ .variant = .primary }).clicked) g.toggleDemoWindow(c);
        if (g.demo_window != null) {
            if (ui.checkbox(c, "Borderless", &g.demo_borderless)) g.reopenDemo(c);
            if (ui.checkbox(c, "Out of the taskbar", &g.demo_skip_taskbar)) g.reopenDemo(c);
        }
    }

    /// The opacity slider is its own card, so it can come and go with the demo
    /// window without closing the one above it.
    fn windowsOpacityCard(g: *Gallery, c: *ui.Context) void {
        if (g.demo_window == null) return;
        ui.card(c, .{ .width = .fill, .gap = 10 });
        defer ui.end(c);
        ui.text(c, "Opacity", .{ .weight = .semibold });
        if (ui.slider(c, &g.demo_opacity, .{ .min = 0.2, .max = 1, .width = .{ .px = 200 } })) g.applyDemoOpacity();
        ui.textf(c, .{ .mono = true, .size = 12 }, "{d:.0}%", .{g.demo_opacity * 100});
    }

    /// What the three options become on Windows: the page says it, so the demo
    /// does not have to be read alongside the source to make sense.
    fn windowsNotesCard(_: *Gallery, c: *ui.Context) void {
        const th = c.theme;
        ui.card(c, .{ .width = .fill, .gap = 8 });
        defer ui.end(c);
        ui.text(c, "What each one asks Windows for", .{ .weight = .semibold });
        for ([_][]const u8{
            "decorations = false  ->  WS_POPUP: no title bar, no frame, no drag-to-resize",
            "skip_taskbar = true  ->  WS_EX_TOOLWINDOW: out of the taskbar and Alt-Tab",
            "opacity < 1          ->  WS_EX_LAYERED + SetLayeredWindowAttributes",
        }) |line| ui.text(c, line, .{ .size = 12, .mono = true, .color = th.muted });
        ui.text(c, "While the window is translucent it is drawn by the canvas and presented with GDI: " ++
            "SetLayeredWindowAttributes does nothing on a DXGI flip-model swap chain. At 100% the GPU comes back.", .{ .size = 12, .color = th.muted, .wrap = true });
    }

    /// Makes the demo window with the current options, or remakes it: some of
    /// them (`WS_POPUP`, `WS_EX_LAYERED`) are fixed when a window is created and
    /// cannot be changed afterwards.
    fn toggleDemoWindow(g: *Gallery, c: *ui.Context) void {
        if (g.demo_window) |w| {
            w.close();
            g.demo_window = null;
        } else g.openDemo(c);
    }

    fn openDemo(g: *Gallery, c: *ui.Context) void {
        const app = g.app orelse return;
        const opts = nanoui.WindowOptions{
            .title = "Borderless demo",
            .width = 380,
            .height = 220,
            .decorations = !g.demo_borderless,
            .skip_taskbar = g.demo_skip_taskbar,
            .opacity = g.demo_opacity,
            .title_bar = .hidden,
            .content = .{ .view = .init(g, Gallery.demoView) },
        };
        g.demo_window = app.newWindow(opts) catch null;
        c.changed = true;
    }

    fn reopenDemo(g: *Gallery, c: *ui.Context) void {
        if (g.demo_window) |w| {
            w.close();
            g.demo_window = null;
        }
        g.openDemo(c);
    }

    fn applyDemoOpacity(g: *Gallery) void {
        if (g.demo_window) |w| {
            w.setOpacity(g.demo_opacity);
            // The demo window shows the number, so it is built again too.
            if (w.surface) |s| s.requestFrame();
        }
    }
    /// The demo window's own content: it says what it is, so it is obvious which
    /// window the options applied to, and it closes itself.
    ///
    /// The Close button is not decoration. A borderless window has no title bar
    /// and no system menu, and `skip_taskbar` keeps it out of the taskbar and
    /// Alt-Tab, so without a button of its own the window could not be closed at
    /// all — the first version of this demo could not be.
    ///
    /// Dragging: a borderless window cannot be moved by its title bar either.
    /// The header below is a drag handle (`ui.drag` moves the window), except
    /// when `decorations` is on, where the system's own title bar does it.
    fn demoView(g: *Gallery, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(16), .gap = 10, .width = .fill, .height = .fill });
        defer ui.end(c);

        // The header drags the window, and holds the Close button.
        const header = ui.div(c).row().wFull().gap(10).itemsCenter().h(30);
        defer header.end();
        // A borderless window has no title bar to drag, so the header is the
        // handle. A decorated one keeps its own title bar, and making this a
        // handle too would move the window twice.
        _ = c.leaf(.{ .grow = 1, .window_drag = g.demo_borderless }, .{ .text = .{
            .str = "Drag here to move",
            .style = .{ .size = 11 },
            .color = c.theme.muted,
        } }, null);
        if (ui.button(c, "Close", .{ .variant = .secondary, .size = 12 }).clicked) g.closeDemo();

        ui.text(c, "This window", .{ .size = 18, .weight = .bold });
        ui.text(c, if (g.demo_borderless) "borderless: no title bar, no frame." else "decorated: drag the title bar.", .{});
        ui.text(c, if (g.demo_skip_taskbar) "Out of the taskbar and Alt-Tab." else "In the taskbar and Alt-Tab.", .{});
        ui.textf(c, .{ .color = c.theme.muted }, "opacity {d:.0}%", .{g.demo_opacity * 100});
    }

    /// Closes the demo window and lets the page know, so the button goes back to
    /// "Open" and the controls that only apply to a live window go away.
    fn closeDemo(g: *Gallery) void {
        if (g.demo_window) |w| {
            g.demo_window = null;
            w.close();
        }
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
    g.app = app;
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
