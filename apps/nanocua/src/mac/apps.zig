//! Running apps through NSWorkspace: the ones with windows (regular
//! activation policy), finding one by name, and opening one, behind what the
//! user is doing or brought forward. Callers hold an autorelease pool.
const std = @import("std");
const objc = @import("nanoui").objc;

pub const App = struct {
    pid: i32,
    name: []const u8,
    bundle: []const u8,
    active: bool,
};

fn running() objc.Object {
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    return objc.msg(objc.Object, ws, "runningApplications", .{});
}

/// Calls `f(ctx, app)` for every regular app; strings live until the pool pops.
pub fn each(ctx: anytype, comptime f: fn (@TypeOf(ctx), App) void) void {
    const list = running();
    const n = objc.msg(usize, list, "count", .{});
    for (0..n) |i| {
        const a = objc.msg(objc.Object, list, "objectAtIndex:", .{i});
        if (objc.msg(isize, a, "activationPolicy", .{}) != 0) continue;
        f(ctx, .{
            .pid = objc.msg(i32, a, "processIdentifier", .{}),
            .name = objc.fromNSString(objc.msg(?objc.Object, a, "localizedName", .{})),
            .bundle = objc.fromNSString(objc.msg(?objc.Object, a, "bundleIdentifier", .{})),
            .active = objc.msg(bool, a, "isActive", .{}),
        });
    }
}

fn find(name: []const u8) ?objc.Object {
    const list = running();
    const n = objc.msg(usize, list, "count", .{});
    for (0..n) |i| {
        const a = objc.msg(objc.Object, list, "objectAtIndex:", .{i});
        const an = objc.fromNSString(objc.msg(?objc.Object, a, "localizedName", .{}));
        const ab = objc.fromNSString(objc.msg(?objc.Object, a, "bundleIdentifier", .{}));
        if (std.ascii.eqlIgnoreCase(an, name) or std.ascii.eqlIgnoreCase(ab, name)) return a;
    }
    return null;
}

/// The pid of the running app named `name` (or with that bundle id).
pub fn pidNamed(name: []const u8) ?i32 {
    const a = find(name) orelse return null;
    return objc.msg(i32, a, "processIdentifier", .{});
}

pub const OpenResult = enum { running, activated, launched, not_found };

/// Launches `name` from the usual folders (or by bundle id) if it isn't
/// running. Only with `forward` does it come in front of the user's work.
pub fn open(name: []const u8, forward: bool) OpenResult {
    if (find(name)) |a| {
        if (!forward) return .running;
        // NSApplicationActivateAllWindows
        _ = objc.msg(bool, a, "activateWithOptions:", .{@as(usize, 1)});
        return .activated;
    }
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    var url: ?objc.Object = null;
    if (std.mem.indexOfScalar(u8, name, '.') != null)
        url = objc.msg(?objc.Object, ws, "URLForApplicationWithBundleIdentifier:", .{objc.nsString(name)});
    if (url == null) url = byPath(name);
    const u = url orelse return .not_found;
    const config = objc.msg(objc.Object, objc.class("NSWorkspaceOpenConfiguration"), "configuration", .{});
    objc.msg(void, config, "setActivates:", .{forward});
    objc.msg(void, ws, "openApplicationAtURL:configuration:completionHandler:", .{ u, config, @as(?*anyopaque, null) });
    return .launched;
}

fn byPath(name: []const u8) ?objc.Object {
    if (name.len == 0 or name.len > 200 or std.mem.indexOfScalar(u8, name, '/') != null) return null;
    const dirs = [_][]const u8{ "/Applications/", "/System/Applications/", "/System/Applications/Utilities/", "/Applications/Utilities/" };
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    var buf: [300]u8 = undefined;
    for (dirs) |d| {
        const path = std.fmt.bufPrint(&buf, "{s}{s}.app", .{ d, name }) catch continue;
        const ns = objc.nsString(path);
        if (!objc.msg(bool, fm, "fileExistsAtPath:", .{ns})) continue;
        return objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{ns});
    }
    return null;
}
