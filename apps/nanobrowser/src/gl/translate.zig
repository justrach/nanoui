//! A page's shaders in the dialect the Mac's OpenGL reads: GLSL ES 1.00 as GLSL 1.20 on a
//! WebGL 1 context (the legacy profile), GLSL ES 3.00 or 1.00 as GLSL 4.10 on a WebGL 2
//! context (the core profile). Words only: it scans tokens, doesn't parse, so a shader that
//! was wrong stays wrong and the driver's compiler says so. Nothing here checks what
//! ANGLE would; see the README.
const std = @import("std");

pub const Target = enum { legacy_120, core_410 };
pub const Stage = enum { vertex, fragment };
pub const Output = union(enum) {
    /// The source for `glShaderSource`, the caller's to free.
    source: []u8,
    /// Why the shader can't be, for its info log.
    failed: []const u8,
};

const Dialect = enum { es100, es300 };

const Version = struct { dialect: Dialect, line_start: usize, line_end: usize };

/// Where the shader's `#version` line is, if any, past the comments and space before it.
fn findVersion(src: []const u8) error{Unsupported}!?Version {
    var i: usize = 0;
    while (i < src.len) {
        if (std.ascii.isWhitespace(src[i])) {
            i += 1;
        } else if (std.mem.startsWith(u8, src[i..], "//")) {
            i = lineEnd(src, i);
        } else if (std.mem.startsWith(u8, src[i..], "/*")) {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/") orelse return null;
            i = close + 2;
        } else break;
    }
    if (i >= src.len or src[i] != '#') return null;
    const end = lineEnd(src, i);
    var words = std.mem.tokenizeAny(u8, src[i + 1 .. end], " \t\r");
    if (!std.mem.eql(u8, words.next() orelse "", "version")) return null;
    const number = words.next() orelse "";
    const profile = words.next() orelse "";
    if (std.mem.eql(u8, number, "300") and std.mem.eql(u8, profile, "es"))
        return .{ .dialect = .es300, .line_start = i, .line_end = end };
    if (std.mem.eql(u8, number, "100") and profile.len == 0)
        return .{ .dialect = .es100, .line_start = i, .line_end = end };
    return error.Unsupported;
}

fn lineEnd(src: []const u8, from: usize) usize {
    return std.mem.indexOfScalarPos(u8, src, from, '\n') orelse src.len;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const Rename = struct { from: []const u8, to: []const u8 };

/// ES's own predefined macros, which a desktop compiler would refuse to see defined.
const macros = [_]Rename{
    .{ .from = "GL_ES", .to = "NB_GL_ES" },
    .{ .from = "GL_FRAGMENT_PRECISION_HIGH", .to = "NB_FRAGMENT_PRECISION_HIGH" },
    .{ .from = "GL_OES_standard_derivatives", .to = "NB_OES_standard_derivatives" },
};

/// GLSL ES 1.00's words where the core profile has others; a WebGL 2 context takes it.
const to_core = [_]Rename{
    .{ .from = "texture2D", .to = "texture" },
    .{ .from = "texture2DProj", .to = "textureProj" },
    .{ .from = "texture2DLod", .to = "textureLod" },
    .{ .from = "texture2DProjLod", .to = "textureProjLod" },
    .{ .from = "textureCube", .to = "texture" },
    .{ .from = "textureCubeLod", .to = "textureLod" },
    .{ .from = "gl_FragColor", .to = "nb_FragColor" },
    .{ .from = "gl_FragData", .to = "nb_FragData" },
};

fn renamed(table: []const Rename, word: []const u8) ?[]const u8 {
    for (table) |r| if (std.mem.eql(u8, r.from, word)) return r.to;
    return null;
}

const Body = struct {
    text: std.ArrayList(u8) = .empty,
    frag_color: bool = false,
    frag_data: bool = false,
};

/// The `#extension` line, if `src` has one at `i`, that the target has no use for.
fn knownExtensionLine(src: []const u8, i: usize) bool {
    if (src[i] != '#') return false;
    const line = src[i + 1 .. lineEnd(src, i)];
    var words = std.mem.tokenizeAny(u8, line, " \t\r:");
    if (!std.mem.eql(u8, words.next() orelse "", "extension")) return false;
    return std.mem.eql(u8, words.next() orelse "", "GL_OES_standard_derivatives");
}

/// Copies `n` bytes of `src` from `i`, newlines kept and everything else spaces, so
/// the driver's log still counts the page's lines.
fn blank(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| try out.append(a, if (c == '\n') '\n' else ' ');
}

fn scan(a: std.mem.Allocator, src: []const u8, dialect: Dialect, target: Target, stage: Stage, skip: ?Version) !Body {
    var b: Body = .{};
    errdefer b.text.deinit(a);
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (skip) |v| if (i == v.line_start) {
            try blank(a, &b.text, src[v.line_start..v.line_end]);
            i = v.line_end;
            continue;
        };
        if (std.mem.startsWith(u8, src[i..], "//")) {
            const end = lineEnd(src, i);
            try b.text.appendSlice(a, src[i..end]);
            i = end;
        } else if (std.mem.startsWith(u8, src[i..], "/*")) {
            const end = if (std.mem.indexOfPos(u8, src, i + 2, "*/")) |e| e + 2 else src.len;
            try b.text.appendSlice(a, src[i..end]);
            i = end;
        } else if (knownExtensionLine(src, i)) {
            const end = lineEnd(src, i);
            try blank(a, &b.text, src[i..end]);
            i = end;
        } else if (isIdentStart(c)) {
            var e = i + 1;
            while (e < src.len and isIdent(src[e])) e += 1;
            const word = src[i..e];
            i = e;
            if (target == .legacy_120 and std.mem.eql(u8, word, "precision")) {
                const end = std.mem.indexOfScalarPos(u8, src, i, ';') orelse src.len;
                try blank(a, &b.text, word);
                try blank(a, &b.text, src[i..@min(end + 1, src.len)]);
                i = @min(end + 1, src.len);
                continue;
            }
            if (std.mem.eql(u8, word, "__VERSION__")) {
                try b.text.appendSlice(a, if (dialect == .es300) "300" else "100");
                continue;
            }
            if (renamed(&macros, word)) |to| {
                try b.text.appendSlice(a, to);
                continue;
            }
            if (target == .core_410 and dialect == .es100) {
                if (std.mem.eql(u8, word, "attribute")) {
                    try b.text.appendSlice(a, "in");
                    continue;
                }
                if (std.mem.eql(u8, word, "varying")) {
                    try b.text.appendSlice(a, if (stage == .vertex) "out" else "in");
                    continue;
                }
                if (renamed(&to_core, word)) |to| {
                    if (std.mem.eql(u8, word, "gl_FragColor")) b.frag_color = true;
                    if (std.mem.eql(u8, word, "gl_FragData")) b.frag_data = true;
                    try b.text.appendSlice(a, to);
                    continue;
                }
            }
            try b.text.appendSlice(a, word);
        } else if (std.ascii.isDigit(c)) {
            // A number's letters (`1e5`, `0x1f`) aren't a word.
            var e = i + 1;
            while (e < src.len and isIdent(src[e])) e += 1;
            try b.text.appendSlice(a, src[i..e]);
            i = e;
        } else {
            try b.text.append(a, c);
            i += 1;
        }
    }
    return b;
}

const macro_defines = "#define NB_GL_ES 1\n#define NB_OES_standard_derivatives 1\n";

/// `src` as the driver wants it.
pub fn translate(a: std.mem.Allocator, src: []const u8, target: Target, stage: Stage) !Output {
    const version = findVersion(src) catch return .{ .failed = "ERROR: 0:1: '' : this #version is not available here\n" };
    const dialect: Dialect = if (version) |v| v.dialect else .es100;
    if (dialect == .es300 and target == .legacy_120)
        return .{ .failed = "ERROR: 0:1: '' : GLSL ES 3.00 needs a WebGL 2 context\n" };
    var body = try scan(a, src, dialect, target, stage, version);
    defer body.text.deinit(a);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    switch (target) {
        .legacy_120 => {
            try out.appendSlice(a, "#version 120\n#define lowp\n#define mediump\n#define highp\n");
        },
        .core_410 => {
            try out.appendSlice(a, "#version 410 core\n");
            if (body.frag_color) try out.appendSlice(a, "layout(location = 0) out vec4 nb_FragColor;\n");
            if (body.frag_data) try out.appendSlice(a, "layout(location = 0) out vec4 nb_FragData[1];\n");
        },
    }
    try out.appendSlice(a, macro_defines);
    if (stage == .fragment) try out.appendSlice(a, "#define NB_FRAGMENT_PRECISION_HIGH 1\n");
    try out.appendSlice(a, "#line 1\n");
    try out.appendSlice(a, body.text.items);
    return .{ .source = try out.toOwnedSlice(a) };
}

const testing = std.testing;

fn expectSource(src: []const u8, target: Target, stage: Stage) ![]u8 {
    const got = try translate(testing.allocator, src, target, stage);
    return switch (got) {
        .source => |s| s,
        .failed => |why| {
            std.debug.print("failed: {s}\n", .{why});
            return error.TestFailed;
        },
    };
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "webgl translate: ES 1.00 to 1.20 drops precision and defines the qualifiers empty" {
    const s = try expectSource("precision mediump float;\nvarying lowp vec4 v;\nvoid main(){gl_FragColor=v;}", .legacy_120, .fragment);
    defer testing.allocator.free(s);
    try testing.expect(std.mem.startsWith(u8, s, "#version 120\n"));
    try testing.expect(!has(s, "precision"));
    try testing.expect(has(s, "#define lowp\n#define mediump\n#define highp\n"));
    try testing.expect(has(s, "varying lowp vec4 v;"));
    try testing.expect(has(s, "gl_FragColor=v"));
}

test "webgl translate: a word that only contains precision stays, and so do comments" {
    const s = try expectSource("// precision mediump float;\n/* precision */ float myprecision; uniform float precision_;\nvoid main(){}", .legacy_120, .vertex);
    defer testing.allocator.free(s);
    try testing.expect(has(s, "// precision mediump float;"));
    try testing.expect(has(s, "/* precision */"));
    try testing.expect(has(s, "float myprecision;"));
    try testing.expect(has(s, "precision_"));
}

test "webgl translate: dropped lines keep the page's line numbers" {
    const s = try expectSource("#version 100\nprecision\n highp float;\nvoid main(){}", .legacy_120, .vertex);
    defer testing.allocator.free(s);
    const after = s[std.mem.indexOf(u8, s, "#line 1\n").? + 8 ..];
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, after, "\n"));
    try testing.expect(std.mem.endsWith(u8, after, "void main(){}"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, s, "#version"));
}

test "webgl translate: 300 es becomes 410 core, keeping what it means" {
    const s = try expectSource("#version 300 es\nprecision highp float;\nin vec2 p;out vec4 c;\nvoid main(){c=vec4(p,0,1);}", .core_410, .fragment);
    defer testing.allocator.free(s);
    try testing.expect(std.mem.startsWith(u8, s, "#version 410 core\n"));
    try testing.expect(!has(s, "300 es"));
    try testing.expect(has(s, "in vec2 p;out vec4 c;"));
}

test "webgl translate: 300 es is refused on a WebGL 1 context and other versions anywhere" {
    const one = try translate(testing.allocator, "#version 300 es\nvoid main(){}", .legacy_120, .vertex);
    try testing.expect(one == .failed);
    const two = try translate(testing.allocator, "#version 450\nvoid main(){}", .core_410, .vertex);
    try testing.expect(two == .failed);
}

test "webgl translate: ES 1.00 on a WebGL 2 context reads as core" {
    const v = try expectSource("attribute vec2 a;varying vec2 t;void main(){t=a;gl_Position=vec4(a,0,1);}", .core_410, .vertex);
    defer testing.allocator.free(v);
    try testing.expect(has(v, "in vec2 a;out vec2 t;"));
    const f = try expectSource("precision mediump float;varying vec2 t;uniform sampler2D s;void main(){gl_FragColor=texture2D(s,t);}", .core_410, .fragment);
    defer testing.allocator.free(f);
    try testing.expect(has(f, "in vec2 t;"));
    try testing.expect(has(f, "out vec4 nb_FragColor;"));
    try testing.expect(has(f, "nb_FragColor=texture(s,t)"));
}

test "webgl translate: ES's macros and the derivatives extension" {
    const s = try expectSource("#extension GL_OES_standard_derivatives : enable\n#ifdef GL_ES\nprecision highp float;\n#endif\nvoid main(){gl_FragColor=vec4(dFdx(1e5));}", .legacy_120, .fragment);
    defer testing.allocator.free(s);
    try testing.expect(!has(s, "#extension"));
    try testing.expect(has(s, "#ifdef NB_GL_ES"));
    try testing.expect(has(s, "dFdx(1e5)"));
}
