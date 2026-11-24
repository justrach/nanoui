//! `nui snapshot`: builds the app, then runs it headlessly with
//! `--nanoui-snapshot` (or `--nanoui-eval` for pages) and exits; no window shows.
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("main.zig");
const proj = @import("project.zig");

pub const projectRoot = proj.projectRoot;

pub fn run(a: std.mem.Allocator, io: std.Io, out: *cli.Out, rest: []const []const u8) !void {
    var png: ?[]const u8 = null;
    var exe_override: ?[]const u8 = null;
    var eval_js: ?[]const u8 = null;
    var portable = false;
    var flags: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (cli.eq(arg, "--dark")) {
            try flags.append(a, "--nanoui-dark");
        } else if (cli.eq(arg, "--portable")) {
            portable = true;
        } else if (cli.eq(arg, "--out") or cli.eq(arg, "--script") or cli.eq(arg, "--wait") or cli.eq(arg, "--exe") or cli.eq(arg, "--play") or cli.eq(arg, "--eval")) {
            i += 1;
            if (i >= rest.len) return out.fail("{s} needs a value", .{arg}, "nui help snapshot");
            if (cli.eq(arg, "--out")) {
                png = rest[i];
            } else if (cli.eq(arg, "--exe")) {
                exe_override = rest[i];
            } else if (cli.eq(arg, "--eval")) {
                eval_js = rest[i];
                try flags.append(a, try std.fmt.allocPrint(a, "--nanoui-eval={s}", .{rest[i]}));
            } else if (cli.eq(arg, "--play")) {
                try flags.append(a, try std.fmt.allocPrint(a, "--nanoui-play={s}", .{rest[i]}));
            } else if (cli.eq(arg, "--script")) {
                try flags.append(a, try std.fmt.allocPrint(a, "--nanoui-script={s}", .{rest[i]}));
            } else {
                try flags.append(a, try std.fmt.allocPrint(a, "--nanoui-wait={s}", .{rest[i]}));
            }
        } else {
            return out.fail("what is {s}?", .{arg}, "nui snapshot [--out PNG] [--script STEPS] [--dark] [--wait SECONDS] [--portable] [--exe NAME] [--eval JS]");
        }
    }

    const here = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    const p = (try proj.load(a, io)) orelse return out.fail("no build.zig.zon here or above", .{}, "run it in an app's folder (nui start NAME makes one)");
    const bin_name = exe_override orelse p.name;

    out.step("building {s}…", .{bin_name});
    const build_args: []const []const u8 = if (portable) &.{ "build", "-Dportable=true" } else &.{"build"};
    const br = try proj.runZig(a, io, build_args, p.root, if (out.json) .capture else .inherit);
    if (!br.ok) return out.failDetail("{s} doesn't build", .{bin_name}, "the compiler's errors are above", proj.tailDetail(br.stderr, 2048));

    const exe_file = if (builtin.os.tag == .windows) try std.fmt.allocPrint(a, "{s}.exe", .{bin_name}) else bin_name;
    const exe = try std.fs.path.join(a, &.{ p.root, "zig-out", "bin", exe_file });

    if (eval_js != null) {
        const argv = try std.mem.concat(a, []const u8, &.{ &.{exe}, flags.items });
        const r = try proj.runCmd(a, io, argv, p.root, .capture);
        if (!r.ok) return out.failDetail("{s} failed during --eval", .{bin_name}, "check page logs below", proj.tailDetail(r.stderr, 2048));
        if (!out.json and r.stderr.len > 0) out.stdout.print("{s}\n", .{std.mem.trim(u8, r.stderr, "\r\n")}) catch {};
        return out.done(.{ .exe = bin_name, .log = std.mem.trim(u8, r.stderr, "\r\n") }, &.{});
    }

    const target = if (png) |path| (if (std.fs.path.isAbsolute(path)) path else try std.fs.path.join(a, &.{ here, path })) else try std.fs.path.join(a, &.{ p.root, "zig-out", "snapshot.png" });
    if (std.fs.path.dirname(target)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    std.Io.Dir.cwd().deleteFile(io, target) catch {};

    const argv = try std.mem.concat(a, []const u8, &.{ &.{ exe, try std.fmt.allocPrint(a, "--nanoui-snapshot={s}", .{target}) }, flags.items });
    const r = try proj.runCmd(a, io, argv, p.root, .capture);
    if (!r.ok) return out.failDetail("{s} stopped before its picture was taken", .{bin_name}, "pass --exe NAME if the binary differs from build.zig.zon", proj.tailDetail(r.stderr, 2048));
    std.Io.Dir.cwd().access(io, target, .{}) catch return out.fail("no picture at {s}", .{target}, "does the app open a native UI window? (use --eval JS for webview pages)");
    out.step("rendered {s}", .{target});
    out.done(.{ .png = target }, &.{});
}

test "the project's folder is found from inside it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = if (builtin.os.tag == .windows) "C:\\Windows\\Temp\\nui-test-root" else "/tmp/nui-test-root";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const deep = try std.fs.path.join(a, &.{ root, "src", "deep" });
    try std.Io.Dir.cwd().createDirPath(io, deep);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "build.zig.zon" }), .data = ".{}" });
    try std.testing.expectEqualStrings(root, (try projectRoot(a, io, deep)).?);
}
