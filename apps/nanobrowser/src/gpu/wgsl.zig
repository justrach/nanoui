//! Deliberately bounded WGSL -> Metal compiler. Parsing is independent of emission;
//! unsupported constructs fail with source positions, never substitute a shader.
const std = @import("std");
const ast = @import("wgsl_ast.zig");
const lex = @import("wgsl_lex.zig");
const E = lex.Error;
pub const Entry = struct { name: []const u8, stage: ast.Stage, workgroup: [3]usize = .{ 1, 1, 1 }, bindings: u8 = 0 };
pub const Binding = struct { name: []const u8, slot: usize, stride: usize, writable: bool, kind: enum { storage, uniform } = .storage, min_size: usize = 4, visibility: u8 = 0 };
pub const Translation = struct { source: []const u8, entries: []const Entry, bindings: []const Binding };
pub const Sink = lex.Sink;

pub fn translate(a: std.mem.Allocator, sink: *Sink, source: []const u8) E!Translation {
    if (source.len > 65536) return sink.fail(.{}, "shader exceeds the supported 64 KiB limit", .{});
    // Bound parser recursion and compilation work before building the AST.
    var lexer: lex.Lexer = .{ .src = source, .sink = sink };
    var depth: usize = 0;
    var tokens: usize = 0;
    var unary_run: usize = 0;
    while (true) {
        const t = try lexer.next();
        if (t.tag == .eof) break;
        tokens += 1;
        switch (t.tag) {
            .lparen, .lbrace, .lbracket, .lt => depth += 1,
            .rparen, .rbrace, .rbracket, .gt => depth -|= 1,
            .shr => depth -|= 2,
            else => {},
        }
        unary_run = switch (t.tag) {
            .minus, .bang, .tilde, .amp, .star => unary_run + 1,
            else => 0,
        };
        if (depth > 64 or unary_run > 64 or tokens > 4096) return sink.fail(t.pos, "shader exceeds supported nesting or token limit", .{});
    }
    const module = try @import("wgsl_parse.zig").parse(a, sink, source);
    var w: Writer = .{ .a = a, .sink = sink, .module = module };
    try w.put("#include <metal_stdlib>\nusing namespace metal;\n");
    for (module.decls) |d| switch (d) {
        .global => |g| try w.global(g),
        .strct => |s| {
            try w.fmt("struct {s} {{\n", .{s.name});
            for (s.members) |m| {
                try w.attrs(m.attrs, .member);
                try w.ty(m.ty);
                try w.fmt(" {s}", .{m.name});
                try w.attribute(m.attrs, false);
                try w.put(";\n");
            }
            try w.put("};\n");
        },
        .constant => |c| {
            if (c.ty == null) return sink.fail(c.pos, "module constants require explicit types in this subset", .{});
            try w.put("constant ");
            try w.ty(c.ty.?);
            try w.fmt(" {s} = ", .{c.name});
            try w.expr(c.init);
            try w.put(";\n");
        },
        .func => {},
        else => return sink.fail(.{}, "unsupported WGSL declaration", .{}),
    };
    for (module.decls) |d| if (d == .func) try w.function(d.func);
    if (w.entries.items.len == 0) return sink.fail(.{}, "shader has no supported entry point", .{});
    return .{ .source = w.out.items, .entries = w.entries.items, .bindings = w.bindings.items };
}
const Writer = struct {
    a: std.mem.Allocator,
    sink: *Sink,
    out: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    bindings: std.ArrayList(Binding) = .empty,
    stage: ast.Stage = .compute,
    module: ast.Module,
    used_bindings: u8 = 0,
    arrays: std.StringHashMapUnmanaged(usize) = .empty,
    fn useBinding(w: *Writer, name: []const u8) void {
        for (w.bindings.items) |*b| if (eq(b.name, name)) {
            w.used_bindings |= @as(u8, 1) << @intCast(b.slot);
            b.visibility |= switch (w.stage) {
                .vertex => @as(u8, 1),
                .fragment => 2,
                .compute => 4,
            };
        };
    }
    fn put(w: *Writer, s: []const u8) E!void {
        try w.out.appendSlice(w.a, s);
    }
    fn fmt(w: *Writer, comptime s: []const u8, args: anytype) E!void {
        try w.put(try std.fmt.allocPrint(w.a, s, args));
    }
    fn eq(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
    fn integer(w: *Writer, e: *ast.Expr) E!usize {
        if (e.k == .int and e.k.int.value >= 0 and e.k.int.value <= 65535) return @intCast(e.k.int.value);
        return w.sink.fail(e.pos, "expected a nonnegative literal integer <= 65535", .{});
    }
    fn attrs(w: *Writer, a: ast.Attrs, place: enum { entry, member, param, global }) E!void {
        if (a.interpolate != null or a.align_ != null or a.size != null or a.id != null or a.must_use or a.invariant)
            return w.sink.fail(a.pos, "unsupported WGSL attribute", .{});
        if ((a.group != null or a.binding != null) and place != .global) return w.sink.fail(a.pos, "binding attributes only supported on globals", .{});
        if ((a.stage != null or a.workgroup_size != null) and place != .entry) return w.sink.fail(a.pos, "entry point attributes on non-function", .{});
        if ((a.builtin != null or a.location != null) and (place == .entry or place == .global)) return w.sink.fail(a.pos, "invalid IO attributes", .{});
        if (a.builtin != null and a.location != null) return w.sink.fail(a.pos, "conflicting IO attributes", .{});
    }
    fn attribute(w: *Writer, a: ast.Attrs, ret: bool) E!void {
        if (a.builtin) |b| {
            const m = if (eq(b, "position")) "position" else if (eq(b, "vertex_index")) "vertex_id" else if (eq(b, "instance_index")) "instance_id" else if (eq(b, "global_invocation_id")) "thread_position_in_grid" else if (eq(b, "local_invocation_id")) "thread_position_in_threadgroup" else if (eq(b, "workgroup_id")) "threadgroup_position_in_grid" else return w.sink.fail(a.builtin_pos, "unsupported builtin '{s}'", .{b});
            try w.fmt(" [[{s}]]", .{m});
        }
        if (a.location) |l| {
            const n = try w.integer(l);
            if (n > 7) return w.sink.fail(l.pos, "only IO locations 0 through 7 are supported", .{});
            if (ret and w.stage == .fragment) try w.fmt(" [[color({d})]]", .{n}) else try w.fmt(" [[user(loc{d})]]", .{n});
        }
    }
    fn ty(w: *Writer, e: *ast.Expr) E!void {
        switch (e.k) {
            .ident => |n| {
                const names = [_][]const u8{ "f32", "u32", "i32", "bool", "vec2f", "vec3f", "vec4f", "vec2u", "vec3u", "vec4u", "vec2i", "vec3i", "vec4i" };
                const metal = [_][]const u8{ "float", "uint", "int", "bool", "float2", "float3", "float4", "uint2", "uint3", "uint4", "int2", "int3", "int4" };
                for (names, metal) |s, m| if (eq(n, s)) return w.put(m);
                if (eq(n, "f16") or std.mem.startsWith(u8, n, "texture") or eq(n, "sampler")) return w.sink.fail(e.pos, "unsupported type '{s}'", .{n});
                try w.put(n); // user struct; Metal validates unknown names.
            },
            .tmpl => |t| {
                if ((eq(t.name, "vec2") or eq(t.name, "vec3") or eq(t.name, "vec4")) and t.args.len == 1) {
                    try w.ty(t.args[0]);
                    try w.put(t.name[3..]);
                } else if (eq(t.name, "array") and t.args.len == 2) {
                    const n = try w.integer(t.args[1]);
                    if (n == 0 or n > 4096) return w.sink.fail(e.pos, "unsupported array length", .{});
                    try w.put("array<");
                    try w.ty(t.args[0]);
                    try w.fmt(", {d}>", .{n});
                } else return w.sink.fail(e.pos, "unsupported template type '{s}'", .{t.name});
            },
            else => return w.sink.fail(e.pos, "expected a type", .{}),
        }
    }
    fn global(w: *Writer, g: *ast.Global) E!void {
        try w.attrs(g.attrs, .global);
        const uniform = eq(g.space orelse "", "uniform");
        if ((!uniform and !eq(g.space orelse "", "storage")) or g.ty == null or g.init != null or g.attrs.group == null or g.attrs.binding == null)
            return w.sink.fail(g.pos, "only group(0) storage arrays and scalar uniform structs are supported as globals", .{});
        if (try w.integer(g.attrs.group.?) != 0) return w.sink.fail(g.pos, "only bind group 0 is supported", .{});
        const slot = try w.integer(g.attrs.binding.?);
        if (slot >= 8) return w.sink.fail(g.pos, "only bindings 0 through 7 are supported", .{});
        for (w.bindings.items) |b| if (b.slot == slot or eq(b.name, g.name)) return w.sink.fail(g.pos, "duplicate storage binding", .{});
        const t = g.ty.?.k;
        if (uniform) {
            if (g.access != null or t != .ident) return w.sink.fail(g.pos, "uniform requires a scalar struct without an access qualifier", .{});
            var size: usize = 0;
            for (w.module.decls) |d| if (d == .strct and eq(d.strct.name, t.ident)) {
                for (d.strct.members) |m| {
                    try w.attrs(m.attrs, .member);
                    if (m.attrs.builtin != null or m.attrs.location != null or m.ty.k != .ident or
                        (!eq(m.ty.k.ident, "f32") and !eq(m.ty.k.ident, "u32") and !eq(m.ty.k.ident, "i32")))
                        return w.sink.fail(m.pos, "uniform structs support only undecorated f32, u32 and i32 fields", .{});
                    size += 4;
                }
                break;
            };
            if (size == 0) return w.sink.fail(g.pos, "uniform requires a nonempty declared scalar struct", .{});
            try w.bindings.append(w.a, .{ .name = g.name, .slot = slot, .stride = 0, .writable = false, .kind = .uniform, .min_size = size });
            try w.fmt("typedef {s} __element{d};\n", .{ t.ident, slot });
            return;
        }
        if (t != .tmpl or !eq(t.tmpl.name, "array") or t.tmpl.args.len != 1 or t.tmpl.args[0].k != .ident)
            return w.sink.fail(g.pos, "storage must be a runtime array of f32, i32 or u32", .{});
        const scalar = t.tmpl.args[0].k.ident;
        if (!eq(scalar, "f32") and !eq(scalar, "i32") and !eq(scalar, "u32")) return w.sink.fail(g.pos, "unsupported storage element type", .{});
        const access = g.access orelse "read";
        if (!eq(access, "read") and !eq(access, "read_write")) return w.sink.fail(g.pos, "unsupported storage access", .{});
        try w.bindings.append(w.a, .{ .name = g.name, .slot = slot, .stride = 4, .writable = eq(access, "read_write") });
        // Record its type for function signatures without retaining a second table.
        try w.fmt("typedef {s} __element{d};\n", .{ if (eq(scalar, "f32")) "float" else if (eq(scalar, "u32")) "uint" else "int", slot });
    }
    fn function(w: *Writer, f: *ast.Func) E!void {
        try w.attrs(f.attrs, .entry);
        const stage = f.attrs.stage orelse return w.sink.fail(f.pos, "helper functions are not supported yet", .{});
        w.stage = stage;
        w.arrays.clearRetainingCapacity();
        w.used_bindings = 0;
        if (stage != .compute) for (w.bindings.items) |b| {
            if (b.kind == .storage) return w.sink.fail(f.pos, "render storage bindings are not supported", .{});
        };
        var entry: Entry = .{ .name = f.name, .stage = stage };
        if (stage == .compute) {
            const size = f.attrs.workgroup_size orelse return w.sink.fail(f.pos, "compute requires workgroup_size", .{});
            for (size, 0..) |n, i| if (n) |v| {
                entry.workgroup[i] = try w.integer(v);
            };
            if (entry.workgroup[0] == 0 or entry.workgroup[1] == 0 or entry.workgroup[2] == 0 or entry.workgroup[0] * entry.workgroup[1] * entry.workgroup[2] > 256)
                return w.sink.fail(f.pos, "workgroup size must contain 1 through 256 threads", .{});
            if (f.ret != null) return w.sink.fail(f.pos, "compute entry cannot return a value", .{});
        } else if (f.attrs.workgroup_size != null) return w.sink.fail(f.pos, "workgroup_size on a render entry", .{});
        for (w.entries.items) |old| if (eq(old.name, entry.name)) return w.sink.fail(f.pos, "duplicate entry point", .{});
        try w.put(switch (stage) {
            .compute => "kernel ",
            .vertex => "vertex ",
            .fragment => "fragment ",
        });
        if (f.ret) |r| try w.ty(r) else try w.put("void");
        try w.fmt(" __wgsl_{s}(", .{f.name});
        var count: usize = 0;
        for (f.params) |p| {
            for (w.bindings.items) |b| if (eq(b.name, p.name)) return w.sink.fail(p.pos, "shadowing storage bindings is unsupported", .{});
            try w.attrs(p.attrs, .param);
            if (count > 0) try w.put(", ");
            try w.ty(p.ty);
            try w.fmt(" {s}", .{p.name});
            try w.attribute(p.attrs, false);
            if (p.attrs.builtin == null and p.attrs.location == null) {
                if (stage != .fragment) return w.sink.fail(p.pos, "only fragment struct stage input is supported", .{});
                try w.put(" [[stage_in]]");
            }
            count += 1;
        }
        for (w.bindings.items) |b| {
            if (count > 0) try w.put(", ");
            if (b.kind == .uniform)
                try w.fmt("constant __element{d}& {s} [[buffer({d})]]", .{ b.slot, b.name, b.slot })
            else
                try w.fmt("device {s}__element{d}* {s} [[buffer({d})]], constant uint& __len{d} [[buffer({d})]]", .{ if (b.writable) "" else "const ", b.slot, b.name, b.slot, b.slot, b.slot + 8 });
            count += 1;
        }
        try w.put(")");
        try w.attrs(f.ret_attrs, .param);
        // Direct Metal stage returns imply position / color(0); attributes belong
        // to struct fields, not the function return type.
        if (stage == .fragment and f.ret_attrs.location == null) return w.sink.fail(f.pos, "fragment output requires explicit location(0)", .{});
        if (stage == .vertex and f.ret_attrs.builtin == null and f.ret != null and (f.ret.?.k == .tmpl or (f.ret.?.k == .ident and std.mem.startsWith(u8, f.ret.?.k.ident, "vec")))) return w.sink.fail(f.pos, "vertex vector return requires builtin(position)", .{});
        if (f.ret_attrs.builtin) |b| {
            if (stage != .vertex or !eq(b, "position")) return w.sink.fail(f.pos, "unsupported entry return builtin", .{});
        }
        if (f.ret_attrs.location) |l| {
            if (stage != .fragment or try w.integer(l) != 0) return w.sink.fail(f.pos, "only fragment return location 0 supported", .{});
        }
        try w.block(f.body);
        entry.bindings = w.used_bindings;
        try w.entries.append(w.a, entry);
    }
    fn block(w: *Writer, body: []const *ast.Stmt) E!void {
        try w.put("{\n");
        for (body) |s| try w.stmt(s);
        try w.put("}\n");
    }
    fn stmt(w: *Writer, s: *ast.Stmt) E!void {
        switch (s.k) {
            .block => |b| return w.block(b),
            .decl => |v| {
                if (w.arrays.contains(v.name)) return w.sink.fail(v.name_pos, "shadowing local arrays is unsupported", .{});
                for (w.bindings.items) |b| if (eq(b.name, v.name)) return w.sink.fail(v.name_pos, "shadowing storage bindings is unsupported", .{});
                const type_expr = v.ty orelse if (v.init != null and v.init.?.k == .call) v.init.?.k.call.callee else null;
                if (type_expr) |t| {
                    if (t.k == .tmpl and eq(t.k.tmpl.name, "array") and t.k.tmpl.args.len == 2)
                        try w.arrays.put(w.a, v.name, try w.integer(t.k.tmpl.args[1]));
                }
                if (v.kind != .var_) try w.put("const ");
                if (v.ty) |t| try w.ty(t) else try w.put("auto");
                try w.fmt(" {s}", .{v.name});
                if (v.init) |e| {
                    try w.put(" = ");
                    try w.expr(e);
                } else if (v.ty != null) try w.put("{}");
            },
            .assign => |a| {
                if (a.lhs) |l| {
                    try w.expr(l);
                    if (a.op) |op| try w.put(bin(op));
                    try w.put("=");
                } else try w.put("(void)");
                try w.expr(a.rhs);
            },
            .ret => |e| {
                try w.put("return ");
                if (e) |v| try w.expr(v);
            },
            .if_ => |i| {
                try w.put("if (");
                try w.expr(i.cond);
                try w.put(")");
                try w.block(i.then);
                if (i.els) |e| {
                    try w.put("else ");
                    try w.stmt(e);
                }
                return;
            },
            .call => |e| try w.expr(e),
            .incdec => |i| {
                try w.expr(i.lhs);
                try w.put(if (i.inc) "++" else "--");
            },
            .discard => {
                if (w.stage != .fragment) return w.sink.fail(s.pos, "discard outside fragment shader", .{});
                try w.put("discard_fragment()");
            },
            else => return w.sink.fail(s.pos, "loops, switch and control directives are unsupported", .{}),
        }
        try w.put(";\n");
    }
    fn bin(op: ast.BinOp) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .band => "&",
            .bor => "|",
            .bxor => "^",
            .shl => "<<",
            .shr => ">>",
            .land => "&&",
            .lor => "||",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
        };
    }
    fn expr(w: *Writer, e: *ast.Expr) E!void {
        switch (e.k) {
            .int => |n| try w.fmt("{d}{s}", .{ n.value, if (n.suffix == 'u') "u" else "" }),
            .float => |n| try w.fmt("float({d})", .{n.value}),
            .boolean => |b| try w.put(if (b) "true" else "false"),
            .ident => |n| {
                w.useBinding(n);
                try w.put(n);
            },
            .tmpl => try w.ty(e),
            .member => |m| {
                try w.expr(m.base);
                try w.fmt(".{s}", .{m.name});
            },
            .index => |i| {
                try w.expr(i.base);
                try w.put("[");
                var binding: ?usize = null;
                if (i.base.k == .ident) for (w.bindings.items) |b| {
                    if (b.kind == .storage and eq(b.name, i.base.k.ident)) {
                        binding = b.slot;
                        break;
                    }
                };
                const local_len = if (i.base.k == .ident) w.arrays.get(i.base.k.ident) else null;
                if (binding == null and local_len == null) return w.sink.fail(e.pos, "indexing requires a named storage or fixed local array", .{});
                try w.put("min(uint(");
                try w.expr(i.i);
                if (binding) |slot| try w.fmt("), __len{d}-1u)", .{slot}) else try w.fmt("), {d}u)", .{local_len.? - 1});
                try w.put("]");
            },
            .unary => |u| {
                if (u.op == .addr or u.op == .deref) return w.sink.fail(e.pos, "pointers are unsupported except in arrayLength", .{});
                try w.put(switch (u.op) {
                    .neg => "(-",
                    .not => "(!",
                    .bitnot => "(~",
                    else => unreachable,
                });
                try w.expr(u.e);
                try w.put(")");
            },
            .binary => |b| {
                try w.put("(");
                try w.expr(b.l);
                try w.put(bin(b.op));
                try w.expr(b.r);
                try w.put(")");
            },
            .call => |c| {
                if (c.callee.k == .ident and eq(c.callee.k.ident, "arrayLength")) {
                    if (c.args.len == 1 and c.args[0].k == .unary and c.args[0].k.unary.op == .addr and c.args[0].k.unary.e.k == .ident) {
                        for (w.bindings.items) |b| if (b.kind == .storage and eq(b.name, c.args[0].k.unary.e.k.ident)) {
                            w.useBinding(b.name);
                            return w.fmt("__len{d}", .{b.slot});
                        };
                    }
                    return w.sink.fail(e.pos, "arrayLength requires a storage array address", .{});
                }
                if (c.callee.k == .ident) {
                    const n = c.callee.k.ident;
                    const allowed = [_][]const u8{ "f32", "u32", "i32", "bool", "vec2f", "vec3f", "vec4f", "vec2u", "vec3u", "vec4u", "vec2i", "vec3i", "vec4i", "min", "max", "clamp", "abs", "sin", "cos", "sqrt", "dot", "normalize", "length", "mix", "floor", "ceil" };
                    var ok = false;
                    for (allowed) |a| if (eq(n, a)) {
                        ok = true;
                        break;
                    };
                    if (!ok) return w.sink.fail(e.pos, "unsupported function or constructor '{s}'", .{n});
                }
                try w.ty(c.callee);
                const arr = c.callee.k == .tmpl and eq(c.callee.k.tmpl.name, "array");
                if (arr and c.args.len != 0 and c.args.len != try w.integer(c.callee.k.tmpl.args[1])) return w.sink.fail(e.pos, "array constructor element count differs from array length", .{});
                try w.put(if (arr) "{" else "(");
                for (c.args, 0..) |arg, i| {
                    if (i > 0) try w.put(",");
                    try w.expr(arg);
                }
                try w.put(if (arr) "}" else ")");
            },
        }
    }
};
