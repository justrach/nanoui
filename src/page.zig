//! The web page a window shows, the same whichever webview draws it: the
//! bridge injected at document start, assets served from one origin, and
//! the outbox of messages batched into one evaluation per main-loop turn.
//! Each platform's webview (`page_webkit.zig` for WKWebView,
//! `page_webview2.zig` for Windows') supplies the four things that differ:
//! making the view, loading a URL, running JavaScript, and serving a path.
const std = @import("std");
const window_types = @import("window_types.zig");

/// The page runtime, injected at document start into every page's main frame.
pub const bridge_js = @embedFile("bridge.js");

/// Events wait for dom-ready so listeners exist; bounded per page.
pub const max_held = 1024;

/// Where a page's relative URLs resolve, per platform: WKWebView's custom
/// scheme on macOS, an `https` origin on Windows (Chromium needs a scheme
/// it knows; WebView2 intercepts every request to this one).
pub const origin = if (@import("builtin").os.tag == .macos) "nanoui://localhost" else "https://nanoui.local";

/// A file served to pages: what `serve` answers with.
pub const Served = struct {
    /// The body: the app's, the asset's, or a static message. Never freed here.
    data: []const u8,
    mime: []const u8,
    status: u16,
};

/// What a platform's webview must do for `Page`.
pub fn Backend(comptime Self: type) type {
    return struct {
        /// Makes the view inside `window`, sized to it.
        create: *const fn (self: *Self, window: anytype, options: window_types.PageOptions) anyerror!void,
        /// Points the view at `url`, absolute, on `origin`.
        load: *const fn (self: *Self, url: []const u8) void,
        /// Runs `js` in the page's main frame.
        eval: *const fn (self: *Self, js: []const u8) void,
        /// Frees the view.
        destroy: *const fn (self: *Self) void,
    };
}

/// The part of a page that has no platform in it: the outbox, the messages
/// held until the DOM is ready, and the asset table. A platform's `Page`
/// embeds one of these and forwards its callbacks to it.
pub fn Queue(comptime Window: type) type {
    return struct {
        const Self = @This();

        window: *Window,
        gpa: std.mem.Allocator,
        options: window_types.PageOptions,
        outbox: std.ArrayList(u8) = .empty,
        held: std.ArrayList([]u8) = .empty,
        dom_ready: bool = false,
        flush_scheduled: bool = false,
        dead: bool = false,
        /// Set once the platform's view exists: `eval` runs through it.
        send: ?*const fn (ctx: *anyopaque, js: []const u8) void = null,
        ctx: ?*anyopaque = null,
        /// The URL the view was last told to load: the page bar marks it.
        current_url: []const u8 = "",
        /// Where `current_url`'s bytes live.
        current_buf: [2048]u8 = undefined,

        /// Records the page now showing, for the bar's "current" mark.
        pub fn setCurrent(self: *Self, url: []const u8) void {
            if (url.len > self.current_buf.len) return;
            @memcpy(self.current_buf[0..url.len], url);
            self.current_url = self.current_buf[0..url.len];
        }

        pub fn init(window: *Window, options: window_types.PageOptions) Self {
            return .{ .window = window, .gpa = window.app.gpa, .options = options };
        }

        /// Queues a message for the page. Events (`hold`) wait for dom-ready.
        pub fn enqueue(self: *Self, msg: []const u8, hold: bool) void {
            const gpa = self.gpa;
            if (hold and !self.dom_ready) {
                if (self.held.items.len >= max_held) return;
                const copy = gpa.dupe(u8, msg) catch return;
                self.held.append(gpa, copy) catch gpa.free(copy);
                return;
            }
            if (self.outbox.items.len > 0) self.outbox.append(gpa, ',') catch return;
            self.outbox.appendSlice(gpa, msg) catch return;
        }

        /// Sends everything queued, in one evaluation, when the loop turns.
        /// True when this call is the one that scheduled it.
        pub fn schedule(self: *Self) bool {
            if (self.flush_scheduled) return false;
            self.flush_scheduled = true;
            return true;
        }

        /// The page's DOM is there: held messages go out, and `--nanoui-eval`.
        pub fn domReady(self: *Self) void {
            self.dom_ready = true;
            const gpa = self.gpa;
            for (self.held.items) |m| {
                self.enqueue(m, false);
                gpa.free(m);
            }
            self.held.clearRetainingCapacity();
            if (self.window.app.flags.eval) |js| self.eval(js);
        }

        /// Runs `js` now, through the platform's view.
        pub fn eval(self: *Self, js: []const u8) void {
            const send = self.send orelse return;
            send(self.ctx orelse return, js);
        }

        /// The one evaluation a turn makes: `__nanoui.receive([...])`.
        pub fn flush(self: *Self) void {
            self.flush_scheduled = false;
            if (self.outbox.items.len == 0) return;
            const gpa = self.gpa;
            var script: std.ArrayList(u8) = .empty;
            defer script.deinit(gpa);
            script.appendSlice(gpa, "__nanoui.receive([") catch return;
            script.appendSlice(gpa, self.outbox.items) catch return;
            script.appendSlice(gpa, "])") catch return;
            self.outbox.clearRetainingCapacity();
            self.eval(script.items);
        }

        /// What a request for `path` answers: the client JavaScript, an
        /// asset, or a 404.
        pub fn serve(self: *Self, path_in: []const u8) Served {
            var path = path_in;
            if (path.len == 0 or std.mem.eql(u8, path, "/")) path = "/index.html";
            if (std.mem.eql(u8, path, "/nanoui.js")) {
                const js = self.window.app.clientJs() catch return notFound();
                return .{ .data = js, .mime = "text/javascript; charset=utf-8", .status = 200 };
            }
            for (self.options.assets) |a| {
                if (std.mem.eql(u8, a.path, path)) {
                    return .{ .data = a.data, .mime = a.mime orelse mimeType(path), .status = 200 };
                }
            }
            return notFound();
        }

        /// Releases the outbox, the held messages and a pending flush's object.
        pub fn deinit(self: *Self) void {
            self.dead = true;
            const gpa = self.gpa;
            for (self.held.items) |m| gpa.free(m);
            self.held.deinit(gpa);
            self.outbox.deinit(gpa);
        }
    };
}

fn notFound() Served {
    return .{ .data = "Not Found", .mime = "text/plain", .status = 404 };
}

/// The path part of a URL on `origin` (`/index.html`), or "/" for the root —
/// also for a URL that is not on `origin` at all, which is nobody's path.
pub fn pathOf(url: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, url, origin)) return "/";
    const rest = url[origin.len..];
    return if (rest.len == 0) "/" else rest;
}

/// The URL to load: an absolute `http(s)://` one as it is, else the path on
/// `origin` the app serves its assets on. `buf` holds the composed one.
pub fn fullUrl(buf: []u8, url: []const u8) []const u8 {
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) return url;
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{
        origin,
        if (url.len > 0 and url[0] == '/') "" else "/",
        url,
    }) catch url;
}

pub fn mimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const table = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".woff2", "font/woff2" },
        .{ ".wasm", "application/wasm" },
    };
    inline for (table) |e| if (std.ascii.eqlIgnoreCase(ext, e[0])) return e[1];
    return "application/octet-stream";
}

test "a page's root is its index" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeType("/index.html"));
}

test "the path of a page's URL drops the origin" {
    try std.testing.expectEqualStrings("/main.js", pathOf(origin ++ "/main.js"));
    try std.testing.expectEqualStrings("/", pathOf(origin));
}

test "the ipc bridge is what a page is sent, unmodified" {
    // The same bytes on every platform: `bridge.js` picks its post.
    try std.testing.expect(std.mem.indexOf(u8, bridge_js, "__nanoui") != null);
}
