//! Build, test, check, dev, run, gen and info commands for `nui`.
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("main.zig");
const proj = @import("project.zig");

pub const DevMode = enum { run, @"test", build };

pub const ParsedArgs = struct {
    target: ?[]const u8 = null,
    optimize: ?[]const u8 = null,
    portable: bool = false,
    watch: bool = false,
    all: bool = false,
    lines: bool = false,
    dev_mode: DevMode = .run,
    filter: ?[]const u8 = null,
    out_dir: ?[]const u8 = null,
    exe_name: ?[]const u8 = null,
    zig_flags: []const []const u8 = &.{},
    app_args: []const []const u8 = &.{},
};

pub fn parseArgs(a: std.mem.Allocator, cmd: []const u8, rest: []const []const u8) !union(enum) { ok: ParsedArgs, err: struct { msg: []const u8, fix: []const u8 } } {
    var p: ParsedArgs = .{};
    var zig_flags: std.ArrayList([]const u8) = .empty;
    var app_args: std.ArrayList([]const u8) = .empty;
    const is_run = cli.eq(cmd, "run") or cli.eq(cmd, "dev");
    const is_test = cli.eq(cmd, "test");
    const is_check = cli.eq(cmd, "check");
    const is_gen = cli.eq(cmd, "gen");
    var passthru = false;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (passthru) {
            try app_args.append(a, arg);
            continue;
        }
        if (cli.eq(arg, "--")) {
            passthru = true;
        } else if (cli.eq(arg, "--release")) {
            p.optimize = "ReleaseFast";
        } else if (cli.eq(arg, "--small")) {
            p.optimize = "ReleaseSmall";
        } else if (cli.eq(arg, "--safe")) {
            p.optimize = "ReleaseSafe";
        } else if (cli.eq(arg, "--portable")) {
            p.portable = true;
        } else if (cli.eq(arg, "--watch")) {
            p.watch = true;
        } else if (cli.eq(arg, "--all") and (is_test or is_check)) {
            p.all = true;
        } else if (cli.eq(arg, "--lines") and is_check) {
            p.lines = true;
        } else if (cli.eq(arg, "--test") and cli.eq(cmd, "dev")) {
            p.dev_mode = .@"test";
        } else if (cli.eq(arg, "--build") and cli.eq(cmd, "dev")) {
            p.dev_mode = .build;
        } else if (cli.eq(arg, "--target") or cli.eq(arg, "-t")) {
            i += 1;
            if (i >= rest.len) return .{ .err = .{ .msg = try std.fmt.allocPrint(a, "{s} needs a target", .{arg}), .fix = "use macos, linux, windows, ios-sim, ios, android, web, or a Zig triple" } };
            p.target = rest[i];
        } else if (cli.eq(arg, "--filter") and (is_test or is_check)) {
            i += 1;
            if (i >= rest.len) return .{ .err = .{ .msg = "--filter needs a pattern", .fix = "nui test --filter TEXT" } };
            p.filter = rest[i];
        } else if (cli.eq(arg, "--out") and is_gen) {
            i += 1;
            if (i >= rest.len) return .{ .err = .{ .msg = "--out needs a folder", .fix = "nui gen --out frontend" } };
            p.out_dir = rest[i];
        } else if (cli.eq(arg, "--exe") and is_gen) {
            i += 1;
            if (i >= rest.len) return .{ .err = .{ .msg = "--exe needs a name", .fix = "nui gen --exe hello" } };
            p.exe_name = rest[i];
        } else if (std.mem.startsWith(u8, arg, "-D") or std.mem.startsWith(u8, arg, "-j") or std.mem.startsWith(u8, arg, "-f")) {
            try zig_flags.append(a, arg);
        } else if (cli.eq(arg, "--summary")) {
            i += 1;
            if (i >= rest.len) return .{ .err = .{ .msg = "--summary needs all|new|failures|none", .fix = "nui help build" } };
            try zig_flags.append(a, arg);
            try zig_flags.append(a, rest[i]);
        } else if (!is_run and arg.len > 0 and arg[0] != '-') {
            try zig_flags.append(a, arg);
        } else if (is_run and arg.len > 0 and arg[0] != '-') {
            try app_args.append(a, arg);
        } else {
            return .{ .err = .{ .msg = try std.fmt.allocPrint(a, "unknown flag {s}", .{arg}), .fix = try std.fmt.allocPrint(a, "nui help {s}", .{cmd}) } };
        }
    }
    p.zig_flags = try zig_flags.toOwnedSlice(a);
    p.app_args = try app_args.toOwnedSlice(a);
    return .{ .ok = p };
}

pub fn run(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *cli.Out, cmd: []const u8, rest: []const []const u8) !void {
    if (cli.eq(cmd, "info")) return runInfo(a, io, out);
    const parsed = switch (try parseArgs(a, cmd, rest)) {
        .ok => |v| v,
        .err => |e| return out.fail("{s}", .{e.msg}, e.fix),
    };
    const p = (try proj.load(a, io)) orelse return out.fail("no build.zig.zon or build.zig here or above", .{}, "run it in an app's folder (`nui start my-app` makes one)");
    const tspec: ?proj.TargetSpec = if (parsed.target) |spec|
        (proj.resolveTarget(spec) orelse return out.fail("unknown target {s}", .{spec}, "try macos, linux, windows, ios-sim, ios, android, web, or a Zig triple"))
    else
        null;

    if (cli.eq(cmd, "check")) return runCheck(a, io, env, out, p, parsed, tspec);
    if (cli.eq(cmd, "gen")) return runGen(a, io, out, p, parsed);

    const step: ?[]const u8 = if (cli.eq(cmd, "build")) null else if (cli.eq(cmd, "dev")) switch (parsed.dev_mode) {
        .run => "run",
        .@"test" => "test",
        .build => null,
    } else cmd;

    if (cli.eq(cmd, "test") and parsed.all) {
        if (!try runZigStep(a, io, env, out, p, "test", parsed, tspec, false)) return;
        if (!try runZigStep(a, io, env, out, p, "test", parsed, tspec, true)) return;
        return out.done(.{ .command = "test", .project = p.name, .all = true }, &.{});
    }

    if (tspec) |ts| if (ts.is_web and (cli.eq(cmd, "run") or (cli.eq(cmd, "dev") and parsed.dev_mode == .run))) {
        const web_step: ?[]const u8 = if (p.has_web_step) "web" else null;
        if (!try runZigStep(a, io, env, out, p, web_step, parsed, tspec, false)) return;
        const web_dir = try std.fs.path.join(a, &.{ p.root, "zig-out", "web" });
        out.step("built WebGPU bundle in {s}", .{web_dir});
        return out.done(.{ .command = cmd, .project = p.name, .target = ts.zig_target, .dir = web_dir }, &.{
            try std.fmt.allocPrint(a, "python3 -m http.server -d {s} 8080 --bind 127.0.0.1", .{web_dir}),
        });
    };

    const effective_step: ?[]const u8 = if (tspec != null and tspec.?.is_web and step == null and p.has_web_step) "web" else step;
    const watch = parsed.watch or cli.eq(cmd, "dev");
    var p_eff = parsed;
    p_eff.watch = watch;
    if (!try runZigStep(a, io, env, out, p, effective_step, p_eff, tspec, parsed.portable)) return;
    out.done(.{
        .command = cmd,
        .project = p.name,
        .root = p.root,
        .target = if (tspec) |ts| ts.zig_target else "native",
    }, &.{});
}

fn runZigStep(
    a: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    out: *cli.Out,
    p: proj.Project,
    step: ?[]const u8,
    parsed: ParsedArgs,
    tspec: ?proj.TargetSpec,
    portable: bool,
) !bool {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(a, "build");
    if (tspec) |ts| if (ts.is_ios) {
        if (try proj.findIosZigLib(a, io, env, p.root, p.nanoui_local)) |flag| {
            try args.append(a, flag);
        }
    };
    if (step) |s| try args.append(a, s);
    if (tspec) |ts| if (!ts.is_web or !p.has_web_step) {
        try args.append(a, try std.fmt.allocPrint(a, "-Dtarget={s}", .{ts.zig_target}));
    };
    if (parsed.optimize) |opt| {
        try args.append(a, try std.fmt.allocPrint(a, "-Doptimize={s}", .{opt}));
    } else if (tspec != null and tspec.?.is_web and !p.has_web_step) {
        try args.append(a, "-Doptimize=ReleaseSmall");
    }
    if (portable) try args.append(a, "-Dportable=true");
    if (parsed.filter) |flt| try args.append(a, try std.fmt.allocPrint(a, "-Dtest-filter={s}", .{flt}));
    if (parsed.watch) try args.append(a, "--watch");
    try args.appendSlice(a, parsed.zig_flags);
    if (parsed.app_args.len > 0) {
        try args.append(a, "--");
        try args.appendSlice(a, parsed.app_args);
    }
    const mode: proj.ExecMode = if (out.json) .capture else .inherit;
    const r = try proj.runZig(a, io, args.items, p.root, mode);
    if (!r.ok) {
        if (step) |s| {
            out.failDetail("zig build {s} failed", .{s}, "check the compiler output and `nui doctor`", proj.tailDetail(r.stderr, 2048));
        } else {
            out.failDetail("zig build failed", .{}, "check the compiler output and `nui doctor`", proj.tailDetail(r.stderr, 2048));
        }
        return false;
    }
    return true;
}

fn runCheck(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *cli.Out, p: proj.Project, parsed: ParsedArgs, tspec: ?proj.TargetSpec) !void {
    var fmt_args: std.ArrayList([]const u8) = .empty;
    try fmt_args.appendSlice(a, &.{ "fmt", "--check" });
    var fmt_targets: usize = 0;
    for ([_][]const u8{ "build.zig", "build.zig.zon", "src" }) |rel| {
        const full = try std.fs.path.join(a, &.{ p.root, rel });
        if (std.Io.Dir.cwd().access(io, full, .{})) |_| {
            try fmt_args.append(a, rel);
            fmt_targets += 1;
        } else |_| {}
    }
    if (fmt_targets > 0) {
        out.step("checking zig fmt…", .{});
        const fr = try proj.runZig(a, io, fmt_args.items, p.root, if (out.json) .capture else .inherit);
        if (!fr.ok) return out.failDetail("formatting check failed", .{}, "run: zig fmt build.zig build.zig.zon src", proj.tailDetail(fr.stderr, 1024));
    }

    var checked_files: usize = 0;
    if (parsed.lines) {
        out.step("checking 600-line ceiling…", .{});
        const lres = try checkLines(a, io, p.root, 600);
        checked_files = lres.checked;
        if (lres.over) |bad| {
            return out.failDetail("{s} is {d} lines (limit 600)", .{ bad.path, bad.lines }, "split the file by responsibility before adding more", null);
        }
    }

    out.step("building {s}…", .{p.name});
    if (!try runZigStep(a, io, env, out, p, null, parsed, tspec, parsed.portable)) return;

    if (tspec == null) {
        out.step("running tests…", .{});
        if (!try runZigStep(a, io, env, out, p, "test", parsed, null, parsed.portable)) return;
        if (parsed.all and !parsed.portable) {
            out.step("running portable CPU tests…", .{});
            if (!try runZigStep(a, io, env, out, p, "test", parsed, null, true)) return;
        }
    }

    out.done(.{
        .command = "check",
        .project = p.name,
        .fmt = true,
        .lines_checked = if (parsed.lines) checked_files else 0,
        .built = true,
        .tested = tspec == null,
    }, &.{});
}

fn runGen(a: std.mem.Allocator, io: std.Io, out: *cli.Out, p: proj.Project, parsed: ParsedArgs) !void {
    if (parsed.out_dir == null and parsed.exe_name == null and p.has_gen_step) {
        out.step("running zig build gen…", .{});
        const r = try proj.runZig(a, io, &.{ "build", "gen" }, p.root, if (out.json) .capture else .inherit);
        if (!r.ok) return out.failDetail("zig build gen failed", .{}, "check build.zig's gen step", proj.tailDetail(r.stderr, 2048));
        return out.done(.{ .command = "gen", .project = p.name, .step = "gen" }, &.{});
    }
    const exe_name = parsed.exe_name orelse p.name;
    out.step("building {s}…", .{exe_name});
    const br = try proj.runZig(a, io, &.{"build"}, p.root, if (out.json) .capture else .inherit);
    if (!br.ok) return out.failDetail("{s} doesn't build", .{exe_name}, "fix the build errors above", proj.tailDetail(br.stderr, 2048));

    const default_dir = blk: {
        const src_fe = try std.fs.path.join(a, &.{ p.root, "src", "frontend" });
        if (std.Io.Dir.cwd().access(io, src_fe, .{})) |_| break :blk "src/frontend" else |_| break :blk "frontend";
    };
    const out_rel = parsed.out_dir orelse default_dir;
    const out_abs = if (std.fs.path.isAbsolute(out_rel)) out_rel else try std.fs.path.join(a, &.{ p.root, out_rel });
    try std.Io.Dir.cwd().createDirPath(io, out_abs);

    const bin_name = if (builtin.os.tag == .windows) try std.fmt.allocPrint(a, "{s}.exe", .{exe_name}) else exe_name;
    const exe_path = try std.fs.path.join(a, &.{ p.root, "zig-out", "bin", bin_name });
    const gr = try proj.runCmd(a, io, &.{ exe_path, try std.fmt.allocPrint(a, "--nanoui-generate={s}", .{out_abs}) }, p.root, .capture);
    if (!gr.ok) return out.failDetail("client generation failed for {s}", .{exe_name}, "pass --exe NAME if the binary name differs from build.zig.zon", proj.tailDetail(gr.stderr, 1024));
    out.step("wrote client bindings in {s}", .{out_abs});
    out.done(.{ .command = "gen", .project = p.name, .dir = out_abs }, &.{});
}

fn runInfo(a: std.mem.Allocator, io: std.Io, out: *cli.Out) !void {
    const p = (try proj.load(a, io)) orelse return out.fail("no build.zig.zon or build.zig here or above", .{}, "run inside a nanoui project");
    out.step("name: {s}", .{p.name});
    out.step("root: {s}", .{p.root});
    out.step("nanoui: {s}", .{p.nanoui_local orelse "fetched dependency"});
    out.done(.{
        .name = p.name,
        .root = p.root,
        .nanoui_local = p.nanoui_local,
        .has_web_step = p.has_web_step,
        .has_gen_step = p.has_gen_step,
    }, &.{});
}

pub const LineReport = struct {
    checked: usize = 0,
    over: ?struct { path: []const u8, lines: usize } = null,
};

pub fn checkLines(a: std.mem.Allocator, io: std.Io, root: []const u8, limit: usize) !LineReport {
    var report: LineReport = .{};
    for ([_][]const u8{ "build.zig", "build.zig.zon", "AGENTS.md" }) |rel| {
        const full = try std.fs.path.join(a, &.{ root, rel });
        if (countFileLines(io, a, full)) |n| {
            report.checked += 1;
            if (n > limit) {
                report.over = .{ .path = rel, .lines = n };
                return report;
            }
        }
    }
    const src_dir = try std.fs.path.join(a, &.{ root, "src" });
    if (std.Io.Dir.cwd().openDir(io, src_dir, .{ .iterate = true })) |d_| {
        var d = d_;
        defer d.close(io);
        var walker = try d.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const full = try std.fs.path.join(a, &.{ src_dir, entry.path });
            if (countFileLines(io, a, full)) |n| {
                report.checked += 1;
                if (n > limit) {
                    report.over = .{ .path = try std.fs.path.join(a, &.{ "src", entry.path }), .lines = n };
                    return report;
                }
            }
        }
    } else |_| {}
    return report;
}

fn countFileLines(io: std.Io, a: std.mem.Allocator, path: []const u8) ?usize {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 << 20)) catch return null;
    if (std.mem.indexOfScalar(u8, data, 0) != null) return null;
    var lines = std.mem.count(u8, data, "\n");
    if (data.len > 0 and data[data.len - 1] != '\n') lines += 1;
    return lines;
}

test "parseArgs keeps build flags before -- and app args after --" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const res = try parseArgs(a, "run", &.{ "--release", "--portable", "--target", "linux", "-Dfoo=bar", "--", "--nanoui-dark", "--json" });
    const p = res.ok;
    try std.testing.expectEqualStrings("ReleaseFast", p.optimize.?);
    try std.testing.expect(p.portable);
    try std.testing.expectEqualStrings("linux", p.target.?);
    try std.testing.expectEqualSlices([]const u8, &.{"-Dfoo=bar"}, p.zig_flags);
    try std.testing.expectEqualSlices([]const u8, &.{ "--nanoui-dark", "--json" }, p.app_args);
}

test "checkLines flags files over limit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = if (builtin.os.tag == .windows) "C:\\Windows\\Temp\\nui-lines-test" else "/tmp/nui-lines-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(a, &.{ root, "src" }));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "src", "big.zig" }), .data = "a\nb\nc\nd\n" });
    const ok = try checkLines(a, io, root, 4);
    try std.testing.expect(ok.over == null);
    const bad = try checkLines(a, io, root, 3);
    try std.testing.expect(bad.over != null);
    try std.testing.expectEqual(@as(usize, 4), bad.over.?.lines);
}
