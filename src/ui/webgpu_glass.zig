//! Glass backdrop passes. Uniform slots are unique until submission;
//! queue.writeBuffer cannot change a uniform between passes of one encoder.
const api = @import("webgpu_api.zig");
const common = @import("webgpu_target.zig");
const gpu = @import("gpu.zig");
const glass = @import("glass.zig");
pub const Glass = struct {
    a: ?common.Target = null,
    b: ?common.Target = null,
    pub fn deinit(g: *Glass) void {
        if (g.a) |a| a.deinit();
        if (g.b) |b| b.deinit();
        g.* = .{};
    }
    pub fn prepare(g: *Glass, r: anytype, instances: []const gpu.Instance, target: common.Target, scale: f32) void {
        var w: u32 = 1;
        var h: u32 = 1;
        var used = false;
        for (instances) |i| if (i.kind == gpu.Kind.glass) {
            if (glass.backdropFor(i, scale, target.width, target.height)) |b| {
                w = @max(w, @as(u32, @intCast(b.w)));
                h = @max(h, @as(u32, @intCast(b.h)));
                used = true;
            }
        };
        if (!used) return;
        if (g.a == null or g.a.?.width < w or g.a.?.height < h or g.a.?.format != target.format) {
            r.clearSamples();
            g.deinit();
            g.a = common.Target.init(w, h, target.format) catch return;
            g.b = common.Target.init(w, h, target.format) catch return;
        }
    }
    pub fn pane(g: *Glass, r: anytype, encoder: api.Handle, target: common.Target, inst: gpu.Instance, index: usize) void {
        const b = glass.backdropFor(inst, r.frame_params.scale, target.width, target.height) orelse return;
        const w: u32 = @intCast(b.w);
        const h: u32 = @intCast(b.h);
        if (g.a == null or g.a.?.width < w or g.a.?.height < h or g.a.?.format != target.format) {
            r.clearSamples();
            g.deinit();
            g.a = common.Target.init(w, h, target.format) catch return;
            g.b = common.Target.init(w, h, target.format) catch return;
        }
        var params = r.frame_params;
        params.area = b.area;
        params.down = @floatFromInt(b.down);
        params.size = .{ @floatFromInt(b.w), @floatFromInt(b.h) };
        params.sigma = b.sigma;
        params.progressive = b.progressive;
        params.radius = b.radius;
        params.origin = .{ @floatFromInt(b.area[0]), @floatFromInt(b.area[1]) };
        // Textures may be larger than the pane's valid backdrop; scissor via
        // viewport to the valid w/h keeps edge texels from another pane out.
        pass(r, encoder, g.a.?, target.view, 3, params, w, h);
        if (b.sigma > 0) {
            params.dir = .{ 1, 0 };
            pass(r, encoder, g.b.?, g.a.?.view, 4, params, w, h);
            params.dir = .{ 0, 1 };
            pass(r, encoder, g.a.?, g.b.?.view, 4, params, w, h);
        }
        const slot = r.parameterSlot(params);
        const enc = api.pass_begin(encoder, target.view, 1, 0, 0, 0, 0);
        api.pass_set_pipeline(enc, r.pipelines[2][@backingInt(target.format)]);
        api.pass_set_bind_group(enc, 0, r.group, slot);
        api.pass_set_bind_group(enc, 1, r.sampleGroup(g.a.?.view), 0xffffffff);
        api.pass_draw(enc, 4, 1, @intCast(index));
        api.pass_end(enc);
    }
    fn pass(r: anytype, encoder: api.Handle, target: common.Target, source: api.Handle, kind: usize, params: common.Params, w: u32, h: u32) void {
        const slot = r.parameterSlot(params);
        const enc = api.pass_begin(encoder, target.view, 0, 0, 0, 0, 0);
        api.pass_viewport(enc, w, h);
        api.pass_set_pipeline(enc, r.pipelines[kind][@backingInt(target.format)]);
        api.pass_set_bind_group(enc, 0, r.group, slot);
        const group = api.bind_group_create(r.sample_layout, &.{.{ .binding = 0, .kind = 1, .resource = source }}, 1);
        api.pass_set_bind_group(enc, 1, group, 0xffffffff);
        api.release(group);
        api.pass_draw(enc, 3, 1, 0);
        api.pass_end(enc);
    }
};
