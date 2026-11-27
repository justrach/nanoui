//! Host events enter the single-threaded UI instance here.
const web = @import("web.zig");
const ui = @import("../ui/ui.zig");
const std = @import("std");
const Key = @import("../ui/input.zig").Key;

export fn nanoui_web_frame(time: f64) u32 {
    const s = web.active orelse return 0;
    return @intFromBool(s.frame(time));
}

export fn nanoui_web_resize(w: u32, h: u32, scale: f32) void {
    const s = web.active orelse return;
    if (scale <= 0) return;
    s.size = .{ .w = @as(f32, @floatFromInt(w)) / scale, .h = @as(f32, @floatFromInt(h)) / scale };
    s.scale = scale;
    s.requestFrame();
}

export fn nanoui_web_pointer(kind: u32, x: f32, y: f32, button: u32, mods: u32, clicks: u32) void {
    const s = web.active orelse return;
    const c = &s.ctx;
    c.input.mouse = .{ .x = x, .y = y };
    c.input.shift = mods & 1 != 0;
    c.input.ctrl = mods & 2 != 0;
    c.input.alt = mods & 4 != 0;
    c.input.cmd = mods & 8 != 0;
    c.updateHot();
    if (kind == 1) {
        c.input.button = switch (button) {
            1 => .middle,
            2 => .right,
            else => .left,
        };
        c.input.click_count = @intCast(std.math.clamp(clicks, 1, 3));
        if (button == 2) c.secondaryDown() else c.pointerDown();
    } else if (kind == 2) c.pointerUp() else if (kind == 3) {
        c.input.down = false;
        c.input.pressed = false;
        c.input.released = false;
        c.input.pointer_cancelled = true;
        c.active = 0;
        ui.cancelDrag(c);
    }
    s.requestFrame();
}

export fn nanoui_web_pinch(x: f32, y: f32, scale: f32, dx: f32, dy: f32) void {
    const s = web.active orelse return;
    if (!(scale > 0) or !@import("std").math.isFinite(scale)) return;
    const c = &s.ctx;
    c.input.mouse = .{ .x = x, .y = y };
    c.input.zoom = scale;
    c.input.pan = .{ .x = dx, .y = dy };
    c.updateHot();
    s.requestFrame();
}

/// Send at most one keyboard edge per frame. Kind 3 updates modifiers
/// alone. `code` is a Shortcut key and `typed` is the actual character.
export fn nanoui_web_key(kind: u32, code: u32, mods: u32, typed: u32) void {
    const s = web.active orelse return;
    const c = &s.ctx;
    c.key_up_supported = true;
    if (kind == 2) {
        c.input.releaseKeys();
        s.requestFrame();
        return;
    }
    if (code > 0x10ffff or typed > 0x10ffff) return;
    const Sc = ui.Shortcut;
    const shortcut: Sc = .{
        .key = Sc.keyOf(@intCast(code)),
        .shift = mods & 1 != 0,
        .ctrl = mods & 2 != 0,
        .alt = mods & 4 != 0,
        .cmd = mods & 8 != 0,
    };
    c.input.mods_changed = c.input.mods_changed or c.input.shift != shortcut.shift or
        c.input.ctrl != shortcut.ctrl or c.input.alt != shortcut.alt or c.input.cmd != shortcut.cmd;
    c.input.shift = shortcut.shift;
    c.input.ctrl = shortcut.ctrl;
    c.input.alt = shortcut.alt;
    c.input.cmd = shortcut.cmd;
    if (kind == 1) {
        c.input.queueKeyUp(c.gpa, shortcut);
    } else if (kind == 0) {
        c.input.repeat = mods & 16 != 0;
        if (c.focused_text == null or (shortcut.ctrl and !shortcut.alt and (shortcut.key == 'z' or shortcut.key == 'y')))
            c.input.shortcut = shortcut;
        c.input.key = switch (shortcut.key) {
            Sc.backspace => .backspace,
            Sc.forward_delete => .delete,
            Sc.left => .left,
            Sc.right => .right,
            Sc.up => .up,
            Sc.down => .down,
            Sc.home => .home,
            Sc.end => .end,
            Sc.enter => .enter,
            Sc.tab => .tab,
            Sc.escape => .escape,
            Sc.page_up => .page_up,
            Sc.page_down => .page_down,
            Sc.f(1)...Sc.f(12) => @fromBackingInt(@intCast(@backingInt(Key.f1) + shortcut.key - Sc.f(1))),
            else => null,
        };
        if (c.focused_text != null) {
            if (shortcut.ctrl and !shortcut.alt and !shortcut.shift and shortcut.key == 'a') {
                s.text_op[0] = .{ .command = .select_all };
                c.input.ops = &s.text_op;
            } else if (typed != 0 and !shortcut.ctrl) {
                const len = std.unicode.utf8Encode(@intCast(typed), &s.key_text) catch 0;
                c.input.chars = s.key_text[0..len];
            }
        }
    }
    s.requestFrame();
}

export fn nanoui_web_wheel(x: f32, y: f32, dx: f32, dy: f32) void {
    const s = web.active orelse return;
    s.ctx.input.mouse = .{ .x = x, .y = y };
    s.ctx.input.precise = true;
    if (!s.ctx.applyScroll(dy)) s.ctx.input.scroll.y += dy;
    s.ctx.input.scroll.x += dx;
    s.requestFrame();
}

export fn nanoui_web_theme_changed() void {
    if (web.active) |s| s.refreshTheme();
}
export fn nanoui_web_device_lost() void {
    if (web.active) |s| s.lost = true;
}
export fn nanoui_web_cancel_input() void {
    const s = web.active orelse return;
    const mouse = s.ctx.input.mouse;
    nanoui_web_pointer(3, mouse.x, mouse.y, 0, 0, 1);
    s.ctx.input.releaseKeys();
}
export fn nanoui_web_use_cpu() void {
    if (web.active) |s| s.useCpu();
}
export fn nanoui_web_device() u32 {
    const s = web.active orelse return 0;
    s.setDevice() catch return 1;
    return 0;
}
export fn nanoui_web_destroy() void {
    if (web.active) |s| {
        if (snapshot) |pixels| pixels.deinit(s.gpa);
        snapshot = null;
        s.deinit();
    }
}
export fn nanoui_web_frames() u32 {
    return if (web.active) |s| s.frame_count else 0;
}

// Offscreen CPU reference for the browser harness; never presents a window.
var snapshot: ?@import("../ui/gpu.zig").Pixels = null;
export fn nanoui_web_snapshot() usize {
    const s = web.active orelse return 0;
    if (snapshot) |pixels| pixels.deinit(s.gpa);
    snapshot = null;
    const width: usize = @intFromFloat(@round(s.size.w * s.scale));
    const height: usize = @intFromFloat(@round(s.size.h * s.scale));
    const pixels = s.gpa.alloc(u8, width * height * 4) catch return 0;
    snapshot = .{ .bytes = pixels, .width = width, .height = height };
    var pictures = s.text.images.pictures();
    // Sink-backed images keep decoded sources, not a duplicate CPU atlas.
    var mirror: ?[]u8 = null;
    defer if (mirror) |bytes| s.gpa.free(bytes);
    if (pictures.size == 0 and s.text.images.entries.count() > 0) {
        const side = s.text.images.side;
        const bytes = s.gpa.alloc(u8, side * side * 4) catch return 0;
        mirror = bytes;
        @memset(bytes, 0);
        var it = s.text.images.entries.iterator();
        while (it.next()) |entry| {
            const placed = entry.value_ptr.entry orelse continue;
            const decoded = (s.text.images.decoded.get(entry.key_ptr.*) orelse continue) orelse continue;
            const x: usize = @intFromFloat(@round(placed.uv[0] * @as(f32, @floatFromInt(side))));
            const y: usize = @intFromFloat(@round(placed.uv[1] * @as(f32, @floatFromInt(side))));
            for (0..decoded.h) |row| @memcpy(bytes[((y + row) * side + x) * 4 ..][0 .. decoded.w * 4], decoded.bgra[row * decoded.w * 4 ..][0 .. decoded.w * 4]);
        }
        pictures = .{ .pixels = bytes, .size = side };
    }
    pictures.textures = s.ctx.textures.items;
    pictures.gradients = s.ctx.gradients.items;
    @import("../ui/raster.zig").draw(snapshot.?, s.instances.items, s.text.atlas.mask(), pictures, s.scale, s.theme.background);
    return @intFromPtr(pixels.ptr);
}

export fn nanoui_web_record_frames() u32 {
    const s = web.active orelse return 1;
    _ = s.recordFrames(s.gpa) catch return 1;
    return 0;
}
export fn nanoui_web_last_record() u32 {
    return if (web.active) |s| s.last_record else 0xffffffff;
}
export fn nanoui_web_gpu_time(index: u32, ms: f64) void {
    if (web.active) |s| if (s.frame_log) |*log| log.setGpuMs(index, ms);
}
export fn nanoui_web_log_count() u32 {
    const s = web.active orelse return 0;
    return if (s.frame_log) |*log| @intCast(log.records.items.len) else 0;
}
export fn nanoui_web_log_value(index: u32, metric: u32) f64 {
    const s = web.active orelse return 0;
    const log = &(s.frame_log orelse return 0);
    if (index >= log.records.items.len) return 0;
    const r = log.records.items[index];
    return switch (metric) {
        0 => r.build_ms,
        1 => r.layout_ms,
        2 => r.paint_ms,
        3 => r.encode_ms,
        4 => r.gpu_ms,
        5 => @floatFromInt(r.instances),
        else => 0,
    };
}
