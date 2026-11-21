//! Tracks the visible draws in each tile of the browser's retained surface.
const std = @import("std");
const gpu = @import("gpu.zig");
const api = @import("webgpu_api.zig");
const Target = @import("webgpu_target.zig").Target;
const Color = @import("types.zig").Color;

const tile: u32 = 64;
const allocator = std.heap.wasm_allocator;

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn intersects(a: Rect, b: Rect) bool {
        return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
    }
};

pub const Damage = struct {
    target: ?Target = null,
    previous: std.ArrayList(u64) = .empty,
    next: std.ArrayList(u64) = .empty,
    valid: bool = false,
    key: u64 = 0,
    regions: [24]Rect = undefined,

    pub fn deinit(d: *Damage) void {
        if (d.target) |t| t.deinit();
        d.previous.deinit(allocator);
        d.next.deinit(allocator);
        d.* = .{};
    }

    pub fn backing(d: *Damage, width: u32, height: u32, format: api.Format) !Target {
        if (d.target) |t| {
            if (t.width == width and t.height == height and t.format == format) return t;
            t.deinit();
            d.target = null;
        }
        d.valid = false;
        const target = try Target.init(width, height, format);
        d.target = target;
        return target;
    }

    // A complete pass handles effects that read other pixels or move their
    // bounds in the shader. It also handles applications with their own passes.
    pub fn supported(instances: []const gpu.Instance) bool {
        for (instances) |*i| {
            if (i.kind == gpu.Kind.glass or i.kind >= gpu.Kind.layer_begin or
                i.xf[0] != 0 or i.xf[1] != 0 or i.pulse[0] != 0 or i.turn[0] != 0 or
                i.vel[0] != 0 or i.vel[1] != 0 or i.vel[2] != 0 or gpu.hasMatrix(i) or
                (i.kind == gpu.Kind.texture and !std.mem.allEqual(f32, &i.border_color, 0))) return false;
        }
        return true;
    }

    /// Null requests a full repaint. An empty slice leaves the previous
    /// presentation in place while the editor continues to step.
    pub fn update(d: *Damage, target: Target, scale: f32, clear: Color, versions: [3]u64, gradients: []const [4]f32, instances: []const gpu.Instance, textures: []const gpu.Texture) ?[]const Rect {
        const columns = std.math.divCeil(u32, target.width, tile) catch unreachable;
        const rows = std.math.divCeil(u32, target.height, tile) catch unreachable;
        d.next.resize(allocator, @as(usize, columns) * rows) catch {
            d.valid = false;
            return null;
        };
        @memset(d.next.items, 0);
        var key = std.hash.Wyhash.init(0);
        key.update(std.mem.asBytes(&scale));
        key.update(std.mem.asBytes(&clear));
        const signature = key.final();
        for (instances) |*i| {
            const rect = bounds(i, target, scale) orelse continue;
            var hash = std.hash.Wyhash.hash(0, std.mem.asBytes(i));
            if (i.kind == gpu.Kind.text) {
                hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&versions[0]));
            } else if (i.kind == gpu.Kind.image) {
                hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(versions[1..3]));
            } else if (i.kind == gpu.Kind.quad and i.uv[1] > 1.5) {
                // Hash only the gradient that this draw samples. Meters
                // can update their stops on every editor tick.
                const at: usize = @intFromFloat(i.uv[2]);
                if (at < gradients.len) {
                    const stops: usize = @intFromFloat(gradients[at][2]);
                    const end = @min(at + 1 + 2 * stops, gradients.len);
                    hash = std.hash.Wyhash.hash(hash, std.mem.sliceAsBytes(gradients[at..end]));
                }
            }
            const live = if (i.kind == gpu.Kind.texture) addTexture(&hash, textures, @intFromFloat(i.border_width)) else false;
            const x0 = rect.x / tile;
            const x1 = (rect.x + rect.w - 1) / tile + 1;
            const y0 = rect.y / tile;
            const y1 = (rect.y + rect.h - 1) / tile + 1;
            for (y0..y1) |y| for (d.next.items[y * columns + x0 .. y * columns + x1]) |*stamp| {
                // Include painter order. Reserve the high bit for textures
                // whose contents can change with the same object handle.
                stamp.* = (stamp.* & high_bit) | ((stamp.* *% 0x9e3779b185ebca87 +% hash) & ~high_bit);
                if (live) stamp.* |= high_bit;
            };
        }
        const matched = d.valid and d.key == signature and d.previous.items.len == d.next.items.len;
        const regions = if (matched) d.changedRegions(target, columns, rows) else null;
        std.mem.swap(std.ArrayList(u64), &d.previous, &d.next);
        d.key = signature;
        d.valid = true;
        return regions;
    }

    fn changedRegions(d: *Damage, target: Target, columns: u32, rows: u32) ?[]const Rect {
        var len: usize = 0;
        var pixels: u64 = 0;
        for (0..rows) |y| {
            var x: usize = 0;
            while (x < columns) {
                if (!d.changed(y * columns + x)) {
                    x += 1;
                    continue;
                }
                const start = x;
                while (x < columns and d.changed(y * columns + x)) : (x += 1) {}
                const left: u32 = @intCast(start * tile);
                const top: u32 = @intCast(y * tile);
                const w = @min(@as(u32, @intCast(x * tile)), target.width) - left;
                const h = @min(tile, target.height - top);
                pixels += @as(u64, w) * h;
                if (pixels * 2 >= @as(u64, target.width) * target.height) return null;
                for (d.regions[0..len]) |*rect| {
                    if (rect.x == left and rect.w == w and rect.y + rect.h == top) {
                        rect.h += h;
                        break;
                    }
                } else {
                    if (len == d.regions.len) return null;
                    d.regions[len] = .{ .x = left, .y = top, .w = w, .h = h };
                    len += 1;
                }
            }
        }
        return d.regions[0..len];
    }

    const high_bit: u64 = 1 << 63;

    fn changed(d: *Damage, i: usize) bool {
        return d.next.items[i] != d.previous.items[i] or d.next.items[i] & high_bit != 0;
    }
};

fn addTexture(hash: *u64, textures: []const gpu.Texture, slot: usize) bool {
    if (slot >= textures.len) return true;
    const t = textures[slot];
    const ids = [2]u32{
        if (t.web_texture != 0) api.resource_content_serial(t.web_texture) else 0,
        if (t.web_external != 0) api.resource_content_serial(t.web_external) else 0,
    };
    hash.* = std.hash.Wyhash.hash(hash.*, std.mem.asBytes(&ids));
    return t.needsPost() or (t.web_texture == 0 and t.web_external == 0) or
        (t.web_texture != 0 and ids[0] == 0) or (t.web_external != 0 and ids[1] == 0);
}

/// Axis-aligned WebGPU primitives, including their blur and an antialiasing
/// margin. Complex transforms take the full renderer path.
pub fn bounds(i: *const gpu.Instance, target: Target, scale: f32) ?Rect {
    const grow = if (i.kind == gpu.Kind.shadow or i.kind == gpu.Kind.shadow_out)
        i.border_width * 3
    else if (i.kind == gpu.Kind.segment)
        i.border_width + 2
    else
        0;
    const w: f32 = @floatFromInt(target.width);
    const h: f32 = @floatFromInt(target.height);
    const x0 = std.math.clamp(@floor(@max(i.rect[0] - grow, i.clip[0]) * scale) - 2, 0, w);
    const y0 = std.math.clamp(@floor(@max(i.rect[1] - grow, i.clip[1]) * scale) - 2, 0, h);
    const x1 = std.math.clamp(@ceil(@min(i.rect[0] + i.rect[2] + grow, i.clip[2]) * scale) + 2, 0, w);
    const y1 = std.math.clamp(@ceil(@min(i.rect[1] + i.rect[3] + grow, i.clip[3]) * scale) + 2, 0, h);
    if (!(x1 > x0 and y1 > y0)) return null;
    return .{ .x = @intFromFloat(x0), .y = @intFromFloat(y0), .w = @intFromFloat(x1 - x0), .h = @intFromFloat(y1 - y0) };
}
