//! The GTK window's own tests: what `Options` asks of GTK, read back from
//! the GtkWindow. They need a display (CI runs them under Xvfb) and skip
//! without one. Drawn on the CPU, so no GL context is needed either.

const std = @import("std");
const testing = std.testing;
const ui = @import("../ui/ui.zig");
const gtk = @import("gtk.zig");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;

const Page = struct {
    fn view(_: *Page, c: *ui.Context) void {
        ui.text(c, "window", .{});
    }
};

/// An app with GTK up, or a skip where there is no GTK or no display.
fn makeApp(gpa: std.mem.Allocator) !*App {
    if (!gtk.load()) return error.SkipZigTest;
    const ok = if (gtk.v4) gtk.v4api.gtk_init_check() else gtk.v3.gtk_init_check(null, null);
    if (ok == 0) return error.SkipZigTest;
    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .io = testing.io,
        .options = .{ .quit_on_last_window_closed = false },
        .flags = .{ .hidden = true },
        .gui = true,
        .cpu_only = true,
    };
    return app;
}

test "decorations, skip_taskbar and opacity reach the GtkWindow" {
    const app = try makeApp(testing.allocator);
    defer app.destroy();
    var p: Page = .{};
    const plain = try app.newWindow(.{ .title = "plain", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&p, Page.view) } });
    const bare = try app.newWindow(.{ .title = "bare", .width = 200, .height = 120, .visible = false, .decorations = false, .skip_taskbar = true, .opacity = 0.5, .content = .{ .view = .init(&p, Page.view) } });
    const g = &gtk.api;

    try testing.expect(g.gtk_window_get_decorated(plain.gtkwindow.?) != 0);
    try testing.expect(g.gtk_window_get_decorated(bare.gtkwindow.?) == 0);
    // GTK keeps opacity in 8 bits.
    try testing.expectApproxEqAbs(@as(f64, 0.5), g.gtk_widget_get_opacity(bare.gtkwindow.?), 0.01);
    bare.setOpacity(0.25);
    try testing.expectApproxEqAbs(@as(f64, 0.25), g.gtk_widget_get_opacity(bare.gtkwindow.?), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 1), g.gtk_widget_get_opacity(plain.gtkwindow.?), 0.01);
    // GTK 4 has no taskbar hint to read; GTK 3 does.
    if (!gtk.v4) {
        try testing.expect(gtk.v3.gtk_window_get_skip_taskbar_hint(bare.gtkwindow.?) != 0);
        try testing.expect(gtk.v3.gtk_window_get_skip_taskbar_hint(plain.gtkwindow.?) == 0);
    }
    const m = bare.monitorSize();
    try testing.expect(m[0] > 0 and m[1] > 0);
}

const Themed = struct {
    chosen: ?ui.Theme = null,
    seen: ?ui.Theme = null,
    fn view(self: *Themed, c: *ui.Context) void {
        c.theme_chosen = self.chosen;
        self.seen = c.theme;
        ui.text(c, "themed", .{});
    }
};

test "the view's theme choice draws that theme" {
    const app = try makeApp(testing.allocator);
    defer app.destroy();
    var p: Themed = .{ .chosen = ui.Theme.dark_theme };
    const w = try app.newWindow(.{ .title = "themed", .width = 200, .height = 120, .visible = false, .content = .{ .view = .init(&p, Themed.view) } });
    const s = w.surface.?;
    // A hidden GtkWindow is never allocated: give the frame a size.
    s.size = .{ .w = 200, .h = 120 };
    s.frame();
    try testing.expect(p.seen.?.dark);

    p.chosen = ui.Theme.light;
    s.frame();
    try testing.expect(!p.seen.?.dark);

    p.chosen = null;
    s.frame();
    try testing.expect(p.seen != null);
}

fn emit(obj: *anyopaque, signal: [*:0]const u8, args: anytype) void {
    const emit_signal: *const fn (*anyopaque, [*:0]const u8, ...) callconv(.c) void =
        @ptrCast(@alignCast(std.c.dlsym(null, "g_signal_emit_by_name").?));
    @call(.auto, emit_signal, .{ obj, signal } ++ args);
}

test "IME candidate rectangle follows layout in logical client coordinates" {
    var ts = @import("../ui/text.zig").TextSystem.init(testing.allocator);
    defer ts.deinit();
    var c = ui.Context.init(testing.allocator, &ts);
    defer c.deinit();
    c.scale = 2;
    const field: @import("../ui/input.zig").FocusedText = .{
        .id = 1,
        .text = "",
        .caret = 0,
        .anchor = 0,
        .marked = null,
        .caret_rect = .{ .x = 12.75, .y = 22.5, .w = 0.25, .h = 10.75 },
    };
    try c.prev_rects.put(c.gpa, field.id, .{ .x = 10, .y = 20, .h = 20 });
    try c.rects.put(c.gpa, field.id, .{ .x = 14, .y = 14, .h = 30 });
    const candidateRect = @import("ime.zig").candidateRect;
    // A single line follows the field's vertical center in its parent's window.
    try testing.expectEqual(gtk.Rectangle{ .x = 13, .y = 30, .width = 1, .height = 11 }, candidateRect(&c, field, .{ .x = -3, .y = 9 }));
    // A multiline caret follows the top edge. Widget coordinates have zero offset.
    c.focused_multiline = true;
    try testing.expectEqual(gtk.Rectangle{ .x = 16, .y = 16, .width = 1, .height = 11 }, candidateRect(&c, field, .{}));
}

test "GTK receives the focused field's caret in logical coordinates" {
    const Field = struct {
        buf: ui.TextBuffer = .{},
        padding: f32 = 20,
        fn view(self: *@This(), c: *ui.Context) void {
            ui.column(c, .{ .padding = .all(self.padding) });
            defer ui.end(c);
            _ = ui.textField(c, &self.buf, .{ .multiline = true });
        }
    };
    const Capture = struct {
        var rect: ?gtk.Rectangle = null;
        fn set(_: *anyopaque, r: *const gtk.Rectangle) callconv(.c) void {
            rect = r.*;
        }
    };
    const app = try makeApp(testing.allocator);
    defer app.destroy();
    var field: Field = .{};
    defer field.buf.deinit();
    field.buf.set("one\ntwo");
    const w = try app.newWindow(.{ .visible = false, .content = .{ .view = .init(&field, Field.view) } });
    const s = w.surface.?;
    s.size = .{ .w = 360, .h = 200 };
    s.scale = 2;
    const set = gtk.api.gtk_im_context_set_cursor_location;
    defer gtk.api.gtk_im_context_set_cursor_location = set;
    gtk.api.gtk_im_context_set_cursor_location = Capture.set;
    Capture.rect = null;
    s.frame();
    try testing.expect(Capture.rect == null);

    field.buf.focus();
    s.frame();
    const end = Capture.rect orelse return error.MissingImeLocation;
    field.buf.want_caret = 0;
    s.frame();
    const start = Capture.rect.?;
    const caret = s.ctx.focused_text.?.caret_rect;
    try testing.expect(start.x >= 20 and start.y >= 20);
    try testing.expect(start.x < end.x and start.y < end.y);
    try testing.expectEqual(@as(c_int, @intFromFloat(@floor(caret.x))), start.x);
    try testing.expectEqual(@as(c_int, @intFromFloat(@floor(caret.y))), start.y);
    try testing.expectEqual(@as(c_int, @intFromFloat(@round(caret.h))), start.height);
    try testing.expect(start.width >= 1);

    field.padding += 40;
    s.frame();
    try testing.expectEqual(start.x + 40, Capture.rect.?.x);
    try testing.expectEqual(start.y + 40, Capture.rect.?.y);
}

test "GTK input method commits text outside a key event" {
    const Field = struct {
        fn view(buf: *ui.TextBuffer, c: *ui.Context) void {
            _ = ui.textField(c, buf, .{ .bare = true });
        }
    };
    var buf: ui.TextBuffer = .{};
    defer buf.deinit();
    const app = try makeApp(testing.allocator);
    defer app.destroy();
    const w = try app.newWindow(.{ .visible = false, .content = .{ .view = .init(&buf, Field.view) } });
    const s = w.surface.?;
    s.size = .{ .w = 320, .h = 100 };
    buf.focus();
    s.frame();

    const text: [*:0]const u8 = "你好";
    emit(s.im, "commit", .{text});
    try testing.expectEqualStrings("你好", buf.text());
    s.frame();
    try testing.expectEqualStrings("你好", buf.text());
}

test "GTK updates the preedit cursor, cancels and commits marked text" {
    const Fields = struct {
        a: ui.TextBuffer = .{},
        b: ui.TextBuffer = .{},
        fn view(self: *@This(), c: *ui.Context) void {
            _ = ui.textField(c, &self.a, .{});
            _ = ui.textArea(c, &self.b, .{});
        }
    };
    const PreeditStub = struct {
        var text: [*:0]const u8 = "";
        var cursor_pos: c_int = 1;
        fn get(_: *anyopaque, str: *?[*:0]u8, _: ?*anyopaque, cursor_chars: *c_int) callconv(.c) void {
            const dup: *const fn ([*:0]const u8) callconv(.c) ?[*:0]u8 = @ptrCast(@alignCast(std.c.dlsym(null, "g_strdup").?));
            str.* = dup(text);
            cursor_chars.* = cursor_pos;
        }
        fn change(im: *anyopaque, value: [*:0]const u8) void {
            text = value;
            emit(im, "preedit-changed", .{});
        }
    };
    const app = try makeApp(testing.allocator);
    defer app.destroy();
    var fields: Fields = .{};
    defer fields.a.deinit();
    defer fields.b.deinit();
    fields.a.set("aXz");
    const w = try app.newWindow(.{ .visible = false, .content = .{ .view = .init(&fields, Fields.view) } });
    const s = w.surface.?;
    s.size = .{ .w = 320, .h = 160 };
    fields.a.focus();
    fields.a.want_selection = .{ 1, 2 };
    s.frame();
    const get = gtk.api.gtk_im_context_get_preedit_string;
    var text: ?[*:0]u8 = null;
    var cursor_chars: c_int = -1;
    get(s.im, &text, null, &cursor_chars);
    defer gtk.api.g_free(text);
    try testing.expectEqualStrings("", std.mem.span(text.?));
    try testing.expectEqual(@as(c_int, 0), cursor_chars);
    defer gtk.api.gtk_im_context_get_preedit_string = get;
    gtk.api.gtk_im_context_get_preedit_string = PreeditStub.get;

    PreeditStub.change(s.im, "你hao");
    try testing.expectEqualStrings("a你haoz", s.ctx.focused_text.?.text);
    try testing.expectEqual(@as(usize, 1 + "你".len), s.ctx.focused_text.?.caret);
    try testing.expectEqualStrings("a你haoz", fields.a.text());
    // GTK counts characters, even when only the cursor changes.
    PreeditStub.cursor_pos = 0;
    defer PreeditStub.cursor_pos = 1;
    PreeditStub.change(s.im, "你hao");
    try testing.expectEqualStrings("a你haoz", fields.a.text());
    try testing.expectEqual(@as(usize, 1), s.ctx.focused_text.?.caret);
    PreeditStub.change(s.im, "");
    try testing.expectEqualStrings("az", s.ctx.focused_text.?.text);
    try testing.expectEqualStrings("az", fields.a.text());
    try testing.expectEqual(@as(usize, 1), s.ctx.focused_text.?.anchor);
    try testing.expectEqual(@as(usize, 1), s.ctx.focused_text.?.caret);

    // If the IM leaves Escape to the widget, cancel only the marked range.
    PreeditStub.change(s.im, "ni hao");
    try testing.expect(@import("surface.zig").keyPress(s, 0xff1b, 0, null));
    try testing.expectEqualStrings("az", fields.a.text());
    try testing.expectEqual(fields.a.last_id, s.ctx.focus);
    try testing.expect(s.ctx.focused_text.?.marked == null);

    // Moving the caret within A ends its candidate just as switching to B does.
    {
        const Focus = struct {
            var leaves: usize = 0;
            fn leave(_: *anyopaque) callconv(.c) void {
                leaves += 1;
            }
        };
        PreeditStub.change(s.im, "ni");
        const active = s.ctx.input.window_active;
        defer s.ctx.input.window_active = active;
        s.ctx.input.window_active = true;
        const leave = gtk.api.gtk_im_context_focus_out;
        defer gtk.api.gtk_im_context_focus_out = leave;
        gtk.api.gtk_im_context_focus_out = Focus.leave;
        Focus.leaves = 0;
        const rect = s.ctx.rects.get(fields.a.last_id).?;
        s.ctx.input.mouse = .{ .x = rect.x + 1, .y = rect.y + rect.h / 2 };
        s.ctx.pointerDown();
        s.frame();
        s.ctx.pointerUp();
        s.frame();
        try testing.expectEqual(fields.a.last_id, s.ctx.focus);
        try testing.expect(s.ctx.focused_text.?.marked == null);
        try testing.expectEqualStrings("aniz", fields.a.text());
        try testing.expectEqual(@as(usize, 1), Focus.leaves);
    }

    fields.a.set("az");
    fields.a.want_caret = 1;
    s.frame();
    PreeditStub.change(s.im, "ni");
    fields.b.focus();
    s.frame();
    try testing.expect(s.ctx.focused_text.?.marked == null);
    try testing.expectEqualStrings("", s.ctx.focused_text.?.text);
    try testing.expectEqualStrings("aniz", fields.a.text());
    PreeditStub.change(s.im, "ni");
    try testing.expectEqualStrings("ni", s.ctx.focused_text.?.text);
    emit(s.im, "commit", .{@as([*:0]const u8, "你")});
    try testing.expectEqualStrings("你", fields.b.text());
    try testing.expect(s.ctx.focused_text.?.marked == null);
    PreeditStub.change(s.im, "");
    try testing.expectEqualStrings("你", fields.b.text());

    // A nested GTK loop can clear the preedit and send its result before the next frame.
    PreeditStub.change(s.im, "hao");
    s.in_frame = true;
    PreeditStub.change(s.im, "");
    emit(s.im, "commit", .{@as([*:0]const u8, "好")});
    s.in_frame = false;
    s.frame();
    try testing.expectEqualStrings("你好", fields.b.text());

    // A native focus-out can itself emit a final commit. Keep the draft once.
    const CommitOnFocusOut = struct {
        fn focusOut(im: *anyopaque) callconv(.c) void {
            emit(im, "commit", .{@as([*:0]const u8, "ni")});
        }
    };
    PreeditStub.change(s.im, "ni");
    const focus_out = gtk.api.gtk_im_context_focus_out;
    defer gtk.api.gtk_im_context_focus_out = focus_out;
    gtk.api.gtk_im_context_focus_out = CommitOnFocusOut.focusOut;
    @import("ime.zig").focusOut(s);
    s.frame();
    try testing.expectEqualStrings("你好ni", fields.b.text());
    try testing.expect(s.ctx.focused_text.?.marked == null);
}

test "should_close keeps window up until allowed and destroyNow tears down" {
    const app = try makeApp(testing.allocator);
    defer app.destroy();
    const Gate = struct {
        allow: bool = false,
        asked: u32 = 0,
        closed: u32 = 0,
        fn should(ctx: *anyopaque, _: *Window) bool {
            const g: *@This() = @ptrCast(@alignCast(ctx));
            g.asked += 1;
            return g.allow;
        }
        fn onClose(ctx: *anyopaque, _: *Window) void {
            const g: *@This() = @ptrCast(@alignCast(ctx));
            g.closed += 1;
        }
        fn view(_: *@This(), c: *ui.Context) void {
            ui.text(c, "veto", .{});
        }
    };
    var g: Gate = .{};
    const w = try app.newWindow(.{
        .title = "veto",
        .width = 160,
        .height = 100,
        .visible = false,
        .should_close = .{ .ctx = &g, .func = Gate.should },
        .on_close = .{ .ctx = &g, .func = Gate.onClose },
        .content = .{ .view = .init(&g, Gate.view) },
    });
    w.close();
    try testing.expectEqual(@as(u32, 1), g.asked);
    try testing.expectEqual(@as(u32, 0), g.closed);
    try testing.expectEqual(@as(usize, 1), app.windows.items.len);
    // Final teardown via app.destroy uses destroyNow and bypasses the close veto.
    const w2 = try app.newWindow(.{
        .title = "veto-teardown",
        .width = 160,
        .height = 100,
        .visible = false,
        .should_close = .{ .ctx = &g, .func = Gate.should },
        .on_close = .{ .ctx = &g, .func = Gate.onClose },
        .content = .{ .view = .init(&g, Gate.view) },
    });
    g.allow = true;
    w.close();
    try testing.expectEqual(@as(u32, 2), g.asked);
    try testing.expectEqual(@as(u32, 1), g.closed);
    try testing.expectEqual(@as(usize, 1), app.windows.items.len);
    g.allow = false;
    _ = w2;
}

test "should_terminate keeps app running until allowed" {
    const app = try makeApp(testing.allocator);
    defer app.destroy();
    const Gate = struct {
        allow: bool = false,
        asked: u32 = 0,
        fn should(ctx: ?*anyopaque) bool {
            const g: *@This() = @ptrCast(@alignCast(ctx.?));
            g.asked += 1;
            return g.allow;
        }
    };
    var g: Gate = .{};
    app.options.ctx = &g;
    app.options.should_terminate = Gate.should;
    app.quit();
    try testing.expectEqual(@as(u32, 1), g.asked);
    try testing.expect(!app.stopping);
    g.allow = true;
    app.quit();
    try testing.expectEqual(@as(u32, 2), g.asked);
    try testing.expect(app.stopping);
    app.quit();
    try testing.expectEqual(@as(u32, 2), g.asked);
}

test "file choosers are modal for their owner and cancel when it closes" {
    // A native chooser opens a window of its own. Only run under Xvfb.
    if (std.c.getenv("NANOUI_TEST_NATIVE_FILE_CHOOSER") == null) return error.SkipZigTest;
    const dialog = @import("dialog.zig");
    const app = try makeApp(testing.allocator);
    defer app.destroy();
    var page: Page = .{};
    const other = try app.newWindow(.{ .title = "Other", .visible = false, .content = .{ .view = .init(&page, Page.view) } });
    const Probe = struct {
        owner: *Window,
        close_source: ?c_uint = null,
        deadline_source: ?c_uint = null,
        modal_to_owner: bool = false,
        refused_second: bool = false,

        fn start(probe: *@This()) void {
            probe.close_source = gtk.api.g_timeout_add(50, close, probe);
            probe.deadline_source = gtk.api.g_timeout_add(5000, deadline, null);
        }

        fn stop(probe: *@This()) void {
            if (probe.close_source) |id| _ = gtk.api.g_source_remove(id);
            if (probe.deadline_source) |id| _ = gtk.api.g_source_remove(id);
        }

        fn deadline(_: ?*anyopaque) callconv(.c) c_int {
            @panic("file chooser did not settle after its owner closed");
        }

        fn close(ctx: ?*anyopaque) callconv(.c) c_int {
            const probe: *@This() = @ptrCast(@alignCast(ctx));
            probe.close_source = null;
            if (probe.owner.file_chooser) |wait| {
                const native = wait.chooser;
                probe.modal_to_owner = gtk.api.gtk_native_dialog_get_modal(native) != 0 and
                    gtk.api.gtk_native_dialog_get_transient_for(native) == probe.owner.gtkwindow;
                _ = dialog.saveForWindow(testing.allocator, probe.owner, .{}) catch |err| {
                    probe.refused_second = err == error.ChooserBusy;
                };
            }
            probe.owner.close();
            return 0;
        }
    };

    {
        const opener = try app.newWindow(.{ .title = "Open owner", .visible = false, .content = .{ .view = .init(&page, Page.view) } });
        var opening: Probe = .{ .owner = opener };
        opening.start();
        defer opening.stop();
        try testing.expectEqual(null, try dialog.openForWindow(testing.allocator, opener, .{}));
        try testing.expect(opening.modal_to_owner and opening.refused_second);
    }
    {
        const saver = try app.newWindow(.{ .title = "Save owner", .visible = false, .content = .{ .view = .init(&page, Page.view) } });
        var saving: Probe = .{ .owner = saver };
        saving.start();
        defer saving.stop();
        try testing.expectEqual(null, try dialog.saveForWindow(testing.allocator, saver, .{}));
        try testing.expect(saving.modal_to_owner and saving.refused_second);
    }
    try testing.expect(!other.closed);
}
