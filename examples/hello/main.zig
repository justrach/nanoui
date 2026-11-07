//! A window showing a web page whose frontend calls Zig: bound services,
//! typed events, and the generated client served at /nanoui.js.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");

const Greeter = struct {
    pub const nanoui_params = .{ .greet = .{"name"} };

    /// Returns a greeting.
    pub fn greet(_: *Greeter, call: *nanoui.Call, name: []const u8) ![]const u8 {
        const who = std.mem.trim(u8, name, " ");
        return std.fmt.allocPrint(call.arena, "Hello, {s}! (from Zig {s})", .{ if (who.len == 0) "stranger" else who, builtin.zig_version_string });
    }
};

const Todo = struct {
    id: u32,
    title: []const u8,
    done: bool,
};

const Todos = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Todo) = .empty,
    next_id: u32 = 1,

    pub const nanoui_params = .{ .add = .{"title"}, .toggle = .{"id"}, .remove = .{"id"} };

    pub fn list(self: *Todos) []const Todo {
        return self.items.items;
    }

    pub fn add(self: *Todos, title: []const u8) !Todo {
        const t = std.mem.trim(u8, title, " ");
        if (t.len == 0) return error.EmptyTitle;
        const todo: Todo = .{ .id = self.next_id, .title = try self.gpa.dupe(u8, t), .done = false };
        try self.items.append(self.gpa, todo);
        self.next_id += 1;
        return todo;
    }

    pub fn toggle(self: *Todos, id: u32) !Todo {
        for (self.items.items) |*t| if (t.id == id) {
            t.done = !t.done;
            return t.*;
        };
        return error.NoSuchTodo;
    }

    pub fn remove(self: *Todos, id: u32) !void {
        for (self.items.items, 0..) |t, i| if (t.id == id) {
            self.gpa.free(t.title);
            _ = self.items.orderedRemove(i);
            return;
        };
        return error.NoSuchTodo;
    }

    fn deinit(self: *Todos) void {
        for (self.items.items) |t| self.gpa.free(t.title);
        self.items.deinit(self.gpa);
    }
};

const TickPayload = struct { uptime: u64, todos: usize };
const Tick = nanoui.Event("tick", TickPayload);

var uptime: u64 = 0;
var todos_ptr: *Todos = undefined;

fn tick(ctx: ?*anyopaque) callconv(.c) void {
    const app: *nanoui.App = @ptrCast(@alignCast(ctx));
    uptime += 1;
    Tick.broadcast(app, .{ .uptime = uptime, .todos = todos_ptr.items.items.len });
    nanoui.App.after(1000, app, tick);
}

const assets = [_]nanoui.Asset{
    .{ .path = "/index.html", .data = @embedFile("frontend/index.html") },
    .{ .path = "/main.js", .data = @embedFile("frontend/main.js") },
    .{ .path = "/style.css", .data = @embedFile("frontend/style.css") },
};

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Hello" });
    defer app.destroy();

    var greeter: Greeter = .{};
    var todos: Todos = .{ .gpa = init.gpa };
    defer todos.deinit();
    todos_ptr = &todos;
    _ = try todos.add("Try nanoui");
    _ = try todos.add("Call Zig from JavaScript");

    try app.bind(&greeter);
    try app.bind(&todos);
    try app.registerEvent(Tick);

    _ = try app.newWindow(.{
        .title = "Hello",
        .width = 720,
        .height = 560,
        .title_bar = .hidden,
        .content = .{
            .page = .{
                .url = "/",
                .assets = &assets,
                // The bar in the page's corner: the app's own page, and a real
                // page from the web in the same window.
                .pages = &.{
                    .{ .title = "Hello", .url = "/" },
                    .{ .title = "WebView2 docs", .url = "https://learn.microsoft.com/en-us/microsoft-edge/webview2/" },
                },
            },
        },
    });
    nanoui.App.after(1000, app, tick);
    try app.run();
}
