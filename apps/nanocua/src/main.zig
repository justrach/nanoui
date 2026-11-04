//! nanocua: lets AI agents see and use the computer, as far as its user
//! allows. `nanocua` is the app: the control panel, and the server agents
//! reach over a Unix socket. `nanocua mcp` is what an agent runs: an MCP
//! server on stdio that carries its lines to the app. `nanocua ctl` is what
//! graff and Harness run to show and change the switches.
const std = @import("std");
const nanoui = @import("nanoui");
const app_mod = @import("app.zig");
const theme = @import("theme.zig");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "mcp"))
        return if (comptime @import("server.zig").supported) @import("proxy.zig").run(init) else 1;

    if (args.len > 1 and std.mem.eql(u8, args[1], "ctl"))
        return if (comptime @import("server.zig").supported) @import("ctl.zig").run(init, args[2..]) else 1;
    for (args) |arg| if (@import("control.zig").devFlagRefused(builtin.mode, arg)) {
        std.debug.print("nanocua: {s} is only for debug builds\n", .{arg});
        return 2;
    };

    const app = try nanoui.App.create(init, .{ .name = "nanocua" });
    defer app.destroy();
    var plat: app_mod.Platform = .init(init.gpa);
    var a: app_mod.App = undefined;
    a.init(init.gpa, undefined);
    plat.attach(&a);
    defer a.deinit();
    var path_buf: [512]u8 = undefined;
    if (@import("sockpath.zig").path(&path_buf, init.environ_map, @import("sockpath.zig").realHome())) |path| a.listen(path) else |_| {
        a.listen_error = "No folder for the socket (HOME is unset).";
    }
    var exe_buf: [1024]u8 = undefined;
    if (std.process.executablePath(init.io, &exe_buf)) |n| a.setCommand(exe_buf[0..n]) else |_| {}
    a.stopKey();
    if (comptime app_mod.mac) {
        @import("mac/pointer.zig").watch();
        a.hidden = app.flags.hidden;
    }
    a.window = try app.newWindow(.{
        .title = "nanocua",
        .width = 560,
        .height = 720,
        .min_width = 460,
        .min_height = 520,
        .theme = theme.ui(nanoui.isDark()),
        .content = .{ .view = .init(&a, @import("view.zig").view) },
    });
    try app.run();
    return 0;
}
