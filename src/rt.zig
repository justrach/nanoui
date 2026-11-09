//! Precompiled runtime library (`libnanoui-rt.a`).
//!
//! Built once as a static library linked to the `nanoui` module, so editing an
//! app's view (`src/app.zig`) does not re-analyze or re-codegen the windowing
//! backend, GPU renderer, text shaper, layout/paint passes, or hash maps.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui.zig");
const ui = nanoui.ui;
const types = @import("ui/types.zig");
const Content = @import("ui/content.zig").Content;
const hooks = @import("ui/context_hooks.zig");

pub const desktop = (builtin.os.tag == .macos or builtin.os.tag == .linux or builtin.os.tag == .windows) and !builtin.abi.isAndroid();
pub const enabled = desktop and !@import("build_options").in_rt and !builtin.is_test;

comptime {
    if (desktop and @import("build_options").in_rt) {
        @export(&nanoui_rt_panic, .{ .name = "nanoui_rt_panic" });
        @export(&nanoui_rt_app_create, .{ .name = "nanoui_rt_app_create" });
        @export(&nanoui_rt_app_create_minimal, .{ .name = "nanoui_rt_app_create_minimal" });
        @export(&nanoui_rt_app_destroy, .{ .name = "nanoui_rt_app_destroy" });
        @export(&nanoui_rt_app_new_window, .{ .name = "nanoui_rt_app_new_window" });
        @export(&nanoui_rt_app_run, .{ .name = "nanoui_rt_app_run" });
        @export(&nanoui_rt_ctx_open, .{ .name = "nanoui_rt_ctx_open" });
        @export(&nanoui_rt_ctx_end, .{ .name = "nanoui_rt_ctx_end" });
        @export(&nanoui_rt_ctx_leaf, .{ .name = "nanoui_rt_ctx_leaf" });
        @export(&nanoui_rt_ctx_interact, .{ .name = "nanoui_rt_ctx_interact" });
        @export(&nanoui_rt_ctx_animate, .{ .name = "nanoui_rt_ctx_animate" });
        @export(&nanoui_rt_ctx_alloc, .{ .name = "nanoui_rt_ctx_alloc" });
        @export(&nanoui_rt_ctx_print_i64, .{ .name = "nanoui_rt_ctx_print_i64" });
        @export(&nanoui_rt_widget_button, .{ .name = "nanoui_rt_widget_button" });
        @export(&nanoui_rt_tester_init, .{ .name = "nanoui_rt_tester_init" });
        @export(&nanoui_rt_tester_deinit, .{ .name = "nanoui_rt_tester_deinit" });
        @export(&nanoui_rt_tester_frame, .{ .name = "nanoui_rt_tester_frame" });
    }
}

var rt_safe_alloc: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
var rt_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var rt_threaded: std.Io.Threaded = undefined;
var rt_env_map: std.process.Environ.Map = undefined;
var rt_minimal_active: bool = false;

pub fn createFromMinimal(min: std.process.Init.Minimal, options: nanoui.AppOptions) !*nanoui.App {
    const gpa = switch (builtin.mode) {
        .debug, .safe => rt_safe_alloc.allocator(),
        .fast, .small => std.heap.c_allocator,
    };
    rt_arena = .init(std.heap.page_allocator);
    rt_threaded = .init(gpa, .{
        .argv0 = .init(min.args),
        .environ = min.environ,
    });
    rt_env_map = try std.process.Environ.createMap(min.environ, gpa);
    const preopens = try std.process.Preopens.init(rt_arena.allocator());
    rt_minimal_active = true;
    return nanoui.App.createImpl(.{
        .minimal = min,
        .arena = &rt_arena,
        .gpa = gpa,
        .io = rt_threaded.io(),
        .environ_map = &rt_env_map,
        .preopens = preopens,
    }, options);
}

fn nanoui_rt_panic(ptr: [*]const u8, len: usize, addr: usize, has_addr: u8) callconv(.c) noreturn {
    std.debug.defaultPanic(ptr[0..len], if (has_addr != 0) addr else null);
}

fn nanoui_rt_app_create(init_ptr: *const std.process.Init, opts_ptr: *const nanoui.AppOptions, out: **nanoui.App) callconv(.c) u8 {
    if (std.debug.default_enable_segfault_handler) std.debug.attachSegfaultHandler();
    out.* = nanoui.App.createImpl(init_ptr.*, opts_ptr.*) catch return 1;
    return 0;
}

fn nanoui_rt_app_create_minimal(min_ptr: *const std.process.Init.Minimal, opts_ptr: *const nanoui.AppOptions, out: **nanoui.App) callconv(.c) u8 {
    if (std.debug.default_enable_segfault_handler) std.debug.attachSegfaultHandler();
    out.* = createFromMinimal(min_ptr.*, opts_ptr.*) catch return 1;
    return 0;
}

fn nanoui_rt_app_destroy(app: *nanoui.App) callconv(.c) void {
    app.destroyImpl();
    if (rt_minimal_active) {
        rt_minimal_active = false;
        rt_env_map.deinit();
        rt_threaded.deinit();
        rt_arena.deinit();
        if (builtin.mode == .debug or builtin.mode == .safe) _ = rt_safe_alloc.deinit();
    }
}

fn nanoui_rt_app_new_window(app: *nanoui.App, opts_ptr: *const nanoui.WindowOptions, out: **nanoui.Window) callconv(.c) u8 {
    out.* = app.newWindowImpl(opts_ptr.*) catch return 1;
    return 0;
}

fn nanoui_rt_app_run(app: *nanoui.App) callconv(.c) u8 {
    app.runImpl() catch return 1;
    return 0;
}

fn nanoui_rt_ctx_open(c: *ui.Context, style_ptr: *const types.Style, key_ptr: ?[*]const u8, key_len: usize) callconv(.c) u32 {
    const k: ?[]const u8 = if (key_ptr) |p| p[0..key_len] else null;
    return c.openImpl(style_ptr.*, k);
}

fn nanoui_rt_ctx_end(c: *ui.Context) callconv(.c) void {
    c.endImpl();
}

fn nanoui_rt_ctx_leaf(c: *ui.Context, style_ptr: *const types.Style, content_ptr: *const Content, key_ptr: ?[*]const u8, key_len: usize) callconv(.c) u32 {
    const k: ?[]const u8 = if (key_ptr) |p| p[0..key_len] else null;
    return c.leafImpl(style_ptr.*, content_ptr.*, k);
}

fn nanoui_rt_ctx_interact(c: *ui.Context, index: u32, opts_ptr: *const hooks.InteractOptions, out: *ui.Interaction) callconv(.c) void {
    out.* = hooks.interactImpl(c, index, opts_ptr.*);
}

fn nanoui_rt_ctx_animate(c: *ui.Context, id: u64, salt: u32, target: f32, speed: f32) callconv(.c) f32 {
    return hooks.animateImpl(c, id, salt, target, speed);
}

fn nanoui_rt_ctx_alloc(c: *ui.Context, out: *std.mem.Allocator) callconv(.c) void {
    out.* = c.arena.allocator();
}

fn nanoui_rt_ctx_print_i64(c: *ui.Context, val: i64, out_ptr: *[*]const u8, out_len: *usize) callconv(.c) void {
    const s = std.fmt.allocPrint(c.arena.allocator(), "{d}", .{val}) catch "…";
    out_ptr.* = s.ptr;
    out_len.* = s.len;
}

fn nanoui_rt_widget_button(c: *ui.Context, lbl_ptr: [*]const u8, lbl_len: usize, opts_ptr: *const ui.ButtonOptions, out: *ui.Interaction) callconv(.c) void {
    out.* = @import("ui/widgets.zig").buttonImpl(c, lbl_ptr[0..lbl_len], opts_ptr.*);
}

fn nanoui_rt_tester_init(t: *ui.Tester, gpa_ptr: *const std.mem.Allocator, view_ptr: *const ui.View, opts_ptr: *const ui.TesterOptions) callconv(.c) u8 {
    t.initImpl(gpa_ptr.*, view_ptr.*, opts_ptr.*) catch return 1;
    return 0;
}

fn nanoui_rt_tester_deinit(t: *ui.Tester) callconv(.c) void {
    t.deinitImpl();
}

fn nanoui_rt_tester_frame(t: *ui.Tester) callconv(.c) void {
    t.frameImpl();
}
