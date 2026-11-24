//! Shared project discovery, target resolution, build.zig.zon helpers,
//! and process runners for `nui`.
const std = @import("std");
const builtin = @import("builtin");

pub const Project = struct {
    root: []const u8,
    name: []const u8,
    zon: []const u8,
    nanoui_local: ?[]const u8 = null,
    has_web_step: bool = false,
    has_gen_step: bool = false,
};

pub const TargetSpec = struct {
    zig_target: []const u8,
    label: []const u8,
    is_ios: bool = false,
    is_android: bool = false,
    is_windows: bool = false,
    is_web: bool = false,
};

pub const ExecMode = enum { inherit, capture, silent };

pub const RunResult = struct {
    ok: bool,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

/// Resolves a short target alias (`macos`, `linux`, `windows`, `ios-sim`,
/// `ios`, `android`, `web`, ...) or passes through a raw Zig target triple.
pub fn resolveTarget(spec: []const u8) ?TargetSpec {
    if (eq(spec, "macos") or eq(spec, "macos-arm64")) return .{ .zig_target = "aarch64-macos", .label = "macOS arm64" };
    if (eq(spec, "macos-x64")) return .{ .zig_target = "x86_64-macos", .label = "macOS x86_64" };
    if (eq(spec, "linux") or eq(spec, "linux-x64")) return .{ .zig_target = "x86_64-linux-gnu", .label = "Linux x86_64" };
    if (eq(spec, "linux-arm64")) return .{ .zig_target = "aarch64-linux-gnu", .label = "Linux arm64" };
    if (eq(spec, "windows") or eq(spec, "windows-x64")) return .{ .zig_target = "x86_64-windows-gnu", .label = "Windows x86_64", .is_windows = true };
    if (eq(spec, "windows-arm64")) return .{ .zig_target = "aarch64-windows-gnu", .label = "Windows arm64", .is_windows = true };
    if (eq(spec, "ios-sim") or eq(spec, "ios-simulator")) return .{ .zig_target = "aarch64-ios-simulator", .label = "iOS Simulator", .is_ios = true };
    if (eq(spec, "ios")) return .{ .zig_target = "aarch64-ios", .label = "iOS device", .is_ios = true };
    if (eq(spec, "android") or eq(spec, "android-arm64")) return .{ .zig_target = "aarch64-linux-android", .label = "Android arm64", .is_android = true };
    if (eq(spec, "android-x64")) return .{ .zig_target = "x86_64-linux-android", .label = "Android x86_64", .is_android = true };
    if (eq(spec, "web") or eq(spec, "wasm")) return .{ .zig_target = "wasm32-wasi", .label = "WebGPU wasm32-wasi", .is_web = true };
    if (spec.len > 0 and std.mem.indexOfScalar(u8, spec, '-') != null) {
        return .{
            .zig_target = spec,
            .label = spec,
            .is_ios = std.mem.indexOf(u8, spec, "-ios") != null,
            .is_android = std.mem.indexOf(u8, spec, "-android") != null,
            .is_windows = std.mem.indexOf(u8, spec, "-windows") != null,
            .is_web = std.mem.startsWith(u8, spec, "wasm32-"),
        };
    }
    return null;
}

/// The folder holding build.zig.zon (or build.zig), walking upward from `from`.
pub fn projectRoot(a: std.mem.Allocator, io: std.Io, from: []const u8) !?[]const u8 {
    var dir: []const u8 = from;
    while (true) {
        const zon = try std.fs.path.join(a, &.{ dir, "build.zig.zon" });
        if (std.Io.Dir.cwd().access(io, zon, .{})) |_| return dir else |_| {}
        dir = std.fs.path.dirname(dir) orelse break;
    }
    dir = from;
    while (true) {
        const bzig = try std.fs.path.join(a, &.{ dir, "build.zig" });
        if (std.Io.Dir.cwd().access(io, bzig, .{})) |_| return dir else |_| {}
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

/// Loads project metadata from the nearest ancestor holding build.zig.zon / build.zig.
pub fn load(a: std.mem.Allocator, io: std.Io) !?Project {
    const here = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    const root = (try projectRoot(a, io, here)) orelse return null;
    const zon_path = try std.fs.path.join(a, &.{ root, "build.zig.zon" });
    const zon = std.Io.Dir.cwd().readFileAlloc(io, zon_path, a, .limited(1 << 16)) catch "";
    const name = if (zon.len > 0) (zonName(zon) orelse std.fs.path.basename(root)) else std.fs.path.basename(root);
    const bzig_path = try std.fs.path.join(a, &.{ root, "build.zig" });
    const bzig = std.Io.Dir.cwd().readFileAlloc(io, bzig_path, a, .limited(1 << 18)) catch "";
    return .{
        .root = root,
        .name = name,
        .zon = zon,
        .nanoui_local = extractLocalDep(a, zon),
        .has_web_step = std.mem.indexOf(u8, bzig, "b.step(\"web\",") != null,
        .has_gen_step = std.mem.indexOf(u8, bzig, "b.step(\"gen\",") != null,
    };
}

/// build.zig.zon's package name (`.name = .my_app` or `.name = .@"my-app"`).
pub fn zonName(zon: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, zon, ".name") orelse return null;
    var rest = std.mem.trimStart(u8, zon[at + ".name".len ..], " \t\r\n");
    if (!std.mem.startsWith(u8, rest, "=")) return null;
    rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
    if (!std.mem.startsWith(u8, rest, ".")) return null;
    rest = rest[1..];
    if (std.mem.startsWith(u8, rest, "@\"")) {
        const quoted = rest[2..];
        const end = std.mem.indexOfScalar(u8, quoted, '"') orelse return null;
        return quoted[0..end];
    }
    const end = std.mem.indexOfAny(u8, rest, ",\n\r \t") orelse return null;
    return rest[0..end];
}

/// Extracts `.nanoui = .{ .path = "..." }` from build.zig.zon if present.
pub fn extractLocalDep(a: std.mem.Allocator, zon: []const u8) ?[]const u8 {
    const dep_at = std.mem.indexOf(u8, zon, ".nanoui") orelse return null;
    const open = std.mem.indexOfPos(u8, zon, dep_at, ".{") orelse return null;
    var end = open + 2;
    var depth: usize = 1;
    var in_str = false;
    while (end < zon.len and depth > 0) : (end += 1) {
        const ch = zon[end];
        if (in_str) {
            if (ch == '\\' and end + 1 < zon.len) {
                end += 1;
            } else if (ch == '"') {
                in_str = false;
            }
            continue;
        }
        if (ch == '"') {
            in_str = true;
        } else if (ch == '{') {
            depth += 1;
        } else if (ch == '}') {
            depth -= 1;
        }
    }
    if (depth != 0) return null;
    const block = zon[open..end];
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, block, pos, ".path")) |k| {
        const after = block[k + ".path".len ..];
        const trimmed = std.mem.trimStart(u8, after, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "=")) {
            const q = std.mem.indexOfScalar(u8, trimmed, '"') orelse return null;
            var out: std.ArrayList(u8) = .empty;
            var i = q + 1;
            while (i < trimmed.len) : (i += 1) {
                const ch = trimmed[i];
                if (ch == '"') return out.toOwnedSlice(a) catch null;
                if (ch == '\\' and i + 1 < trimmed.len) {
                    i += 1;
                    out.append(a, trimmed[i]) catch return null;
                } else {
                    out.append(a, ch) catch return null;
                }
            }
            return null;
        }
        pos = k + ".path".len;
    }
    return null;
}

/// Rewrites `.paths = .{ ... },` in `zon`, optionally adding a local `.nanoui` path dependency.
pub fn patchZon(a: std.mem.Allocator, zon: []const u8, local_path: ?[]const u8, paths: []const []const u8) ![]const u8 {
    const key_pos = std.mem.indexOf(u8, zon, ".paths") orelse return error.MissingPaths;
    const line_start = if (std.mem.lastIndexOfScalar(u8, zon[0..key_pos], '\n')) |nl| nl + 1 else 0;
    const open_brace = std.mem.indexOfPos(u8, zon, key_pos, ".{") orelse return error.MissingPaths;
    var i = open_brace + 2;
    var depth: usize = 1;
    var in_str = false;
    while (i < zon.len and depth > 0) : (i += 1) {
        const ch = zon[i];
        if (in_str) {
            if (ch == '\\' and i + 1 < zon.len) {
                i += 1;
            } else if (ch == '"') {
                in_str = false;
            }
            continue;
        }
        if (ch == '"') {
            in_str = true;
        } else if (ch == '{') {
            depth += 1;
        } else if (ch == '}') {
            depth -= 1;
        }
    }
    if (depth != 0) return error.MissingPaths;
    if (i < zon.len and zon[i] == ',') i += 1;

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, zon[0..line_start]);
    if (local_path) |p| {
        var escaped: std.ArrayList(u8) = .empty;
        for (p) |ch| {
            if (ch == '\\' or ch == '"') try escaped.append(a, '\\');
            try escaped.append(a, ch);
        }
        try buf.print(a, "    .dependencies = .{{\n        .nanoui = .{{ .path = \"{s}\" }},\n    }},\n", .{escaped.items});
    }
    try buf.appendSlice(a, "    .paths = .{ ");
    for (paths, 0..) |entry, idx| {
        if (idx > 0) try buf.appendSlice(a, ", ");
        try buf.print(a, "\"{s}\"", .{entry});
    }
    try buf.appendSlice(a, " },");
    try buf.appendSlice(a, zon[i..]);
    return try buf.toOwnedSlice(a);
}

/// Runs `zig ARGS` in `cwd`.
pub fn runZig(a: std.mem.Allocator, io: std.Io, args: []const []const u8, cwd: ?[]const u8, mode: ExecMode) !RunResult {
    const argv = try std.mem.concat(a, []const u8, &.{ &.{"zig"}, args });
    return runCmd(a, io, argv, cwd, mode);
}

/// Runs an arbitrary command in `cwd`.
pub fn runCmd(a: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8, mode: ExecMode) !RunResult {
    const cwd_opt: std.process.Child.Cwd = if (cwd) |d| .{ .path = d } else .inherit;
    if (mode == .capture) {
        const r = std.process.run(a, io, .{
            .argv = argv,
            .cwd = cwd_opt,
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
        }) catch return .{ .ok = false };
        return .{ .ok = r.term.success(), .stdout = r.stdout, .stderr = r.stderr };
    }
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .stdin = .ignore,
        .stdout = if (mode == .inherit) .inherit else .ignore,
        .stderr = if (mode == .inherit) .inherit else .ignore,
    }) catch return .{ .ok = false };
    const term = child.wait(io) catch return .{ .ok = false };
    return .{ .ok = term.success() };
}

/// Resolves `--zig-lib=...` via nanoui's `tools/ios/zig-lib.sh` when targeting iOS.
pub fn findIosZigLib(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, root: []const u8, nanoui_local: ?[]const u8) !?[]const u8 {
    var script: ?[]const u8 = null;
    const own = try std.fs.path.join(a, &.{ root, "tools", "ios", "zig-lib.sh" });
    if (std.Io.Dir.cwd().access(io, own, .{})) |_| script = own else |_| {}
    if (script == null) if (nanoui_local) |loc| {
        const base = if (std.fs.path.isAbsolute(loc)) loc else try std.fs.path.join(a, &.{ root, loc });
        const cand = try std.fs.path.join(a, &.{ base, "tools", "ios", "zig-lib.sh" });
        if (std.Io.Dir.cwd().access(io, cand, .{})) |_| script = cand else |_| {}
    };
    if (script == null) {
        const cache_base = env.get("ZIG_GLOBAL_CACHE_DIR") orelse
            (if (env.get("XDG_CACHE_HOME")) |x| try std.fs.path.join(a, &.{ x, "zig" }) else null) orelse
            (if (env.get("HOME")) |h| try std.fs.path.join(a, &.{ h, ".cache", "zig" }) else null);
        if (cache_base) |cb| {
            const pdir = try std.fs.path.join(a, &.{ cb, "p" });
            if (std.Io.Dir.cwd().openDir(io, pdir, .{ .iterate = true })) |d_| {
                var d = d_;
                defer d.close(io);
                var it = d.iterate();
                while (it.next(io) catch null) |e| {
                    if (e.kind != .directory) continue;
                    if (!std.mem.startsWith(u8, e.name, "nanoui-")) continue;
                    const cand = try std.fs.path.join(a, &.{ pdir, e.name, "tools", "ios", "zig-lib.sh" });
                    if (std.Io.Dir.cwd().access(io, cand, .{})) |_| {
                        script = cand;
                        break;
                    } else |_| {}
                }
            } else |_| {}
        }
    }
    const path = script orelse return null;
    const r = try runCmd(a, io, &.{ "sh", path }, root, .capture);
    if (!r.ok) return null;
    const flag = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (flag.len == 0) return null;
    return flag;
}

/// Last `max_bytes` of `text`, trimmed and aligned on a line start if truncated.
pub fn tailDetail(text: []const u8, max_bytes: usize) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len <= max_bytes) return trimmed;
    const start = trimmed.len - max_bytes;
    if (std.mem.indexOfScalarPos(u8, trimmed, start, '\n')) |nl| {
        if (nl + 1 < trimmed.len) return trimmed[nl + 1 ..];
    }
    return trimmed[start..];
}

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

test "targets, zonName, extractLocalDep and patchZon" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const w = resolveTarget("windows").?;
    try std.testing.expectEqualStrings("x86_64-windows-gnu", w.zig_target);
    try std.testing.expect(w.is_windows);
    try std.testing.expect(resolveTarget("ios-sim").?.is_ios);
    try std.testing.expect(resolveTarget("web").?.is_web);
    try std.testing.expect(resolveTarget("bogus") == null);
    try std.testing.expectEqualStrings("riscv64-linux-gnu", resolveTarget("riscv64-linux-gnu").?.zig_target);

    const zon_single =
        \\.{
        \\    .name = .my_app,
        \\    .version = "0.0.1",
        \\    .minimum_zig_version = "0.17.0",
        \\    .paths = .{""},
        \\    .fingerprint = 0x542b89b0eb57ea7f,
        \\}
    ;
    const zon_multi =
        \\.{
        \\    .name = .@"my-app",
        \\    .version = "0.0.0",
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    },
        \\}
    ;
    try std.testing.expectEqualStrings("my_app", zonName(zon_single).?);
    try std.testing.expectEqualStrings("my-app", zonName(zon_multi).?);

    const patched = try patchZon(a, zon_multi, "C:\\code\\nanoui", &.{ "build.zig", "build.zig.zon", "src" });
    try std.testing.expectEqualStrings("C:\\code\\nanoui", extractLocalDep(a, patched).?);
    try std.testing.expect(std.mem.indexOf(u8, patched, ".paths = .{ \"build.zig\", \"build.zig.zon\", \"src\" },") != null);

    const remote = try patchZon(a, zon_single, null, &.{ "build.zig", "build.zig.zon", "src", "frontend" });
    try std.testing.expect(std.mem.indexOf(u8, remote, ".dependencies") == null);
    try std.testing.expect(std.mem.indexOf(u8, remote, "\"frontend\"") != null);

    const remote_fetched =
        \\.{
        \\    .name = .my_app,
        \\    .version = "0.0.1",
        \\    .dependencies = .{
        \\        .nanoui = .{
        \\            .url = "git+https://github.com/justrach/nanoui#v0.14.9",
        \\            .hash = "nanoui-0.14.9-abc",
        \\        },
        \\    },
        \\    .paths = .{ "build.zig", "build.zig.zon", "src" },
        \\}
    ;
    try std.testing.expect(extractLocalDep(a, remote_fetched) == null);
}
