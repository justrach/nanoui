//! The Windows page of the gallery: options only Windows can show on a
//! second window (decorations, skip_taskbar, and live opacity).
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const phone = @import("phone.zig");

pub const Demo = struct {
    /// The window the Windows page made, if it is open: one at a time, and
    /// the opacity slider writes to it.
    demo_window: ?*nanoui.Window = null,
    /// The demo window's options, as the page's controls set them. A slider
    /// is `f32` and a window's opacity is `f64`, so this is the slider's
    /// type and the window reads it converted.
    demo_opacity: f32 = 0.85,
    demo_borderless: bool = true,
    demo_skip_taskbar: bool = true,

    const demo_w: f64 = 320;
    const demo_h: f64 = 180;

    /// The Windows page's whole body, in the same scrolling column the other
    /// pages use: the three cards stack, they do not sit side by side.
    pub fn view(d: *Demo, c: *ui.Context, app: ?*nanoui.App, host_window: ?*nanoui.Window) void {
        ui.scroll(c, .{ .grow = 1, .width = .fill, .height = .fill, .padding = .all(if (phone.compact(c)) 24 else 28), .gap = 20 });
        defer ui.end(c);
        d.pageCard(c, app, host_window);
        d.opacityCard(c);
        notesCard(c);
    }

    /// The window options only Windows can show: a borderless window, one that
    /// stays out of the taskbar, and one whose opacity a slider changes.
    ///
    /// The point of the page is that a person can see the result. Nothing about
    /// `decorations`, `skip_taskbar` or `opacity` is visible from the main
    /// window, so the page makes a second one and changes it live.
    fn pageCard(d: *Demo, c: *ui.Context, app: ?*nanoui.App, host_window: ?*nanoui.Window) void {
        const th = c.theme;
        ui.heading(c, "Windows");
        ui.text(c, "A second window, made with the options below.", .{ .color = th.muted });
        ui.card(c, .{ .width = .fill, .gap = 12 });
        defer ui.end(c);
        ui.text(c, "Window", .{ .weight = .semibold });
        ui.textf(c, .{ .size = 12, .color = th.muted }, "decorations = {s}   skip_taskbar = {s}   opacity = {d:.2}", .{
            if (d.demo_borderless) "false (borderless)" else "true",
            if (d.demo_skip_taskbar) "true" else "false",
            d.demo_opacity,
        });
        if (ui.button(c, if (d.demo_window == null) "Open" else "Close", .{ .variant = .primary }).clicked) d.toggle(c, app, host_window);
        if (d.demo_window != null) {
            if (ui.checkbox(c, "Borderless", &d.demo_borderless)) d.reopen(c, app, host_window);
            if (ui.checkbox(c, "Out of the taskbar", &d.demo_skip_taskbar)) d.reopen(c, app, host_window);
        }
    }

    /// The opacity slider is its own card, so it can come and go with the
    /// demo window without closing the one above it.
    fn opacityCard(d: *Demo, c: *ui.Context) void {
        if (d.demo_window == null) return;
        ui.card(c, .{ .width = .fill, .gap = 10 });
        defer ui.end(c);
        ui.text(c, "Opacity", .{ .weight = .semibold });
        if (ui.slider(c, &d.demo_opacity, .{ .min = 0.2, .max = 1, .width = .{ .px = 200 } })) d.applyOpacity();
        ui.textf(c, .{ .mono = true, .size = 12 }, "{d:.0}%", .{d.demo_opacity * 100});
    }

    /// What the three options become on Windows: the page says it, so the demo
    /// does not have to be read alongside the source to make sense.
    fn notesCard(c: *ui.Context) void {
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

    /// Makes the demo window with the current options, or remakes it: some
    /// of them (`WS_POPUP`, `WS_EX_LAYERED`) are fixed when a window is created
    /// and cannot be changed afterwards.
    fn toggle(d: *Demo, c: *ui.Context, app: ?*nanoui.App, host_window: ?*nanoui.Window) void {
        if (d.demo_window) |w| {
            w.close();
            d.demo_window = null;
        } else d.open(c, app, host_window);
    }

    fn open(d: *Demo, c: *ui.Context, maybe_app: ?*nanoui.App, host_window: ?*nanoui.Window) void {
        const app = maybe_app orelse return;
        // Beside the gallery, not over it. The point of the demo is to be
        // looked at while the page's controls change it, so it must not cover
        // them: it goes to the right of the window, and below it when there is
        // no room there.
        const at = placement(c, host_window);
        const opts = nanoui.WindowOptions{
            .title = "Borderless demo",
            .width = demo_w,
            .height = demo_h,
            .x = at[0],
            .y = at[1],
            .decorations = !d.demo_borderless,
            .skip_taskbar = d.demo_skip_taskbar,
            .opacity = d.demo_opacity,
            .title_bar = .hidden,
            // Above other windows so it stays visible while the gallery has
            // the keyboard: changing a slider must not hide what changes.
            .always_on_top = true,
            .content = .{ .view = .init(d, Demo.demoView) },
        };
        d.demo_window = app.newWindow(opts) catch null;
        c.changed = true;
    }

    /// Where the demo window goes: to the right of the gallery when there is
    /// room, else to its left, else below it. The gallery's own frame
    /// decides, so a window the user moved gets the demo beside it.
    fn placement(c: *ui.Context, host_window: ?*nanoui.Window) [2]f64 {
        const gap: f64 = 12;
        const win = host_window orelse return .{ c.size.w + gap, 80 };
        const f = win.frame();
        const m = win.monitorSize();
        const right = f.x + f.width + gap;
        if (right + demo_w <= m[0]) return .{ right, f.y };
        const left = f.x - demo_w - gap;
        if (left >= 0) return .{ left, f.y };
        return .{ f.x, f.y + f.height + gap };
    }

    fn reopen(d: *Demo, c: *ui.Context, app: ?*nanoui.App, host_window: ?*nanoui.Window) void {
        if (d.demo_window) |w| {
            w.close();
            d.demo_window = null;
        }
        d.open(c, app, host_window);
    }

    fn applyOpacity(d: *Demo) void {
        if (d.demo_window) |w| {
            w.setOpacity(d.demo_opacity);
            // The demo window shows the number, so it is built again too.
            if (w.surface) |s| s.requestFrame();
        }
    }

    /// The demo window's own content: it says what it is.
    ///
    /// A borderless window cannot be moved by its title bar, so the header is
    /// a `window_drag` handle — only when borderless, because a decorated
    /// window already moves by its own title bar and would be moved twice.
    fn demoView(d: *Demo, c: *ui.Context) void {
        if (!d.demo_borderless) c.title_bar_height = 38;
        ui.column(c, .{ .padding = .all(16), .gap = 10, .width = .fill, .height = .fill });
        defer ui.end(c);
        const drag = ui.div(c).row().wFull().itemsCenter().h(24);
        defer drag.end();
        _ = c.leaf(.{ .grow = 1, .window_drag = d.demo_borderless }, .{ .text = .{
            .str = if (d.demo_borderless) "Drag here to move" else "",
            .style = .{ .size = 11 },
            .color = c.theme.muted,
        } }, null);

        ui.text(c, "This window", .{ .size = 18, .weight = .bold });
        ui.text(c, if (d.demo_borderless) "borderless: no title bar, no frame." else "decorated: drag the title bar.", .{});
        ui.text(c, if (d.demo_skip_taskbar) "Out of the taskbar and Alt-Tab." else "In the taskbar and Alt-Tab.", .{});
        ui.textf(c, .{ .color = c.theme.muted }, "opacity {d:.0}%", .{d.demo_opacity * 100});
    }
};
