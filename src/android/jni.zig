//! The Java side of Android, through JNI: its function table, called by
//! index as jni.h lays it out (no headers), and calls by method name and
//! signature. Arguments go as arrays (`jvalue`, the `...A` functions):
//! nothing variadic. Each thread has its own `Env` (`attach`); local
//! references live until the frame they were made in pops (`Frame`).
const std = @import("std");

pub const Object = ?*anyopaque;
pub const Method = ?*anyopaque;
pub const Field = ?*anyopaque;

pub const Value = extern union {
    z: u8,
    b: i8,
    c: u16,
    s: i16,
    i: i32,
    j: i64,
    f: f32,
    d: f64,
    l: Object,
};

/// A thread's JNIEnv: a pointer to the function table's pointer.
pub const Env = *const *const [233]?*const anyopaque;
/// The JavaVM: the invocation interface.
pub const VM = *const *const [8]?*const anyopaque;

fn at(env: Env, comptime i: usize, comptime T: type) T {
    return @ptrCast(@alignCast(env.*[i].?));
}

/// `env` for the calling thread, attached to the VM if it wasn't.
pub fn attach(vm: VM) ?Env {
    var env: ?Env = null;
    const get: *const fn (VM, *?Env, i32) callconv(.c) i32 = @ptrCast(@alignCast(vm.*[6].?));
    if (get(vm, &env, 0x00010006) == 0) return env;
    const attachThread: *const fn (VM, *?Env, ?*anyopaque) callconv(.c) i32 = @ptrCast(@alignCast(vm.*[4].?));
    if (attachThread(vm, &env, null) != 0) return null;
    return env;
}

pub fn detach(vm: VM) void {
    const f: *const fn (VM) callconv(.c) i32 = @ptrCast(@alignCast(vm.*[5].?));
    _ = f(vm);
}

/// A frame of local references: what's made after `push` is freed by `pop`.
pub const Frame = struct {
    env: Env,

    pub fn push(env: Env, capacity: i32) Frame {
        _ = at(env, 19, *const fn (Env, i32) callconv(.c) i32)(env, capacity);
        return .{ .env = env };
    }

    pub fn pop(f: Frame) void {
        _ = at(f.env, 20, *const fn (Env, Object) callconv(.c) Object)(f.env, null);
    }
};

/// A Java exception happened: it is logged and cleared, so JNI goes on.
pub fn failed(env: Env) bool {
    if (at(env, 228, *const fn (Env) callconv(.c) u8)(env) == 0) return false;
    at(env, 16, *const fn (Env) callconv(.c) void)(env);
    at(env, 17, *const fn (Env) callconv(.c) void)(env);
    return true;
}

pub fn findClass(env: Env, name: [*:0]const u8) Object {
    const c = at(env, 6, *const fn (Env, [*:0]const u8) callconv(.c) Object)(env, name);
    return if (failed(env)) null else c;
}

pub fn classOf(env: Env, obj: Object) Object {
    return at(env, 31, *const fn (Env, Object) callconv(.c) Object)(env, obj);
}

pub fn newGlobal(env: Env, obj: Object) Object {
    return at(env, 21, *const fn (Env, Object) callconv(.c) Object)(env, obj);
}

pub fn deleteGlobal(env: Env, obj: Object) void {
    at(env, 22, *const fn (Env, Object) callconv(.c) void)(env, obj);
}

pub fn deleteLocal(env: Env, obj: Object) void {
    at(env, 23, *const fn (Env, Object) callconv(.c) void)(env, obj);
}

fn methodId(env: Env, cls: Object, comptime static: bool, name: [*:0]const u8, sig: [*:0]const u8) Method {
    const f = at(env, if (static) 113 else 33, *const fn (Env, Object, [*:0]const u8, [*:0]const u8) callconv(.c) Method);
    const m = f(env, cls, name, sig);
    return if (failed(env)) null else m;
}

fn fieldId(env: Env, cls: Object, comptime static: bool, name: [*:0]const u8, sig: [*:0]const u8) Field {
    const f = at(env, if (static) 144 else 94, *const fn (Env, Object, [*:0]const u8, [*:0]const u8) callconv(.c) Field);
    const id = f(env, cls, name, sig);
    return if (failed(env)) null else id;
}

/// What a signature returns, from its last part.
fn Return(comptime sig: []const u8) type {
    const r = sig[std.mem.lastIndexOfScalar(u8, sig, ')').? + 1 ..];
    return switch (r[0]) {
        'V' => void,
        'Z' => bool,
        'I' => i32,
        'J' => i64,
        'F' => f32,
        'L', '[' => Object,
        else => @compileError("jni: unsupported return type " ++ r),
    };
}

/// The table's index of the `...A` call returning `sig`'s type: instance
/// calls from `CallObjectMethodA`, static ones from `CallStaticObjectMethodA`.
fn callIndex(comptime sig: []const u8, comptime static: bool) usize {
    const base: usize = if (static) 116 else 36;
    const r = sig[std.mem.lastIndexOfScalar(u8, sig, ')').? + 1 ..];
    return base + 3 * @as(usize, switch (r[0]) {
        'L', '[' => 0,
        'Z' => 1,
        'I' => 5,
        'J' => 6,
        'F' => 7,
        'V' => 9,
        else => unreachable,
    });
}

fn Raw(comptime T: type) type {
    return switch (T) {
        bool => u8,
        else => T,
    };
}

fn invoke(env: Env, comptime sig: []const u8, comptime static: bool, target: Object, m: Method, args: []const Value) ?Return(sig) {
    const R = Return(sig);
    const f = at(env, callIndex(sig, static), *const fn (Env, Object, Method, [*]const Value) callconv(.c) Raw(R));
    const r = f(env, target, m, args.ptr);
    if (failed(env)) return null;
    return if (R == bool) r != 0 else r;
}

/// Calls `obj.name(args)`; null if it threw (or there's no such method).
pub fn call(env: Env, obj: Object, name: [*:0]const u8, comptime sig: [:0]const u8, args: []const Value) ?Return(sig) {
    if (obj == null) return null;
    const cls = classOf(env, obj);
    defer deleteLocal(env, cls);
    const m = methodId(env, cls, false, name, sig) orelse return null;
    return invoke(env, sig, false, obj, m, args);
}

/// Calls `Class.name(args)`, a static method of `class` ("android/os/Looper").
pub fn callStatic(env: Env, class: [*:0]const u8, name: [*:0]const u8, comptime sig: [:0]const u8, args: []const Value) ?Return(sig) {
    const cls = findClass(env, class) orelse return null;
    defer deleteLocal(env, cls);
    const m = methodId(env, cls, true, name, sig) orelse return null;
    return invoke(env, sig, true, cls, m, args);
}

/// `new Class(args)`, with the constructor of signature `sig` ("(I)V").
pub fn new(env: Env, class: [*:0]const u8, sig: [*:0]const u8, args: []const Value) Object {
    const cls = findClass(env, class) orelse return null;
    defer deleteLocal(env, cls);
    const m = methodId(env, cls, false, "<init>", sig) orelse return null;
    const obj = at(env, 30, *const fn (Env, Object, Method, [*]const Value) callconv(.c) Object)(env, cls, m, args.ptr);
    return if (failed(env)) null else obj;
}

/// A static int field: `Class.NAME` (a constant).
pub fn staticInt(env: Env, class: [*:0]const u8, name: [*:0]const u8) ?i32 {
    const cls = findClass(env, class) orelse return null;
    defer deleteLocal(env, cls);
    const id = fieldId(env, cls, true, name, "I") orelse return null;
    return at(env, 150, *const fn (Env, Object, Field) callconv(.c) i32)(env, cls, id);
}

/// An int field of `obj`.
pub fn intField(env: Env, obj: Object, name: [*:0]const u8) ?i32 {
    if (obj == null) return null;
    const cls = classOf(env, obj);
    defer deleteLocal(env, cls);
    const id = fieldId(env, cls, false, name, "I") orelse return null;
    return at(env, 100, *const fn (Env, Object, Field) callconv(.c) i32)(env, obj, id);
}

pub fn setIntField(env: Env, obj: Object, name: [*:0]const u8, value: i32) void {
    if (obj == null) return;
    const cls = classOf(env, obj);
    defer deleteLocal(env, cls);
    const id = fieldId(env, cls, false, name, "I") orelse return;
    at(env, 109, *const fn (Env, Object, Field, i32) callconv(.c) void)(env, obj, id, value);
}

/// A Java string of UTF-8 `s` (JNI's modified UTF-8: no NULs in `s`).
pub fn string(env: Env, s: []const u8) Object {
    var stack: [1024]u8 = undefined;
    var heap: ?[]u8 = null;
    defer if (heap) |h| std.heap.c_allocator.free(h);
    const buf = if (s.len < stack.len) stack[0 .. s.len + 1] else blk: {
        heap = std.heap.c_allocator.alloc(u8, s.len + 1) catch return null;
        break :blk heap.?;
    };
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    // JNI's strings end at a NUL: keep what's before one.
    const z: [*:0]const u8 = @ptrCast(buf.ptr);
    const r = at(env, 167, *const fn (Env, [*:0]const u8) callconv(.c) Object)(env, z);
    return if (failed(env)) null else r;
}

/// A copy of Java string `str` as UTF-8, `gpa`'s; null for a null string.
pub fn fromString(env: Env, gpa: std.mem.Allocator, str: Object) !?[]u8 {
    if (str == null) return null;
    const chars = at(env, 169, *const fn (Env, Object, ?*u8) callconv(.c) ?[*:0]const u8)(env, str, null) orelse return null;
    defer at(env, 170, *const fn (Env, Object, [*:0]const u8) callconv(.c) void)(env, str, chars);
    return try gpa.dupe(u8, std.mem.span(chars));
}

/// `obj.toString()`, as UTF-8 in `gpa`'s memory.
pub fn toString(env: Env, gpa: std.mem.Allocator, obj: Object) !?[]u8 {
    const s = call(env, obj, "toString", "()Ljava/lang/String;", &.{}) orelse return null;
    defer deleteLocal(env, s);
    return fromString(env, gpa, s);
}

pub fn arrayLength(env: Env, array: Object) i32 {
    return at(env, 171, *const fn (Env, Object) callconv(.c) i32)(env, array);
}

pub fn arrayElement(env: Env, array: Object, i: i32) Object {
    const r = at(env, 173, *const fn (Env, Object, i32) callconv(.c) Object)(env, array, i);
    return if (failed(env)) null else r;
}

pub fn newStringArray(env: Env, n: i32) Object {
    const cls = findClass(env, "java/lang/String") orelse return null;
    defer deleteLocal(env, cls);
    const r = at(env, 172, *const fn (Env, i32, Object, Object) callconv(.c) Object)(env, n, cls, null);
    return if (failed(env)) null else r;
}

pub fn setArrayElement(env: Env, array: Object, i: i32, value: Object) void {
    at(env, 174, *const fn (Env, Object, i32, Object) callconv(.c) void)(env, array, i, value);
    _ = failed(env);
}

pub fn ref(o: Object) Value {
    return .{ .l = o };
}

pub fn int(i: i32) Value {
    return .{ .i = i };
}

pub fn boolean(b: bool) Value {
    return .{ .z = @intFromBool(b) };
}

test "return types and call indices follow jni.h" {
    try std.testing.expectEqual(36, callIndex("()Ljava/lang/Object;", false));
    try std.testing.expectEqual(39, callIndex("()Z", false));
    try std.testing.expectEqual(51, callIndex("(I)I", false));
    try std.testing.expectEqual(54, callIndex("()J", false));
    try std.testing.expectEqual(57, callIndex("()F", false));
    try std.testing.expectEqual(63, callIndex("(Ljava/lang/String;)V", false));
    try std.testing.expectEqual(116, callIndex("()[Ljava/lang/String;", true));
    try std.testing.expectEqual(119, callIndex("()Z", true));
    try std.testing.expectEqual(131, callIndex("(II)I", true));
    try std.testing.expectEqual(143, callIndex("()V", true));
    try std.testing.expect(Return("(I)Z") == bool);
}
