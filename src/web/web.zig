//! A single canvas surface, driven by the JavaScript event loop. This does
//! not implement App/Window or the rest of the desktop platform interface.
const std = @import("std");
const ui = @import("../ui/ui.zig");
const gpu = @import("../ui/gpu.zig");
const text = @import("../ui/text.zig");
const frames = @import("../ui/frame.zig");
const webgpu = @import("../ui/webgpu.zig");
pub const Renderer = webgpu.Renderer;
pub const Target = webgpu.Target;

pub extern "nanoui_web" fn request_frame() void;
pub extern "nanoui_web" fn request_after(ms: f64) void;
pub extern "nanoui_web" fn now_ms() f64;
extern "nanoui_web" fn run_forever() noreturn;

pub var active: ?*Surface = null;
comptime {
    _ = @import("exports.zig");
}

/// Optional fallback fonts shipped with the web examples. Applications may
/// instead register their own embedded fonts with ui.registerFont.
pub fn registerBundledFonts() bool {
    return ui.registerFont(@embedFile("../ui/web_fonts/DejaVuSans.ttf")) and
        ui.registerFont(@embedFile("../ui/web_fonts/DejaVuSans-Bold.ttf"));
}

pub const Options = struct {
    allocator: std.mem.Allocator = std.heap.wasm_allocator,
    width: f32 = 420,
    height: f32 = 300,
    scale: f32 = 1,
    theme: ui.Theme = .light,
};

pub const Surface = struct {
    gpa: std.mem.Allocator,
    ctx: ui.Context,
    text: text.TextSystem,
    view: ui.View,
    renderer: webgpu.Renderer,
    instances: std.ArrayList(gpu.Instance) = .empty,
    size: ui.Size,
    scale: f32,
    theme: ui.Theme,
    dirty: bool = true,
    lost: bool = false,
    last_time: f64 = 0,
    start_time: f64 = 0,
    before_encode: ?gpu.BeforeEncode = null,
    after_frame_ctx: ?*anyopaque = null,
    after_frame: ?*const fn (?*anyopaque, *Surface) bool = null,
    frame_count: u32 = 0,
    key_text: [4]u8 = undefined,
    text_op: [1]@import("../ui/input.zig").TextOp = undefined,
    frame_log: ?ui.FrameLog = null,
    last_record: u32 = 0xffffffff,

    pub fn recordFrames(s: *Surface, allocator: std.mem.Allocator) !*ui.FrameLog {
        if (s.frame_log == null) s.frame_log = try ui.FrameLog.init(allocator, null);
        return &s.frame_log.?;
    }

    pub fn requestFrame(s: *Surface) void {
        s.dirty = true;
        if (!s.lost) request_frame();
    }

    pub fn frame(s: *Surface, milliseconds: f64) bool {
        if (s.lost or s.size.w <= 0 or s.size.h <= 0) return false;
        const time = milliseconds / 1000;
        const dt: f32 = if (s.last_time > 0) @floatCast(std.math.clamp(time - s.last_time, 0, 0.5)) else 1.0 / 60.0;
        s.last_time = time;
        s.text.setScale(s.scale);
        s.dirty = false;
        s.ctx.frame_time = dt;
        s.ctx.renderer = "WebGPU";
        const theme = s.ctx.theme_chosen orelse s.theme;
        const result = frames.run(&s.ctx, s.view, &s.text, &s.instances, s.size, s.scale, theme, dt, time - s.start_time);
        if (!std.meta.eql(theme, s.ctx.theme_chosen orelse s.theme)) s.dirty = true;
        const after_start = now_ms();
        if (s.after_frame) |f| if (f(s.after_frame_ctx, s)) {
            s.dirty = true;
        };
        const after_ms = now_ms() - after_start;
        s.renderer.before_encode = s.before_encode;
        s.renderer.gradients = s.ctx.gradients.items;
        s.renderer.textures = s.ctx.textures.items;
        s.renderer.sync(s.text.atlas.mask(), s.text.atlas.generation, s.text.images.pictures(), s.text.images.generation);
        const width: u32 = @intFromFloat(@round(s.size.w * s.scale));
        const height: u32 = @intFromFloat(@round(s.size.h * s.scale));
        const encode_start = now_ms();
        s.renderer.draw(s.instances.items, s.size, s.scale, s.ctx.theme.background, .canvas(width, height), time - s.start_time);
        if (s.frame_log) |*log| s.last_record = @intCast(log.append(.{
            .t = time,
            .kind = .input,
            .interval_ms = dt * 1000,
            .duration = dt,
            .dt = dt,
            .build_ms = s.ctx.stats.build_ms,
            .layout_ms = s.ctx.stats.layout_ms,
            .paint_ms = s.ctx.stats.paint_ms,
            .after_frame_ms = after_ms,
            .drawable_wait_ms = 0,
            .encode_ms = now_ms() - encode_start,
            .sync = false,
            .nodes = s.ctx.stats.nodes,
            .instances = s.ctx.stats.instances,
            .atlas_reset = s.text.atlas.reset_during_frame,
            .animating = s.ctx.animating,
        }));
        s.frame_count +%= 1;
        const more = s.dirty or s.ctx.animating or result.hot_changed or s.ctx.time_driven == .fast;
        if (!more) {
            s.last_time = 0;
            if (s.ctx.frame_in) |delay| request_after(delay * 1000) else if (s.ctx.time_driven == .slow) request_after(1000.0 / 24.0);
        }
        return more;
    }

    pub fn setDevice(s: *Surface) !void {
        s.renderer.deinit();
        s.renderer = try .init();
        s.text.images.invalidateAtlas();
        s.lost = false;
        s.requestFrame();
    }

    pub fn deinit(s: *Surface) void {
        if (active == s) active = null;
        if (s.frame_log) |*log| log.deinit();
        s.renderer.deinit();
        s.instances.deinit(s.gpa);
        s.ctx.deinit();
        s.text.deinit();
        s.gpa.destroy(s);
    }
};

/// Mount one view. Its state must outlive the surface; `run` preserves main's
/// stack by unwinding to JavaScript without running Zig's deferred teardown.
pub fn mount(view: ui.View, options: Options) !*Surface {
    if (active != null) return error.AlreadyMounted;
    const s = try options.allocator.create(Surface);
    errdefer options.allocator.destroy(s);
    s.* = .{
        .gpa = options.allocator,
        .ctx = undefined,
        .text = .init(options.allocator),
        .view = view,
        .renderer = try .init(),
        .size = .{ .w = options.width, .h = options.height },
        .scale = options.scale,
        .theme = options.theme,
        .start_time = now_ms() / 1000,
    };
    s.ctx = .init(s.gpa, &s.text);
    s.text.images.sink = .{ .ctx = &s.renderer, .upload = webgpu.Renderer.uploadImage };
    s.ctx.waker = .{ .ctx = s, .wake = wake };
    active = s;
    s.requestFrame();
    return s;
}

fn wake(ctx: *anyopaque) void {
    const s: *Surface = @ptrCast(@alignCast(ctx));
    s.requestFrame();
}

pub fn run() noreturn {
    request_frame();
    run_forever();
}
