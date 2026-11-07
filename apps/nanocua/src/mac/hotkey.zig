//! The kill switch's key, ⌃⌥⌘. (period), heard wherever the focus is:
//! a Carbon hot key, which needs no permission and arrives on the main
//! thread. Stopping by keyboard matters because an agent may be moving
//! the pointer.
const std = @import("std");

const EventTypeSpec = extern struct { class: u32, kind: u32 };
const HotKeyID = extern struct { signature: u32, id: u32 };
const Handler = *const fn (next: ?*anyopaque, event: ?*anyopaque, user: ?*anyopaque) callconv(.c) i32;
extern "c" fn GetEventDispatcherTarget() *anyopaque;
extern "c" fn InstallEventHandler(target: *anyopaque, handler: Handler, n: usize, list: [*]const EventTypeSpec, user: ?*anyopaque, out: ?*?*anyopaque) i32;
extern "c" fn RegisterEventHotKey(code: u32, modifiers: u32, id: HotKeyID, target: *anyopaque, options: u32, out: *?*anyopaque) i32;
extern "c" fn UnregisterEventHotKey(ref: *anyopaque) i32;

const keyboard_class: u32 = 0x6b657962; // 'keyb'
const hot_key_pressed: u32 = 5;
const cmd: u32 = 0x100;
const option: u32 = 0x800;
const control: u32 = 0x1000;
const period: u32 = 47;

pub const label = "⌃⌥⌘.";

pub const HotKey = struct {
    ref: ?*anyopaque = null,
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,

    /// Registers the key; `hk` must stay where it is.
    pub fn register(hk: *HotKey) bool {
        const target = GetEventDispatcherTarget();
        const spec = [_]EventTypeSpec{.{ .class = keyboard_class, .kind = hot_key_pressed }};
        if (InstallEventHandler(target, pressed, 1, &spec, hk, null) != 0) return false;
        return RegisterEventHotKey(period, cmd | option | control, .{ .signature = 0x6e637561, .id = 1 }, target, 0, &hk.ref) == 0;
    }

    pub fn deinit(hk: *HotKey) void {
        if (hk.ref) |r| _ = UnregisterEventHotKey(r);
        hk.ref = null;
    }

    fn pressed(_: ?*anyopaque, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) i32 {
        const hk: *HotKey = @ptrCast(@alignCast(user orelse return 0));
        hk.func(hk.ctx);
        return 0;
    }
};
