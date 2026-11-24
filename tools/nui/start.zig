//! `nui start NAME`: scaffolds a nanoui app that builds immediately
//! (`--template native | kit | page`).
const std = @import("std");
const cli = @import("main.zig");
const proj = @import("project.zig");

pub const Template = enum { native, kit, page };

pub const Options = struct {
    name: []const u8,
    dir: ?[]const u8 = null,
    /// A git ref of nanoui to fetch (a tag, a commit).
    ref: []const u8,
    /// A local nanoui checkout instead.
    local: ?[]const u8 = null,
    template: Template = .native,
    id: ?[]const u8 = null,
    build: bool = true,
};

const FileSpec = struct { path: []const u8, text: []const u8 };

const native_files = [_]FileSpec{
    .{ .path = "build.zig", .text = @embedFile("template/build.zig.in") },
    .{ .path = "src/main.zig", .text = @embedFile("template/main.zig.in") },
    .{ .path = "src/app.zig", .text = @embedFile("template/app.zig.in") },
    .{ .path = "src/tests.zig", .text = @embedFile("template/tests.zig.in") },
    .{ .path = "AGENTS.md", .text = @embedFile("template/AGENTS.md.in") },
    .{ .path = ".gitignore", .text = @embedFile("template/gitignore.in") },
};

const kit_files = [_]FileSpec{
    .{ .path = "build.zig", .text = @embedFile("template/build.zig.in") },
    .{ .path = "src/main.zig", .text = @embedFile("template/main.zig.in") },
    .{ .path = "src/app.zig", .text = @embedFile("template/kit_app.zig.in") },
    .{ .path = "src/tests.zig", .text = @embedFile("template/kit_tests.zig.in") },
    .{ .path = "AGENTS.md", .text = @embedFile("template/AGENTS.md.in") },
    .{ .path = ".gitignore", .text = @embedFile("template/gitignore.in") },
};

const page_files = [_]FileSpec{
    .{ .path = "build.zig", .text = @embedFile("template/page_build.zig.in") },
    .{ .path = "src/main.zig", .text = @embedFile("template/page_main.zig.in") },
    .{ .path = "src/tests.zig", .text = @embedFile("template/page_tests.zig.in") },
    .{ .path = "src/frontend/index.html", .text = @embedFile("template/page_index.html.in") },
    .{ .path = "src/frontend/main.js", .text = @embedFile("template/page_main.js.in") },
    .{ .path = "src/frontend/style.css", .text = @embedFile("template/page_style.css.in") },
    .{ .path = "AGENTS.md", .text = @embedFile("template/AGENTS.md.in") },
    .{ .path = ".gitignore", .text = @embedFile("template/gitignore.in") },
};

/// A name a folder and a Zig package can both have.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or !std.ascii.isAlphabetic(name[0])) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

/// "my-app" as a title: "My App".
pub fn title(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const out = try a.dupe(u8, name);
    var start = true;
    for (out) |*ch| {
        if (ch.* == '-' or ch.* == '_') {
            ch.* = ' ';
            start = true;
        } else {
            if (start) ch.* = std.ascii.toUpper(ch.*);
            start = false;
        }
    }
    return out;
}

/// Default reverse-DNS bundle id for `name`: `dev.nanoui.<slug>`.
pub fn defaultBundleId(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const slug = try a.dupe(u8, name);
    for (slug) |*ch| {
        if (ch.* == '_') ch.* = '-' else ch.* = std.ascii.toLower(ch.*);
    }
    return std.fmt.allocPrint(a, "dev.nanoui.{s}", .{slug});
}

/// `text` with `{{name}}`, `{{title}}`, and `{{id}}` filled in.
pub fn fill(a: std.mem.Allocator, text: []const u8, name: []const u8, app_title: []const u8, bundle_id: []const u8) ![]const u8 {
    const s1 = try std.mem.replaceOwned(u8, a, text, "{{name}}", name);
    const s2 = try std.mem.replaceOwned(u8, a, s1, "{{title}}", app_title);
    return std.mem.replaceOwned(u8, a, s2, "{{id}}", bundle_id);
}

pub const zonName = proj.zonName;

pub fn withLocal(a: std.mem.Allocator, zon: []const u8, path: []const u8) ![]const u8 {
    return proj.patchZon(a, zon, path, &.{ "build.zig", "build.zig.zon", "src" });
}

pub fn run(a: std.mem.Allocator, io: std.Io, out: *cli.Out, o: Options) !void {
    if (!validName(o.name)) return out.fail("not a name an app can have: {s}", .{o.name}, "use letters, digits, - and _, starting with a letter (my-app)");
    const dir = o.dir orelse o.name;
    const cwd = std.Io.Dir.cwd();
    if (cwd.openDir(io, dir, .{ .iterate = true })) |d_| {
        var d = d_;
        defer d.close(io);
        var it = d.iterate();
        if (try it.next(io) != null) return out.fail("{s} exists and isn't empty", .{dir}, "choose another name, or --dir PATH");
    } else |_| {}
    try cwd.createDirPath(io, dir);
    out.step("made {s}/", .{dir});

    const init_res = try proj.runZig(a, io, &.{ "init", "--minimal" }, dir, .silent);
    if (!init_res.ok) return out.fail("zig init failed in {s}", .{dir}, "run `nui doctor`");

    const zon_path = try std.fs.path.join(a, &.{ dir, "build.zig.zon" });
    var zon: []const u8 = try cwd.readFileAlloc(io, zon_path, a, .limited(1 << 16));
    const name = zonName(zon) orelse return out.fail("build.zig.zon has no name", .{}, null);
    const paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src" };

    if (o.local) |local| {
        const abs = cwd.realPathFileAlloc(io, local, a) catch return out.fail("no nanoui checkout at {s}", .{local}, "pass the path to your nanoui folder");
        const app_abs = try cwd.realPathFileAlloc(io, dir, a);
        const rel = try std.fs.path.relativeAlloc(a, app_abs, null, app_abs, abs);
        zon = proj.patchZon(a, zon, rel, paths) catch return out.fail("unexpected build.zig.zon layout", .{}, "check `zig version` is 0.17.x");
        try cwd.writeFile(io, .{ .sub_path = zon_path, .data = zon });
        out.step("nanoui from {s}", .{abs});
    } else {
        zon = proj.patchZon(a, zon, null, paths) catch return out.fail("unexpected build.zig.zon layout", .{}, "check `zig version` is 0.17.x");
        try cwd.writeFile(io, .{ .sub_path = zon_path, .data = zon });
        const url = try std.fmt.allocPrint(a, "git+https://github.com/justrach/nanoui#{s}", .{o.ref});
        const fr = try proj.runZig(a, io, &.{ "fetch", "--save=nanoui", url }, dir, if (out.json) .capture else .inherit);
        if (!fr.ok) return out.failDetail("couldn't fetch nanoui {s}", .{o.ref}, "check the network, or use --local PATH to a nanoui checkout", proj.tailDetail(fr.stderr, 1024));
        out.step("nanoui {s}, pinned", .{o.ref});
    }

    const app_title = try title(a, o.name);
    const bundle_id = o.id orelse try defaultBundleId(a, o.name);
    const files: []const FileSpec = switch (o.template) {
        .native => &native_files,
        .kit => &kit_files,
        .page => &page_files,
    };
    try cwd.createDirPath(io, try std.fs.path.join(a, &.{ dir, "src" }));
    if (o.template == .page) {
        try cwd.createDirPath(io, try std.fs.path.join(a, &.{ dir, "src", "frontend" }));
    }
    for (files) |t| {
        const path = try std.fs.path.join(a, &.{ dir, t.path });
        try cwd.writeFile(io, .{ .sub_path = path, .data = try fill(a, t.text, name, app_title, bundle_id) });
    }
    out.step("wrote {s} template ({d} files)", .{ @tagName(o.template), files.len });

    if (o.build) {
        out.step("building…", .{});
        const br = try proj.runZig(a, io, &.{"build"}, dir, if (out.json) .capture else .inherit);
        if (!br.ok) return out.failDetail("{s} doesn't build", .{dir}, "the compiler's errors are above", proj.tailDetail(br.stderr, 2048));
        out.step("it builds", .{});
    }

    const next: []const []const u8 = if (o.template == .page) &.{
        try std.fmt.allocPrint(a, "cd {s}", .{dir}),
        "nui test",
        "nui gen",
        "nui run",
    } else &.{
        try std.fmt.allocPrint(a, "cd {s}", .{dir}),
        "nui check --lines",
        "nui snapshot --out shot.png",
        "nui run",
    };
    out.done(.{
        .name = name,
        .dir = dir,
        .template = @tagName(o.template),
        .id = bundle_id,
        .built = o.build,
    }, next);
}

test "names, titles, ids, templates and build.zig.zon" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(validName("my-app") and validName("Notes_2"));
    try std.testing.expect(!validName("2fast") and !validName("a b") and !validName("../x") and !validName(""));
    try std.testing.expectEqualStrings("My App", try title(a, "my-app"));
    try std.testing.expectEqualStrings("dev.nanoui.my-app", try defaultBundleId(a, "My_App"));
    try std.testing.expectEqualStrings("exe my_app, My App, dev.nanoui.my-app", try fill(a, "exe {{name}}, {{title}}, {{id}}", "my_app", "My App", "dev.nanoui.my-app"));
    const zon =
        \\.{
        \\    .name = .my_app,
        \\    .version = "0.0.1",
        \\    .minimum_zig_version = "0.17.0",
        \\    .paths = .{""},
        \\    .fingerprint = 0x542b89b0eb57ea7f,
        \\}
    ;
    try std.testing.expectEqualStrings("my_app", zonName(zon).?);
    const local = try withLocal(a, zon, "C:\\code\\nanoui");
    try std.testing.expect(std.mem.indexOf(u8, local, ".nanoui = .{ .path = \"C:\\\\code\\\\nanoui\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, local, ".paths = .{ \"build.zig\", \"build.zig.zon\", \"src\" }") != null);
    for (native_files) |t| try std.testing.expect(t.text.len > 0);
    for (kit_files) |t| try std.testing.expect(t.text.len > 0);
    for (page_files) |t| try std.testing.expect(t.text.len > 0);
}
