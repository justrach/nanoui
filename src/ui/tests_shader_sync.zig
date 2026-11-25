//! A small drift alarm, alongside pixel parity tests. These coefficients
//! define the same corners and shadows in every renderer. Match numeric
//! tokens in code so a comment cannot hide an accidentally removed value.
const std = @import("std");
const testing = std.testing;

const corners = [_][]const u8{
    "1.52866495", "0.63149399", "0.00759166", "0.06728002",
    "0.00003973", "0.950248",   "0.931599",
};
const erf = [_][]const u8{ "0.278393", "0.230389", "0.078108" };
const dither = [_][]const u8{ "1664525", "22695477" };
const constants = corners ++ erf ++ dither;

const Source = struct {
    name: []const u8,
    code: []const u8,
    missing: []const []const u8 = &.{},
};

const sources = [_]Source{
    .{ .name = "Metal", .code = @embedFile("shader.metal") },
    .{ .name = "OpenGL", .code = @embedFile("shader.glsl") },
    .{ .name = "D3D11", .code = @embedFile("shader.hlsl") ++ "\n" ++ @embedFile("corner_sdf.hlsl") },
    .{ .name = "CPU", .code = @embedFile("raster.zig") ++ "\n" ++ @embedFile("raster_shapes.zig") },
    .{ .name = "WebGPU", .code = @embedFile("shader.wgsl") ++ "\n" ++ @embedFile("shader_shapes.wgsl") },
};

test "renderer corner and shadow coefficients stay in sync" {
    for (sources) |source| {
        for (constants) |value| {
            const present = hasNumber(source.code, value);
            const allowed = for (source.missing) |gap| {
                if (std.mem.eql(u8, gap, value)) break true;
            } else false;
            if (present == allowed) {
                std.debug.print("{s}: {s} coefficient {s}\n", .{
                    source.name, if (allowed) "remove stale allowance for" else "missing", value,
                });
                return error.ShaderCoefficientDrift;
            }
        }
    }
}

fn hasNumber(code: []const u8, wanted: []const u8) bool {
    var i: usize = 0;
    while (i < code.len) {
        if (std.mem.startsWith(u8, code[i..], "//")) {
            i += std.mem.indexOfScalar(u8, code[i..], '\n') orelse return false;
        } else if (std.mem.startsWith(u8, code[i..], "/*")) {
            const end = std.mem.indexOf(u8, code[i + 2 ..], "*/") orelse return false;
            i += end + 4;
        } else if (std.ascii.isAlphanumeric(code[i]) or code[i] == '_' or code[i] == '.') {
            const start = i;
            while (i < code.len and (std.ascii.isAlphanumeric(code[i]) or code[i] == '_' or code[i] == '.')) : (i += 1) {}
            const token = std.mem.trimEnd(u8, code[start..i], "uUfF");
            if (std.mem.eql(u8, token, wanted)) return true;
        } else i += 1;
    }
    return false;
}

test "shader coefficient checks ignore comments and match whole numbers" {
    try testing.expect(hasNumber("uint h = x * 1664525u;", "1664525"));
    try testing.expect(hasNumber("float c = 0.950248f;", "0.950248"));
    try testing.expect(!hasNumber("// 0.950248\n/* 0.950248 */ float c = 0.95;", "0.950248"));
    try testing.expect(!hasNumber("float c = 10.950248;", "0.950248"));
    try testing.expect(!hasNumber("constant_1664525", "1664525"));
}
