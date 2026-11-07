//! nanobrowser: a web browser on nanoui, with its own engine (no WebKit) in
//! the look of browse. Give it an address to open:
//!
//!     nanobrowser https://en.wikipedia.org/wiki/Bird
//!     nanobrowser --nanoui-snapshot=/tmp/bird.png --nanoui-wait=8 https://en.wikipedia.org/wiki/Bird
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("shell/browser.zig").Browser;
const address = @import("shell/address.zig");
const theme = @import("shell/theme.zig");
const web = @import("web/web.zig");

pub fn main(init: std.process.Init) !void {
    web.setLogging(init.environ_map.get("NANOBROWSER_LOG") != null);
    const app = try nanoui.App.create(init, .{ .name = "nanobrowser" });
    defer app.destroy();
    var browser: Browser = .{ .gpa = app.gpa };
    defer browser.deinit();
    try browser.init();
    try browser.connect();
    if (builtin.os.tag == .macos) try @import("shell/menu_bar.zig").install(app, &browser);

    const window = try app.newWindow(.{
        .title = "nanobrowser",
        .width = 1280,
        .height = 860,
        .min_width = 480,
        .min_height = 320,
        .title_bar = .hidden,
        .traffic_lights = .{ .x = 26, .y = theme.metrics.lights_center },
        .content = .{ .view = .init(&browser, Browser.view) },
    });
    browser.window = window;

    for (try init.minimal.args.toSlice(init.arena.allocator()), 0..) |arg, i| {
        if (i == 0 or std.mem.startsWith(u8, arg, "--")) continue;
        const url = (try address.parse(app.gpa, arg)) orelse continue;
        defer app.gpa.free(url);
        browser.tabs.items[browser.current].go(url);
        break;
    }
    try app.run();
    if (init.environ_map.get("NANOBROWSER_EVAL")) |source| {
        if (browser.tabs.items[browser.current].page) |page| @import("dump.zig").eval(page, source);
    }
    if (init.environ_map.get("NANOBROWSER_DUMP")) |file| {
        if (browser.tabs.items[browser.current].page) |page| try @import("dump.zig").write(app.gpa, page, file);
    }
}
