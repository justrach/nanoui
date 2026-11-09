//! The Mac app's smaller parts (`App`'s): the About panel told the app's
//! name, version and icon (a bare executable has no Info.plist to read
//! them from), the system's recent documents, and the menu bar and Dock
//! hidden for a full-screen view.
const std = @import("std");
const objc = @import("objc.zig");

/// What the About panel shows (the standard panel, `orderFrontStandardAboutPanelWithOptions:`).
pub const About = struct {
    /// The app's name (null: `Options.name`).
    name: ?[]const u8 = null,
    /// The version under the name: "1.4.0".
    version: ?[]const u8 = null,
    /// The build, in parentheses after the version.
    build: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    /// The icon, as PNG bytes (null: the app's own, which a window's
    /// `icon` sets for a bare executable).
    icon_png: ?[]const u8 = null,
};

/// What `App.setPresentationOptions` hides (NSApplicationPresentationOptions):
/// auto-hidden ones come back when the pointer goes to the edge.
pub const Presentation = struct {
    auto_hide_dock: bool = false,
    hide_dock: bool = false,
    auto_hide_menu_bar: bool = false,
    hide_menu_bar: bool = false,
    disable_process_switching: bool = false,

    /// The mask, made one AppKit takes: hiding the menu bar needs the
    /// Dock hidden as well (AppKit raises otherwise), so it is.
    pub fn mask(p: Presentation) objc.NSUInteger {
        var m: objc.NSUInteger = 0;
        var o = p;
        if (o.hide_menu_bar) o.hide_dock = true;
        if (o.auto_hide_menu_bar and !o.hide_dock) o.auto_hide_dock = true;
        if (o.hide_dock) o.auto_hide_dock = false;
        if (o.hide_menu_bar) o.auto_hide_menu_bar = false;
        if (o.auto_hide_dock) m |= 1 << 0;
        if (o.hide_dock) m |= 1 << 1;
        if (o.auto_hide_menu_bar) m |= 1 << 2;
        if (o.hide_menu_bar) m |= 1 << 3;
        if (o.disable_process_switching and (o.hide_dock or o.auto_hide_dock)) m |= 1 << 5;
        return m;
    }
};

/// An NSImage from PNG (or any ImageIO) bytes; owned by the caller.
pub fn image(bytes: []const u8) ?objc.Object {
    if (bytes.len == 0) return null;
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, @as(objc.NSUInteger, bytes.len) });
    return objc.msg(?objc.Object, objc.alloc("NSImage"), "initWithData:", .{data});
}

/// The About panel's options for `about`, the app named `name`.
/// Autoreleased.
pub fn aboutOptions(about: About, name: []const u8) objc.Object {
    const dict = objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});
    const put = struct {
        fn f(d: objc.Object, key: []const u8, value: objc.Object) void {
            objc.msg(void, d, "setObject:forKey:", .{ value, objc.nsString(key) });
        }
    }.f;
    put(dict, "ApplicationName", objc.nsString(about.name orelse name));
    if (about.version) |v| put(dict, "ApplicationVersion", objc.nsString(v));
    // An empty build hides AppKit's "(CFBundleVersion)" when there's none.
    put(dict, "Version", objc.nsString(about.build orelse ""));
    if (about.copyright) |c| put(dict, "Copyright", objc.nsString(c));
    if (about.icon_png) |png| if (image(png)) |img| {
        put(dict, "ApplicationIcon", img);
        objc.release(img);
    };
    return dict;
}

/// Shows the standard About panel with `about`'s options.
pub fn showAbout(nsapp: objc.Object, about: About, name: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    objc.msg(void, nsapp, "orderFrontStandardAboutPanelWithOptions:", .{aboutOptions(about, name)});
}

/// Adds the file at `path` to the system's recent documents (File ▸ Open
/// Recent, the Dock icon's menu).
pub fn addRecentDocument(path: []const u8) void {
    if (path.len == 0) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(?objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)}) orelse return;
    const dc = objc.msg(objc.Object, objc.class("NSDocumentController"), "sharedDocumentController", .{});
    objc.msg(void, dc, "noteNewRecentDocumentURL:", .{url});
}

/// Forgets the system's recent documents for this app.
pub fn clearRecentDocuments() void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const dc = objc.msg(objc.Object, objc.class("NSDocumentController"), "sharedDocumentController", .{});
    objc.msg(void, dc, "clearRecentDocuments:", .{@as(?objc.Object, null)});
}

/// How many recent documents the system keeps for this app.
pub fn recentDocumentCount() usize {
    const dc = objc.msg(objc.Object, objc.class("NSDocumentController"), "sharedDocumentController", .{});
    const urls = objc.msg(objc.Object, dc, "recentDocumentURLs", .{});
    return objc.msg(objc.NSUInteger, urls, "count", .{});
}

test "presentation masks AppKit takes" {
    try std.testing.expectEqual(@as(objc.NSUInteger, 1 | 4), (Presentation{ .auto_hide_menu_bar = true }).mask());
    try std.testing.expectEqual(@as(objc.NSUInteger, 2 | 8), (Presentation{ .hide_menu_bar = true }).mask());
    try std.testing.expectEqual(@as(objc.NSUInteger, 1 | 4), (Presentation{ .auto_hide_menu_bar = true, .auto_hide_dock = true }).mask());
    try std.testing.expectEqual(@as(objc.NSUInteger, 0), (Presentation{}).mask());
}

test "the About panel's options: name, version, build and icon" {
    const pool = objc.Pool.push();
    defer pool.pop();
    var px = [_]u8{ 0, 0, 255, 255 };
    const png = try @import("ui/png.zig").encode(std.testing.allocator, .{ .bytes = &px, .width = 1, .height = 1 });
    defer std.testing.allocator.free(png);
    const d = aboutOptions(.{ .version = "2.1.0", .build = "42", .icon_png = png }, "Alchemist");
    const get = struct {
        fn f(dict: objc.Object, key: []const u8) ?objc.Object {
            return objc.msg(?objc.Object, dict, "objectForKey:", .{objc.nsString(key)});
        }
    }.f;
    try std.testing.expectEqualStrings("Alchemist", objc.fromNSString(get(d, "ApplicationName")));
    try std.testing.expectEqualStrings("2.1.0", objc.fromNSString(get(d, "ApplicationVersion")));
    try std.testing.expectEqualStrings("42", objc.fromNSString(get(d, "Version")));
    try std.testing.expect(get(d, "ApplicationIcon") != null);
    try std.testing.expect(get(aboutOptions(.{}, "Alchemist"), "ApplicationIcon") == null);
}

test "addRecentDocument takes a file and leaves nothing behind" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cut.alcm", .data = "{}" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(std.testing.io, "cut.alcm", &buf);
    addRecentDocument(buf[0..n]);
    addRecentDocument("");
    clearRecentDocuments();
    try std.testing.expectEqual(@as(usize, 0), recentDocumentCount());
}
