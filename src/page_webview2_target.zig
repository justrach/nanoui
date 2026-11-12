//! A callback owns this detachable target, never a Page or Window lifetime.
//! Only callbacks currently on the UI-thread stack pin the page's storage.
const std = @import("std");
const w = @import("windows/win32.zig");

var next_id: usize = 1;

pub fn Target(comptime Page: type) type {
    return struct {
        gpa: std.mem.Allocator,
        page: ?*Page,
        refs: usize = 1,
        id: usize,

        pub fn create(gpa: std.mem.Allocator, page: *Page) !*@This() {
            // Never reuse an id: a posted message may outlive its old page.
            if (next_id == 0) return error.PageIdsExhausted;
            const self = try gpa.create(@This());
            self.* = .{ .gpa = gpa, .page = page, .id = next_id };
            next_id +%= 1;
            return self;
        }

        pub fn retain(self: *@This()) void {
            self.refs += 1;
        }

        pub fn release(self: *@This()) void {
            self.refs -= 1;
            if (self.refs == 0) self.gpa.destroy(self);
        }
    };
}

/// Shared by the real window posts and deterministic fake-message tests.
pub fn post(page: anytype, message: u32, comptime send: anytype) void {
    _ = send(page.owner_hwnd, message, page.target.id, 0);
}

pub const Handles = struct {
    owner: w.HWND,
    parent: w.HWND,

    pub fn init(owner: ?w.HWND, parent: ?*anyopaque) !Handles {
        const hwnd = owner orelse return error.NoWindow;
        return .{ .owner = hwnd, .parent = if (parent) |p| @ptrCast(p) else hwnd };
    }
};
