//! Paint-layer entrances, reversible hover fades, and bounded loader ticks.
//! Call an entrance immediately before its box (ui.key first for lists).
const std = @import("std");
const Context = @import("../context.zig").Context;
const Color = @import("../types.zig").Color;
const motion = @import("motion.zig");
const catalog = @import("catalog.zig");
const effects = @import("effects.zig");

pub fn fadeIn(c: *Context) motion.Frame {
    return motion.frame(c, catalog.fade_in.animate(.{ .opacity = 0, .y = 4 }, .{ .opacity = 1, .y = 0 }));
}

pub fn settleDown(c: *Context) motion.Frame {
    return motion.frame(c, catalog.fade_in.animate(.{ .opacity = 0, .y = -10 }, .{ .opacity = 1, .y = 0 }));
}

pub fn fadeQuick(c: *Context) motion.Frame {
    return motion.frame(c, catalog.fade_quick.animate(.{ .opacity = 0 }, .{ .opacity = 1 }));
}

/// Matches GPUI's fade/translation approximation, not an added scale effect.
pub fn menuIn(c: *Context) motion.Frame {
    return motion.frame(c, catalog.menu_in.animate(.{ .opacity = 0.3, .y = -2 }, .{ .opacity = 1, .y = 0 }));
}

/// Caller-owned eased closing progress cannot replay on a keyed remount.
/// Pass catalog.menu_out.progress(elapsed / catalog.menu_out.total()).
pub fn menuOut(c: *Context, progress: f32) motion.Frame {
    const t = if (c.reduced_motion) 1 else std.math.clamp(progress, 0, 1);
    if (t < 1) c.animationFrame();
    return .{ .opacity = 1 - t, .y = -2 * t, .animating = t < 1 };
}

pub fn dialogIn(c: *Context) motion.Frame {
    return motion.frame(c, catalog.dialog_in.animate(.{ .opacity = 0, .y = 2 }, .{ .opacity = 1, .y = 0 }));
}

pub fn splashOut(c: *Context) motion.Frame {
    return motion.frame(c, catalog.splash_out.animate(.{ .opacity = 1, .y = 0 }, .{ .opacity = 0, .y = -6 }));
}

/// A key's 150ms hover progress, re-anchored when its target reverses.
/// Unread for a frame means unmounted: a remount starts unhovered.
pub fn hoverT(c: *Context, key: []const u8, hovered: bool) f32 {
    return blend(c, key, "hover:", hovered, catalog.hover_fade, true);
}

/// Slower 320ms reveal, retained across cached/skipped paints.
pub fn revealT(c: *Context, key: []const u8, hovered: bool) f32 {
    return blend(c, key, "reveal:", hovered, catalog.hover_reveal, false);
}

pub fn resetReveal(c: *Context, key: []const u8) void {
    _ = c.motion.map.remove(scoped(c, key, "reveal:"));
}

pub fn hoverBlend(c: *Context, key: []const u8, hovered: bool, rest: Color, hover: Color) Color {
    return effects.mix(rest, hover, hoverT(c, key, hovered));
}

fn scoped(c: *Context, key: []const u8, prefix: []const u8) u64 {
    var hash = std.hash.Wyhash.init(c.peekId(null));
    hash.update("motion:catalog:");
    hash.update(prefix);
    hash.update(key);
    return hash.final();
}

fn blend(c: *Context, key: []const u8, prefix: []const u8, hovered: bool, spec: catalog.MotionSpec, prune: bool) f32 {
    const id = scoped(c, key, prefix);
    const previous = if (c.motion.map.getPtr(id)) |s| s.seen else c.frame;
    const got = c.motion.get(c.gpa, id, c.frame) orelse return if (hovered) 1 else 0;
    const channel = &got.state.ch[0];
    if (got.fresh or (prune and c.frame > previous + 1)) channel.* = .at(0);
    const target: f32 = if (hovered) 1 else 0;
    if (c.reduced_motion) {
        channel.jump(target);
    } else {
        channel.retarget(target, spec.transition(), 0, c.time);
        channel.sample(c.time);
        if (channel.moving) c.animationFrame();
    }
    return @floatCast(channel.value);
}

pub const PulseOptions = struct {
    /// Coarse cell waves need 15Hz instead of 30Hz.
    slow: bool = false,
    /// Pass window focus explicitly: the toolkit owns no app-global focus.
    active: bool = true,
};

/// Mount-scoped scheduling: call only while painting active cosmetic motion.
/// 33ms foreground / 99ms background (twice that for slow cell loaders).
/// No lease thread or idle polling survives an unmounted loader.
pub fn pulseLease(c: *Context, options: PulseOptions) void {
    if (c.reduced_motion) return;
    const stride: f32 = if (options.slow) 2 else 1;
    const background: f32 = if (options.active) 1 else 3;
    c.frameIn(0.033 * stride * background);
}

/// Raw repeating phase. Cells share the Context's epoch, never per-cell
/// mount times. Use phaseAt with a common elapsed clock across windows.
pub fn pulseDelta(c: *Context, spec: catalog.MotionSpec, options: PulseOptions) f32 {
    if (c.reduced_motion or spec.total() <= 0) return 0;
    pulseLease(c, options);
    return phaseAt(spec, c.time);
}

pub fn phaseAt(spec: catalog.MotionSpec, elapsed: f64) f32 {
    const period = spec.total();
    if (period <= 0) return 0;
    return @floatCast(@mod(elapsed, period) / period);
}
