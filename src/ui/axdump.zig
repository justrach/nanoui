//! What VoiceOver reads in a Mac window, through the public NSAccessibility
//! API alone, as `--nanoui-play` steps (`ax:PATH`, `axpress:LABEL`): for
//! checking and showing the tree without Accessibility permission, a
//! visible window, or VoiceOver running.
const std = @import("std");
const objc = @import("../objc.zig");

fn str(o: ?objc.Object) []const u8 {
    const v = o orelse return "";
    // An NSNumber value (a checkbox's) reads as its description.
    if (objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSString")}) == objc.NO)
        return objc.fromNSString(objc.msg(objc.Object, v, "description", .{}));
    return objc.fromNSString(v);
}

/// One line per element of `view`'s accessibility children, written to
/// `path`: role, subrole, label, value, help, frame, enabled. The children
/// of a list follow it, indented by two spaces, with their row index and
/// whether they are selected.
pub fn dump(view: objc.Object, path: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const kids = objc.msg(?objc.Object, view, "accessibilityChildren", .{}) orelse return false;
    const out = objc.msg(objc.Object, objc.class("NSMutableString"), "string", .{});
    write(out, kids, 0);
    const utf8: objc.NSUInteger = 4;
    return objc.msg(objc.BOOL, out, "writeToFile:atomically:encoding:error:", .{ objc.nsString(path), objc.YES, utf8, @as(?*anyopaque, null) }) != objc.NO;
}

fn write(out: objc.Object, kids: objc.Object, depth: usize) void {
    const n = objc.msg(objc.NSUInteger, kids, "count", .{});
    var buf: [1024]u8 = undefined;
    var i: objc.NSUInteger = 0;
    while (i < n) : (i += 1) {
        const e = objc.msg(objc.Object, kids, "objectAtIndex:", .{i});
        const f = objc.msg(objc.CGRect, e, "accessibilityFrame", .{});
        const role = str(objc.msg(?objc.Object, e, "accessibilityRole", .{}));
        const row = std.mem.eql(u8, role, "AXRow");
        const line = std.fmt.bufPrint(&buf, "{s}{d}\t{s}\t{s}\t\"{s}\"\tvalue=\"{s}\"\thelp=\"{s}\"\t{d:.0},{d:.0} {d:.0}x{d:.0}\t{s}{s}{s}{s}\n", .{
            "    "[0 .. @min(depth, 2) * 2],
            i,
            role,
            str(objc.msg(?objc.Object, e, "accessibilitySubrole", .{})),
            str(objc.msg(?objc.Object, e, "accessibilityLabel", .{})),
            str(objc.msg(?objc.Object, e, "accessibilityValue", .{})),
            str(objc.msg(?objc.Object, e, "accessibilityHelp", .{})),
            f.origin.x,
            f.origin.y,
            f.size.width,
            f.size.height,
            if (objc.msg(objc.BOOL, e, "isAccessibilityEnabled", .{}) != objc.NO) "enabled" else "disabled",
            if (objc.msg(objc.BOOL, e, "isAccessibilitySelected", .{}) != objc.NO) "\tselected" else "",
            if (row) "\tindex=" else "",
            if (row) indexText(e) else "",
        }) catch continue;
        objc.msg(void, out, "appendString:", .{objc.nsString(line)});
        if (depth < 2) if (objc.msg(?objc.Object, e, "accessibilityChildren", .{})) |inner| write(out, inner, depth + 1);
    }
}

var index_buf: [24]u8 = undefined;

fn indexText(e: objc.Object) []const u8 {
    const k = objc.msg(objc.NSInteger, e, "accessibilityIndex", .{});
    return std.fmt.bufPrint(&index_buf, "{d}", .{k}) catch "";
}

/// Presses the element labelled `label` as VoiceOver's VO-Space does,
/// looking inside lists too.
pub fn press(view: objc.Object, label: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const kids = objc.msg(?objc.Object, view, "accessibilityChildren", .{}) orelse return false;
    return pressIn(kids, label, 0);
}

fn pressIn(kids: objc.Object, label: []const u8, depth: usize) bool {
    const n = objc.msg(objc.NSUInteger, kids, "count", .{});
    var i: objc.NSUInteger = 0;
    while (i < n) : (i += 1) {
        const e = objc.msg(objc.Object, kids, "objectAtIndex:", .{i});
        if (std.mem.eql(u8, str(objc.msg(?objc.Object, e, "accessibilityLabel", .{})), label))
            return objc.msg(objc.BOOL, e, "accessibilityPerformPress", .{}) != objc.NO;
        if (depth < 2) if (objc.msg(?objc.Object, e, "accessibilityChildren", .{})) |inner| {
            if (pressIn(inner, label, depth + 1)) return true;
        };
    }
    return false;
}
