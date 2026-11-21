//! A tour of the native UI toolkit: layout, text, every widget and motion,
//! drawn by nanoui (with Metal on macOS and iOS, OpenGL or its CPU renderer
//! elsewhere).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const phone = @import("phone.zig");
const catalog = @import("catalog.zig");
const sidebar = @import("sidebar.zig");
const page = @import("page.zig");

const web = @import("builtin").os.tag == .wasi;
const PlatformApp = if (web) void else nanoui.App;
const PlatformWindow = if (web) void else nanoui.Window;

/// Each demo's source, for its heading.
const demo_files = [phone.pages.len][]const u8{ "main.zig", "main.zig", "typography.zig", "main.zig", "glass.zig", "motion.zig", "kit.zig", "studio.zig", "windows.zig" };

const Item = struct { title: [64]u8, len: usize, done: bool };

/// Which theme the gallery draws in: its own light or dark, or the system's.
pub const Appearance = enum { light, dark, system };

pub const Gallery = struct {
    page: usize = 0,
    /// On a phone: the page is open, pushed over the list of pages.
    open: bool = false,
    /// On a phone: the chip chosen over the list, and its search.
    chip: usize = 0,
    search: ui.TextBuffer = .{},
    notifications: bool = true,
    /// Light, dark, or whatever the system shows (`c.theme_chosen`): the
    /// system's is the default, as the rest of the desktop has it.
    appearance: Appearance = .system,
    sync: bool = true,
    volume: f32 = 0.6,
    speed: f32 = 3,
    clicks: u32 = 0,
    name: ui.TextBuffer = .{},
    secret: ui.TextBuffer = .{},
    /// The multiline field on the Controls page: several lines, so the box is
    /// tall enough to hold them.
    notes: ui.TextBuffer = .{},
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
    scroll_probe_x: f32 = 0,
    scroll_probe_y: f32 = 0,
    scroll_received_x: f32 = 0,
    scroll_received_y: f32 = 0,
    scroll_consumed_x: f32 = 0,
    scroll_consumed_y: f32 = 0,
    scroll_precise: bool = false,
    scroll_phase: []const u8 = "none",
    motion: @import("motion.zig").Demo = .{},
    kit: @import("kit.zig").Demo = .{},
    glass: @import("glass.zig").Demo = .{},
    typography: @import("typography.zig").Demo = .{},
    studio: @import("studio.zig").Demo = .{},
    palette: @import("palette.zig").Palette = .{},
    windows: @import("windows.zig").Demo = .{},
    foundations: @import("foundations.zig").Demo = .{},
    components: @import("components.zig").State = .{},
    sidebar: sidebar.State = .{},
    /// The page the sidebar last revealed, so a jump to another (the
    /// palette's, a link's) opens the group holding it.
    revealed: ?usize = null,
    /// The app, so a page can make a window of its own: the Windows page does,
    /// because a borderless or translucent window is the only way to see what
    /// those options do.
    app: ?*PlatformApp = null,
    /// The gallery's own window, so the demo window can be placed beside it
    /// rather than over the controls that change it.
    window: ?*PlatformWindow = null,

    pub fn deinit(g: *Gallery) void {
        const gpa = std.heap.c_allocator;
        g.matches.deinit(gpa);
        g.matches_for.deinit(gpa);
        g.search.deinit();
        g.name.deinit();
        g.secret.deinit();
        g.notes.deinit();
        g.task.deinit();
        g.filter.deinit();
        g.palette.deinit();
        g.studio.deinit();
        g.foundations.deinit();
        g.components.deinit();
    }

    pub fn add(g: *Gallery, title: []const u8) void {
        if (g.count == g.items.len or title.len == 0) return;
        var it: Item = .{ .title = undefined, .len = @min(title.len, 64), .done = false };
        @memcpy(it.title[0..it.len], title[0..it.len]);
        g.items[g.count] = it;
        g.count += 1;
    }

    pub fn view(g: *Gallery, c: *ui.Context) void {
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
        g.palette.handleShortcuts(g, c);
        if (phone.compact(c)) {
            phone.view(g, c);
        } else {
            // The desktop shows the Kit demo as a page per component.
            if (g.page == catalog.kit_demo) g.page = catalog.first_component;
            if (g.revealed != g.page) {
                g.sidebar.reveal(g.page);
                g.revealed = g.page;
            }
            ui.row(c, .{ .width = .fill, .height = .fill });
            defer ui.end(c);
            sidebar.view(g, c);
            g.content(c);
        }
        g.palette.overlay(g, c);
    }

    /// The page shown, beside the sidebar or pushed on a phone.
    pub fn content(g: *Gallery, c: *ui.Context) void {
        // Beside the sidebar, a demo sits under the same fixed heading as the
        // reference pages.
        if (!phone.compact(c) and g.page < phone.pages.len) {
            page.beginDemo(c, phone.pages[g.page][0], c.print("{s}  ·  examples/gallery/{s}", .{ phone.blurbs[g.page], demo_files[g.page] }));
            defer page.end(c);
            return g.demo(c);
        }
        return g.demo(c);
    }

    fn demo(g: *Gallery, c: *ui.Context) void {
        if (g.page == 3) return g.bigList(c);
        if (g.page == 4) return g.glass.view(c);
        if (g.page == 5) return g.motion.page(c);
        if (g.page == 6) return g.kit.view(c, &g.appearance);
        if (g.page == 7) return g.studio.view(c, &g.appearance);
        if (g.page == 8) {
            if (comptime web) {
                ui.heading(c, "Windows");
                ui.text(c, "Native windows are unavailable in this canvas demo.", .{});
                return;
            }
            return g.windows.view(c, g.app, g.window);
        }
        if (g.page == catalog.colors) return g.foundations.colors(c);
        if (g.page == catalog.icons) return g.foundations.icons(c, if (phone.compact(c)) 0 else sidebar.width);
        if (catalog.component(g.page)) |comp| return @import("components.zig").view(&g.components, c, comp);
        ui.scroll(c, .{ .grow = 1, .width = .fill, .height = .fill, .padding = .all(if (phone.compact(c)) 24 else 28), .gap = 20 });
        defer ui.end(c);
        switch (g.page) {
            0 => g.controls(c),
            1 => g.tasks(c),
            2 => g.typography.view(c),
            else => g.bigList(c),
        }
    }

    fn controls(g: *Gallery, c: *ui.Context) void {
        page.demoTitle(c, "Controls");
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
                var choice: usize = @backingInt(g.appearance);
                if (ui.segmented(c, &.{ "Light", "Dark", "System" }, &choice)) {
                    g.appearance = @fromBackingInt(@intCast(choice));
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
        g.scrollDiagnostic(c);
        ui.card(c, .{ .width = .fill, .gap = 12 });
        {
            defer ui.end(c);
            ui.text(c, "Text field", .{ .weight = .semibold });
            ui.row(c, .{ .gap = 8, .align_items = .center });
            _ = ui.textField(c, &g.name, .{ .placeholder = "Your name" });
            ui.end(c);
            const name = g.name.text();
            ui.text(c, if (name.len == 0) "Type to be greeted." else c.print("Hello, {s}!", .{name}), .{ .color = c.theme.muted });
            {
                ui.row(c, .{ .gap = 8, .align_items = .center });
                defer ui.end(c);
                ui.text(c, "Password", .{ .color = c.theme.muted });
                _ = ui.textField(c, &g.secret, .{ .password = true, .width = .{ .px = 180 } });
            }
        }
        ui.card(c, .{ .width = .fill, .gap = 12 });
        {
            defer ui.end(c);
            ui.text(c, "Multiline text field", .{ .weight = .semibold });
            // Up to eight lines before it scrolls: a place to write a paragraph,
            // not a single line. Return breaks the line here rather than
            // submitting, which is what a notes field wants.
            _ = ui.textArea(c, &g.notes, .{
                .placeholder = "Write something. Return starts a new line.",
                .min_lines = 5,
                .max_lines = 10,
                .submit_on_return = false,
                .bare = false,
            });
            const notes = g.notes.text();
            var newlines: usize = 0;
            for (notes) |ch| if (ch == '\n') {
                newlines += 1;
            };
            ui.textf(c, .{ .color = c.theme.muted }, "{d} characters, {d} line{s}.", .{
                notes.len,
                newlines + 1,
                if (newlines == 0) "" else "s",
            });
        }
    }

    fn scrollDiagnostic(g: *Gallery, c: *ui.Context) void {
        const th = c.theme;
        ui.card(c, .{ .width = .fill, .gap = 10 });
        defer ui.end(c);
        ui.text(c, "Scroll input", .{ .weight = .semibold });
        ui.text(c, "Scroll here. Input is normalized; used is this pad's movement.", .{ .size = 12, .color = th.muted });
        const pad = ui.div(c).column().wFull().h(112).p(10).gap(5).rounded(8).clip().bg(th.background.alpha(0.7)).border(th.border).wheel();
        defer pad.end();
        if (pad.hovered()) {
            c.wants_wheel = true;
            const delta = c.input.scroll;
            if (delta.x != 0 or delta.y != 0) {
                const before_x = g.scroll_probe_x;
                const before_y = g.scroll_probe_y;
                g.scroll_probe_x = std.math.clamp(before_x - delta.x, 0, 180);
                g.scroll_probe_y = std.math.clamp(before_y - delta.y, 0, 180);
                g.scroll_received_x = delta.x;
                g.scroll_received_y = delta.y;
                g.scroll_consumed_x = g.scroll_probe_x - before_x;
                g.scroll_consumed_y = g.scroll_probe_y - before_y;
                g.scroll_precise = c.input.precise;
                g.scroll_phase = @tagName(c.input.scroll_phase);
            }
        }
        ui.textf(c, .{ .size = 11, .mono = true }, "Input x {d:.1} y {d:.1}", .{
            g.scroll_received_x,
            g.scroll_received_y,
        });
        ui.textf(c, .{ .size = 11, .mono = true }, "Mode {s} | phase {s}", .{
            if (g.scroll_precise) "precise" else "wheel",
            g.scroll_phase,
        });
        ui.textf(c, .{ .size = 11, .mono = true }, "Used x {d:.1} y {d:.1}", .{
            g.scroll_consumed_x,
            g.scroll_consumed_y,
        });
        ui.textf(c, .{ .size = 11, .mono = true }, "Position x {d:.0} y {d:.0} of 180", .{
            g.scroll_probe_x,
            g.scroll_probe_y,
        });
        ui.text(c, "Mouse wheel or two-finger trackpad.", .{ .size = 11, .color = th.muted });
    }

    fn tasks(g: *Gallery, c: *ui.Context) void {
        page.demoTitle(c, "Tasks");
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
        const pad: f32 = if (phone.compact(c)) 24 else 28;
        ui.column(c, .{ .grow = 1, .height = .fill, .padding = .{ .top = pad, .left = pad, .right = pad }, .gap = 12 });
        defer ui.end(c);
        page.demoTitle(c, "List");
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
};

var web_gallery: ?*Gallery = null;
export fn gallery_page(index: u32) void {
    if (comptime web) {
        if (web_gallery) |g| {
            g.page = @min(index, phone.pages.len - 1);
            if (nanoui.web.active) |surface| surface.requestFrame();
        }
    }
}

/// `gallery` opens the window; `gallery PAGE` opens it at a page (`colors`,
/// `icons`, a component such as `button`, or a demo such as `studio`);
/// `gallery --shot PAGE OUT.png [WIDTH [HEIGHT]]` draws that page offscreen
/// into a PNG at twice the size and quits, with no window.
pub fn main(init: std.process.Init) !void {
    var g: Gallery = .{};
    defer g.deinit();
    g.add("Write a UI toolkit in Zig");
    g.add("Draw it with Metal");
    g.add("Ship it");
    g.items[1].done = true;
    if (comptime web) {
        web_gallery = &g;
        _ = nanoui.web.registerBundledFonts();
        _ = try nanoui.web.mount(.init(&g, Gallery.view), .{ .width = 900, .height = 640 });
        nanoui.web.run();
    }
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "--shot")) {
        if (args.len < 4) return usage();
        g.page = catalog.find(args[2]) orelse return usage();
        const w = if (args.len > 4) try std.fmt.parseFloat(f32, args[4]) else 1040;
        const h = if (args.len > 5) try std.fmt.parseFloat(f32, args[5]) else 700;
        var t: ui.Tester = undefined;
        try t.init(init.gpa, .init(&g, Gallery.view), .{ .width = w, .height = h });
        defer t.deinit();
        t.settle(4);
        try t.screenshot(args[3]);
        return;
    }
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--nanoui-") or std.mem.startsWith(u8, arg, "-psn_")) continue;
        g.page = catalog.find(arg) orelse return usage();
        break;
    }
    const app = try nanoui.App.create(init, .{ .name = "Gallery" });
    defer app.destroy();
    g.app = app;
    const win = try app.newWindow(.{
        .title = "Gallery",
        .width = 1040,
        .height = 700,
        .min_width = 600,
        .min_height = 400,
        .title_bar = .hidden,
        .content = .{ .view = .init(&g, Gallery.view) },
    });
    g.window = win;
    try app.run();
}

fn usage() error{UnknownPage} {
    var buf: [32]u8 = undefined;
    std.debug.print("usage: gallery [PAGE] | gallery --shot PAGE OUT.png [WIDTH [HEIGHT]]\npages:", .{});
    for (0..catalog.page_count) |i| std.debug.print(" {s}", .{catalog.slug(&buf, i)});
    std.debug.print("\n", .{});
    return error.UnknownPage;
}
