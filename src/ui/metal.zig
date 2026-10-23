//! The Metal renderer: one pipeline, one instanced draw per frame, into a
//! CAMetalLayer the native view hosts. Panes of glass split the frame:
//! each reads what was drawn before it (`metal_glass.zig`).
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const types = @import("types.zig");

const shader_source = @embedFile("shader.metal") ++ @embedFile("glass.metal");

const gpu = @import("gpu.zig");
const metal_glass = @import("metal_glass.zig");
const metal_texture = @import("metal_texture.zig");
pub const Instance = gpu.Instance;
pub const Kind = gpu.Kind;
pub const color4 = gpu.color4;
pub const clip4 = gpu.clip4;
pub const Pixels = gpu.Pixels;

extern "c" fn dispatch_time(when: u64, delta: i64) u64;
const FrameLog = @import("frame_log.zig").FrameLog;

pub const DrawStats = struct {
    drawable_wait_ms: f64 = 0,
    encode_ms: f64 = 0,
    sync: bool = false,
    presented: bool = false,
    queued: u8 = 0,
};

const DoneSlot = struct {
    renderer: *Renderer = undefined,
    log: ?*FrameLog = null,
    record_idx: usize = 0,
};

const MTLScissorRect = extern struct { x: objc.NSUInteger, y: objc.NSUInteger, width: objc.NSUInteger, height: objc.NSUInteger };

pub const Renderer = struct {
    /// The image atlas on the GPU, copied when its generation changes.
    images_texture: ?objc.Object = null,
    images_generation: u64 = std.math.maxInt(u64),
    layer_texture: ?objc.Object = null,
    layer_w: usize = 0,
    layer_h: usize = 0,
    device: objc.Object,
    queue: objc.Object,
    pipeline: objc.Object,
    glass: metal_glass.Glass,
    layer: objc.Object,
    framebuffer_only: bool = true,
    live_resize: bool = false,
    present_at: f64 = 0,
    given_drawable: ?objc.Object = null,
    time: f32 = 0,
    /// Frames go out in the window's transaction (see `setInTransaction`).
    in_transaction: bool = false,
    /// Instances go into one of three buffers, reused once the GPU is done
    /// with the frame that last used it.
    buffers: [frames_in_flight]?objc.Object = @splat(null),
    capacities: [frames_in_flight]usize = @splat(0),
    next_buffer: usize = 0,
    in_flight: objc.dispatch_semaphore_t,
    done_slots: [frames_in_flight]DoneSlot = @splat(.{}),
    next_done: usize = 0,
    /// The frame's textures (`ui.texture`), set by whoever draws it.
    textures: []const gpu.Texture = &.{},
    frame_textures: metal_texture.Textures = .{ .gpa = std.heap.page_allocator },
    /// Pixel buffers each frame in flight holds, by its instance buffer.
    held: [frames_in_flight]std.ArrayList(*anyopaque) = @splat(.empty),
    pub fn init() !Renderer {
        const pool = objc.Pool.push();
        defer pool.pop();
        const device = cf.MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;
        errdefer objc.release(device);
        const queue = objc.msg(objc.Object, device, "newCommandQueue", .{});
        errdefer objc.release(queue);

        var err: ?objc.Object = null;
        const library = objc.msg(?objc.Object, device, "newLibraryWithSource:options:error:", .{
            objc.nsString(shader_source), @as(?objc.Object, null), &err,
        }) orelse {
            const desc = objc.msg(objc.Object, err.?, "localizedDescription", .{});
            std.log.err("nanoui: shader: {s}", .{objc.fromNSString(desc)});
            return error.ShaderCompile;
        };
        defer objc.release(library);
        const pipeline = try makePipeline(device, library, "fs");
        errdefer objc.release(pipeline);
        const glass = try metal_glass.Glass.init(device, library, try makePipeline(device, library, "fs_glass"));

        const layer = objc.new("CAMetalLayer");
        objc.msg(void, layer, "setDevice:", .{device});
        objc.msg(void, layer, "setPixelFormat:", .{pixel_format});
        // Framebuffer-only until a pane of glass needs to read the backdrop.
        objc.msg(void, layer, "setFramebufferOnly:", .{objc.YES});
        // Three drawables managed by CAMetalDisplayLink.
        objc.msg(void, layer, "setMaximumDrawableCount:", .{@as(objc.NSUInteger, 3)});
        objc.msg(void, layer, "setOpaque:", .{objc.YES});
        // A frame waits for a drawable rather than being dropped: a dropped
        // one in a resize leaves the last, at the old size, stretched.
        objc.msg(void, layer, "setAllowsNextDrawableTimeout:", .{objc.NO});
        // Colors are sRGB, as in CSS: tag them so the display matches them.
        // (iOS treats untagged colors as sRGB, and older iOS lacks the setter.)
        const tags = objc.msg(objc.BOOL, layer, "respondsToSelector:", .{objc.sel("setColorspace:")});
        if (tags) if (cf.CGColorSpaceCreateWithName(cf.kCGColorSpaceSRGB)) |srgb| {
            defer cf.CGColorSpaceRelease(srgb);
            objc.msg(void, layer, "setColorspace:", .{srgb});
        };
        return .{ .device = device, .queue = queue, .pipeline = pipeline, .glass = glass, .layer = layer, .in_flight = objc.dispatch_semaphore_create(frames_in_flight) };
    }

    /// Brings the GPU's copy of the image atlas up to date (made on the
    /// first picture).
    /// Puts a packed picture straight into the GPU's image atlas (the
    /// `Images.Sink` of a window): no copy of the atlas stays in memory.
    pub fn uploadImage(ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, bgra: []const u8) void {
        const self: *Renderer = @ptrCast(@alignCast(ctx));
        const side: objc.NSUInteger = @import("images.zig").size;
        if (self.images_texture == null) {
            const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ pixel_format, side, side, objc.NO });
            self.images_texture = objc.msg(objc.Object, self.device, "newTextureWithDescriptor:", .{desc});
        } else if (x == 0 and y == 0) {
            self.waitIdle();
        }
        const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
        objc.msg(void, self.images_texture.?, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            Region{ .x = x, .y = y, .z = 0, .w = w, .h = h, .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, bgra.ptr), @as(objc.NSUInteger, w) * 4,
        });
    }

    pub fn syncImages(self: *Renderer, im: *Images) void {
        if (im.sink != null or im.pixels.len == 0 or im.generation == self.images_generation) return;
        const side: objc.NSUInteger = @import("images.zig").size;
        if (self.images_texture == null) {
            const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ pixel_format, side, side, objc.NO });
            self.images_texture = objc.msg(objc.Object, self.device, "newTextureWithDescriptor:", .{desc});
        }
        const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
        // Only the rows that changed, unless the texture is new.
        const rows: [2]u32 = if (self.images_generation == std.math.maxInt(u64)) .{ 0, @intCast(side) } else im.dirty orelse .{ 0, 0 };
        if (rows[1] > rows[0]) objc.msg(void, self.images_texture.?, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            Region{ .x = 0, .y = rows[0], .z = 0, .w = side, .h = rows[1] - rows[0], .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, im.pixels.ptr + @as(usize, rows[0]) * side * 4), side * 4,
        });
        im.dirty = null;
        self.images_generation = im.generation;
    }

    pub fn deinit(self: *Renderer) void {
        if (self.images_texture) |t| objc.release(t);
        if (self.layer_texture) |t| objc.release(t);
        // Wait for the frames in flight: their handlers signal this renderer.
        self.waitIdle();
        for (&self.held) |*h| {
            self.frame_textures.release(h);
            h.deinit(self.frame_textures.gpa);
        }
        self.frame_textures.deinit();
        objc.dispatch_release(self.in_flight);
        for (self.buffers) |b| if (b) |buf| objc.release(buf);
        objc.release(self.layer);
        self.glass.deinit();
        objc.release(self.pipeline);
        objc.release(self.queue);
        objc.release(self.device);
    }

    pub fn waitIdle(self: *Renderer) void {
        for (0..frames_in_flight) |_| _ = objc.dispatch_semaphore_wait(self.in_flight, objc.DISPATCH_TIME_FOREVER);
        for (0..frames_in_flight) |_| _ = objc.dispatch_semaphore_signal(self.in_flight);
    }

    pub fn resize(self: *Renderer, size: types.Size, scale: f32) void {
        if (self.layer_texture) |t| {
            objc.release(t);
            self.layer_texture = null;
            self.layer_w = 0;
            self.layer_h = 0;
        }
        if (size.w <= 1 and size.h <= 1) self.glass.releaseTextures();
        objc.msg(void, self.layer, "setContentsScale:", .{@as(f64, scale)});
        objc.msg(void, self.layer, "setDrawableSize:", .{objc.CGSize{
            .width = @max(1, @round(size.w * scale)),
            .height = @max(1, @round(size.h * scale)),
        }});
    }

    /// Draws `instances` over `clear` into the window, sized `size` points.
    pub fn draw(self: *Renderer, instances: []const Instance, atlas: objc.Object, size: types.Size, clear: types.Color) void {
        _ = self.drawLogged(instances, atlas, size, clear, null, 0);
    }

    pub fn drawLogged(self: *Renderer, instances: []const Instance, atlas: objc.Object, size: types.Size, clear: types.Color, log: ?*FrameLog, record_idx: usize) DrawStats {
        const pool = objc.Pool.push();
        defer pool.pop();
        if (self.framebuffer_only) {
            for (instances) |inst| if (inst.kind == Kind.glass) {
                objc.msg(void, self.layer, "setFramebufferOnly:", .{objc.NO});
                self.framebuffer_only = false;
                break;
            };
        }
        const given = self.given_drawable;
        self.given_drawable = null;
        const t0 = cf.CACurrentMediaTime();
        if (objc.dispatch_semaphore_wait(self.in_flight, dispatch_time(0, std.time.ns_per_s)) != 0) {
            return .{ .drawable_wait_ms = (cf.CACurrentMediaTime() - t0) * 1000, .sync = self.live_resize };
        }
        const drawable = given orelse {
            _ = objc.dispatch_semaphore_signal(self.in_flight);
            return .{ .drawable_wait_ms = (cf.CACurrentMediaTime() - t0) * 1000, .sync = self.live_resize };
        };
        const sync = self.live_resize;
        const t1 = cf.CACurrentMediaTime();
        const texture = objc.msg(?objc.Object, drawable, "texture", .{}) orelse {
            _ = objc.dispatch_semaphore_signal(self.in_flight);
            return .{ .drawable_wait_ms = (t1 - t0) * 1000, .sync = sync };
        };
        // The slot's last frame is done: its pixel buffers can go.
        const held = &self.held[self.next_buffer];
        self.frame_textures.release(held);
        const buffer = self.upload(instances);
        const cmd = self.encode(texture, buffer, instances, atlas, size, clear, held);
        const slot_idx = self.next_done;
        self.next_done = (slot_idx + 1) % frames_in_flight;
        self.done_slots[slot_idx] = .{ .renderer = self, .log = log, .record_idx = record_idx };
        var done = objc.Block(DoneSlot, &.{objc.Object}).init(&self.done_slots[slot_idx], frameDone);
        objc.msg(void, cmd, "addCompletedHandler:", .{@as(*anyopaque, @ptrCast(&done))});
        const t2 = cf.CACurrentMediaTime();
        if (sync or self.in_transaction) {
            // In the window's transaction: a resizing window never shows a
            // stretched or misplaced frame.
            objc.msg(void, cmd, "commit", .{});
            objc.msg(void, cmd, "waitUntilScheduled", .{});
            objc.msg(void, drawable, "present", .{});
        } else {
            objc.msg(void, cmd, "presentDrawable:", .{drawable});
            objc.msg(void, cmd, "commit", .{});
        }
        return .{
            .drawable_wait_ms = (t1 - t0) * 1000,
            .encode_ms = (t2 - t1) * 1000,
            .sync = sync,
            .presented = true,
        };
    }


    fn frameDone(slot: *DoneSlot, cmd: objc.Object) void {
        if (slot.log) |log| {
            const gpu_s = objc.msg(f64, cmd, "GPUEndTime", .{}) - objc.msg(f64, cmd, "GPUStartTime", .{});
            log.setGpuMs(slot.record_idx, @max(0, gpu_s * 1000));
        }
        const r = slot.renderer;
        _ = objc.dispatch_semaphore_signal(r.in_flight);
    }

    /// Copies `instances` into the next buffer of the ring, grown as needed.
    fn upload(self: *Renderer, instances: []const Instance) ?objc.Object {
        if (instances.len == 0) return null;
        const i = self.next_buffer;
        self.next_buffer = (i + 1) % frames_in_flight;
        const bytes = std.mem.sliceAsBytes(instances);
        if (self.capacities[i] < bytes.len) {
            if (self.buffers[i]) |old| objc.release(old);
            const cap = @max(bytes.len * 3 / 2, 64 * 1024);
            self.buffers[i] = objc.msg(objc.Object, self.device, "newBufferWithLength:options:", .{ @as(objc.NSUInteger, cap), @as(objc.NSUInteger, 0) });
            self.capacities[i] = cap;
        }
        const buf = self.buffers[i].?;
        const dst: [*]u8 = @ptrCast(objc.msg(*anyopaque, buf, "contents", .{}));
        @memcpy(dst[0..bytes.len], bytes);
        return buf;
    }

    pub fn setInTransaction(self: *Renderer, on: bool) void {
        if (self.in_transaction == on) return;
        self.in_transaction = on;
        objc.msg(void, self.layer, "setPresentsWithTransaction:", .{on or self.live_resize});
    }

    pub fn setLiveResize(self: *Renderer, on: bool) void {
        if (self.live_resize == on) return;
        self.live_resize = on;
        objc.msg(void, self.layer, "setPresentsWithTransaction:", .{on or self.in_transaction});
    }

    pub fn setOpaque(self: *Renderer, on: bool) void {
        objc.msg(void, self.layer, "setOpaque:", .{if (on) objc.YES else objc.NO});
    }

    /// A render target of `size` points at `scale`, kept by the caller
    /// across frames (release it): for benchmarks drawing without a window.
    pub fn newTarget(self: *Renderer, size: types.Size, scale: f32) objc.Object {
        const w: usize = @intFromFloat(@max(1, @round(size.w * scale)));
        const h: usize = @intFromFloat(@max(1, @round(size.h * scale)));
        const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            pixel_format, w, h, objc.NO,
        });
        objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1 | 4)}); // shader read, render target
        objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 2)}); // private: GPU only, as a drawable
        return objc.msg(objc.Object, self.device, "newTextureWithDescriptor:", .{desc});
    }

    pub const Timing = struct {
        /// CPU time to upload the instances and encode the frame.
        encode_ms: f64,
        /// GPU time of the frame, from the command buffer's timestamps.
        gpu_ms: f64,
    };

    /// Draws a frame into `target` as a window's frame is drawn (the ring
    /// of instance buffers, one command buffer), waits for it, and times it.
    pub fn drawTimed(self: *Renderer, target: objc.Object, instances: []const Instance, atlas: objc.Object, size: types.Size, clear: types.Color) Timing {
        const pool = objc.Pool.push();
        defer pool.pop();
        _ = objc.dispatch_semaphore_wait(self.in_flight, objc.DISPATCH_TIME_FOREVER);
        defer _ = objc.dispatch_semaphore_signal(self.in_flight);
        const t0 = cf.CACurrentMediaTime();
        const held = &self.held[self.next_buffer];
        self.frame_textures.release(held);
        const buffer = self.upload(instances);
        const cmd = self.encode(target, buffer, instances, atlas, size, clear, held);
        objc.msg(void, cmd, "commit", .{});
        const t1 = cf.CACurrentMediaTime();
        objc.msg(void, cmd, "waitUntilCompleted", .{});
        self.frame_textures.release(held);
        const gpu_s = objc.msg(f64, cmd, "GPUEndTime", .{}) - objc.msg(f64, cmd, "GPUStartTime", .{});
        return .{ .encode_ms = (t1 - t0) * 1000, .gpu_ms = gpu_s * 1000 };
    }

    /// Draws into a new offscreen texture and returns its BGRA pixels,
    /// premultiplied, `width * 4` bytes per row: frames without a window.
    pub fn drawOffscreen(self: *Renderer, gpa: std.mem.Allocator, instances: []const Instance, atlas: objc.Object, size: types.Size, scale: f32, clear: types.Color) !Pixels {
        const pool = objc.Pool.push();
        defer pool.pop();
        const w: usize = @intFromFloat(@max(1, @round(size.w * scale)));
        const h: usize = @intFromFloat(@max(1, @round(size.h * scale)));
        const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            pixel_format, w, h, objc.NO,
        });
        objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1 | 4)}); // shader read, render target
        objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 0)}); // shared
        const texture = objc.msg(objc.Object, self.device, "newTextureWithDescriptor:", .{desc});
        defer objc.release(texture);
        const src = std.mem.sliceAsBytes(instances);
        const buffer: ?objc.Object = if (instances.len == 0) null else objc.msg(objc.Object, self.device, "newBufferWithBytes:length:options:", .{
            @as(*const anyopaque, src.ptr), @as(objc.NSUInteger, src.len), @as(objc.NSUInteger, 0),
        });
        defer if (buffer) |b| objc.release(b);
        var held: std.ArrayList(*anyopaque) = .empty;
        defer held.deinit(self.frame_textures.gpa);
        const cmd = self.encode(texture, buffer, instances, atlas, size, clear, &held);
        objc.msg(void, cmd, "commit", .{});
        objc.msg(void, cmd, "waitUntilCompleted", .{});
        self.frame_textures.release(&held);
        const bytes = try gpa.alloc(u8, w * h * 4);
        const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
        objc.msg(void, texture, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{
            @as(*anyopaque, bytes.ptr), w * 4, Region{ .x = 0, .y = 0, .z = 0, .w = w, .h = h, .d = 1 }, @as(objc.NSUInteger, 0),
        });
        return .{ .bytes = bytes, .width = w, .height = h };
    }

    /// A pass drawing into `texture`, cleared to `clear` or keeping it.
    fn pass(cmd: objc.Object, texture: objc.Object, clear: ?types.Color) objc.Object {
        const desc = objc.msg(objc.Object, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
        const ca = objc.msg(objc.Object, objc.msg(objc.Object, desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(objc.NSUInteger, 0)});
        objc.msg(void, ca, "setTexture:", .{texture});
        objc.msg(void, ca, "setLoadAction:", .{@as(objc.NSUInteger, if (clear != null) 2 else 1)}); // clear, or load
        objc.msg(void, ca, "setStoreAction:", .{@as(objc.NSUInteger, 1)}); // store
        if (clear) |c| {
            const ClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };
            objc.msg(void, ca, "setClearColor:", .{ClearColor{ .r = c.r, .g = c.g, .b = c.b, .a = c.a }});
        }
        return objc.msg(objc.Object, cmd, "renderCommandEncoderWithDescriptor:", .{desc});
    }

    /// Draws instances [first, first + count) with `pipeline`.
    fn ensureLayerTexture(self: *Renderer, w: usize, h: usize) objc.Object {
        if (self.layer_texture) |t| {
            if (self.layer_w == w and self.layer_h == h) return t;
            objc.release(t);
        }
        const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            pixel_format, w, h, objc.NO,
        });
        objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1 | 4)}); // shader read, render target
        objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 2)}); // private
        const t = objc.msg(objc.Object, self.device, "newTextureWithDescriptor:", .{desc});
        self.layer_texture = t;
        self.layer_w = w;
        self.layer_h = h;
        return t;
    }

    /// Draws instances [first, first + count) with `pipeline`.
    fn drawRange(self: *Renderer, enc: objc.Object, pipeline: objc.Object, buffer: objc.Object, atlas: objc.Object, layer_tex: ?objc.Object, size: types.Size, first: usize, count: usize) void {
        const viewport: [2]f32 = .{ size.w, size.h };
        objc.msg(void, enc, "setRenderPipelineState:", .{pipeline});
        objc.msg(void, enc, "setVertexBuffer:offset:atIndex:", .{ buffer, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 0) });
        objc.msg(void, enc, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &viewport), @as(objc.NSUInteger, 8), @as(objc.NSUInteger, 1) });
        objc.msg(void, enc, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &self.time), @as(objc.NSUInteger, 4), @as(objc.NSUInteger, 2) });
        objc.msg(void, enc, "setFragmentBuffer:offset:atIndex:", .{ buffer, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 0) });
        objc.msg(void, enc, "setFragmentTexture:atIndex:", .{ atlas, @as(objc.NSUInteger, 0) });
        // Pictures, when there are any; else the atlas stands in (unread).
        objc.msg(void, enc, "setFragmentTexture:atIndex:", .{ self.images_texture orelse atlas, @as(objc.NSUInteger, 1) });
        if (layer_tex) |lt| objc.msg(void, enc, "setFragmentTexture:atIndex:", .{ lt, @as(objc.NSUInteger, 2) });
        objc.msg(void, enc, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", .{
            @as(objc.NSUInteger, 4), @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 4), @as(objc.NSUInteger, count), @as(objc.NSUInteger, first), // triangle strip
        });
    }

    fn nextSplit(instances: []const Instance, from: usize) ?usize {
        for (instances[from..], from..) |inst, k| {
            if (inst.kind == Kind.glass or inst.kind == Kind.layer_begin) return k;
        }
        return null;
    }

    /// Draws instances [first, end) with the main pipeline, a texture's
    /// quad (`ui.texture`) alone, its texture bound.
    fn drawRun(self: *Renderer, enc: objc.Object, buffer: objc.Object, atlas: objc.Object, size: types.Size, instances: []const Instance, first: usize, end: usize, held: *std.ArrayList(*anyopaque)) void {
        var from = first;
        var i = first;
        while (i < end) : (i += 1) {
            if (instances[i].kind != Kind.texture) continue;
            if (i > from) self.drawRange(enc, self.pipeline, buffer, atlas, atlas, size, from, i - from);
            from = i + 1;
            const slot: usize = @intFromFloat(instances[i].border_width);
            if (slot >= self.textures.len) continue;
            const tex = self.frame_textures.get(self.device, self.textures[slot], slot, held) orelse continue;
            objc.msg(void, enc, "setFragmentTexture:atIndex:", .{ tex, @as(objc.NSUInteger, 3) });
            self.drawRange(enc, self.pipeline, buffer, atlas, atlas, size, i, 1);
        }
        if (end > from) self.drawRange(enc, self.pipeline, buffer, atlas, atlas, size, from, end - from);
    }

    fn encode(self: *Renderer, texture: objc.Object, instance_buffer: ?objc.Object, instances: []const Instance, atlas: objc.Object, size: types.Size, clear: types.Color, held: *std.ArrayList(*anyopaque)) objc.Object {
        const cmd = objc.msg(objc.Object, self.queue, "commandBuffer", .{});
        const buffer = instance_buffer orelse {
            objc.msg(void, pass(cmd, texture, clear), "endEncoding", .{});
            return cmd;
        };
        const tex_w = objc.msg(objc.NSUInteger, texture, "width", .{});
        const tex_h = objc.msg(objc.NSUInteger, texture, "height", .{});
        const scale: f32 = @as(f32, @floatFromInt(tex_w)) / size.w;
        var first: usize = 0;
        var cleared = false;
        while (true) {
            const split_at = nextSplit(instances, first);
            const end = split_at orelse instances.len;
            if (end > first or !cleared) {
                const enc = pass(cmd, texture, if (cleared) null else clear);
                cleared = true;
                if (end > first) self.drawRun(enc, buffer, atlas, size, instances, first, end, held);
                objc.msg(void, enc, "endEncoding", .{});
            }
            const at = split_at orelse break;
            if (instances[at].kind == Kind.glass) {
                first = at + 1;
                const p = self.glass.backdrop(self.device, cmd, texture, instances[at], scale) orelse continue;
                const genc = pass(cmd, texture, null);
                objc.msg(void, genc, "setFragmentBytes:length:atIndex:", .{ @as(*const anyopaque, &p), @as(objc.NSUInteger, @sizeOf(metal_glass.Pane)), @as(objc.NSUInteger, 1) });
                self.drawRange(genc, self.glass.pipeline, buffer, atlas, self.glass.a.?, size, at, 1);
                objc.msg(void, genc, "endEncoding", .{});
                continue;
            }
            // Kind.layer_begin .. Kind.layer_end
            var end_at = at + 1;
            while (end_at < instances.len and instances[end_at].kind != Kind.layer_end) : (end_at += 1) {}
            first = if (end_at < instances.len) end_at + 1 else instances.len;
            if (end_at <= at + 1 or end_at >= instances.len) continue;
            const r = instances[at].rect;
            const fw: f32 = @floatFromInt(tex_w);
            const fh: f32 = @floatFromInt(tex_h);
            const sx0: usize = @intFromFloat(std.math.clamp(@floor(r[0] * scale), 0, fw));
            const sy0: usize = @intFromFloat(std.math.clamp(@floor(r[1] * scale), 0, fh));
            const sx1: usize = @intFromFloat(std.math.clamp(@ceil((r[0] + r[2]) * scale), 0, fw));
            const sy1: usize = @intFromFloat(std.math.clamp(@ceil((r[1] + r[3]) * scale), 0, fh));
            if (sx1 <= sx0 or sy1 <= sy0) continue;
            // Any glass inside the group draws in the main pass before the group.
            for (instances[at + 1 .. end_at], at + 1..) |gi, gk| {
                if (gi.kind == Kind.glass) {
                    const p = self.glass.backdrop(self.device, cmd, texture, gi, scale) orelse continue;
                    const genc = pass(cmd, texture, null);
                    objc.msg(void, genc, "setFragmentBytes:length:atIndex:", .{ @as(*const anyopaque, &p), @as(objc.NSUInteger, @sizeOf(metal_glass.Pane)), @as(objc.NSUInteger, 1) });
                    self.drawRange(genc, self.glass.pipeline, buffer, atlas, self.glass.a.?, size, gk, 1);
                    objc.msg(void, genc, "endEncoding", .{});
                }
            }
            const ltex = self.ensureLayerTexture(tex_w, tex_h);
            const lenc = pass(cmd, ltex, types.Color.transparent);
            objc.msg(void, lenc, "setScissorRect:", .{MTLScissorRect{ .x = sx0, .y = sy0, .width = sx1 - sx0, .height = sy1 - sy0 }});
            var seg_start = at + 1;
            while (seg_start < end_at) {
                var seg_end = seg_start;
                while (seg_end < end_at and instances[seg_end].kind != Kind.glass) : (seg_end += 1) {}
                if (seg_end > seg_start) self.drawRun(lenc, buffer, atlas, size, instances, seg_start, seg_end, held);
                seg_start = seg_end + 1;
            }
            objc.msg(void, lenc, "endEncoding", .{});
            var comp_inst = instances[end_at];
            comp_inst.kind = Kind.layer_composite;
            const cenc = pass(cmd, texture, null);
            const viewport: [2]f32 = .{ size.w, size.h };
            objc.msg(void, cenc, "setRenderPipelineState:", .{self.pipeline});
            objc.msg(void, cenc, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &comp_inst), @as(objc.NSUInteger, @sizeOf(Instance)), @as(objc.NSUInteger, 0) });
            objc.msg(void, cenc, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &viewport), @as(objc.NSUInteger, 8), @as(objc.NSUInteger, 1) });
            objc.msg(void, cenc, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &self.time), @as(objc.NSUInteger, 4), @as(objc.NSUInteger, 2) });
            objc.msg(void, cenc, "setFragmentBytes:length:atIndex:", .{ @as(*const anyopaque, &comp_inst), @as(objc.NSUInteger, @sizeOf(Instance)), @as(objc.NSUInteger, 0) });
            objc.msg(void, cenc, "setFragmentTexture:atIndex:", .{ atlas, @as(objc.NSUInteger, 0) });
            objc.msg(void, cenc, "setFragmentTexture:atIndex:", .{ self.images_texture orelse atlas, @as(objc.NSUInteger, 1) });
            objc.msg(void, cenc, "setFragmentTexture:atIndex:", .{ ltex, @as(objc.NSUInteger, 2) });
            objc.msg(void, cenc, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", .{
                @as(objc.NSUInteger, 4), @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 4), @as(objc.NSUInteger, 1), @as(objc.NSUInteger, 0),
            });
            objc.msg(void, cenc, "endEncoding", .{});
        }
        return cmd;
    }
};

fn makePipeline(device: objc.Object, library: objc.Object, comptime fragment: []const u8) !objc.Object {
    const vs = objc.msg(objc.Object, library, "newFunctionWithName:", .{objc.nsString("vs")});
    defer objc.release(vs);
    const fs = objc.msg(objc.Object, library, "newFunctionWithName:", .{objc.nsString(fragment)});
    defer objc.release(fs);
    const desc = objc.new("MTLRenderPipelineDescriptor");
    defer objc.release(desc);
    objc.msg(void, desc, "setVertexFunction:", .{vs});
    objc.msg(void, desc, "setFragmentFunction:", .{fs});
    const attachments = objc.msg(objc.Object, desc, "colorAttachments", .{});
    const ca = objc.msg(objc.Object, attachments, "objectAtIndexedSubscript:", .{@as(objc.NSUInteger, 0)});
    objc.msg(void, ca, "setPixelFormat:", .{pixel_format});
    objc.msg(void, ca, "setBlendingEnabled:", .{objc.YES});
    // Premultiplied alpha: one, one minus source alpha.
    objc.msg(void, ca, "setSourceRGBBlendFactor:", .{@as(objc.NSUInteger, 1)});
    objc.msg(void, ca, "setSourceAlphaBlendFactor:", .{@as(objc.NSUInteger, 1)});
    objc.msg(void, ca, "setDestinationRGBBlendFactor:", .{@as(objc.NSUInteger, 5)});
    objc.msg(void, ca, "setDestinationAlphaBlendFactor:", .{@as(objc.NSUInteger, 5)});
    var err: ?objc.Object = null;
    return objc.msg(?objc.Object, device, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err }) orelse error.PipelineCreate;
}

const pixel_format: objc.NSUInteger = 80; // BGRA8Unorm
const Images = @import("images.zig").Images;
const frames_in_flight = 3;
