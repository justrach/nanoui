//! TypeScript declarations and the JavaScript client, generated at comptime
//! from bound services and events. Zig keeps no parameter names in function
//! types, so a service may name them: `pub const nanoui_params = .{ .greet = .{"name"} };`
const std = @import("std");

/// A named type declaration (`interface X {...}` or `type X = ...`), deduped
/// by name across services.
pub const Decl = struct { name: []const u8, source: []const u8 };

pub fn shortName(comptime T: type) []const u8 {
    if (@hasDecl(T, "nanoui_name")) return T.nanoui_name;
    const full = @typeName(T);
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

/// True for the methods a service exposes: public functions whose first
/// parameter is the service itself.
pub fn isMethod(comptime T: type, comptime name: []const u8) bool {
    const F = @TypeOf(@field(T, name));
    const info = @typeInfo(F);
    if (info != .@"fn") return false;
    const f = info.@"fn";
    if (f.is_generic or f.param_types.len == 0 or name[0] == '_') return false;
    const P = f.param_types[0] orelse return false;
    return P == T or P == *T or P == *const T;
}

pub fn methodNames(comptime T: type) []const []const u8 {
    comptime {
        var names: []const []const u8 = &.{};
        for (@typeInfo(T).@"struct".decl_names) |name| {
            if (isMethod(T, name)) names = names ++ .{name};
        }
        return names;
    }
}

fn isCallParam(comptime P: type) bool {
    if (@typeInfo(P) != .pointer) return false;
    const C = @typeInfo(P).pointer.child;
    return switch (@typeInfo(C)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(C, "nanoui_call_context"),
        else => false,
    };
}

fn paramName(comptime T: type, comptime method: []const u8, comptime i: usize) []const u8 {
    if (@hasDecl(T, "nanoui_params") and @hasField(@TypeOf(T.nanoui_params), method)) {
        const names = @field(T.nanoui_params, method);
        if (i < names.len) return names[i];
    }
    return std.fmt.comptimePrint("arg{d}", .{i});
}

/// The TypeScript type of `T`, appending the declarations it needs to `decls`.
pub fn tsType(comptime T: type, comptime decls: *[]const Decl) []const u8 {
    comptime {
        if (T == std.json.Value) return "unknown";
        switch (@typeInfo(T)) {
            .void, .null => return "void",
            .bool => return "boolean",
            .int, .float, .comptime_int, .comptime_float => return "number",
            .optional => |o| return tsType(o.child, decls) ++ " | null",
            .error_union => |e| return tsType(e.payload, decls),
            .array => |a| return if (a.child == u8) "string" else arrayOf(tsType(a.child, decls)),
            .pointer => |p| switch (p.size) {
                .slice => return if (p.child == u8) "string" else arrayOf(tsType(p.child, decls)),
                .one => {
                    if (@typeInfo(p.child) == .array) return tsType(p.child, decls);
                    return tsType(p.child, decls);
                },
                else => @compileError("nanoui: unsupported pointer type " ++ @typeName(T)),
            },
            .@"enum" => |e| {
                const name = shortName(T);
                if (!hasDecl(decls.*, name)) {
                    var src: []const u8 = "export type " ++ name ++ " =";
                    for (e.field_names, 0..) |f, i| src = src ++ (if (i == 0) " " else " | ") ++ "\"" ++ f ++ "\"";
                    decls.* = decls.* ++ .{Decl{ .name = name, .source = src ++ ";" }};
                }
                return name;
            },
            .@"struct" => |s| {
                if (s.is_tuple) @compileError("nanoui: tuples are not supported: " ++ @typeName(T));
                const name = shortName(T);
                if (!hasDecl(decls.*, name)) {
                    // Reserve the name first so recursive types terminate.
                    const index = decls.len;
                    decls.* = decls.* ++ .{Decl{ .name = name, .source = "" }};
                    var src: []const u8 = "export interface " ++ name ++ " {\n";
                    for (s.field_names, s.field_types) |f, FT| {
                        const optional = @typeInfo(FT) == .optional;
                        src = src ++ "  " ++ f ++ (if (optional) "?" else "") ++ ": " ++ tsType(FT, decls) ++ ";\n";
                    }
                    var copy = decls.*[0..decls.len].*;
                    copy[index].source = src ++ "}";
                    decls.* = &copy;
                }
                return name;
            },
            else => @compileError("nanoui: unsupported type " ++ @typeName(T)),
        }
    }
}

fn arrayOf(comptime t: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, t, ' ') != null) "(" ++ t ++ ")[]" else t ++ "[]";
}

fn hasDecl(decls: []const Decl, name: []const u8) bool {
    for (decls) |d| if (std.mem.eql(u8, d.name, name)) return true;
    return false;
}

pub const Service = struct {
    /// `export declare const Name: {...};`
    dts: []const u8,
    /// `export const Name = ...;`
    js: []const u8,
    decls: []const Decl,
};

pub fn service(comptime T: type) Service {
    comptime {
        @setEvalBranchQuota(100_000);
        var decls: []const Decl = &.{};
        const name = shortName(T);
        var dts: []const u8 = "export declare const " ++ name ++ ": {\n";
        var js: []const u8 = "export const " ++ name ++ " = Object.freeze({\n";
        for (methodNames(T)) |m| {
            const f = @typeInfo(@TypeOf(@field(T, m))).@"fn";
            var params: []const u8 = "";
            var n = 0;
            for (f.param_types[1..]) |P| {
                if (isCallParam(P.?)) continue;
                params = params ++ (if (n > 0) ", " else "") ++ paramName(T, m, n) ++ ": " ++ tsType(P.?, &decls);
                n += 1;
            }
            dts = dts ++ "  " ++ m ++ "(" ++ params ++ "): Promise<" ++ tsType(f.return_type.?, &decls) ++ ">;\n";
            js = js ++ "  " ++ m ++ ": (...a) => window.nanoui.call(\"" ++ name ++ "." ++ m ++ "\", ...a),\n";
        }
        const d = decls[0..decls.len].*;
        return .{ .dts = dts ++ "};\n", .js = js ++ "});\n", .decls = &d };
    }
}

pub fn event(comptime name: []const u8, comptime T: type) Service {
    comptime {
        @setEvalBranchQuota(100_000);
        var decls: []const Decl = &.{};
        const fn_name = "on" ++ pascal(name);
        const ty = tsType(T, &decls);
        const d = decls[0..decls.len].*;
        return .{
            .dts = "export declare function " ++ fn_name ++ "(listener: (payload: " ++ ty ++ ") => void): () => void;\n",
            .js = "export const " ++ fn_name ++ " = (fn) => window.nanoui.on(\"" ++ name ++ "\", fn);\n",
            .decls = &d,
        };
    }
}

fn pascal(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var upper = true;
        for (s) |c| {
            if (c == '-' or c == '_' or c == ':' or c == '.') {
                upper = true;
                continue;
            }
            out = out ++ .{if (upper) std.ascii.toUpper(c) else c};
            upper = false;
        }
        return out;
    }
}

pub const runtime_dts =
    \\// Generated by nanoui. Do not edit.
    \\export declare const nanoui: {
    \\  call(method: string, ...args: unknown[]): Promise<unknown>;
    \\  on(event: string, listener: (payload: unknown) => void): () => void;
    \\  once(event: string, listener: (payload: unknown) => void): () => void;
    \\  log(...values: unknown[]): void;
    \\  window: { close(): void; minimize(): void; toggleMaximize(): void; setTitle(title: string): void };
    \\  platform: "macos" | "windows" | "linux";
    \\  version: string;
    \\};
    \\
;

pub const runtime_js =
    \\// Generated by nanoui. Do not edit.
    \\export const nanoui = window.nanoui;
    \\
;

test "types" {
    const Todo = struct { id: u32, title: []const u8, done: bool, note: ?[]const u8 };
    comptime var decls: []const Decl = &.{};
    try std.testing.expectEqualStrings("Todo[]", comptime tsType([]const Todo, &decls));
    try std.testing.expectEqualStrings("(string | null)[]", comptime tsType([]const ?[]const u8, &decls));
    try std.testing.expectEqualStrings(
        "export interface Todo {\n  id: number;\n  title: string;\n  done: boolean;\n  note?: string | null;\n}",
        decls[0].source,
    );
}
