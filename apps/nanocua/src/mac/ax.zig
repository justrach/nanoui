//! An app's accessibility tree, walked with one round trip per element
//! (AXUIElementCopyMultipleAttributeValues), written as text with refs;
//! the elements behind the refs, kept until the next walk; and what can
//! be done to one: press it, focus it, set its value, find its frame.
//! Used from the backend's queue only.
const std = @import("std");
const cf = @import("cf.zig");
const tree = @import("../tree.zig");

extern "c" fn usleep(us: c_uint) c_int;

/// Elements named by the last tree: ref n is list[n - 1], retained.
pub const Refs = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(cf.AXUIElementRef) = .empty,

    pub fn clear(r: *Refs) void {
        for (r.list.items) |e| cf.CFRelease(e);
        r.list.clearRetainingCapacity();
    }

    pub fn deinit(r: *Refs) void {
        r.clear();
        r.list.deinit(r.gpa);
    }

    fn add(r: *Refs, el: cf.AXUIElementRef) !u32 {
        try r.list.append(r.gpa, el);
        _ = cf.CFRetain(el);
        return @intCast(r.list.items.len);
    }

    pub fn get(r: *Refs, ref: i64) ?cf.AXUIElementRef {
        if (ref < 1 or ref > r.list.items.len) return null;
        return r.list.items[@intCast(ref - 1)];
    }
};

const names = [_][]const u8{ "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXPosition", "AXSize", "AXChildren", "AXEnabled", "AXFocused", "AXSelected" };
const Attr = enum { role, subrole, title, description, value, position, size, children, enabled, focused, selected };

pub const Options = struct {
    max_nodes: usize = 400,
    /// The menu bar's items (long; keys reach menus anyway).
    menus: bool = false,
};

const Walk = struct {
    refs: *Refs,
    w: *std.Io.Writer,
    opts: Options,
    names: cf.CFArrayRef,
    shown: usize = 0,
    full: bool = false,
};

/// Writes app `pid`'s tree to `w`, replacing the refs.
pub fn writeTree(refs: *Refs, w: *std.Io.Writer, pid: i32, opts: Options) !void {
    refs.clear();
    var name_refs: [names.len]?*const anyopaque = undefined;
    for (names, 0..) |n, i| name_refs[i] = cf.str(n);
    defer for (name_refs) |n| cf.CFRelease(@constCast(n.?));
    const arr = cf.CFArrayCreate(null, &name_refs, names.len, &cf.kCFTypeArrayCallBacks) orelse return error.OutOfMemory;
    defer cf.CFRelease(arr);
    const app = cf.AXUIElementCreateApplication(pid);
    defer cf.CFRelease(app);
    // Chromium and Electron build their tree only for assistive technology
    // that says it's there; everything else ignores this. Until it's built
    // they show no elements, so an empty first read is worth another look.
    _ = set(app, "AXManualAccessibility", cf.kCFBooleanTrue);
    var walk: Walk = .{ .refs = refs, .w = w, .opts = opts, .names = arr };
    var title_buf: [128]u8 = undefined;
    try w.print("app \"{s}\" pid {d}\n", .{ copyText(&title_buf, app, "AXTitle"), pid });
    const before = w.end;
    try visit(&walk, app, 0, 0);
    var tries: usize = 0;
    while (w.end == before and tries < 3) : (tries += 1) {
        _ = usleep(300_000);
        try visit(&walk, app, 0, 0);
    }
    if (w.end == before) try w.writeAll("(no elements: the app shows no windows, or it doesn't support accessibility)\n");
    if (walk.full) try w.print("(stopped at {d} elements: ask for a larger max_nodes, up to 2000)\n", .{walk.shown});
}

fn visit(walk: *Walk, el: cf.AXUIElementRef, depth: usize, level: usize) !void {
    if (walk.full or level > 64) return;
    var out: ?cf.CFArrayRef = null;
    if (cf.AXUIElementCopyMultipleAttributeValues(el, walk.names, 0, &out) != 0) return;
    const vals = out orelse return;
    defer cf.CFRelease(vals);
    var v: [names.len]?*anyopaque = undefined;
    for (0..names.len) |i| {
        const x = cf.CFArrayGetValueAtIndex(vals, @intCast(i));
        // Missing attributes come back as AXValues holding an error.
        v[i] = if (x) |p| (if (cf.CFGetTypeID(p) == cf.AXValueGetTypeID() and cf.AXValueGetType(@ptrCast(p)) == 5) null else p) else null;
    }
    var bufs: [5][256]u8 = undefined;
    const at = struct {
        fn f(vs: *[names.len]?*anyopaque, a: Attr) ?*anyopaque {
            return vs[@backingInt(a)];
        }
    }.f;
    var node: tree.Node = .{
        .role = cf.text(&bufs[0], at(&v, .role)),
        .subrole = cf.text(&bufs[1], at(&v, .subrole)),
        .title = cf.text(&bufs[2], at(&v, .title)),
        .description = cf.text(&bufs[3], at(&v, .description)),
        .value = cf.text(&bufs[4], at(&v, .value)),
        .enabled = cf.boolean(at(&v, .enabled)) orelse true,
        .focused = cf.boolean(at(&v, .focused)) orelse false,
        .selected = cf.boolean(at(&v, .selected)) orelse false,
    };
    if (cf.point(at(&v, .position))) |p| if (cf.size(at(&v, .size))) |s| {
        node.frame = .{ p.x, p.y, s.width, s.height };
    };
    if (std.mem.eql(u8, node.role, "AXMenuBar") and !walk.opts.menus) return;
    var child_depth = depth;
    // The application itself is the header, not a line.
    if (level > 0 and tree.shown(node)) {
        if (walk.shown >= walk.opts.max_nodes) {
            walk.full = true;
            return;
        }
        const ref = try walk.refs.add(el);
        try tree.writeLine(walk.w, node, ref, depth);
        walk.shown += 1;
        child_depth += 1;
    }
    const kids = cf.array(at(&v, .children)) orelse return;
    const n: usize = @intCast(cf.CFArrayGetCount(kids));
    for (0..n) |i| {
        const k = cf.CFArrayGetValueAtIndex(kids, @intCast(i)) orelse continue;
        try visit(walk, @ptrCast(k), child_depth, level + 1);
    }
}

/// An attribute as text (a title, a role).
pub fn copyText(buf: []u8, el: cf.AXUIElementRef, attr: []const u8) []const u8 {
    const v = copy(el, attr) orelse return "";
    defer cf.CFRelease(v);
    return cf.text(buf, v);
}

/// An attribute's value, owned: release it.
pub fn copy(el: cf.AXUIElementRef, attr: []const u8) ?*anyopaque {
    const name = cf.str(attr);
    defer cf.CFRelease(name);
    var out: ?cf.CFTypeRef = null;
    if (cf.AXUIElementCopyAttributeValue(el, name, &out) != 0) return null;
    return out;
}

/// x, y, width, height in screen points.
pub fn frame(el: cf.AXUIElementRef) ?[4]f64 {
    const p = copy(el, "AXPosition") orelse return null;
    defer cf.CFRelease(p);
    const s = copy(el, "AXSize") orelse return null;
    defer cf.CFRelease(s);
    const pt = cf.point(p) orelse return null;
    const sz = cf.size(s) orelse return null;
    return .{ pt.x, pt.y, sz.width, sz.height };
}

pub fn center(el: cf.AXUIElementRef) ?[2]f64 {
    const f = frame(el) orelse return null;
    return .{ f[0] + f[2] / 2, f[1] + f[3] / 2 };
}

pub fn pidOf(el: cf.AXUIElementRef) ?i32 {
    var pid: i32 = 0;
    return if (cf.AXUIElementGetPid(el, &pid) == 0) pid else null;
}

pub fn perform(el: cf.AXUIElementRef, action: []const u8) bool {
    const a = cf.str(action);
    defer cf.CFRelease(a);
    return cf.AXUIElementPerformAction(el, a) == 0;
}

pub fn set(el: cf.AXUIElementRef, attr: []const u8, value: *anyopaque) cf.AXError {
    const a = cf.str(attr);
    defer cf.CFRelease(a);
    return cf.AXUIElementSetAttributeValue(el, a, value);
}

pub fn setText(el: cf.AXUIElementRef, s: []const u8) cf.AXError {
    const v = cf.str(s);
    defer cf.CFRelease(v);
    return set(el, "AXValue", v);
}

pub fn focus(el: cf.AXUIElementRef) bool {
    return set(el, "AXFocused", cf.kCFBooleanTrue) == 0;
}

/// The app owning whatever is at x, y.
pub fn pidAt(x: f64, y: f64) ?i32 {
    const sys = cf.AXUIElementCreateSystemWide();
    defer cf.CFRelease(sys);
    var el: ?cf.AXUIElementRef = null;
    if (cf.AXUIElementCopyElementAtPosition(sys, @floatCast(x), @floatCast(y), &el) != 0) return null;
    const e = el orelse return null;
    defer cf.CFRelease(e);
    return pidOf(e);
}

/// The app the keyboard goes to.
pub fn focusedPid() ?i32 {
    const sys = cf.AXUIElementCreateSystemWide();
    defer cf.CFRelease(sys);
    const app = copy(sys, "AXFocusedApplication") orelse return null;
    defer cf.CFRelease(app);
    return pidOf(@ptrCast(app));
}

/// How long a call waits for an app that doesn't answer (a hung app
/// mustn't hold every agent for the default six seconds).
pub fn setTimeout(seconds: f32) void {
    const sys = cf.AXUIElementCreateSystemWide();
    defer cf.CFRelease(sys);
    _ = cf.AXUIElementSetMessagingTimeout(sys, seconds);
}
