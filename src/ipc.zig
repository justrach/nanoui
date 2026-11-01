//! Typed IPC: services bound with `App.bind`, their methods called by pages,
//! and typed events sent to them. The same wire protocol wherever pages work
//! (`src/page.zig`); what differs is whose `Window` and `App` these are, so
//! the module is made per platform:
//!
//!     pub const ipc = @import("ipc.zig").ipc(Window, App);
const std = @import("std");
const tsgen = @import("tsgen.zig");

pub fn ipc(comptime Window: type, comptime App: type) type {
    return struct {
        /// The context of a call, for methods that take `*nanoui.Call` after self.
        pub const Call = struct {
            pub const nanoui_call_context = {};
            /// Freed when the reply is sent: allocate results here.
            arena: std.mem.Allocator,
            window: *Window,
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

        /// Handles one message from a page, on the main thread.
        pub fn handleMessage(window: *Window, body: []const u8) void {
            const app = window.app;
            var arena: std.heap.ArenaAllocator = .init(app.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const env = std.json.parseFromSliceLeaky(Envelope, a, body, .{ .ignore_unknown_fields = true }) catch {
                std.log.warn("nanoui: malformed message from page", .{});
                return;
            };
            const page = window.page orelse return;
            if (std.mem.eql(u8, env.t, "call")) {
                var aw: std.Io.Writer.Allocating = .init(a);
                aw.writer.print("{{\"t\":\"reply\",\"id\":{d},", .{pageId(env.id)}) catch return;
                const mark = aw.written().len;
                callMethod(app, window, a, env.m, env.a, &aw.writer) catch |err| {
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

        fn callMethod(app: *App, window: *Window, arena: std.mem.Allocator, method: []const u8, args: []const std.json.Value, out: *std.Io.Writer) !void {
            const dot = std.mem.indexOfScalar(u8, method, '.') orelse return error.UnknownMethod;
            const svc = app.services.get(method[0..dot]) orelse return error.UnknownService;
            try out.writeAll("\"ok\":true,\"v\":");
            var call: Call = .{ .arena = arena, .window = window };
            try svc.dispatch(svc.ctx, &call, method[dot + 1 ..], args, out);
        }
    };
}
