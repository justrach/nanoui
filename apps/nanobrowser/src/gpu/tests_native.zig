const std = @import("std");
const testing = std.testing;
const gpu = @import("context.zig");
const wgsl = @import("wgsl.zig");
const metal = @import("metal.zig");
const compute_source =
    \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
    \\@compute @workgroup_size(1)
    \\fn doubleData(@builtin(global_invocation_id) id: vec3<u32>) {
    \\  if (id.x < arrayLength(&data)) { data[id.x] = data[id.x] * 2.0; }
    \\}
;
pub const triangle_source =
    \\@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    \\  let positions = array<vec2f, 3>(vec2f(-0.8, -0.8), vec2f(0.8, -0.8), vec2f(0.0, 0.8));
    \\  return vec4f(positions[i], 0.0, 1.0);
    \\}
    \\@fragment fn fs() -> @location(0) vec4f { return vec4f(1.0, 0.0, 0.0, 1.0); }
;

test "WebGPU WGSL parses nested comments, precedence and rejects unsupported syntax" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sink: wgsl.Sink = .{ .arena = arena.allocator() };
    const tr = try wgsl.translate(arena.allocator(), &sink, "/* a /* b */ c */\n" ++ compute_source);
    try testing.expectEqual(@as(usize, 1), tr.entries.len);
    try testing.expectEqual(@as(usize, 1), tr.bindings.len);
    const bad = [_][]const u8{
        "@compute @workgroup_size(1) fn main(){ loop {} }",
        "@compute @workgroup_size(0) fn main(){}",
        "@group(1) @binding(0) var<storage, read_write> x: array<u32>; @compute @workgroup_size(1) fn main(){}",
        "@compute @workgroup_size(1) fn main(){let x = textureSample();}",
        "@compute @workgroup_size(1) fn main(){let x = 1 + ;}",
    };
    for (bad) |s| {
        sink.diag = null;
        try testing.expectError(error.Wgsl, wgsl.translate(arena.allocator(), &sink, s));
        try testing.expect(sink.diag != null);
        try testing.expect(sink.diag.?.message.len > 0);
    }
}

test "WebGPU real Metal compute doubleDatas storage buffer and blits readback" {
    if (!gpu.supported) return error.SkipZigTest;
    var c: gpu.Context = .{ .gpa = testing.allocator };
    defer c.deinit();
    if (!c.available()) return error.SkipZigTest;
    const shader = c.shader(compute_source) catch |e| {
        std.debug.print("{s}\n", .{c.diagnostic()});
        return e;
    };
    const pipeline = try c.compute(shader, "doubleData");
    const data = try c.buffer(16, 128 | 4 | 8);
    const out = try c.buffer(16, 1 | 8);
    const input = [_]f32{ 1, -2, 3.5, 0.25 };
    @memcpy(try c.bytes(data, 0, 16), std.mem.asBytes(&input));
    var bindings: [8]u32 = @splat(0);
    bindings[0] = data;
    try c.dispatch(pipeline, bindings, .{ 4, 1, 1 });
    try c.copy(data, 0, out, 0, 16);
    const got = std.mem.bytesToValue([4]f32, try c.bytes(out, 0, 16));
    try testing.expectEqualSlices(f32, &.{ 2, -4, 7, 0.5 }, &got);
    try testing.expectError(error.Validation, c.copy(data, 0, out, 12, 8));
    c.destroy(data);
    try testing.expectError(error.Validation, c.dispatch(pipeline, bindings, .{ 1, 1, 1 }));
}

test "WebGPU real Metal offscreen triangle has red center and blue clear corners" {
    if (!gpu.supported) return error.SkipZigTest;
    var c: gpu.Context = .{ .gpa = testing.allocator };
    defer c.deinit();
    if (!c.available()) return error.SkipZigTest;
    const shader = c.shader(triangle_source) catch |e| {
        std.debug.print("{s}\n", .{c.diagnostic()});
        return e;
    };
    const pipeline = c.render(shader, "vs", shader, "fs") catch |e| {
        std.debug.print("{s}\n", .{c.diagnostic()});
        return e;
    };
    const texture = try c.texture(32, 32);
    try c.draw(texture, pipeline, 3, 0, .{ 0, 0, 1, 1 });
    var pixels: [32 * 32 * 4]u8 = undefined;
    metal.readTexture((try c.get(texture, .texture)).obj.?, 32, 32, &pixels);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, pixels[(16 * 32 + 16) * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, pixels[0..4]);
    // The top has the triangle's narrow tip, the bottom its wide base.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, pixels[(6 * 32 + 8) * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, pixels[(24 * 32 + 8) * 4 ..][0..4]);
}
