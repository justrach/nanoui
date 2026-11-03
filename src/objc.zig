//! The Objective-C runtime, called directly: no C shims, no headers.
//!
//! `msg` builds the exact prototype of each `objc_msgSend` call at comptime
//! (arm64 requires calling it with the callee's real signature), and
//! `defineClass` registers classes at run time whose methods are Zig
//! functions, routed back to Zig objects through one pointer ivar.
const std = @import("std");
const builtin = @import("builtin");

/// UIKit (iOS), not AppKit: the few classes the shared Apple code names
/// differ (`UIFont` for `NSFont`, `UIImage` for `NSImage`).
pub const uikit = @import("builtin").os.tag == .ios;
/// The system font class, toll-free bridged with CTFont on both.
pub const font_class: [:0]const u8 = if (uikit) "UIFont" else "NSFont";

pub const Object = *opaque {};
pub const SEL = *opaque {};
pub const Class = *opaque {};
pub const Protocol = *opaque {};
pub const Ivar = *opaque {};
pub const BOOL = bool;
pub const YES = true;
pub const NO = false;
pub const NSInteger = isize;
pub const NSUInteger = usize;
pub const CGFloat = f64;

pub const CGPoint = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
pub const CGSize = extern struct { width: CGFloat = 0, height: CGFloat = 0 };
pub const CGRect = extern struct { origin: CGPoint = .{}, size: CGSize = .{} };

extern "c" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "c" fn objc_getProtocol(name: [*:0]const u8) ?Protocol;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void;
extern "c" fn objc_msgSendSuper() void;
extern "c" fn objc_msgSend_stret() void;
extern "c" fn objc_msgSendSuper_stret() void;
extern "c" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra: usize) ?Class;
extern "c" fn objc_registerClassPair(cls: Class) void;
extern "c" fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) BOOL;
extern "c" fn class_addProtocol(cls: Class, protocol: Protocol) BOOL;
extern "c" fn class_addIvar(cls: Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) BOOL;
extern "c" fn class_getInstanceVariable(cls: Class, name: [*:0]const u8) ?Ivar;
extern "c" fn ivar_getOffset(v: Ivar) isize;
extern "c" fn object_getClass(obj: Object) Class;
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

pub fn class(comptime name: [:0]const u8) Class {
    return objc_getClass(name) orelse std.debug.panic("objc: no class {s}", .{name});
}

pub fn sel(name: [:0]const u8) SEL {
    return sel_registerName(name);
}

/// Sends `selector` to `target` (an Object or a Class) with `args`, a tuple
/// whose field types must be concrete C-compatible types.
pub fn msg(comptime R: type, target: anytype, selector: [:0]const u8, args: anytype) R {
    const Args = @TypeOf(args);
    const info = @typeInfo(Args).@"struct";
    const params = comptime blk: {
        var p: [info.field_types.len + 2]type = undefined;
        p[0] = @TypeOf(target);
        p[1] = SEL;
        for (info.field_types, 0..) |t, i| p[i + 2] = t;
        break :blk p;
    };
    const F = @Fn(&params, &@splat(.{}), R, .{ .@"callconv" = .c });
    const f: *const F = if (comptime needsStret(R))
        @ptrCast(&objc_msgSend_stret)
    else
        @ptrCast(&objc_msgSend);
    return @call(.auto, f, .{ target, sel(selector) } ++ args);
}

const Super = extern struct { receiver: Object, super_class: Class };

/// Calls the implementation of `superclass` (the class the override is
/// defined in's superclass, never resolved from the object, which KVO may
/// have subclassed).
pub fn msgSuper(comptime R: type, target: Object, superclass: Class, selector: [:0]const u8, args: anytype) R {
    const info = @typeInfo(@TypeOf(args)).@"struct";
    const params = comptime blk: {
        var p: [info.field_types.len + 2]type = undefined;
        p[0] = *const Super;
        p[1] = SEL;
        for (info.field_types, 0..) |t, i| p[i + 2] = t;
        break :blk p;
    };
    const F = @Fn(&params, &@splat(.{}), R, .{ .@"callconv" = .c });
    const f: *const F = if (comptime needsStret(R))
        @ptrCast(&objc_msgSendSuper_stret)
    else
        @ptrCast(&objc_msgSendSuper);
    const s: Super = .{ .receiver = target, .super_class = superclass };
    return @call(.auto, f, .{ &s, sel(selector) } ++ args);
}

/// x86_64 returns structs larger than 16 bytes via a hidden pointer,
/// which needs objc_msgSend_stret. arm64 has no stret variant.
fn needsStret(comptime R: type) bool {
    return builtin.cpu.arch == .x86_64 and @sizeOf(R) > 16;
}

pub fn alloc(comptime class_name: [:0]const u8) Object {
    return msg(Object, class(class_name), "alloc", .{});
}

pub fn new(comptime class_name: [:0]const u8) Object {
    return msg(Object, class(class_name), "new", .{});
}

pub fn release(obj: Object) void {
    msg(void, obj, "release", .{});
}

pub fn retain(obj: Object) Object {
    return msg(Object, obj, "retain", .{});
}

pub fn autorelease(obj: Object) void {
    _ = msg(Object, obj, "autorelease", .{});
}

pub const Pool = struct {
    handle: ?*anyopaque,
    pub fn push() Pool {
        return .{ .handle = objc_autoreleasePoolPush() };
    }
    pub fn pop(p: Pool) void {
        objc_autoreleasePoolPop(p.handle);
    }
};

/// An autoreleased NSString copied from `s`.
pub fn nsString(s: []const u8) Object {
    const str = msg(?Object, alloc("NSString"), "initWithBytes:length:encoding:", .{ s.ptr, s.len, @as(NSUInteger, 4) }) orelse
        msg(?Object, alloc("NSString"), "initWithBytes:length:encoding:", .{ s.ptr, s.len, @as(NSUInteger, 5) }) orelse
        return msg(Object, class("NSString"), "string", .{});
    autorelease(str);
    return str;
}

/// The UTF-8 bytes of an NSString, valid while the string lives.
pub fn fromNSString(str: ?Object) []const u8 {
    const s = str orelse return "";
    const p = msg(?[*:0]const u8, s, "UTF8String", .{}) orelse return "";
    return std.mem.span(p);
}

/// A method of a class defined at run time.
pub const Method = struct {
    name: [:0]const u8,
    imp: *const anyopaque,
    types: [:0]const u8,
};

pub const ClassSpec = struct {
    name: [:0]const u8,
    superclass: [:0]const u8 = "NSObject",
    protocols: []const [:0]const u8 = &.{},
    methods: []const Method,
};

const zig_ivar = "zigPtr";

/// Defines a class once; its instances carry one pointer to a Zig object,
/// set with `setZig` and read with `getZig`.
pub fn defineClass(spec: ClassSpec) Class {
    if (objc_getClass(spec.name)) |c| return c;
    const cls = objc_allocateClassPair(class_by_name(spec.superclass), spec.name, 0) orelse
        std.debug.panic("objc: cannot define {s}", .{spec.name});
    _ = class_addIvar(cls, zig_ivar, @sizeOf(usize), @ctz(@as(usize, @alignOf(usize))), "^v");
    for (spec.protocols) |p| {
        if (objc_getProtocol(p)) |proto| _ = class_addProtocol(cls, proto);
    }
    for (spec.methods) |m| _ = class_addMethod(cls, sel(m.name), m.imp, m.types);
    objc_registerClassPair(cls);
    return cls;
}

fn class_by_name(name: [:0]const u8) Class {
    return objc_getClass(name) orelse std.debug.panic("objc: no class {s}", .{name});
}

fn ivarSlot(obj: Object) ?*?*anyopaque {
    const iv = class_getInstanceVariable(object_getClass(obj), zig_ivar) orelse return null;
    const base: [*]u8 = @ptrCast(obj);
    return @ptrCast(@alignCast(base + @as(usize, @intCast(ivar_getOffset(iv)))));
}

pub fn setZig(obj: Object, ptr: ?*anyopaque) void {
    (ivarSlot(obj) orelse @panic("objc: object has no zig ivar")).* = ptr;
}

/// Null too for an object of a class `defineClass` didn't make (a plain `WKWebView`).
pub fn getZig(comptime T: type, obj: Object) ?*T {
    const slot = ivarSlot(obj) orelse return null;
    return @ptrCast(@alignCast(slot.*));
}

// libdispatch: work posted to the main thread, without blocks.
pub const dispatch_queue_t = *opaque {};
extern "c" var _dispatch_main_q: opaque {};
extern "c" fn dispatch_async_f(queue: dispatch_queue_t, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_after_f(when: u64, queue: dispatch_queue_t, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;
extern "c" fn pthread_main_np() c_int;

pub fn mainQueue() dispatch_queue_t {
    return @ptrCast(&_dispatch_main_q);
}

pub fn isMainThread() bool {
    return pthread_main_np() != 0;
}

pub fn dispatchMain(context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void {
    dispatch_async_f(mainQueue(), context, work);
}

pub fn dispatchAfter(ns: u64, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void {
    dispatch_after_f(dispatch_time(0, @intCast(ns)), mainQueue(), context, work);
}

// Blocks: Apple's closures, for completion handlers. A `Block(Ctx, Args)`
// carries one pointer of context; APIs that keep it copy it to the heap
// (`_Block_copy`), which copies these bytes: nothing to retain.
extern "c" var _NSConcreteStackBlock: opaque {};

const BlockDescriptor = extern struct { reserved: usize = 0, size: usize };

/// A block calling `invoke(ctx, args...)`. Build it where it is passed;
/// the callee copies it if it keeps it.
pub fn Block(comptime Ctx: type, comptime Args: []const type) type {
    return BlockRet(Ctx, Args, void);
}

pub fn BlockRet(comptime Ctx: type, comptime Args: []const type, comptime Ret: type) type {
    return extern struct {
        isa: *anyopaque,
        flags: i32 = 0,
        reserved: i32 = 0,
        invoke: *const anyopaque,
        descriptor: *const BlockDescriptor,
        ctx: *Ctx,

        const Self = @This();
        const descriptor_value: BlockDescriptor = .{ .size = @sizeOf(Self) };

        pub fn init(ctx: *Ctx, comptime func: anytype) Self {
            const params = comptime blk: {
                var p: [Args.len + 1]type = undefined;
                p[0] = *const Self;
                for (Args, 0..) |a, i| p[i + 1] = a;
                break :blk p;
            };
            const Trampoline = struct {
                fn call(block: *const Self, args: anytype) Ret {
                    return @call(.auto, func, .{block.ctx} ++ args);
                }
            };
            const F = @Fn(&params, &@splat(.{}), Ret, .{ .@"callconv" = .c });
            const invoke: *const F = switch (Args.len) {
                0 => &struct {
                    fn f(b: *const Self) callconv(.c) Ret {
                        return Trampoline.call(b, .{});
                    }
                }.f,
                1 => &struct {
                    fn f(b: *const Self, a: Args[0]) callconv(.c) Ret {
                        return Trampoline.call(b, .{a});
                    }
                }.f,
                2 => &struct {
                    fn f(b: *const Self, a: Args[0], c: Args[1]) callconv(.c) Ret {
                        return Trampoline.call(b, .{ a, c });
                    }
                }.f,
                3 => &struct {
                    fn f(b: *const Self, a: Args[0], c: Args[1], d: Args[2]) callconv(.c) Ret {
                        return Trampoline.call(b, .{ a, c, d });
                    }
                }.f,
                4 => &struct {
                    fn f(b: *const Self, a: Args[0], c: Args[1], d: Args[2], e: Args[3]) callconv(.c) Ret {
                        return Trampoline.call(b, .{ a, c, d, e });
                    }
                }.f,
                else => @compileError("objc.Block: up to 4 arguments"),
            };
            return .{ .isa = @ptrCast(&_NSConcreteStackBlock), .invoke = @ptrCast(invoke), .descriptor = &descriptor_value, .ctx = ctx };
        }
    };
}

pub const dispatch_semaphore_t = *opaque {};
pub extern "c" fn dispatch_semaphore_create(value: isize) dispatch_semaphore_t;
pub extern "c" fn dispatch_semaphore_wait(sem: dispatch_semaphore_t, timeout: u64) isize;
pub extern "c" fn dispatch_semaphore_signal(sem: dispatch_semaphore_t) isize;
pub extern "c" fn dispatch_release(obj: *anyopaque) void;
pub const DISPATCH_TIME_FOREVER: u64 = std.math.maxInt(u64);
pub extern "c" fn NSAccessibilityPostNotificationWithUserInfo(element: Object, notification: Object, user_info: ?Object) void;
