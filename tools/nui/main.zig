//! nui: nanoui's command, for people and for coding agents. It never asks
//! anything and never opens a window on its own (`run` aside): `start`
//! makes an app that builds, `check` verifies fmt/lines/build/test,
//! `snapshot` renders to PNG headlessly, and `--json` emits machine output.
const std = @import("std");
const version = @import("build_options").version;
const start_cmd = @import("start.zig");
const build_cmd = @import("build_cmd.zig");

const usage =
    \\nui: make, build and verify nanoui apps
    \\
    \\  nui start NAME [--template native|kit|page] [--id BUNDLE_ID]
    \\                 [--dir PATH] [--nanoui REF | --local PATH] [--no-build]
    \\                         scaffold a new app that builds (also: new, init)
    \\  nui build [FLAGS]      compile (targets: macos, linux, windows, ios-sim, ios, android, web)
    \\  nui test [FLAGS]       run offscreen ui.Tester tests (--portable, --all, --filter, --watch)
    \\  nui check [FLAGS]      run `zig fmt --check`, optional `--lines` (<=600), build and test
    \\  nui dev [FLAGS]        watch and rebuild (`--test` or `--build` stay headless for agents)
    \\  nui run [FLAGS] [-- ARGS...]
    \\                         build and open the app's window (for people, not agents)
    \\  nui snapshot [--out PNG] [--script STEPS] [--dark] [--wait SEC] [--portable] [--exe NAME] [--eval JS]
    \\                         render the first window offscreen to PNG (or eval page JS); no window
    \\  nui gen [--out DIR] [--exe NAME]
    \\                         generate frontend nanoui.js and nanoui.d.ts for webview pages
    \\  nui doctor [--target TARGET]
    \\                         check Zig 0.17 and platform toolchains
    \\  nui info               print project name, root and nanoui dependency mode
    \\  nui help [COMMAND]     detailed help for a command
    \\  nui version
    \\
    \\  --json                 structured JSON output (place before `--`)
    \\
    \\Build flags: --target|-t TARGET, --release, --small, --safe, --portable, --watch, -D...
    \\Script steps: click:TEXT, type:TEXT, key:enter, wait:SECONDS, live:SECONDS, ";" between.
    \\
;

/// Human lines, or one JSON object at the end.
pub const Out = struct {
    json: bool,
    stdout: *std.Io.Writer,
    failed: bool = false,

    pub fn step(o: *Out, comptime fmt: []const u8, args: anytype) void {
        if (o.json) return;
        o.stdout.print("  " ++ fmt ++ "\n", args) catch {};
        o.stdout.flush() catch {};
    }

    pub fn fail(o: *Out, comptime fmt: []const u8, args: anytype, fix: ?[]const u8) void {
        o.failDetail(fmt, args, fix, null);
    }

    pub fn failDetail(o: *Out, comptime fmt: []const u8, args: anytype, fix: ?[]const u8, detail: ?[]const u8) void {
        o.failed = true;
        const clean_detail: ?[]const u8 = if (detail) |d| (if (d.len > 0) d else null) else null;
        if (o.json) {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
            o.stdout.print("{f}\n", .{std.json.fmt(.{
                .ok = false,
                .@"error" = msg,
                .fix = fix,
                .detail = clean_detail,
            }, .{})}) catch {};
        } else {
            o.stdout.print("error: " ++ fmt ++ "\n", args) catch {};
            if (clean_detail) |d| o.stdout.print("{s}\n", .{d}) catch {};
            if (fix) |f| o.stdout.print("fix: {s}\n", .{f}) catch {};
        }
        o.stdout.flush() catch {};
    }

    pub fn done(o: *Out, what: anytype, next: []const []const u8) void {
        if (o.json) {
            o.stdout.print("{f}\n", .{std.json.fmt(.{ .ok = true, .result = what, .next = next }, .{})}) catch {};
        } else if (next.len > 0) {
            o.stdout.print("\nnext:\n", .{}) catch {};
            for (next) |n| o.stdout.print("  {s}\n", .{n}) catch {};
        }
        o.stdout.flush() catch {};
    }
};

pub const zig = struct {
    pub fn call(a: std.mem.Allocator, io: std.Io, args: []const []const u8, cwd: ?[]const u8, show: enum { shown, quiet, silent }) !bool {
        const r = try @import("project.zig").runZig(a, io, args, cwd, switch (show) {
            .shown => .inherit,
            .quiet, .silent => .silent,
        });
        return r.ok;
    }
}.call;

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const all = try init.minimal.args.toSlice(a);
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    var out: Out = .{ .json = false, .stdout = &w.interface };

    // Strip --json anywhere before `--` so app flags after `--` stay intact.
    var args: std.ArrayList([]const u8) = .empty;
    var after_dash = false;
    for (all[1..]) |arg| {
        if (eq(arg, "--")) after_dash = true;
        if (!after_dash and eq(arg, "--json")) out.json = true else try args.append(a, arg);
    }

    if (args.items.len == 0 or eq(args.items[0], "--help") or eq(args.items[0], "-h")) {
        try w.interface.writeAll(usage);
        try w.interface.flush();
        return 0;
    }
    if (eq(args.items[0], "help")) {
        try writeHelp(&w.interface, if (args.items.len > 1) args.items[1] else null);
        return 0;
    }

    const cmd = args.items[0];
    const rest = args.items[1..];
    for (rest) |arg| {
        if (eq(arg, "--")) break;
        if (eq(arg, "--help") or eq(arg, "-h")) {
            try writeHelp(&w.interface, cmd);
            return 0;
        }
    }

    if (eq(cmd, "start") or eq(cmd, "new") or eq(cmd, "init")) {
        try start(a, io, &out, rest);
    } else if (eq(cmd, "build") or eq(cmd, "test") or eq(cmd, "check") or eq(cmd, "run") or eq(cmd, "dev") or eq(cmd, "gen") or eq(cmd, "info")) {
        try build_cmd.run(a, io, init.environ_map, &out, cmd, rest);
    } else if (eq(cmd, "snapshot")) {
        try @import("snapshot.zig").run(a, io, &out, rest);
    } else if (eq(cmd, "doctor")) {
        try @import("doctor.zig").run(a, io, init.environ_map, &out, rest);
    } else if (eq(cmd, "version") or eq(cmd, "--version")) {
        if (out.json) out.done(.{ .nui = version }, &.{}) else {
            try w.interface.print("nui {s} (nanoui {s})\n", .{ version, version });
            try w.interface.flush();
        }
    } else {
        out.fail("no command {s}", .{cmd}, "nui help");
    }
    return if (out.failed) 1 else 0;
}

fn start(a: std.mem.Allocator, io: std.Io, out: *Out, rest: []const []const u8) !void {
    var o: start_cmd.Options = .{ .name = "", .ref = "v" ++ version };
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (eq(arg, "--no-build")) {
            o.build = false;
        } else if (eq(arg, "--dir") or eq(arg, "--nanoui") or eq(arg, "--local") or eq(arg, "--template") or eq(arg, "--id")) {
            i += 1;
            if (i >= rest.len) return out.fail("{s} needs a value", .{arg}, "nui help start");
            if (eq(arg, "--dir")) {
                o.dir = rest[i];
            } else if (eq(arg, "--nanoui")) {
                o.ref = rest[i];
            } else if (eq(arg, "--local")) {
                o.local = rest[i];
            } else if (eq(arg, "--id")) {
                o.id = rest[i];
            } else {
                o.template = std.meta.stringToEnum(start_cmd.Template, rest[i]) orelse
                    return out.fail("unknown template {s}", .{rest[i]}, "use native, kit, or page");
            }
        } else if (o.name.len == 0 and arg.len > 0 and arg[0] != '-') {
            o.name = arg;
        } else {
            return out.fail("what is {s}?", .{arg}, "nui start NAME [--template native|kit|page] [--id ID] [--dir PATH] [--nanoui REF | --local PATH] [--no-build]");
        }
    }
    if (o.name.len == 0) return out.fail("start needs a name", .{}, "nui start my-app");
    try start_cmd.run(a, io, out, o);
}

fn writeHelp(w: *std.Io.Writer, cmd: ?[]const u8) !void {
    const topic = cmd orelse {
        try w.writeAll(usage);
        return w.flush();
    };
    const text = if (eq(topic, "start") or eq(topic, "new") or eq(topic, "init"))
        \\nui start NAME [OPTIONS]
        \\  --template native|kit|page   starter layout (default: native)
        \\  --id BUNDLE_ID               reverse-DNS id for iOS/Android (default: dev.nanoui.<name>)
        \\  --dir PATH                   output folder (default: NAME)
        \\  --nanoui REF                 git tag or commit of nanoui to pin
        \\  --local PATH                 use a local nanoui checkout instead of fetching
        \\  --no-build                   scaffold files without running initial `zig build`
        \\
    else if (eq(topic, "build") or eq(topic, "run") or eq(topic, "dev"))
        \\nui build|run|dev [OPTIONS] [-- APP_ARGS...]
        \\  --target, -t TARGET   macos, macos-x64, linux, linux-arm64, windows,
        \\                        windows-arm64, ios-sim, ios, android, android-x64, web
        \\  --release | --small | --safe   set Zig optimize mode
        \\  --portable            use portable TrueType text + CPU renderer
        \\  --watch               rebuild on changes (`dev` enables this by default)
        \\  --test | --build      for `dev`: watch tests or build headlessly
        \\
    else if (eq(topic, "test") or eq(topic, "check"))
        \\nui test|check [OPTIONS]
        \\  --portable            run with portable TrueType text + CPU renderer
        \\  --all                 run both native and portable CPU test suites
        \\  --filter TEXT         only run tests whose names contain TEXT
        \\  --lines               (`check`) enforce <= 600 lines on build.zig, AGENTS.md, src/
        \\  --target, -t TARGET   (`check`) cross-build for TARGET after fmt/line checks
        \\
    else if (eq(topic, "snapshot"))
        \\nui snapshot [OPTIONS]
        \\  --out PNG             output path (default: zig-out/snapshot.png)
        \\  --script STEPS        click:TEXT;type:TEXT;key:enter;wait:SEC;live:SEC
        \\  --play STEPS          human-paced input steps
        \\  --dark                render with dark theme
        \\  --wait SECONDS        run the event loop before snapshot
        \\  --portable            build with -Dportable=true first
        \\  --exe NAME            binary in zig-out/bin if different from build.zig.zon
        \\  --eval JS             evaluate JS in a page app and exit (no PNG)
        \\
    else if (eq(topic, "gen"))
        \\nui gen [--out DIR] [--exe NAME]
        \\  Runs `zig build gen` if defined, or invokes `--nanoui-generate=DIR`
        \\  (default: frontend) to emit nanoui.js and nanoui.d.ts.
        \\
    else if (eq(topic, "doctor"))
        \\nui doctor [--target TARGET]
        \\  Checks Zig 0.17, host SDK/GTK libraries, and optional cross-target tools.
        \\  Pass `--target ios-sim` or `--target android` to require that toolchain.
        \\
    else
        usage;
    try w.writeAll(text);
    try w.flush();
}

pub fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

test {
    _ = @import("project.zig");
    _ = @import("build_cmd.zig");
    _ = @import("start.zig");
    _ = @import("snapshot.zig");
    _ = @import("doctor.zig");
}
