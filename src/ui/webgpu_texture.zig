//! App textures on the shared device: uploaded BGRA, borrowed GPUTextures,
//! transient external textures, and color/LUT passes before UI composition.
const std = @import("std");
const gpu = @import("gpu.zig");
const api = @import("webgpu_api.zig");
const common = @import("webgpu_target.zig");
const color = @import("color.zig");
const LutCache = @import("webgpu_lut.zig").Cache;
const post_source = @embedFile("texture_post.wgsl");

pub const Slot = struct {
    texture: api.Handle = 0,
    source_view: api.Handle = 0,
    input: api.Handle = 0,
    input_serial: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    output: ?common.Target = null,
    view: api.Handle = 0,
    external: api.Handle = 0,
    uniform: api.Handle = 0,
    group: api.Handle = 0,
    group_version: u64 = 0,
    group_views: [4]api.Handle = .{ 0, 0, 0, 0 },
    fn clear(s: *Slot) void {
        for ([_]api.Handle{ s.group, s.uniform, s.source_view, s.texture }) |h| if (h != 0) api.release(h);
        if (s.output) |out| out.deinit();
        s.* = .{};
    }
};
pub const Textures = struct {
    slots: std.ArrayList(Slot) = .empty,
    luts: LutCache = .{},
    shader: api.Handle = 0,
    layout: api.Handle = 0,
    pipeline: api.Handle = 0,
    external_pipeline: api.Handle = 0,
    point: api.Handle = 0,
    linear: api.Handle = 0,
    pub fn deinit(t: *Textures) void {
        for (t.slots.items) |*s| s.clear();
        t.slots.deinit(std.heap.wasm_allocator);
        t.luts.deinit();
        for ([_]api.Handle{ t.shader, t.layout, t.pipeline, t.external_pipeline, t.point, t.linear }) |h| if (h != 0) api.release(h);
        t.* = .{};
    }
    pub fn initPost(t: *Textures, external_layout: api.Handle) void {
        if (t.shader != 0) return;
        t.shader = api.shader_create(post_source.ptr, post_source.len);
        const entries = [_]api.LayoutEntry{
            .{ .binding = 0, .visibility = 2, .kind = 0 },
            .{ .binding = 2, .visibility = 2, .kind = 2 },
            .{ .binding = 3, .visibility = 2, .kind = 2 },
            .{ .binding = 4, .visibility = 2, .kind = 6 },
            .{ .binding = 5, .visibility = 2, .kind = 5 },
            .{ .binding = 6, .visibility = 2, .kind = 5 },
            .{ .binding = 7, .visibility = 2, .kind = 3 },
        };
        t.layout = api.layout_create(&entries, entries.len);
        t.pipeline = api.pipeline_create(&.{ .shader = t.shader, .layout = t.layout, .format = .bgra8unorm, .kind = 8 });
        t.external_pipeline = api.pipeline_create(&.{ .shader = t.shader, .layout = t.layout, .format = .bgra8unorm, .kind = 9, .sample_layout = external_layout });
        t.point = api.sampler_create(0);
        t.linear = api.sampler_create(1);
    }
    pub fn prepare(t: *Textures, r: anytype, encoder: api.Handle, textures: []const gpu.Texture) void {
        t.luts.frame +%= 1;
        while (t.slots.items.len < textures.len) t.slots.append(std.heap.wasm_allocator, .{}) catch @panic("out of memory");
        for (t.slots.items[0..textures.len], textures) |*s, tex| {
            s.view = 0;
            s.external = 0;
            if (tex.width == 0 or tex.height == 0) continue;
            if (tex.web_texture != 0 and api.resource_generation(tex.web_texture) != r.generation) continue;
            const serial = if (tex.web_texture != 0) api.resource_serial(tex.web_texture) else 0;
            if (s.width != tex.width or s.height != tex.height or s.input != tex.web_texture or s.input_serial != serial) {
                r.clearSamples();
                s.clear();
            }
            s.width = tex.width;
            s.height = tex.height;
            s.input = tex.web_texture;
            s.input_serial = serial;
            var source = tex.web_texture;
            var external: api.Handle = 0;
            if (tex.web_external != 0) {
                external = api.external_import(tex.web_external);
            }
            if (source == 0 and (external == 0 or tex.needsPost())) {
                if (s.texture == 0) {
                    s.texture = api.texture_create(&.{ .width = tex.width, .height = tex.height, .format = .bgra8unorm, .usage = 2 | 4 | 16 });
                    s.source_view = api.texture_view(s.texture);
                }
                source = s.texture;
                if (tex.web_external != 0 and external == 0) {
                    if (api.external_copy(tex.web_external, source) == 0) continue;
                } else if (tex.web_external == 0) {
                    const stride = if (tex.stride == 0) @as(usize, tex.width) * 4 else tex.stride;
                    if (stride < @as(usize, tex.width) * 4 or tex.bgra.len < stride * tex.height) continue;
                    api.texture_write(source, &.{ .width = tex.width, .height = tex.height, .bytes_per_row = @intCast(stride) }, tex.bgra.ptr, @intCast(tex.bgra.len));
                }
            }
            if (source != 0 and s.source_view == 0) s.source_view = api.texture_view(source);
            const linear = tex.web_texture != 0 and api.texture_format(tex.web_texture) == .rgba16float;
            const stage = color.stage(tex, if (linear) 3 else 0, tex.web_texture != 0 and api.texture_srgb(tex.web_texture));
            if (!stage.run) {
                s.view = s.source_view;
                s.external = external;
                continue;
            }
            t.initPost(r.external_layout);
            if (s.output == null) s.output = common.Target.init(tex.width, tex.height, .bgra8unorm) catch continue;
            if (s.uniform == 0) s.uniform = api.buffer_create(256, 64 | 8);
            const uniforms = color.uniforms(tex, stage.mode);
            api.buffer_write(s.uniform, 0, std.mem.asBytes(&uniforms).ptr, @sizeOf(color.Uniforms));
            const lut = t.luts.get(tex.lut);
            const source_lut = t.luts.get(tex.source_lut);
            const source_view = if (s.source_view != 0) s.source_view else r.images_view;
            const views = [4]api.Handle{ source_view, r.images_view, lut, source_lut };
            if (s.group == 0 or s.group_version != t.luts.version or !std.mem.eql(api.Handle, &s.group_views, &views)) {
                if (s.group != 0) api.release(s.group);
                const bindings = [_]api.BindEntry{
                    .{ .binding = 0, .kind = 0, .resource = s.uniform, .size = 256 },
                    .{ .binding = 2, .kind = 1, .resource = source_view },
                    .{ .binding = 3, .kind = 1, .resource = r.images_view },
                    .{ .binding = 4, .kind = 2, .resource = t.point },
                    .{ .binding = 5, .kind = 1, .resource = lut },
                    .{ .binding = 6, .kind = 1, .resource = source_lut },
                    .{ .binding = 7, .kind = 2, .resource = t.linear },
                };
                s.group = api.bind_group_create(t.layout, &bindings, bindings.len);
                s.group_views = views;
                s.group_version = t.luts.version;
            }
            const pass = api.pass_begin(encoder, s.output.?.view, 0, 0, 0, 0, 0);
            api.pass_set_pipeline(pass, if (external != 0) t.external_pipeline else t.pipeline);
            api.pass_set_bind_group(pass, 0, s.group, 0);
            if (external != 0) {
                const group = api.bind_group_create(r.external_layout, &.{.{ .binding = 1, .kind = 3, .resource = external }}, 1);
                api.pass_set_bind_group(pass, 1, group, 0xffffffff);
                api.release(group);
            }
            api.pass_draw(pass, 3, 1, 0);
            api.pass_end(pass);
            s.view = s.output.?.view;
        }
        // Release slots no longer displayed, including decoder-pool views.
        for (t.slots.items[textures.len..]) |*s| {
            r.clearSamples();
            s.clear();
        }
        t.slots.shrinkRetainingCapacity(textures.len);
    }
    pub fn get(t: *Textures, slot: usize) ?*Slot {
        if (slot >= t.slots.items.len) return null;
        const s = &t.slots.items[slot];
        return if (s.view == 0 and s.external == 0) null else s;
    }
};
