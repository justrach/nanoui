//! WebGPU renderer. Zig owns passes and storage; JavaScript forwards calls.
const std = @import("std");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const types = @import("types.zig");
pub const api = @import("webgpu_api.zig");
const device = @import("webgpu_device.zig");
pub const Target = @import("webgpu_target.zig").Target;
pub const Params = @import("webgpu_target.zig").Params;
const source = @embedFile("shader.wgsl") ++ "\n" ++ @embedFile("shader_shapes.wgsl") ++ "\n" ++ @embedFile("glass.wgsl");
comptime {
    std.debug.assert(@sizeOf(gpu.Instance) == 192);
    std.debug.assert(@offsetOf(gpu.Instance, "radius") == 80 and @offsetOf(gpu.Instance, "xf") == 96 and @offsetOf(gpu.Instance, "turn") == 144);
    const kinds = [_][]const u8{ "quad", "text", "shadow", "image", "glass", "shadow_out", "segment", "triangle", "texture", "layer_begin", "layer_end", "layer_composite", "hole" };
    std.debug.assert(@typeInfo(gpu.Kind).@"struct".decl_names.len == kinds.len);
    for (kinds, 0..) |name, index| std.debug.assert(@field(gpu.Kind, name) == @as(f32, @floatFromInt(index)));
}

pub const Renderer = struct {
    before_encode: ?gpu.BeforeEncode = null,
    generation: u32,
    shader: api.Handle,
    layout: api.Handle,
    pipelines: [6][2]api.Handle,
    sample_layout: api.Handle,
    external_layout: api.Handle,
    textures: []const gpu.Texture = &.{},
    frame_textures: @import("webgpu_texture.zig").Textures = .{},
    samples: std.AutoHashMapUnmanaged(api.Handle, api.Handle) = .empty,
    extra: @import("webgpu_glass.zig").Glass = .{},
    layers: std.ArrayList(?Target) = .empty,
    gradients: []const [4]f32 = &.{},
    gradient_buffer: api.Handle,
    gradient_capacity: usize = 16,
    uniform: api.Handle,
    uniform_capacity: u32 = 256,
    next_slot: u32 = 1,
    frame_params: Params = undefined,
    instances: api.Handle,
    capacity: u32 = 192,
    sampler: api.Handle,
    atlas: api.Handle,
    atlas_view: api.Handle,
    atlas_size: u32 = 1,
    atlas_generation: u64 = std.math.maxInt(u64),
    images: api.Handle,
    images_view: api.Handle,
    images_size: u32 = 1,
    images_generation: u64 = std.math.maxInt(u64),
    group: api.Handle = 0,

    pub fn init() !Renderer {
        _ = device.get() orelse return error.NoWebGPUDevice;
        const shader = api.shader_create(source.ptr, source.len);
        const entries = [_]api.LayoutEntry{
            .{ .binding = 0, .visibility = 3, .kind = 0 },
            .{ .binding = 1, .visibility = 3, .kind = 1 },
            .{ .binding = 2, .visibility = 2, .kind = 1 },
            .{ .binding = 3, .visibility = 2, .kind = 2 },
            .{ .binding = 4, .visibility = 2, .kind = 2 },
            .{ .binding = 5, .visibility = 2, .kind = 3 },
        };
        const layout = api.layout_create(&entries, entries.len);
        const sample_layout = api.layout_create(&.{.{ .binding = 0, .visibility = 2, .kind = 2 }}, 1);
        const external_layout = api.layout_create(&.{.{ .binding = 1, .visibility = 2, .kind = 4 }}, 1);
        var pipelines: [6][2]api.Handle = undefined;
        for (&pipelines, 0..) |*pair, kind| {
            for (pair, 0..) |*pipeline, format| pipeline.* = api.pipeline_create(&.{
                .shader = shader,
                .layout = layout,
                .format = @fromBackingInt(@intCast(format)),
                .kind = @intCast(kind),
                .sample_layout = if (kind == 5) external_layout else sample_layout,
            });
        }
        const atlas = api.texture_create(&.{ .width = 1, .height = 1, .format = .r8unorm, .usage = 2 | 4 });
        const images = api.texture_create(&.{ .width = 1, .height = 1, .format = .bgra8unorm, .usage = 2 | 4 });
        var result: Renderer = .{
            .generation = device.generation(),
            .shader = shader,
            .layout = layout,
            .pipelines = pipelines,
            .sample_layout = sample_layout,
            .external_layout = external_layout,
            .uniform = api.buffer_create(256, 64 | 8),
            .gradient_buffer = api.buffer_create(16, 128 | 8),
            .instances = api.buffer_create(192, 128 | 8),
            .sampler = api.sampler_create(1),
            .atlas = atlas,
            .atlas_view = api.texture_view(atlas),
            .images = images,
            .images_view = api.texture_view(images),
        };
        result.frame_textures.initPost(external_layout);
        return result;
    }

    pub fn deinit(r: *Renderer) void {
        if (r.generation == 0) return;
        r.frame_textures.deinit();
        r.extra.deinit();
        for (r.layers.items) |layer| if (layer) |target| target.deinit();
        r.layers.deinit(std.heap.wasm_allocator);
        r.clearSamples();
        for (r.pipelines) |pair| for (pair) |pipeline| api.release(pipeline);
        for ([_]api.Handle{ r.shader, r.layout, r.sample_layout, r.external_layout, r.gradient_buffer, r.uniform, r.instances, r.sampler, r.atlas_view, r.atlas, r.images_view, r.images, r.group }) |h| if (h != 0) {
            api.release(h);
        };
        r.generation = 0;
    }
    pub fn groupTarget(r: *Renderer, depth: usize, target: Target) Target {
        while (r.layers.items.len <= depth) r.layers.append(std.heap.wasm_allocator, null) catch @panic("out of memory");
        const slot = &r.layers.items[depth];
        if (slot.* == null or slot.*.?.width != target.width or slot.*.?.height != target.height or slot.*.?.format != target.format) {
            r.clearSamples();
            if (slot.*) |old| old.deinit();
            slot.* = Target.init(target.width, target.height, target.format) catch @panic("invalid layer target");
        }
        return slot.*.?;
    }
    pub fn clearSamples(r: *Renderer) void {
        var it = r.samples.valueIterator();
        while (it.next()) |h| api.release(h.*);
        r.samples.deinit(std.heap.wasm_allocator);
        r.samples = .empty;
    }
    pub fn sampleGroup(r: *Renderer, view: api.Handle) api.Handle {
        if (r.samples.get(view)) |h| return h;
        const h = api.bind_group_create(r.sample_layout, &.{.{ .binding = 0, .kind = 1, .resource = view }}, 1);
        r.samples.put(std.heap.wasm_allocator, view, h) catch @panic("out of memory");
        return h;
    }
    pub fn invalidate(r: *Renderer) void {
        if (r.group != 0) api.release(r.group);
        r.group = 0;
    }
    pub fn sync(r: *Renderer, mask: raster.Mask, mask_generation: u64, pictures: raster.Pictures, pictures_generation: u64) void {
        if (r.generation != device.generation()) return;
        if (mask.size > 0 and (mask_generation != r.atlas_generation or mask.size != r.atlas_size)) {
            if (mask.size != r.atlas_size) r.replaceAtlas(mask.size, false);
            api.texture_write(r.atlas, &.{ .width = mask.size, .height = mask.size, .bytes_per_row = mask.size }, mask.pixels.ptr, @intCast(mask.pixels.len));
            r.atlas_generation = mask_generation;
        }
        if (pictures.size > 0 and (pictures_generation != r.images_generation or pictures.size != r.images_size)) {
            if (pictures.size != r.images_size) r.replaceAtlas(pictures.size, true);
            api.texture_write(r.images, &.{ .width = pictures.size, .height = pictures.size, .bytes_per_row = pictures.size * 4 }, pictures.pixels.ptr, @intCast(pictures.pixels.len));
            r.images_generation = pictures_generation;
        }
    }
    fn replaceAtlas(r: *Renderer, side: u32, picture: bool) void {
        r.invalidate();
        r.clearSamples();
        const tex = if (picture) &r.images else &r.atlas;
        const view = if (picture) &r.images_view else &r.atlas_view;
        api.release(view.*);
        api.release(tex.*);
        tex.* = api.texture_create(&.{ .width = side, .height = side, .format = if (picture) .bgra8unorm else .r8unorm, .usage = 2 | 4 });
        view.* = api.texture_view(tex.*);
        if (picture) r.images_size = side else r.atlas_size = side;
    }
    /// Images.Sink: changed rectangles go straight to the BGRA atlas.
    pub fn uploadImage(ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, pixels: []const u8, side: u32) void {
        const r: *Renderer = @ptrCast(@alignCast(ctx));
        if (r.images_size != side) r.replaceAtlas(side, true);
        api.texture_write(r.images, &.{ .width = w, .height = h, .bytes_per_row = w * 4, .x = x, .y = y }, pixels.ptr, @intCast(pixels.len));
    }
    pub fn draw(r: *Renderer, instances: []const gpu.Instance, size: types.Size, scale: f32, clear: types.Color, target: Target, time: f64) void {
        if (r.generation != device.generation()) return;
        const bytes = std.mem.sliceAsBytes(instances);
        if (bytes.len > r.capacity) {
            r.invalidate();
            api.release(r.instances);
            r.capacity = @intCast(@max(bytes.len, r.capacity * 2));
            r.instances = api.buffer_create(r.capacity, 128 | 8);
        }
        if (bytes.len > 0) api.buffer_write(r.instances, 0, bytes.ptr, @intCast(bytes.len));
        var slot_count: u32 = 1;
        for (instances) |i| if (i.kind == gpu.Kind.glass) {
            slot_count += 4;
        };
        const slots = slot_count * 256;
        if (slots > r.uniform_capacity) {
            r.invalidate();
            api.release(r.uniform);
            r.uniform_capacity = @max(slots, r.uniform_capacity * 2);
            r.uniform = api.buffer_create(r.uniform_capacity, 64 | 8);
        }
        const gradients = std.mem.sliceAsBytes(r.gradients);
        if (gradients.len > r.gradient_capacity) {
            r.invalidate();
            api.release(r.gradient_buffer);
            r.gradient_capacity = @max(gradients.len, r.gradient_capacity * 2);
            r.gradient_buffer = api.buffer_create(@intCast(r.gradient_capacity), 128 | 8);
        }
        if (gradients.len > 0) api.buffer_write(r.gradient_buffer, 0, gradients.ptr, @intCast(gradients.len));
        r.frame_params = .{ .viewport = .{ size.w, size.h }, .scale = scale, .time = @floatCast(time) };
        r.next_slot = 1;
        api.buffer_write(r.uniform, 0, std.mem.asBytes(&r.frame_params).ptr, @sizeOf(Params));
        if (r.group == 0) {
            const bindings = [_]api.BindEntry{
                .{ .binding = 0, .kind = 0, .resource = r.uniform, .size = 256 },
                .{ .binding = 1, .kind = 0, .resource = r.instances },
                .{ .binding = 2, .kind = 0, .resource = r.gradient_buffer },
                .{ .binding = 3, .kind = 1, .resource = r.atlas_view },
                .{ .binding = 4, .kind = 1, .resource = r.images_view },
                .{ .binding = 5, .kind = 2, .resource = r.sampler },
            };
            r.group = api.bind_group_create(r.layout, &bindings, bindings.len);
        }
        r.extra.prepare(r, instances, target, scale);
        const encoder = api.encoder_begin();
        if (r.before_encode) |hook| hook.func(hook.ctx, @ptrFromInt(encoder));
        r.frame_textures.prepare(r, encoder, r.textures);
        const cover = gpu.lastCover(instances, size);
        const frame_clear: types.Color = if (cover) |k| .{ .r = instances[k].color[0], .g = instances[k].color[1], .b = instances[k].color[2], .a = 1 } else clear;
        @import("webgpu_passes.zig").encode(r, encoder, instances, target, frame_clear, if (cover) |k| k + 1 else 0);
        api.encoder_submit(encoder);
        r.frame_textures.luts.afterSubmit();
    }
    pub fn parameterSlot(r: *Renderer, value: Params) u32 {
        const offset = r.next_slot * 256;
        r.next_slot += 1;
        std.debug.assert(offset + 256 <= r.uniform_capacity);
        api.buffer_write(r.uniform, offset, std.mem.asBytes(&value).ptr, @sizeOf(Params));
        return offset;
    }
    /// The output and context must remain alive until asynchronous completion.
    pub fn readInto(r: *Renderer, target: Target, out: gpu.Pixels, ctx: *anyopaque, done: *const fn (*anyopaque, bool) void) void {
        if (r.generation != device.generation() or out.width != target.width or out.height != target.height or out.bytes.len < out.width * out.height * 4) return done(ctx, false);
        const token = api.completion(ctx, done) orelse return done(ctx, false);
        api.read_begin(target.texture, target.width, target.height, target.format, out.bytes.ptr, token);
    }
};
