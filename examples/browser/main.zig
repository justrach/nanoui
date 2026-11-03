//! A window with two pages: one served by the app (its own assets, typed IPC
//! and events), and one loaded from the web — Microsoft's WebView2 docs. The
//! page's own buttons ask the app to switch, which is the one thing a page
//! cannot do for itself: navigating the webview away from the document
//! destroys the bridge that made the call.
const std = @import("std");
const nanoui = @import("nanoui");

const remote_url = "https://learn.microsoft.com/en-us/microsoft-edge/webview2/";

const assets = [_]nanoui.Asset{
    .{ .path = "/index.html", .data = @embedFile("frontend/index.html") },
    .{ .path = "/main.js", .data = @embedFile("frontend/main.js") },
    // The page's stylesheet is inline in index.html: one asset fewer to keep.
};

const Todo = struct { title: []const u8, done: bool };

const Todos = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Todo) = .empty,

    pub fn list(self: *Todos) []const Todo {
        return self.items.items;
    }
};

/// Which page the window shows. Both are the app's to set: `window` is the
/// one the call came from.
const Browser = struct {
    window: *nanoui.Window,

    pub fn local(self: *Browser, _: *nanoui.Call) !void {
        self.window.setPageUrl("/");
    }

    pub fn remote(self: *Browser, _: *nanoui.Call) !void {
        self.window.setPageUrl(remote_url);
    }
};

const TickPayload = struct { uptime: u64 };
const Tick = nanoui.Event("tick", TickPayload);

var uptime: u64 = 0;

fn tick(ctx: ?*anyopaque) callconv(.c) void {
    const app: *nanoui.App = @ptrCast(@alignCast(ctx));
    uptime += 1;
    Tick.broadcast(app, .{ .uptime = uptime });
    nanoui.App.after(1000, app, tick);
}

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Browser" });
    defer app.destroy();

    var todos: Todos = .{ .gpa = init.gpa };
    defer todos.items.deinit(init.gpa);
    try todos.items.append(init.gpa, .{ .title = "A page served by Zig", .done = false });
    try todos.items.append(init.gpa, .{ .title = "A page served by Microsoft", .done = false });
    try todos.items.append(init.gpa, .{ .title = "The same window, one button apart", .done = false });

    var browser: Browser = undefined;
    try app.bind(&todos);
    try app.bind(&browser);
    try app.registerEvent(Tick);

    const window = try app.newWindow(.{
        .title = "Browser",
        .width = 900,
        .height = 700,
        .content = .{ .page = .{
            .url = "/",
            .assets = &assets,
            .pages = &.{
                .{ .title = "Local page", .url = "/" },
                .{ .title = "WebView2 docs", .url = remote_url },
            },
        } },
    });
    // The service needs the window it switches, which exists only now.
    browser = .{ .window = window };

    nanoui.App.after(1000, app, tick);
    try app.run();
}
