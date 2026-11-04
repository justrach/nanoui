//! WebKitGTK and JavaScriptCore, loaded when a window first shows a page (as
//! `gtk.zig` loads GTK): no headers and no libraries at build time. Each
//! function is looked up by its field's name.
//!
//! A WebKitGTK is built for one GTK, and two GTKs in one process abort. So
//! 6.0 goes with GTK 4, and 4.1 or 4.0 with GTK 3.
const std = @import("std");
const gtk = @import("gtk.zig");

const Obj = *anyopaque;
const Str = [*:0]const u8;
const OptStr = ?[*:0]const u8;

pub const SchemeFn = *const fn (request: Obj, data: ?*anyopaque) callconv(.c) void;

/// What every supported WebKitGTK has: 2.40 and later, because
/// `webkit_web_view_evaluate_javascript` is 2.40's.
pub const Api = struct {
    webkit_web_context_register_uri_scheme: *const fn (context: Obj, scheme: Str, callback: SchemeFn, data: ?*anyopaque, destroy: ?*anyopaque) callconv(.c) void,
    webkit_web_context_get_security_manager: *const fn (context: Obj) callconv(.c) Obj,
    webkit_security_manager_register_uri_scheme_as_secure: *const fn (manager: Obj, scheme: Str) callconv(.c) void,
    webkit_security_manager_register_uri_scheme_as_cors_enabled: *const fn (manager: Obj, scheme: Str) callconv(.c) void,
    webkit_web_view_get_type: *const fn () callconv(.c) usize,
    webkit_web_view_load_uri: *const fn (view: Obj, uri: Str) callconv(.c) void,
    webkit_web_view_get_settings: *const fn (view: Obj) callconv(.c) Obj,
    webkit_web_view_get_user_content_manager: *const fn (view: Obj) callconv(.c) Obj,
    webkit_web_view_evaluate_javascript: *const fn (view: Obj, script: [*]const u8, length: isize, world: OptStr, source_uri: OptStr, cancellable: ?Obj, callback: ?*anyopaque, data: ?*anyopaque) callconv(.c) void,
    webkit_settings_set_enable_developer_extras: *const fn (settings: Obj, on: c_int) callconv(.c) void,
    webkit_user_script_new: *const fn (source: Str, frames: c_int, time: c_int, allow: ?*anyopaque, block: ?*anyopaque) callconv(.c) Obj,
    webkit_user_script_unref: *const fn (script: Obj) callconv(.c) void,
    webkit_user_content_manager_add_script: *const fn (manager: Obj, script: Obj) callconv(.c) void,
    // 4.x takes the first two; 6.0 also a world, null for the page's own.
    webkit_user_content_manager_register_script_message_handler: *const fn (manager: Obj, name: Str, world: OptStr) callconv(.c) c_int,
    webkit_uri_scheme_request_get_path: *const fn (request: Obj) callconv(.c) Str,
    webkit_uri_scheme_request_get_web_view: *const fn (request: Obj) callconv(.c) Obj,
    webkit_uri_scheme_request_finish_with_response: *const fn (request: Obj, response: Obj) callconv(.c) void,
    webkit_uri_scheme_response_new: *const fn (stream: Obj, length: i64) callconv(.c) Obj,
    webkit_uri_scheme_response_set_content_type: *const fn (response: Obj, content_type: Str) callconv(.c) void,
    webkit_uri_scheme_response_set_status: *const fn (response: Obj, code: c_uint, reason: OptStr) callconv(.c) void,
    jsc_value_to_string: *const fn (value: Obj) callconv(.c) ?[*:0]u8,
};

/// WebKitGTK 6.0's own: the profile is a network session.
pub const Api6 = struct {
    webkit_web_context_new: *const fn () callconv(.c) Obj,
    webkit_network_session_new: *const fn (data: Str, cache: Str) callconv(.c) Obj,
    webkit_network_session_new_ephemeral: *const fn () callconv(.c) Obj,
};

/// WebKitGTK 4.x's own: the profile is a data manager, and script messages
/// arrive wrapped.
pub const Api4x = struct {
    webkit_web_context_new_with_website_data_manager: *const fn (manager: Obj) callconv(.c) Obj,
    webkit_website_data_manager_get_type: *const fn () callconv(.c) usize,
    webkit_website_data_manager_new_ephemeral: *const fn () callconv(.c) Obj,
    webkit_javascript_result_get_js_value: *const fn (result: Obj) callconv(.c) Obj,
};

pub var api: Api = undefined;
pub var v6: Api6 = undefined;
pub var v4x: Api4x = undefined;
/// WebKitGTK 6.0 is loaded (else 4.1 or 4.0).
pub var six = false;
var state: enum { untried, loaded, missing } = .untried;

const name6 = "libwebkitgtk-6.0.so.4";
const names4x = [_][*:0]const u8{ "libwebkit2gtk-4.1.so.0", "libwebkit2gtk-4.0.so.37" };

/// Before GTK is chosen, for an app whose first window shows a page: picks
/// the GTK that has a WebKitGTK. GTK 4 is preferred, as it is for native UI,
/// but only with 6.0; many machines have GTK 4 and only 4.1.
pub fn prepare() void {
    if (!gtk.wantsThree() and open(name6) != null) return;
    for (names4x) |n| if (open(n) != null) {
        gtk.force3 = true;
        return;
    };
}

fn open(name: [*:0]const u8) ?*anyopaque {
    return std.c.dlopen(name, .{ .NOW = true });
}

/// Loads the WebKitGTK of the GTK that is loaded; false when there is none,
/// or when it is too old. GTK must be loaded first.
pub fn load() bool {
    switch (state) {
        .loaded => return true,
        .missing => return false,
        .untried => {},
    }
    state = .missing;
    if (gtk.v4) {
        const lib = open(name6) orelse return false;
        if (!table(Api, lib, &api) or !table(Api6, lib, &v6)) return false;
        six = true;
    } else {
        const lib = for (names4x) |n| {
            if (open(n)) |l| break l;
        } else return false;
        if (!table(Api, lib, &api) or !table(Api4x, lib, &v4x)) return false;
    }
    state = .loaded;
    return true;
}

fn table(comptime T: type, lib: *anyopaque, out: *T) bool {
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        const sym = std.c.dlsym(lib, name) orelse {
            std.log.warn("nanoui: WebKitGTK lacks {s} (2.40 or later is needed)", .{name});
            return false;
        };
        @field(out.*, name) = @ptrCast(@alignCast(sym));
    }
    return true;
}

// `WebKitUserContentInjectedFrames` and `WebKitUserScriptInjectionTime`.
pub const top_frame = 1;
pub const document_start = 0;
