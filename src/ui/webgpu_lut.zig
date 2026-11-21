//! A bounded cache of half-float 3D LUTs. Textures evicted during encoding
//! stay alive until submit; a large single frame cannot invalidate its passes.
const std = @import("std");
const gpu = @import("gpu.zig");
const api = @import("webgpu_api.zig");
const Entry = struct { key: u64, texture: api.Handle, view: api.Handle, used: u64 };
pub const Cache = struct {
    entries: [16]?Entry = @splat(null),
    retired: std.ArrayList(Entry) = .empty,
    frame: u64 = 0,
    version: u64 = 0,
    dummy: ?Entry = null,
    pub fn deinit(c: *Cache) void {
        for (c.entries) |e| if (e) |entry| drop(entry);
        if (c.dummy) |entry| drop(entry);
        c.afterSubmit();
        c.retired.deinit(std.heap.wasm_allocator);
        c.* = .{};
    }
    pub fn afterSubmit(c: *Cache) void {
        for (c.retired.items) |e| drop(e);
        c.retired.clearRetainingCapacity();
    }
    fn drop(e: Entry) void {
        api.release(e.view);
        api.release(e.texture);
    }
    pub fn get(c: *Cache, lut: ?gpu.Lut) api.Handle {
        if (lut) |l| if (l.valid()) {
            for (&c.entries) |*slot| if (slot.*) |*entry| if (entry.key == l.key) {
                entry.used = c.frame;
                return entry.view;
            };
            var oldest: usize = 0;
            for (c.entries, 0..) |entry, i| {
                if (entry == null) {
                    oldest = i;
                    break;
                }
                if (entry.?.used < c.entries[oldest].?.used) oldest = i;
            }
            if (c.entries[oldest]) |entry| c.retired.append(std.heap.wasm_allocator, entry) catch @panic("out of memory");
            c.version +%= 1;
            const texture = api.texture_create(&.{ .width = l.size, .height = l.size, .depth = l.size, .dimension = 3, .format = .rgba16float, .usage = 2 | 4 });
            const bytes = std.mem.sliceAsBytes(l.data[0 .. @as(usize, l.size) * l.size * l.size * 4]);
            api.texture_write(texture, &.{ .width = l.size, .height = l.size, .depth = l.size, .bytes_per_row = @as(u32, l.size) * 8 }, bytes.ptr, @intCast(bytes.len));
            const view = api.texture_view(texture);
            c.entries[oldest] = .{ .key = l.key, .texture = texture, .view = view, .used = c.frame };
            return view;
        };
        if (c.dummy == null) {
            const texture = api.texture_create(&.{ .width = 1, .height = 1, .depth = 1, .dimension = 3, .format = .rgba16float, .usage = 2 | 4 });
            c.dummy = .{ .key = 0, .texture = texture, .view = api.texture_view(texture), .used = 0 };
        }
        return c.dummy.?.view;
    }
};
