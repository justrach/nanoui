//! Updates where an app is a lone program, not a signed bundle: Linux (a
//! tarball's binary) and Windows (a zip's .exe). The same feed as macOS:
//! the latest release's `manifest.json` names the version and the sha256
//! of this platform's archive. The archive is downloaded into the app's
//! cache, checked against it, unpacked (tar, which Windows ships too), and
//! its program kept only if it runs and says it is that version
//! (`--version`). Installing puts it where the running one is: on Linux a
//! rename over it (the running process keeps its file); on Windows, which
//! can't replace a running .exe but can rename one, the old one is moved
//! aside first and deleted at the next start.
//!
//! Only a build that knows its version (`Options.version`, set at build
//! time) and can write beside itself takes part; elsewhere the updater
//! stays `off`.
const std = @import("std");
const builtin = @import("builtin");
const update = @import("update.zig");
const Updater = update.Updater;
const windows = builtin.os.tag == .windows;

/// The tools every machine has: curl and tar (in System32 since Windows 10).
const curl = if (windows) "C:\\Windows\\System32\\curl.exe" else "/usr/bin/curl";
const tar = if (windows) "C:\\Windows\\System32\\tar.exe" else "/usr/bin/tar";

/// Finds the running program and whether it can be replaced.
pub fn detect(u: *Updater, env: *const std.process.Environ.Map) !void {
    // An Android app is an APK, updated by its store or installed over.
    if (builtin.abi.isAndroid()) return error.Unsupported;
    if (!update.validVersion(u.options.version)) return error.NoVersion;
    const exe = try std.process.executablePathAlloc(u.io, u.gpa);
    defer u.gpa.free(exe);
    const dir = std.fs.path.dirname(exe) orelse return error.NoParent;
    if (!writable(u, dir)) return error.ReadOnly;
    clearAside(u, exe);
    u.bundle = try u.gpa.dupe(u8, exe);
    u.current = try u.gpa.dupe(u8, u.options.version);
    u.cache = try @import("nanoui.zig").path(u.gpa, .cache, u.options.name);
    u.feed = if (env.get("NANOUI_UPDATE_FEED")) |f|
        try u.gpa.dupe(u8, std.mem.trimEnd(u8, f, "/"))
    else
        try std.fmt.allocPrint(u.gpa, "https://github.com/{s}/releases/latest/download", .{u.options.repo});
}

/// Whether a file can be made beside the program (an install the user
/// owns, not one in a system folder).
fn writable(u: *Updater, dir: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const probe = std.fmt.bufPrint(&buf, "{s}{c}.nanoui-update-probe", .{ dir, std.fs.path.sep }) catch return false;
    std.Io.Dir.cwd().writeFile(u.io, .{ .sub_path = probe, .data = "" }) catch return false;
    std.Io.Dir.cwd().deleteFile(u.io, probe) catch {};
    return true;
}

/// Deletes what an install on Windows moved aside (`nanoterm.exe.old-…`).
fn clearAside(u: *Updater, exe: []const u8) void {
    const dir_path = std.fs.path.dirname(exe) orelse return;
    var dir = std.Io.Dir.cwd().openDir(u.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(u.io);
    var buf: [256]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "{s}.old-", .{std.fs.path.basename(exe)}) catch return;
    var it = dir.iterate();
    while (it.next(u.io) catch null) |e| {
        if (std.mem.startsWith(u8, e.name, prefix)) dir.deleteFile(u.io, e.name) catch {};
    }
}

/// Finds, downloads and checks a newer version: true once it's staged.
pub fn fetch(u: *Updater, a: std.mem.Allocator) !bool {
    const updates = try std.fs.path.join(a, &.{ u.cache, "updates" });
    const manifest = try run(a, u.io, &.{ curl, "-fsSL", "--max-time", "30", try std.fmt.allocPrint(a, "{s}/manifest.json", .{u.feed}) });
    const release = try update.parseManifest(a, manifest, u.options.asset);
    if (!update.newer(release.version, u.baseline())) {
        // Nothing waits: what an older check left goes.
        if (u.phase.load(.acquire) != .ready) std.Io.Dir.cwd().deleteTree(u.io, updates) catch {};
        return false;
    }
    const dir = try std.fs.path.join(a, &.{ updates, release.version });
    std.Io.Dir.cwd().deleteTree(u.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(u.io, dir);
    errdefer std.Io.Dir.cwd().deleteTree(u.io, dir) catch {};
    const archive = try std.fs.path.join(a, &.{ dir, u.options.asset });
    // From the release of that version, not "latest": it can't change underfoot.
    const tagged = try std.fmt.allocPrint(a, "https://github.com/{s}/releases/download/v{s}/{s}", .{ u.options.repo, release.version, u.options.asset });
    const from = if (std.mem.startsWith(u8, u.feed, "https://github.com/")) tagged else try std.fmt.allocPrint(a, "{s}/{s}", .{ u.feed, u.options.asset });
    _ = try run(a, u.io, &.{ curl, "-fsSL", "--max-time", "900", "-o", archive, from });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(u.io, archive, a, .limited(1 << 30));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.ascii.eqlIgnoreCase(&std.fmt.bytesToHex(digest, .lower), release.sha256)) return error.ChecksumMismatch;

    const unpacked = try std.fs.path.join(a, &.{ dir, "unpacked" });
    try std.Io.Dir.cwd().createDirPath(u.io, unpacked);
    _ = try run(a, u.io, &.{ tar, "-xf", archive, "-C", unpacked });
    std.Io.Dir.cwd().deleteFile(u.io, archive) catch {};
    const staged = try find(a, u.io, unpacked, std.fs.path.basename(u.bundle)) orelse return error.NoProgram;
    // It runs, and is the version the manifest says.
    const said = try run(a, u.io, &.{ staged, "--version" });
    if (std.mem.indexOf(u8, said, release.version) == null) return error.WrongVersion;

    try u.stage(release.version, staged);
    return true;
}

/// The file called `name` in `root` or a folder in it (archives nest the
/// program in `<app>-<version>-<os>-<arch>/`).
fn find(a: std.mem.Allocator, io: std.Io, root: []const u8, name: []const u8) !?[]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind == .file and std.mem.eql(u8, e.basename, name)) return try std.fs.path.join(a, &.{ root, e.path });
    }
    return null;
}

/// Puts the staged program where the running one is.
pub fn install(u: *Updater) !void {
    try swap(u.gpa, u.io, u.staged_buf[0..u.staged_len], u.bundle);
    u.phase.store(.installed, .release);
    if (std.fs.path.dirname(u.staged_buf[0..u.staged_len])) |d| {
        // updates/<version>/unpacked/<folder>/<program>: the version's folder goes.
        var p: []const u8 = d;
        while (std.fs.path.dirname(p)) |up| {
            if (std.mem.eql(u8, std.fs.path.basename(up), "updates")) break;
            p = up;
        }
        std.Io.Dir.cwd().deleteTree(u.io, p) catch {};
    }
}

/// Copies `staged` beside `exe`, then puts it in `exe`'s place: a rename
/// over it, or on Windows with the old one renamed aside first (and put
/// back if the second rename fails).
pub fn swap(gpa: std.mem.Allocator, io: std.Io, staged: []const u8, exe: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const n = std.Thread.getCurrentId();
    const fresh = try std.fmt.allocPrint(gpa, "{s}.new-{d}", .{ exe, n });
    defer gpa.free(fresh);
    const data = try cwd.readFileAlloc(io, staged, gpa, .limited(1 << 30));
    defer gpa.free(data);
    const perms: std.Io.File.Permissions = if (windows) .default_file else .fromMode(0o755);
    try cwd.writeFile(io, .{ .sub_path = fresh, .data = data, .flags = .{ .permissions = perms } });
    errdefer cwd.deleteFile(io, fresh) catch {};
    if (!windows) return std.Io.Dir.renameAbsolute(fresh, exe, io);
    const old = try std.fmt.allocPrint(gpa, "{s}.old-{d}", .{ exe, n });
    defer gpa.free(old);
    try move(gpa, exe, old);
    move(gpa, fresh, exe) catch |e| {
        move(gpa, old, exe) catch {};
        return e;
    };
}

extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: u32) callconv(.winapi) i32;

/// A rename as Windows lets a running program be renamed (std's rename
/// asks for access the loader's open file refuses).
fn move(gpa: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const f = try std.unicode.utf8ToUtf16LeAllocZ(gpa, from);
    defer gpa.free(f);
    const t = try std.unicode.utf8ToUtf16LeAllocZ(gpa, to);
    defer gpa.free(t);
    if (MoveFileExW(f, t, 1) == 0) return error.FileBusy; // MOVEFILE_REPLACE_EXISTING
}

/// Starts the installed program, on its own; the caller then quits.
pub fn relaunch(u: *Updater) void {
    const argv: []const []const u8 = &.{u.bundle};
    const started = if (windows)
        std.process.spawn(u.io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore })
    else
        std.process.spawn(u.io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .pgid = 0 });
    _ = started catch |e| std.log.warn("nanoui: can't start the update: {t}", .{e});
}

fn run(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]const u8 {
    const r = try std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) });
    if (!r.term.success()) return error.CommandFailed;
    return r.stdout;
}

test "every part builds here" {
    std.testing.refAllDecls(@This());
    _ = &Updater.start;
    _ = &Updater.deinit;
    _ = &Updater.restart;
    _ = &Updater.checkNow;
}

test "a staged program takes the running one's place, nothing left beside it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    var root_buf: [256]u8 = undefined;
    const root = try @import("temp_path.zig").tempPath(&root_buf, "nanoui-test-swap");
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root);
    var exe_buf: [300]u8 = undefined;
    var staged_buf: [300]u8 = undefined;
    const exe = try std.fmt.bufPrint(&exe_buf, "{s}{s}app", .{ root, std.fs.path.sep_str });
    const staged = try std.fmt.bufPrint(&staged_buf, "{s}{s}staged", .{ root, std.fs.path.sep_str });
    try cwd.writeFile(io, .{ .sub_path = exe, .data = "old" });
    try cwd.writeFile(io, .{ .sub_path = staged, .data = "new" });
    try swap(gpa, io, staged, exe);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("new", try cwd.readFile(io, exe, &buf));
    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var aside: usize = 0;
    while (try it.next(io)) |e| {
        if (std.mem.indexOf(u8, e.name, ".old-") != null) aside += 1;
        try std.testing.expect(std.mem.indexOf(u8, e.name, ".new-") == null);
    }
    // Windows keeps the old one aside until the next start clears it.
    try std.testing.expectEqual(@as(usize, if (windows) 1 else 0), aside);
}

test "an update from a feed: found, checked, unpacked, run, installed" {
    if (windows) return error.SkipZigTest; // the fake program is a shell script
    // Android's apps aren't programs that update themselves (`detect`).
    if (builtin.abi.isAndroid()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    var root_buf: [256]u8 = undefined;
    const root = try @import("temp_path.zig").tempPath(&root_buf, "nanoui-test-portable");
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The installed program, 0.1.0, and a release of 0.2.0 in a feed.
    const script = "#!/bin/sh\necho \"app {s}\"\n";
    try cwd.createDirPath(io, root ++ "/bin");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/bin/app", .data = try std.fmt.allocPrint(a, script, .{"0.1.0"}), .flags = .{ .permissions = .fromMode(0o755) } });
    try cwd.createDirPath(io, root ++ "/pack/app-0.2.0-linux-x86_64");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/pack/app-0.2.0-linux-x86_64/app", .data = try std.fmt.allocPrint(a, script, .{"0.2.0"}), .flags = .{ .permissions = .fromMode(0o755) } });
    try cwd.createDirPath(io, root ++ "/feed");
    _ = try run(a, io, &.{ tar, "-czf", root ++ "/feed/app-linux.tar.gz", "-C", root ++ "/pack", "app-0.2.0-linux-x86_64" });
    const archive = try cwd.readFileAlloc(io, root ++ "/feed/app-linux.tar.gz", a, .limited(1 << 20));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    try cwd.writeFile(io, .{ .sub_path = root ++ "/feed/manifest.json", .data = try std.fmt.allocPrint(a, "{{\"version\":\"0.2.0\",\"files\":{{\"app-linux.tar.gz\":{{\"sha256\":\"{s}\"}}}}}}", .{std.fmt.bytesToHex(digest, .lower)}) });

    var u: Updater = .{ .gpa = gpa, .io = io, .options = .{ .repo = "me/app", .asset = "app-linux.tar.gz", .name = "app", .version = "0.1.0" }, .feed = "file://" ++ root ++ "/feed", .bundle = root ++ "/bin/app", .current = "0.1.0", .cache = root ++ "/cache" };
    try std.testing.expect(try fetch(&u, a));
    u.adopt();
    try std.testing.expectEqualStrings("0.2.0", u.version_buf[0..u.version_len]);
    try install(&u);
    try std.testing.expectEqualStrings("app 0.2.0\n", try run(a, io, &.{ root ++ "/bin/app", "--version" }));
    // The cache keeps nothing of it; current now, there's nothing to fetch.
    u.current = "0.2.0";
    try std.testing.expect(!try fetch(&u, a));
    // A wrong sum is refused.
    try cwd.writeFile(io, .{ .sub_path = root ++ "/feed/manifest.json", .data = "{\"version\":\"0.3.0\",\"files\":{\"app-linux.tar.gz\":{\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}}}" });
    try std.testing.expectError(error.ChecksumMismatch, fetch(&u, a));
}

/// A release of `version` in `root`/feed: the app's archive and the manifest.
fn makeRelease(a: std.mem.Allocator, io: std.Io, root: []const u8, version: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const folder = try std.fmt.allocPrint(a, "{s}/pack/app-{s}-linux-x86_64", .{ root, version });
    try cwd.createDirPath(io, folder);
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/app", .{folder}), .data = try std.fmt.allocPrint(a, "#!/bin/sh\necho \"app {s}\"\n", .{version}), .flags = .{ .permissions = .fromMode(0o755) } });
    try cwd.createDirPath(io, try std.fmt.allocPrint(a, "{s}/feed", .{root}));
    const archive = try std.fmt.allocPrint(a, "{s}/feed/app-linux.tar.gz", .{root});
    _ = try run(a, io, &.{ tar, "-czf", archive, "-C", try std.fmt.allocPrint(a, "{s}/pack", .{root}), std.fs.path.basename(folder) });
    const bytes = try cwd.readFileAlloc(io, archive, a, .limited(1 << 20));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/feed/manifest.json", .{root}), .data = try std.fmt.allocPrint(a, "{{\"version\":\"{s}\",\"files\":{{\"app-linux.tar.gz\":{{\"sha256\":\"{s}\"}}}}}}", .{ version, std.fmt.bytesToHex(digest, .lower) }) });
}

test "a newer release while one waits takes its place; the same one isn't fetched again" {
    if (windows) return error.SkipZigTest; // the fake program is a shell script
    // Android's apps aren't programs that update themselves (`detect`).
    if (builtin.abi.isAndroid()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    var root_buf: [256]u8 = undefined;
    const root = try @import("temp_path.zig").tempPath(&root_buf, "nanoui-test-portable-newer");
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try cwd.createDirPath(io, root ++ "/bin");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/bin/app", .data = "#!/bin/sh\necho \"app 0.1.0\"\n", .flags = .{ .permissions = .fromMode(0o755) } });
    var u: Updater = .{ .gpa = gpa, .io = io, .options = .{ .repo = "me/app", .asset = "app-linux.tar.gz", .name = "app", .version = "0.1.0" }, .feed = "file://" ++ root ++ "/feed", .bundle = root ++ "/bin/app", .current = "0.1.0", .cache = root ++ "/cache" };
    // 0.2.0 comes and waits (the app isn't restarted).
    try makeRelease(a, io, root, "0.2.0");
    try std.testing.expect(try fetch(&u, a));
    u.adopt();
    try std.testing.expectEqualStrings("0.2.0", u.ready().?);
    // 0.3.0 comes: fetched beside it, then waits in its place; 0.2.0's files go.
    try makeRelease(a, io, root, "0.3.0");
    try std.testing.expect(try fetch(&u, a));
    try std.testing.expectEqualStrings("0.2.0", u.ready().?); // until adopted, on the main thread
    u.adopt();
    try std.testing.expectEqualStrings("0.3.0", u.ready().?);
    try std.testing.expectError(error.FileNotFound, cwd.access(io, root ++ "/cache/updates/0.2.0", .{}));
    // Still the latest: nothing fetched, and what waits stays.
    try std.testing.expect(!try fetch(&u, a));
    try cwd.access(io, root ++ "/cache/updates/0.3.0", .{});
    // Restarting installs the newest.
    try install(&u);
    try std.testing.expectEqualStrings("app 0.3.0\n", try run(a, io, &.{ root ++ "/bin/app", "--version" }));
}
