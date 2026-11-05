//! What agents can do: each tool's name, what it is for (the model reads
//! it), whether it only looks or acts, and its arguments' JSON Schema, as
//! MCP's tools/list gives them.
const std = @import("std");

pub const Kind = enum {
    /// Reads the screen: allowed unless everything is stopped.
    observe,
    /// Moves the pointer, clicks, types, launches: allowed only when the
    /// user has turned input on.
    act,
};

pub const Tool = enum {
    list_apps,
    get_ui_tree,
    screenshot,
    click,
    type_text,
    press_key,
    scroll,
    move_mouse,
    set_value,
    open_app,

    pub fn kind(t: Tool) Kind {
        return switch (t) {
            .list_apps, .get_ui_tree, .screenshot => .observe,
            else => .act,
        };
    }

    pub fn parse(name: []const u8) ?Tool {
        return std.meta.stringToEnum(Tool, name);
    }

    /// When to use nanocua and when to stop. Here as well as in the handshake's
    /// `instructions`, which clients may ignore: graff does.
    pub const guidance =
        \\ Use nanocua for another app's real UI; to show or test your own work, prefer the project's own commands.
        \\If a call says nanocua is stopped, or input or the whole screen is off, tell the user once and carry on
        \\without it. Don't retry in a loop or set up permissions yourself: they are the user's to give.
    ;

    pub fn description(t: Tool) []const u8 {
        return switch (t) {
            .list_apps =>
            \\Lists the running apps with windows: name, bundle id, pid, and which one is frontmost.
            ++ guidance,
            .get_ui_tree =>
            \\The accessibility tree of an app, in the background (pid or app; else the app you last read, else the
            \\frontmost): one line per element with a ref like [12], its role, title, value and frame in screen points
            \\(top-left origin). The app becomes the one you act in. Use refs with click, type_text, scroll and
            \\set_value; they stay valid until the next get_ui_tree. Prefer this over screenshots: it is exact and cheap.
            ++ guidance,
            .screenshot =>
            \\A JPEG of an app's main window, even behind other windows (pid or app; else the app you last read).
            \\With whole_screen, if the user allows it: the main display, or a region of it (x, y, width, height).
            \\The reply says how image pixels map back to screen points. Use it when the tree does not show what you
            \\need (canvases, images).
            ,
            .click =>
            \\Clicks in the app you act in, without moving the user's pointer: an element by ref, or x,y in screen
            \\points, inside that app's window. Controls are pressed through accessibility, which is exact, except in
            \\web pages, which get a click event because browsers can ignore a press while reporting success. Anything
            \\else gets a click event that apps can ignore in the background, so the reply says it isn't confirmed:
            \\check the result. In a window that isn't its app's key window, that first click may only make it key.
            \\button: left (default) or right; count: 2 for a double click.
            ,
            .type_text =>
            \\Types text into the app you act in, without taking the user's keyboard: into its focused element, or
            \\into the element ref after focusing it.
            ,
            .press_key =>
            \\Presses a key with modifiers in the app you act in, written like "cmd+s", "shift+tab", "enter", "escape",
            \\"cmd+shift+left".
            ,
            .scroll =>
            \\Scrolls in the app you act in, at x,y (or over element ref), by dy lines (positive scrolls down) and dx
            \\lines (positive scrolls right). The reply says whether it moved, when the app has scroll bars to read.
            ,
            .move_mouse =>
            \\Hovers at x,y in screen points in the app you act in. The user's pointer stays put unless whole_screen.
            ,
            .set_value =>
            \\Sets an element's value through accessibility (a text field's text, a slider's value): exact, no typing.
            ,
            .open_app =>
            \\Opens an app by name, like "Safari" or "Notes", behind what the user is doing, and makes it the one you
            \\act in. With whole_screen, if the user allows it: brings it forward.
            ,
        };
    }

    /// The arguments' JSON Schema.
    pub fn schema(t: Tool) []const u8 {
        const point =
            \\"x":{"type":"number","description":"Screen points from the left"},"y":{"type":"number","description":"Screen points from the top"}
        ;
        const ref =
            \\"ref":{"type":"integer","description":"An element's ref from get_ui_tree"}
        ;
        const scope =
            \\"app":{"type":"string","description":"The app to act in, by name (else the last one you read)"},"pid":{"type":"integer"},"whole_screen":{"type":"boolean","description":"Use the real pointer and keyboard, if the user allows it"}
        ;
        return switch (t) {
            .list_apps => "{\"type\":\"object\",\"properties\":{}}",
            .get_ui_tree =>
            \\{"type":"object","properties":{"pid":{"type":"integer"},"app":{"type":"string","description":"An app's name"},"max_nodes":{"type":"integer","description":"At most this many elements (default 400)"}}}
            ,
            .screenshot =>
            \\{"type":"object","properties":{"app":{"type":"string","description":"An app's name"},"pid":{"type":"integer"},"whole_screen":{"type":"boolean","description":"The display, not one app's window, if the user allows it"},"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"},"max_size":{"type":"integer","description":"The image's longer side, in pixels (default 1280)"}}}
            ,
            .click => "{\"type\":\"object\",\"properties\":{" ++ ref ++ "," ++ point ++ "," ++ scope ++
                \\,"button":{"type":"string","enum":["left","right"]},"count":{"type":"integer","minimum":1,"maximum":3}}}
            ,
            .type_text => "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}," ++ ref ++ "," ++ scope ++ "},\"required\":[\"text\"]}",
            .press_key => "{\"type\":\"object\",\"properties\":{\"keys\":{\"type\":\"string\",\"description\":\"Like cmd+s or enter\"}," ++ scope ++ "},\"required\":[\"keys\"]}",
            .scroll => "{\"type\":\"object\",\"properties\":{" ++ ref ++ "," ++ point ++ "," ++ scope ++
                \\,"dx":{"type":"number"},"dy":{"type":"number"}}}
            ,
            .move_mouse => "{\"type\":\"object\",\"properties\":{" ++ point ++ "," ++ scope ++ "},\"required\":[\"x\",\"y\"]}",
            .set_value => "{\"type\":\"object\",\"properties\":{" ++ ref ++ ",\"value\":{\"type\":\"string\"}},\"required\":[\"ref\",\"value\"]}",
            .open_app =>
            \\{"type":"object","properties":{"name":{"type":"string"},"whole_screen":{"type":"boolean","description":"Bring it forward, if the user allows it"}},"required":["name"]}
            ,
        };
    }
};

/// MCP's tools/list result: every tool, its description and schema.
pub fn writeList(w: *std.Io.Writer) !void {
    try w.writeAll("{\"tools\":[");
    inline for (comptime std.enums.values(Tool), 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"name\":\"{s}\",\"description\":", .{@tagName(t)});
        try std.json.Stringify.encodeJsonString(t.description(), .{}, w);
        try w.print(",\"inputSchema\":{s}", .{t.schema()});
        try w.print(",\"annotations\":{{\"readOnlyHint\":{}}}}}", .{t.kind() == .observe});
    }
    try w.writeAll("]}");
}

/// Arguments, read leniently from the call's JSON object.
pub const Args = struct {
    obj: ?std.json.ObjectMap,

    pub fn of(v: ?std.json.Value) Args {
        if (v) |val| if (val == .object) return .{ .obj = val.object };
        return .{ .obj = null };
    }

    pub fn number(a: Args, key: []const u8) ?f64 {
        const v = (a.obj orelse return null).get(key) orelse return null;
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
            else => null,
        };
    }

    pub fn int(a: Args, key: []const u8) ?i64 {
        const n = a.number(key) orelse return null;
        if (!std.math.isFinite(n) or @abs(n) > 1e15) return null;
        return @intFromFloat(n);
    }

    pub fn string(a: Args, key: []const u8) ?[]const u8 {
        const v = (a.obj orelse return null).get(key) orelse return null;
        return if (v == .string) v.string else null;
    }

    pub fn boolean(a: Args, key: []const u8) ?bool {
        const v = (a.obj orelse return null).get(key) orelse return null;
        return if (v == .bool) v.bool else null;
    }

    /// x and y, both or neither.
    pub fn point(a: Args) ?[2]f64 {
        return .{ a.number("x") orelse return null, a.number("y") orelse return null };
    }
};

test "every schema is JSON, and the list parses" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeList(&aw.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, aw.written(), .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array.items;
    try std.testing.expectEqual(std.enums.values(Tool).len, tools.len);
    for (tools) |t| {
        try std.testing.expect(Tool.parse(t.object.get("name").?.string) != null);
        try std.testing.expectEqualStrings("object", t.object.get("inputSchema").?.object.get("type").?.string);
    }
}

test "arguments read leniently" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"x\":10,\"y\":2.5,\"ref\":\"no\",\"text\":\"hi\"}", .{});
    defer parsed.deinit();
    const a = Args.of(parsed.value);
    try std.testing.expectEqual(@as(?[2]f64, .{ 10, 2.5 }), a.point());
    try std.testing.expectEqual(@as(?i64, null), a.int("ref"));
    try std.testing.expectEqualStrings("hi", a.string("text").?);
    try std.testing.expectEqual(@as(?bool, null), a.boolean("text"));
    try std.testing.expectEqual(@as(?[]const u8, null), Args.of(null).string("text"));
}

test "the guidance reaches clients that ignore a server's instructions" {
    for ([_]Tool{ .list_apps, .get_ui_tree }) |t|
        try std.testing.expect(std.mem.indexOf(u8, t.description(), "permissions yourself") != null);
}
