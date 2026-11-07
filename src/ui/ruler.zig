//! A native, bounded ruler picker. Keep one RulerPicker per control and
//! give it a stable ui.key when it is in a list. No per-tick motion slots:
//! only visible marks and three clipped number rows are built each frame.
const std = @import("std");
const ui = @import("ui.zig");
const Model = @import("ruler_physics.zig").Model;

pub const Options = struct {
    width: f32 = 480,
    /// Integer bounds, 0 <= min <= max <= 9999.
    min: u16 = 0,
    max: u16 = 99,
    label: []const u8 = "Value",
};

pub const RulerPicker = struct {
    model: Model = .{},
    last_frame: u64 = std.math.maxInt(u64),
    clock: ?f64 = null,

    pub fn value(s: RulerPicker) i32 {
        return s.model.value();
    }

    /// Sets an integer target without discarding the spring's velocity.
    pub fn select(s: *RulerPicker, n: i32) void {
        s.model.select(@floatFromInt(n));
    }

    /// Returns whether the selected integer changed in this build.
    pub fn draw(s: *RulerPicker, c: *ui.Context, opts: Options) bool {
        const width = if (std.math.isFinite(opts.width)) std.math.clamp(opts.width, 160, 1920) else 480;
        const k = width / 480;
        const spacing = 17 * k;
        const root = ui.div(c).size(width, width).clip().control();
        defer root.end();
        const it = c.interact(root.index, .{ .focusable = true });
        c.adjustable(root.index, .{ .label = opts.label, .value = c.print("{d}", .{s.value()}) });
        const before = s.value();
        if (s.last_frame != c.frame) {
            s.last_frame = c.frame;
            const dt = if (s.clock) |t| @max(0, c.time - t) else 0;
            s.clock = c.time;
            s.model.min = @min(opts.min, 9999);
            s.model.max = @max(s.model.min, @min(opts.max, 9999));
            s.model.position = std.math.clamp(s.model.position, s.model.min, s.model.max);
            s.model.rolling = std.math.clamp(s.model.rolling, s.model.min, s.model.max);
            s.model.target = std.math.clamp(s.model.target, s.model.min, s.model.max);
            s.model.advance(dt, c.reduced_motion);
            if (c.input.pressed and c.input.button == .left and !c.input.secondary and it.hovered) s.model.begin(c.input.mouse.x);
            if (s.model.dragging) {
                c.wants_moves = true;
                if (c.input.down) {
                    s.model.drag(c.input.mouse.x, spacing, dt);
                } else {
                    const tap = !s.model.moved;
                    s.model.release();
                    if (tap) if (it.rect) |r| s.model.select(s.model.position + (c.input.mouse.x - r.x - width / 2) / spacing);
                }
            }
            if (it.a11y_step != 0) s.model.select(s.model.target + @as(f64, @floatFromInt(it.a11y_step)));
            if (it.focused) if (c.input.key) |key| switch (key) {
                .left => s.model.select(s.model.target - 1),
                .right => s.model.select(s.model.target + 1),
                else => {},
            };
        }
        if (s.model.moving()) c.animationFrame();
        // At rest (and while held still), no frame is requested.
        const center = width / 2;
        const first: i32 = @intFromFloat(@max(s.model.min, @floor(s.model.position - 15)));
        const last: i32 = @intFromFloat(@min(s.model.max, @ceil(s.model.position + 15)));
        var n = first;
        while (n <= last) : (n += 1) {
            const x = center + (@as(f32, @floatFromInt(n)) - @as(f32, @floatCast(s.model.position))) * spacing;
            const distance = @abs(x - center) / (240 * k);
            // Bottom-aligned, smoothly tapered envelope fixed to the indicator.
            const z = (x - center) / (130 * k);
            const h = (3 + 57 * @exp(-0.5 * z * z)) * k;
            const alpha = std.math.clamp((1 - distance) * 5, 0, 1);
            const mark = ui.div(c).absolute().offset(x - 3 * k, 270 * k - h).size(6 * k, h).roundedFull().bg(ui.Color.hex(0xd5d5d5)).opacity(alpha);
            mark.end();
        }
        // Stem + pill; the neck is an original tiny SVG joining their curves.
        const stem = ui.div(c).absolute().offset(center - 4 * k, 158 * k).size(8 * k, 172 * k).roundedFull().bg(.hex(0x000000)).shadow(.{ .color = .{ .a = 0.12 }, .blur = 12 * k, .x = 9 * k, .y = 14 * k });
        stem.end();
        {
            const neck = ui.div(c).absolute().offset(center - 16 * k, 168 * k);
            defer neck.end();
            _ = ui.svg(c, .{ .key = "ruler-neck", .bytes = neck_svg, .width = 32 * k, .height = 18 * k });
        }
        const pill = ui.div(c).absolute().offset(center - 48 * k, 110.5 * k).size(96 * k, 60 * k).rounded(30 * k).bg(.hex(0x000000)).shadow(.{ .color = .{ .a = 0.16 }, .blur = 14 * k, .x = 8 * k, .y = 14 * k });
        defer pill.end();
        const clip = ui.div(c).absolute().offset(8 * k, 6 * k).size(80 * k, 48 * k).clip();
        defer clip.end();
        const base: i32 = @intFromFloat(@floor(s.model.rolling));
        for (0..3) |i| {
            const digit = base + @as(i32, @intCast(i)) - 1;
            if (digit < s.model.min or digit > s.model.max) continue;
            const delta = @as(f32, @floatFromInt(digit)) - @as(f32, @floatCast(s.model.rolling));
            const row = ui.div(c).absolute().offset(0, delta * 35 * k).size(80 * k, 48 * k).center().opacity(@max(0, 1 - @abs(delta)));
            defer row.end();
            ui.text(c, if (digit == 0) "0" else c.print("{d:0>2}", .{@as(u32, @intCast(digit))}), .{ .size = (if (digit > 99) @as(f32, 19) else 25) * k, .weight = .bold, .rounded = true, .tabular = true, .color = .hex(0xffffff) });
        }
        const changed = s.value() != before;
        if (changed) c.changed = true;
        return changed;
    }
};

const neck_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 18"><path d="M0 0H32C20 0 20 8 20 18H12C12 8 12 0 0 0Z" fill="black"/></svg>
;
