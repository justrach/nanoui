//! Fails when a file of the repository is longer than 600 lines (AGENTS.md).
const std = @import("std");

const limit = 600;
const roots = [_][]const u8{ "src", "examples", "tools", "hillclimb/src", "hillclimb/mygo", "hillclimb/build.zig", "apps/nanoterm/src", "apps/nanoterm/build.zig", "apps/nanomon/src", "apps/nanomon/build.zig", "apps/nanobrowser/src", "apps/nanobrowser/build.zig", "apps/nanobrowser/README.md", "apps/nanomon/README.md", "apps/nanoterm/README.md", "apps/nanocua/src", "apps/nanocua/build.zig", "apps/nanocua/README.md", "build.zig", "AGENTS.md", "README.md" };
const skip = [_][]const u8{ ".zig-cache", "zig-out", "node_modules", ".git" };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const cwd = std.Io.Dir.cwd();
    var bad: usize = 0;
    var checked: usize = 0;
    for (roots) |root| {
        const stat = cwd.statFile(io, root, .{}) catch continue;
        if (stat.kind == .directory) {
            var dir = try cwd.openDir(io, root, .{ .iterate = true });
            defer dir.close(io);
            var walker = try dir.walk(gpa);
            defer walker.deinit();
            outer: while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;
                for (skip) |s| if (std.mem.indexOf(u8, entry.path, s) != null) continue :outer;
                const path = try std.fs.path.join(gpa, &.{ root, entry.path });
                defer gpa.free(path);
                bad += try check(io, gpa, path);
                checked += 1;
            }
        } else {
            bad += try check(io, gpa, root);
            checked += 1;
        }
    }
    if (bad > 0) {
        std.debug.print("{d} file(s) over {d} lines: split them by responsibility\n", .{ bad, limit });
        std.process.exit(1);
    }
    std.debug.print("{d} files, all within {d} lines\n", .{ checked, limit });
}

fn check(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !usize {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20)) catch return 0;
    defer gpa.free(data);
    // Binary files have no lines to count.
    if (std.mem.indexOfScalar(u8, data, 0) != null) return 0;
    var lines = std.mem.count(u8, data, "\n");
    if (data.len > 0 and data[data.len - 1] != '\n') lines += 1;
    if (lines > limit) {
        std.debug.print("{s}: {d} lines\n", .{ path, lines });
        return 1;
    }
    return 0;
}
