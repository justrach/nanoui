//! Linux GTK 3 & GTK 4 host file-drop interception for WebKitGTK `Page`,
//! sharing `page_drop.Session` routing, epoch cancellation, and URI filtering.
const std = @import("std");
const gtk = @import("gtk.zig");
const page_drop = @import("../page_drop.zig");

const Obj = *anyopaque;
const Widget = gtk.Widget;

const Api = struct {
    g_value_get_boxed: *const fn (*const anyopaque) callconv(.c) ?Obj,
    g_value_get_object: *const fn (*const anyopaque) callconv(.c) ?Obj,
    g_type_check_instance_is_a: *const fn (*const anyopaque, usize) callconv(.c) c_int,
    g_signal_stop_emission_by_name: *const fn (Obj, [*:0]const u8) callconv(.c) void,
    g_file_get_type: *const fn () callconv(.c) usize,
    g_file_get_uri: *const fn (Obj) callconv(.c) ?[*:0]u8,
};

const Api4 = struct {
    gtk_drop_target_new: *const fn (usize, c_uint) callconv(.c) ?Obj,
    gtk_drop_target_set_gtypes: *const fn (Obj, [*]const usize, usize) callconv(.c) void,
    gtk_drop_target_set_preload: *const fn (Obj, c_int) callconv(.c) void,
    gtk_drop_target_get_value: *const fn (Obj) callconv(.c) ?*const anyopaque,
    gtk_drop_target_reject: *const fn (Obj) callconv(.c) void,
    gtk_event_controller_set_propagation_phase: *const fn (Obj, c_int) callconv(.c) void,
    gtk_widget_remove_controller: *const fn (*Widget, Obj) callconv(.c) void,
    gdk_file_list_get_type: *const fn () callconv(.c) usize,
    gdk_file_list_get_files: *const fn (Obj) callconv(.c) ?*gtk.SList,
};

const Api3 = struct {
    gtk_drag_dest_get_target_list: *const fn (*Widget) callconv(.c) ?Obj,
    gtk_drag_dest_add_uri_targets: *const fn (*Widget) callconv(.c) void,
    gtk_drag_dest_find_target: *const fn (*Widget, Obj, ?Obj) callconv(.c) ?Obj,
    gtk_drag_get_data: *const fn (*Widget, Obj, ?Obj, u32) callconv(.c) void,
    gdk_drag_status: *const fn (Obj, c_uint, u32) callconv(.c) void,
    gtk_drag_finish: *const fn (Obj, c_int, c_int, u32) callconv(.c) void,
    gtk_selection_data_get_uris: *const fn (Obj) callconv(.c) ?[*:null]?[*:0]u8,
    gtk_selection_data_get_data: *const fn (Obj) callconv(.c) ?[*]const u8,
    gtk_selection_data_get_length: *const fn (Obj) callconv(.c) c_int,
    g_strfreev: *const fn (?[*:null]?[*:0]u8) callconv(.c) void,
};

var common: Api = undefined;
var v4_api: Api4 = undefined;
var v3_api: Api3 = undefined;
var resolved: enum { untried, ok, unavailable } = .untried;

fn loadStruct(comptime T: type, out: *T) bool {
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        const sym = std.c.dlsym(null, name) orelse return false;
        @field(out.*, name) = @ptrCast(@alignCast(sym));
    }
    return true;
}

fn ensureLoaded() bool {
    if (resolved != .untried) return resolved == .ok;
    const ok = loadStruct(Api, &common) and (if (gtk.v4) loadStruct(Api4, &v4_api) else loadStruct(Api3, &v3_api));
    resolved = if (ok) .ok else .unavailable;
    return ok;
}

/// Host drop hook state embedded inside `page_webkitgtk.Page`.
pub fn State(comptime PageType: type) type {
    return struct {
        controller: ?Obj = null,
        view: ?*Widget = null,
        signals: [4]c_ulong = .{ 0, 0, 0, 0 },
        pending_epoch: ?u64 = null,
        pending_x: f64 = 0,
        pending_y: f64 = 0,

        pub fn attach(self: *@This(), page: *PageType, view: *Widget) void {
            if (!page.drop_session.isEnabled() or !ensureLoaded()) return;
            self.view = view;
            if (gtk.v4) {
                const file_list_t = v4_api.gdk_file_list_get_type();
                const gfile_t = common.g_file_get_type();
                const gtypes = [_]usize{ file_list_t, gfile_t };
                const target = v4_api.gtk_drop_target_new(file_list_t, 1) orelse return;
                v4_api.gtk_drop_target_set_gtypes(target, &gtypes, gtypes.len);
                v4_api.gtk_drop_target_set_preload(target, 1);
                v4_api.gtk_event_controller_set_propagation_phase(target, 1); // GTK_PHASE_CAPTURE
                self.signals[0] = gtk.api.g_signal_connect_data(target, "enter", @ptrCast(&onEnter4), page, null, 0);
                self.signals[1] = gtk.api.g_signal_connect_data(target, "motion", @ptrCast(&onMotion4), page, null, 0);
                self.signals[2] = gtk.api.g_signal_connect_data(target, "leave", @ptrCast(&onLeave4), page, null, 0);
                self.signals[3] = gtk.api.g_signal_connect_data(target, "drop", @ptrCast(&onDrop4), page, null, 0);
                gtk.v4api.gtk_widget_add_controller(view, target);
                self.controller = target;
            } else {
                if (v3_api.gtk_drag_dest_get_target_list(view) != null) {
                    v3_api.gtk_drag_dest_add_uri_targets(view);
                }
                self.signals[0] = gtk.api.g_signal_connect_data(view, "drag-motion", @ptrCast(&onMotion3), page, null, 0);
                self.signals[1] = gtk.api.g_signal_connect_data(view, "drag-leave", @ptrCast(&onLeave3), page, null, 0);
                self.signals[2] = gtk.api.g_signal_connect_data(view, "drag-drop", @ptrCast(&onDrop3), page, null, 0);
                self.signals[3] = gtk.api.g_signal_connect_data(view, "drag-data-received", @ptrCast(&onData3), page, null, 0);
            }
        }

        pub fn detach(self: *@This()) void {
            const target: ?Obj = if (gtk.v4) self.controller else if (self.view) |w| @ptrCast(w) else null;
            if (target) |inst| {
                for (&self.signals) |*id| {
                    if (id.* != 0) gtk.api.g_signal_handler_disconnect(inst, id.*);
                    id.* = 0;
                }
            }
            if (gtk.v4) {
                if (self.controller) |ctl| if (self.view) |w| v4_api.gtk_widget_remove_controller(w, ctl);
            }
            self.controller = null;
            self.view = null;
            self.pending_epoch = null;
        }

        fn extractUrls4(gpa: std.mem.Allocator, value: ?*const anyopaque) []const []const u8 {
            const v = value orelse return &.{};
            var list: std.ArrayList([]const u8) = .empty;
            if (common.g_value_get_boxed(v)) |boxed| {
                var cur = v4_api.gdk_file_list_get_files(boxed);
                defer if (cur) |head| gtk.api.g_slist_free(head);
                while (cur) |node| : (cur = node.next) {
                    if (node.data) |f| appendGFileUri(gpa, &list, f);
                }
            } else if (common.g_value_get_object(v)) |obj| {
                if (common.g_type_check_instance_is_a(obj, common.g_file_get_type()) != 0) {
                    appendGFileUri(gpa, &list, obj);
                }
            }
            return list.toOwnedSlice(gpa) catch &.{};
        }

        fn appendGFileUri(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8), file: Obj) void {
            const raw = common.g_file_get_uri(file) orelse return;
            defer gtk.api.g_free(raw);
            const slice = std.mem.span(raw);
            if (!page_drop.startsWithFileScheme(slice) or slice.len <= "file://".len) return;
            const copy = gpa.dupe(u8, slice) catch return;
            list.append(gpa, copy) catch gpa.free(copy);
        }

        fn handleOffer4(target: Obj, x: f64, y: f64, page: *PageType, phase: page_drop.Phase) c_uint {
            if (page.queue.dead or !page.drop_session.isEnabled()) return 0;
            var arena: std.heap.ArenaAllocator = .init(page.queue.gpa);
            defer arena.deinit();
            const urls = extractUrls4(arena.allocator(), v4_api.gtk_drop_target_get_value(target));
            page.enterDrop();
            defer page.leaveDrop();
            const dec = page.drop_session.onOffer(phase, x, y, urls, true);
            if (page.queue.dead) return 0;
            return switch (dec) {
                .host => 1, // GDK_ACTION_COPY
                .reject => 0,
                .webview => blk: {
                    v4_api.gtk_drop_target_reject(target);
                    break :blk 0;
                },
            };
        }

        fn onEnter4(target: Obj, x: f64, y: f64, data: ?*anyopaque) callconv(.c) c_uint {
            return handleOffer4(target, x, y, @ptrCast(@alignCast(data)), .enter);
        }

        fn onMotion4(target: Obj, x: f64, y: f64, data: ?*anyopaque) callconv(.c) c_uint {
            return handleOffer4(target, x, y, @ptrCast(@alignCast(data)), .update);
        }

        fn onLeave4(_: Obj, data: ?*anyopaque) callconv(.c) void {
            const page: *PageType = @ptrCast(@alignCast(data));
            if (page.queue.dead) return;
            page.enterDrop();
            defer page.leaveDrop();
            page.drop_session.onExit();
        }

        fn onDrop4(_: Obj, value: ?*const anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) c_int {
            const page: *PageType = @ptrCast(@alignCast(data));
            if (page.queue.dead or !page.drop_session.isEnabled()) return 0;
            if (page.drop_session.decision != .host) {
                page.enterDrop();
                defer page.leaveDrop();
                if (page.drop_session.decision == .webview) page.drop_session.finishWebviewDrop() else page.drop_session.onExit();
                return 0;
            }
            var arena: std.heap.ArenaAllocator = .init(page.queue.gpa);
            defer arena.deinit();
            const urls = extractUrls4(arena.allocator(), value);
            page.enterDrop();
            defer page.leaveDrop();
            return if (page.drop_session.deliverDrop(null, x, y, urls)) 1 else 0;
        }

        fn onMotion3(widget: *Widget, ctx: Obj, x: c_int, y: c_int, time: u32, data: ?*anyopaque) callconv(.c) c_int {
            const page: *PageType = @ptrCast(@alignCast(data));
            if (page.queue.dead or !page.drop_session.isEnabled()) return 0;
            const phase: page_drop.Phase = if (page.drop_session.active) .update else .enter;
            page.enterDrop();
            defer page.leaveDrop();
            const has_files = v3_api.gtk_drag_dest_find_target(widget, ctx, null) != null;
            const dec = page.drop_session.onOffer(phase, @floatFromInt(x), @floatFromInt(y), &.{}, has_files);
            if (page.queue.dead) return 1;
            switch (dec) {
                .webview => return 0,
                .host => {
                    v3_api.gdk_drag_status(ctx, 2, time); // GDK_ACTION_COPY (GTK 3)
                    common.g_signal_stop_emission_by_name(widget, "drag-motion");
                    return 1;
                },
                .reject => {
                    v3_api.gdk_drag_status(ctx, 0, time);
                    common.g_signal_stop_emission_by_name(widget, "drag-motion");
                    return 1;
                },
            }
        }

        fn onLeave3(widget: *Widget, _: Obj, _: u32, data: ?*anyopaque) callconv(.c) void {
            const page: *PageType = @ptrCast(@alignCast(data));
            if (page.queue.dead or !page.drop_session.active) return;
            const was_webview = page.drop_session.decision == .webview;
            page.enterDrop();
            defer page.leaveDrop();
            page.drop_session.onExit();
            if (!was_webview and !page.queue.dead) common.g_signal_stop_emission_by_name(widget, "drag-leave");
        }

        fn onDrop3(widget: *Widget, ctx: Obj, x: c_int, y: c_int, time: u32, data: ?*anyopaque) callconv(.c) c_int {
            const page: *PageType = @ptrCast(@alignCast(data));
            if (page.queue.dead or !page.drop_session.isEnabled()) return 0;
            if (!page.drop_session.active) {
                page.drop_session.active_epoch = 0;
                v3_api.gtk_drag_finish(ctx, 0, 0, time);
                common.g_signal_stop_emission_by_name(widget, "drag-drop");
                return 1;
            }
            if (page.drop_session.decision == .webview) {
                page.drop_session.finishWebviewDrop();
                return 0;
            }
            if (page.drop_session.decision == .reject) {
                page.enterDrop();
                defer page.leaveDrop();
                page.drop_session.onExit();
                v3_api.gtk_drag_finish(ctx, 0, 0, time);
                common.g_signal_stop_emission_by_name(widget, "drag-drop");
                return 1;
            }
            const tok = page.drop_session.beginAsyncDrop() orelse {
                v3_api.gtk_drag_finish(ctx, 0, 0, time);
                common.g_signal_stop_emission_by_name(widget, "drag-drop");
                return 1;
            };
            page.drop_gtk.pending_epoch = tok;
            page.drop_gtk.pending_x = @floatFromInt(x);
            page.drop_gtk.pending_y = @floatFromInt(y);
            const target = v3_api.gtk_drag_dest_find_target(widget, ctx, null) orelse {
                page.drop_gtk.pending_epoch = null;
                v3_api.gtk_drag_finish(ctx, 0, 0, time);
                common.g_signal_stop_emission_by_name(widget, "drag-drop");
                return 1;
            };
            v3_api.gtk_drag_get_data(widget, ctx, target, time);
            common.g_signal_stop_emission_by_name(widget, "drag-drop");
            return 1;
        }

        fn onData3(widget: *Widget, ctx: Obj, _: c_int, _: c_int, sel_data: Obj, _: c_uint, time: u32, data: ?*anyopaque) callconv(.c) void {
            const page: *PageType = @ptrCast(@alignCast(data));
            const tok = page.drop_gtk.pending_epoch orelse return;
            const px = page.drop_gtk.pending_x;
            const py = page.drop_gtk.pending_y;
            page.drop_gtk.pending_epoch = null;
            common.g_signal_stop_emission_by_name(widget, "drag-data-received");
            if (page.queue.dead) {
                v3_api.gtk_drag_finish(ctx, 0, 0, time);
                return;
            }
            var arena: std.heap.ArenaAllocator = .init(page.queue.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const urls = readUrls3(a, sel_data);
            page.enterDrop();
            defer page.leaveDrop();
            const ok = page.drop_session.deliverDrop(tok, px, py, urls);
            v3_api.gtk_drag_finish(ctx, if (ok) 1 else 0, 0, time);
        }

        fn readUrls3(gpa: std.mem.Allocator, sel_data: Obj) []const []const u8 {
            if (v3_api.gtk_selection_data_get_uris(sel_data)) |uris| {
                defer v3_api.g_strfreev(uris);
                var list: std.ArrayList([]const u8) = .empty;
                var i: usize = 0;
                while (uris[i]) |p| : (i += 1) {
                    const s = std.mem.span(p);
                    if (!page_drop.startsWithFileScheme(s) or s.len <= "file://".len) continue;
                    const dup = gpa.dupe(u8, s) catch continue;
                    list.append(gpa, dup) catch gpa.free(dup);
                }
                return list.toOwnedSlice(gpa) catch &.{};
            }
            const raw_ptr = v3_api.gtk_selection_data_get_data(sel_data) orelse return &.{};
            const raw_len = v3_api.gtk_selection_data_get_length(sel_data);
            if (raw_len <= 0) return &.{};
            return page_drop.parseUriList(gpa, raw_ptr[0..@intCast(raw_len)]) catch &.{};
        }
    };
}
