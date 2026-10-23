//! Wrapped text, kept for the frame it was made in and the next (as shaped
//! layouts are): a resize makes new widths every frame, and what the last
//! frame wrapped goes at the next frame's start, never during a frame whose
//! boxes still point at it.
const std = @import("std");

pub fn WrapCache(comptime Line: type) type {
    return struct {
        const Self = @This();
        const Map = std.AutoHashMapUnmanaged(u64, []Line);

        current: Map = .empty,
        previous: Map = .empty,

        /// The lines kept for `k` this frame or the last.
        pub fn get(self: *Self, gpa: std.mem.Allocator, k: u64) ?[]const Line {
            if (self.current.get(k)) |lines| return lines;
            const kv = self.previous.fetchRemove(k) orelse return null;
            self.current.put(gpa, k, kv.value) catch {
                gpa.free(kv.value);
                return null;
            };
            return kv.value;
        }

        /// Keeps `lines` (owned) for `k`; empty if it can't.
        pub fn put(self: *Self, gpa: std.mem.Allocator, k: u64, lines: []Line) []const Line {
            self.current.put(gpa, k, lines) catch {
                gpa.free(lines);
                return &.{};
            };
            return lines;
        }

        /// A new frame: the one before last's wraps go.
        pub fn beginFrame(self: *Self, gpa: std.mem.Allocator) void {
            if (self.current.count() >= 2048) {
                free(gpa, &self.previous);
                std.mem.swap(Map, &self.current, &self.previous);
            }
        }

        /// Drops every wrap (fonts changed).
        pub fn clear(self: *Self, gpa: std.mem.Allocator) void {
            free(gpa, &self.current);
            free(gpa, &self.previous);
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.clear(gpa);
            self.current.deinit(gpa);
            self.previous.deinit(gpa);
        }

        fn free(gpa: std.mem.Allocator, map: *Map) void {
            var it = map.valueIterator();
            while (it.next()) |v| gpa.free(v.*);
            map.clearRetainingCapacity();
        }
    };
}
