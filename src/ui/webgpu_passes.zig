//! Frame runs, opacity groups and backdrop splits, matching Metal's order.
const api = @import("webgpu_api.zig");
const gpu = @import("gpu.zig");
const common = @import("webgpu_target.zig");
const Color = @import("types.zig").Color;
const damage = @import("webgpu_damage.zig");

pub fn encode(r: anytype, encoder: api.Handle, instances: []const gpu.Instance, target: common.Target, clear: Color, start: usize) void {
    encodeRange(r, encoder, instances, target, clear, start, instances.len, 0, false);
}

pub fn encodeDamage(r: anytype, encoder: api.Handle, instances: []const gpu.Instance, target: common.Target, scale: f32, regions: []const damage.Rect) void {
    const pass = begin(r, encoder, target, null);
    for (regions) |rect| {
        api.pass_scissor(pass, rect.x, rect.y, rect.w, rect.h);
        api.pass_draw(pass, 4, 1, @intCast(instances.len));
        run(r, pass, instances, 0, instances.len, target, .{ .rect = rect, .scale = scale });
    }
    api.pass_end(pass);
}

const Clip = struct { rect: damage.Rect, scale: f32 };
fn encodeRange(r: anytype, encoder: api.Handle, instances: []const gpu.Instance, target: common.Target, clear: Color, start: usize, limit: usize, depth: usize, skip_glass: bool) void {
    var first = start;
    var cleared = false;
    while (true) {
        var end = first;
        while (end < limit and instances[end].kind != gpu.Kind.glass and instances[end].kind != gpu.Kind.layer_begin) : (end += 1) {}
        if (end > first or !cleared) {
            const enc = begin(r, encoder, target, if (cleared) null else clear);
            run(r, enc, instances, first, end, target, null);
            api.pass_end(enc);
            cleared = true;
        }
        if (end == limit) return;
        if (instances[end].kind == gpu.Kind.glass) {
            if (!skip_glass) r.extra.pane(r, encoder, target, instances[end], end);
            first = end + 1;
            continue;
        }
        const close = gpu.groupEnd(instances, end) orelse {
            first = end + 1;
            continue;
        };
        if (close >= limit) return;
        first = close + 1;
        if (close == end + 1) continue;
        const masked = instances[close].border_color[2] > 0 or instances[close].border_color[3] > 0;
        // Ordinary groups shade their own glass into the parent first.
        // Nested groups own their backdrops; a scroll mask shades into its layer.
        if (!masked) {
            var at = end + 1;
            while (at < close) : (at += 1) {
                if (instances[at].kind == gpu.Kind.layer_begin) {
                    at = gpu.groupEnd(instances, at) orelse break;
                    continue;
                }
                if (instances[at].kind == gpu.Kind.glass) r.extra.pane(r, encoder, target, instances[at], at);
            }
        }
        const layer = r.groupTarget(depth, target);
        encodeRange(r, encoder, instances, layer, Color.transparent, end + 1, close, depth + 1, !masked);
        const comp = begin(r, encoder, target, null);
        api.pass_set_bind_group(comp, 1, r.sampleGroup(layer.view), 0xffffffff);
        api.pass_draw(comp, 4, 1, @intCast(close));
        api.pass_end(comp);
    }
}
fn begin(r: anytype, encoder: api.Handle, target: common.Target, clear: ?Color) api.Handle {
    const c = clear orelse Color.transparent;
    const pass = api.pass_begin(encoder, target.view, if (clear == null) 1 else 0, c.r, c.g, c.b, if (c.a == 0) 0 else 1);
    api.pass_set_pipeline(pass, r.pipelines[0][@backingInt(target.format)]);
    api.pass_set_bind_group(pass, 0, r.group, 0);
    api.pass_set_bind_group(pass, 1, r.sampleGroup(r.images_view), 0xffffffff);
    return pass;
}
fn run(r: anytype, pass: api.Handle, instances: []const gpu.Instance, first: usize, end: usize, target: common.Target, clip: ?Clip) void {
    const format = target.format;
    var from = first;
    while (from < end) {
        const kind = instances[from].kind;
        if (kind == gpu.Kind.glass or kind == gpu.Kind.layer_begin or kind == gpu.Kind.layer_end) {
            from += 1;
            continue;
        }
        if (kind == gpu.Kind.texture) {
            if (clip) |c| {
                const b = damage.bounds(&instances[from], target, c.scale);
                if (b == null or !c.rect.intersects(b.?)) {
                    from += 1;
                    continue;
                }
            }
            if (r.frame_textures.get(@intFromFloat(instances[from].border_width))) |slot| {
                api.pass_set_pipeline(pass, r.pipelines[if (slot.external != 0) @as(usize, 5) else 0][@backingInt(format)]);
                if (slot.external != 0) {
                    const group = api.bind_group_create(r.external_layout, &.{.{ .binding = 1, .kind = 3, .resource = slot.external }}, 1);
                    api.pass_set_bind_group(pass, 1, group, 0xffffffff);
                    api.release(group);
                } else api.pass_set_bind_group(pass, 1, r.sampleGroup(slot.view), 0xffffffff);
                api.pass_draw(pass, 4, 1, @intCast(from));
                api.pass_set_pipeline(pass, r.pipelines[0][@backingInt(format)]);
                api.pass_set_bind_group(pass, 1, r.sampleGroup(r.images_view), 0xffffffff);
            }
            from += 1;
            continue;
        }
        if (kind == gpu.Kind.hole) {
            api.pass_set_pipeline(pass, r.pipelines[1][@backingInt(format)]);
            api.pass_draw(pass, 4, 1, @intCast(from));
            api.pass_set_pipeline(pass, r.pipelines[0][@backingInt(format)]);
            from += 1;
            continue;
        }
        var last = from + 1;
        while (last < end and instances[last].kind <= gpu.Kind.triangle and instances[last].kind != gpu.Kind.glass) : (last += 1) {}
        api.pass_draw(pass, 4, @intCast(last - from), @intCast(from));
        from = last;
    }
}
