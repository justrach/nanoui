//! Command line flags for trying and testing apps without touching the
//! screen, the mouse or the keyboard:
//!
//!   --nanoui-generate=DIR    write the generated client (nanoui.js, nanoui.d.ts) and exit
//!   --nanoui-snapshot=PNG    render the first native UI window offscreen to PNG and exit
//!   --nanoui-script=STEPS    with --nanoui-snapshot: steps run first (see ui.Tester.runScript)
//!   --nanoui-dark            with --nanoui-snapshot: the dark appearance
//!   --nanoui-wait=SECONDS    with --nanoui-snapshot: run the event loop that long first,
//!                            drawing the view as it goes, so processes, timers, replies and
//!                            what the view asks for as it draws arrive
//!   --nanoui-hidden          never show windows
//!   --nanoui-play=STEPS      play steps in the first window as it runs, for recordings
//!                            (macOS, iOS; see play.zig)
//!   --nanoui-eval=JS         evaluate JS in each page once its DOM is ready (implies hidden);
//!                            pages report with nanoui.log() and finish with nanoui.window.close()
const std = @import("std");
const ui = @import("ui/ui.zig");
const runFor = @import("platform.zig").runFor;

pub const Flags = struct {
    generate_dir: ?[]const u8 = null,
    snapshot: ?[]const u8 = null,
    script: []const u8 = "",
    dark: bool = false,
    hidden: bool = false,
    eval: ?[]const u8 = null,
    play: ?[]const u8 = null,
    wait: f64 = 0,

    pub fn parse(init: std.process.Init) !Flags {
        const arena = init.arena.allocator();
        var f: Flags = .{};
        // Windows decodes its command line: that needs memory.
        for (try init.minimal.args.toSlice(arena)) |arg| {
            if (value(arg, "--nanoui-generate=")) |v| f.generate_dir = try arena.dupe(u8, v);
            if (value(arg, "--nanoui-snapshot=")) |v| f.snapshot = try arena.dupe(u8, v);
            if (value(arg, "--nanoui-script=")) |v| f.script = try arena.dupe(u8, v);
            if (value(arg, "--nanoui-eval=")) |v| f.eval = try arena.dupe(u8, v);
            if (value(arg, "--nanoui-play=")) |v| f.play = try arena.dupe(u8, v);
            if (value(arg, "--nanoui-wait=")) |v| f.wait = std.fmt.parseFloat(f64, v) catch 0;
            if (std.mem.eql(u8, arg, "--nanoui-dark")) f.dark = true;
            if (std.mem.eql(u8, arg, "--nanoui-hidden")) f.hidden = true;
        }
        if (f.snapshot != null or f.eval != null or f.generate_dir != null) f.hidden = true;
        return f;
    }

    fn value(arg: []const u8, comptime flag: []const u8) ?[]const u8 {
        return if (std.mem.startsWith(u8, arg, flag)) arg[flag.len..] else null;
    }
};

/// Renders the first window of native UI offscreen, after the script.
pub fn snapshot(app: anytype, path: []const u8) !void {
    for (app.windows.items) |w| {
        const s = w.nativeView() orelse continue;
        // The Tester draws the view from here. The hidden window's own frames would
        // draw it too, with a context of their own: a view that keeps state per window
        // (which field has the keys) would have two contexts undoing each other.
        const quiet = struct {
            var nothing: u8 = 0;
            fn view(_: *u8, _: *ui.Context) void {}
        };
        // Headless on Linux and Windows there is no surface, and nothing to quiet.
        if (w.surface) |surface| surface.view = ui.View.init(&quiet.nothing, quiet.view);
        var t: ui.Tester = undefined;
        try t.init(app.gpa, s.view, .{ .width = s.width, .height = s.height, .scale = s.scale, .dark = app.flags.dark, .theme = s.theme });
        defer t.deinit();
        // Live state first: the event loop runs (replies, timers) without a
        // visible window, and the view is drawn as it goes, so what it asks
        // for as it draws (a picture, a map's tiles) is asked for and answered.
        var waited: f64 = 0;
        const dt = t.dt;
        // Its clock goes as the event loop's does: what animates arrives on time.
        t.dt = 0.05;
        while (waited < app.flags.wait) : (waited += 0.05) {
            runFor(0.05);
            t.frame();
        }
        t.dt = dt;
        t.settle(2);
        try t.runScript(app.flags.script);
        try t.screenshot(path);
        std.debug.print("nanoui: wrote {s} ({d}x{d} points at {d}x)\n", .{ path, t.size.w, t.size.h, t.scale });
        return;
    }
    return error.NoNativeWindow;
}
