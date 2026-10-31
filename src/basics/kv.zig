//! Small values kept between launches (a starred stop, a last tab): string
//! keys to string values. On iOS and macOS they are the app's
//! NSUserDefaults; elsewhere, for now, they live in memory for the run and
//! are gone at the next launch. Encode anything else (JSON, numbers) as a
//! string. `memory()` is a store of its own in memory everywhere: tests.
//!
//!     const kv = nanoui.kv.standard();
//!     try kv.set("starred", "83139,80141");
//!     if (try kv.get(gpa, "starred")) |v| { defer gpa.free(v); ... }
const std = @import("std");
const builtin = @import("builtin");
const apple = builtin.os.tag == .ios or builtin.os.tag == .macos;
const objc = if (apple) @import("../objc.zig") else struct {};

pub const Store = struct {
    /// Null: the system's (NSUserDefaults on Apple platforms).
    mem: ?*Memory,

    /// The value at `key`, copied with `gpa`, or null.
    pub fn get(s: Store, gpa: std.mem.Allocator, key: []const u8) !?[]u8 {
        if (s.mem) |m| return if (m.map.get(key)) |v| try gpa.dupe(u8, v) else null;
        if (!apple) return fallback().get(gpa, key);
        const pool = objc.Pool.push();
        defer pool.pop();
        const str = objc.msg(?objc.Object, defaults(), "stringForKey:", .{objc.nsString(key)}) orelse return null;
        return try gpa.dupe(u8, objc.fromNSString(str));
    }

    pub fn set(s: Store, key: []const u8, value: []const u8) !void {
        if (s.mem) |m| return m.put(key, value);
        if (!apple) return fallback().set(key, value);
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, defaults(), "setObject:forKey:", .{ objc.nsString(value), objc.nsString(key) });
    }

    pub fn remove(s: Store, key: []const u8) void {
        if (s.mem) |m| return m.drop(key);
        if (!apple) return fallback().remove(key);
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, defaults(), "removeObjectForKey:", .{objc.nsString(key)});
    }

    /// Whether `get` would find a value at `key`.
    pub fn has(s: Store, key: []const u8) bool {
        if (s.mem) |m| return m.map.contains(key);
        if (!apple) return fallback().has(key);
        const pool = objc.Pool.push();
        defer pool.pop();
        return objc.msg(?objc.Object, defaults(), "objectForKey:", .{objc.nsString(key)}) != null;
    }
};

/// The app's store.
pub fn standard() Store {
    return .{ .mem = null };
}

/// A store in memory, its own: free it with `Memory.deinit`.
pub const Memory = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn store(m: *Memory) Store {
        return .{ .mem = m };
    }

    fn put(m: *Memory, key: []const u8, value: []const u8) !void {
        const v = try m.gpa.dupe(u8, value);
        errdefer m.gpa.free(v);
        const gop = try m.map.getOrPut(m.gpa, key);
        if (gop.found_existing) m.gpa.free(gop.value_ptr.*) else gop.key_ptr.* = m.gpa.dupe(u8, key) catch |e| {
            m.map.removeByPtr(gop.key_ptr);
            return e;
        };
        gop.value_ptr.* = v;
    }

    fn drop(m: *Memory, key: []const u8) void {
        const kv = m.map.fetchRemove(key) orelse return;
        m.gpa.free(kv.key);
        m.gpa.free(kv.value);
    }

    pub fn deinit(m: *Memory) void {
        var it = m.map.iterator();
        while (it.next()) |e| {
            m.gpa.free(e.key_ptr.*);
            m.gpa.free(e.value_ptr.*);
        }
        m.map.deinit(m.gpa);
    }
};

var process_store: ?Memory = null;

/// Where `standard` keeps values without NSUserDefaults: memory, for the run.
fn fallback() Store {
    if (process_store == null) process_store = .{ .gpa = std.heap.page_allocator };
    return process_store.?.store();
}

fn defaults() objc.Object {
    return objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{});
}

test "a memory store sets, replaces, reads and removes" {
    const gpa = std.testing.allocator;
    var m: Memory = .{ .gpa = gpa };
    defer m.deinit();
    const s = m.store();
    try std.testing.expect(try s.get(gpa, "starred") == null);
    try s.set("starred", "83139");
    try s.set("starred", "83139,80141");
    const v = (try s.get(gpa, "starred")).?;
    defer gpa.free(v);
    try std.testing.expectEqualStrings("83139,80141", v);
    try std.testing.expect(s.has("starred"));
    s.remove("starred");
    try std.testing.expect(!s.has("starred"));
}
