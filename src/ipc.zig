//! Typed IPC: services bound with `App.bind`, their methods called by pages,
//! and typed events sent to them. The same wire protocol wherever pages work
//! (`src/page.zig`); what differs is whose `Window` and `App` these are, so
//! the module is made per platform:
//!
//!     pub const ipc = @import("ipc.zig").ipc(Window, App);
const std = @import("std");
const tsgen = @import("tsgen.zig");
const page_mod = @import("page.zig");

/// The scheme, `://` and host of `url`; "" for a URL without them.
pub fn originOf(url: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return "";
    const rest = url[sep + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return url[0 .. sep + 3 + end];
}

test "a call's origin is its page's scheme and host" {
    try std.testing.expectEqualStrings("nanoui://localhost", originOf("nanoui://localhost/code.html?x=1"));
    try std.testing.expectEqualStrings("https://example.com", originOf("https://example.com"));
    try std.testing.expectEqualStrings("http://localhost:5173", originOf("http://localhost:5173#top"));
    try std.testing.expectEqualStrings("", originOf("/index.html"));
}

pub fn ipc(comptime Window: type, comptime App: type) type {
    return struct {
        /// The context of a call, for methods that take `*nanoui.Call` after self.
        pub const Call = struct {
            pub const nanoui_call_context = {};
            /// Freed when the reply is sent: allocate results here.
            arena: std.mem.Allocator,
            window: *Window,
            /// The page the call came from (the window's own or a docked
            /// one), as the platform's `*Page`: compare it with a page the
            /// app made to know who is calling.
            page: ?*anyopaque = null,
            /// That page's `PageOptions.label`.
            label: []const u8 = "",
            /// The URL of the document that sent the call, as the webview
            /// reports it with the message (WKWebView's frame request,
            /// WebView2's message `Source`), so a page that navigated itself
            /// is seen where it went. Absolute: the app's own assets are on
            /// `origin` (`nanoui://localhost/code.html`). Only when the
            /// webview gives none is it the URL the page was last told to
            /// load, resolved the same way.
            url: []const u8 = "",

            /// The scheme and host of `url` (`nanoui://localhost`,
            /// `https://example.com`), without a path: what to check before
            /// trusting a call that only one of the app's pages may make.
            pub fn origin(call: *const Call) []const u8 {
                return originOf(call.url);
            }
        };

        pub const Service = struct {
            name: []const u8,
            ctx: *anyopaque,
            dispatch: *const fn (ctx: *anyopaque, call: *Call, method: []const u8, args: []const std.json.Value, out: *std.Io.Writer) anyerror!void,
            client: tsgen.Service,
        };

        pub fn service(comptime T: type, ptr: *T) Service {
            const Impl = struct {
                fn dispatch(ctx: *anyopaque, call: *Call, method: []const u8, args: []const std.json.Value, out: *std.Io.Writer) anyerror!void {
                    const self: *T = @ptrCast(@alignCast(ctx));
                    inline for (comptime tsgen.methodNames(T)) |name| {
                        if (std.mem.eql(u8, method, name)) return invoke(T, name, self, call, args, out);
                    }
                    return error.UnknownMethod;
                }
            };
            return .{ .name = tsgen.shortName(T), .ctx = ptr, .dispatch = Impl.dispatch, .client = comptime tsgen.service(T) };
        }

        fn invoke(comptime T: type, comptime name: []const u8, self: *T, call: *Call, args: []const std.json.Value, out: *std.Io.Writer) !void {
            const func = @field(T, name);
            const F = @typeInfo(@TypeOf(func)).@"fn";
            var tuple: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
            tuple[0] = switch (F.param_types[0].?) {
                T => self.*,
                else => self,
            };
            comptime var next = 0;
            inline for (F.param_types[1..], 1..) |P, i| {
                if (P.? == *Call) {
                    tuple[i] = call;
                } else {
                    if (next >= args.len) return error.MissingArgument;
                    tuple[i] = std.json.parseFromValueLeaky(P.?, call.arena, args[next], .{ .ignore_unknown_fields = true }) catch
                        return error.InvalidArgument;
                    next += 1;
                }
            }
            if (args.len > next) return error.TooManyArguments;
            const result = @call(.auto, func, tuple);
            const value = if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
            try writeJson(value, out);
        }

        pub fn writeJson(value: anytype, out: *std.Io.Writer) !void {
            if (@TypeOf(value) == void) return out.writeAll("null");
            try std.json.Stringify.value(value, .{}, out);
        }

        /// A typed event: `const Tick = nanoui.Event("tick", struct { n: u32 });`
        /// Pages listen with the generated `onTick(fn)`.
        pub fn Event(comptime event_name: []const u8, comptime T: type) type {
            return struct {
                pub const name = event_name;
                pub const Payload = T;
                pub const client = tsgen.event(event_name, T);

                /// Sends `payload` to one window's page. Safe from any thread.
                pub fn emit(window: *Window, payload: T) void {
                    const msg = encode(window.app.gpa, payload) catch return;
                    window.sendOwned(msg);
                }

                /// Sends `payload` to one page (a docked one). Main thread.
                pub fn emitPage(page: anytype, payload: T) void {
                    const msg = encode(page.queue.gpa, payload) catch return;
                    page.sendOwned(msg);
                }

                /// Sends `payload` to every window's page. Main thread only.
                pub fn broadcast(app: *App, payload: T) void {
                    const msg = encode(app.gpa, payload) catch return;
                    defer app.gpa.free(msg);
                    for (app.windows.items) |w| {
                        if (w.page) |p| p.enqueue(msg, true);
                    }
                }

                fn encode(gpa: std.mem.Allocator, payload: T) ![]u8 {
                    var aw: std.Io.Writer.Allocating = .init(gpa);
                    errdefer aw.deinit();
                    try aw.writer.writeAll("{\"t\":\"event\",\"n\":");
                    try std.json.Stringify.encodeJsonString(event_name, .{}, &aw.writer);
                    try aw.writer.writeAll(",\"p\":");
                    try writeJson(payload, &aw.writer);
                    try aw.writer.writeByte('}');
                    return aw.toOwnedSlice();
                }
            };
        }

        const Envelope = struct {
            t: []const u8,
            id: f64 = 0,
            m: []const u8 = "",
            a: []const std.json.Value = &.{},
            op: []const u8 = "",
            v: ?[]const u8 = null,
        };

        /// The id a page sent, whole and in range. It is whatever JSON had —
        /// a remote page's too, since the bar loads the web — and the casts
        /// below must not trap on `1e300` or `NaN`.
        fn pageId(id: f64) u64 {
            if (!std.math.isFinite(id) or id < 0) return 0;
            // f64 keeps integers only up to 2^53; past that JSON says little.
            return @intFromFloat(@min(id, 9007199254740992.0));
        }

        /// A page its own call closed, freed once the call has returned: as
        /// its platform frees one (`freeClosed`), or when no flush is left
        /// to free it (WebKit's flush frees a dead page as it runs).
        fn freeClosed(page: anytype) void {
            if (@hasDecl(@TypeOf(page.*), "freeClosed")) return page.freeClosed();
            if (!page.queue.flush_scheduled) page.queue.gpa.destroy(page);
        }

        /// Handles one message from the window's page, on the main thread.
        pub fn handleMessage(window: *Window, body: []const u8) void {
            const page = window.page orelse return;
            handlePageMessage(window, page, body, "");
        }

        /// Handles one message from `page`, one of `window`'s (its `page`
        /// or a docked one), on the main thread. `source` is the URL of the
        /// document that posted it, as the webview reports it ("" when it
        /// reports none): what `Call.url` and `Call.origin` say.
        pub fn handlePageMessage(window: *Window, page: anytype, body: []const u8, source: []const u8) void {
            const app = window.app;
            var arena: std.heap.ArenaAllocator = .init(app.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const env = std.json.parseFromSliceLeaky(Envelope, a, body, .{ .ignore_unknown_fields = true }) catch {
                std.log.warn("nanoui: malformed message from page", .{});
                return;
            };
            // A method may close `window` (freeing it) and its page: only
            // `page` is used after `callMethod`, and it outlives this call.
            page.queue.dispatching = true;
            defer {
                page.queue.dispatching = false;
                if (page.queue.dead) freeClosed(page);
            }
            if (std.mem.eql(u8, env.t, "call")) {
                var aw: std.Io.Writer.Allocating = .init(a);
                aw.writer.print("{{\"t\":\"reply\",\"id\":{d},", .{pageId(env.id)}) catch return;
                const mark = aw.written().len;
                const url = if (source.len > 0)
                    source
                else
                    page_mod.fullUrl(a.alloc(u8, page.queue.current_url.len + page_mod.origin.len + 1) catch return, page.queue.current_url);
                var call: Call = .{ .arena = a, .window = window, .page = @ptrCast(page), .label = page.queue.options.label, .url = url };
                callMethod(app, &call, env.m, env.a, &aw.writer) catch |err| {
                    aw.shrinkRetainingCapacity(mark);
                    aw.writer.writeAll("\"ok\":false,\"e\":") catch return;
                    const text = std.fmt.allocPrint(a, "{s}: {s}", .{ env.m, @errorName(err) }) catch return;
                    std.json.Stringify.encodeJsonString(text, .{}, &aw.writer) catch return;
                    aw.writer.writeByte('}') catch return;
                    page.enqueue(aw.written(), false);
                    return;
                };
                aw.writer.writeByte('}') catch return;
                page.enqueue(aw.written(), false);
            } else if (std.mem.eql(u8, env.t, "dom-ready")) {
                page.domReady();
            } else if (std.mem.eql(u8, env.t, "page")) {
                // The bar in the page asked for one of the app's pages.
                window.showPage(@intCast(pageId(env.id)));
            } else if (std.mem.eql(u8, env.t, "log")) {
                std.debug.print("page: {s}\n", .{env.v orelse ""});
            } else if (std.mem.eql(u8, env.t, "drag")) {
                page.startDrag();
            } else if (std.mem.eql(u8, env.t, "dblclick")) {
                window.zoom();
            } else if (std.mem.eql(u8, env.t, "win")) {
                if (std.mem.eql(u8, env.op, "close")) window.close() //
                else if (std.mem.eql(u8, env.op, "minimize")) window.minimize() //
                else if (std.mem.eql(u8, env.op, "zoom")) window.zoom() //
                else if (std.mem.eql(u8, env.op, "title")) window.setTitle(env.v orelse "");
            }
        }

        fn callMethod(app: *App, call: *Call, method: []const u8, args: []const std.json.Value, out: *std.Io.Writer) !void {
            const dot = std.mem.indexOfScalar(u8, method, '.') orelse return error.UnknownMethod;
            const svc = app.services.get(method[0..dot]) orelse return error.UnknownService;
            try out.writeAll("\"ok\":true,\"v\":");
            try svc.dispatch(svc.ctx, call, method[dot + 1 ..], args, out);
        }
    };
}
