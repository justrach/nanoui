//! The accessibility tree as text for a model: one line per element worth
//! naming, indented by depth, with a ref to act on it. Containers with
//! nothing to say (a group with no title) are left out and their children
//! moved up, which keeps deep web pages and toolbars short.
const std = @import("std");

pub const Node = struct {
    /// "AXButton", as the platform names it; written without "AX".
    role: []const u8,
    subrole: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    value: []const u8 = "",
    /// x, y, width, height in screen points.
    frame: ?[4]f64 = null,
    enabled: bool = true,
    focused: bool = false,
    selected: bool = false,
};

/// Roles a model may act on, named even when they say nothing.
const actionable = [_][]const u8{
    "Button",      "CheckBox",           "RadioButton", "TextField", "TextArea", "SecureTextField", "ComboBox", "PopUpButton",
    "MenuItem",    "MenuButton",         "MenuBarItem", "Slider",    "Link",     "Tab",             "Cell",     "Row",
    "Incrementor", "DisclosureTriangle", "SearchField", "Window",    "Sheet",    "Dialog",          "Image",    "ColorWell",
};

/// Roles that are only containers.
const plumbing = [_][]const u8{ "Group", "Unknown", "SplitGroup", "ScrollArea", "LayoutArea", "LayoutItem", "Splitter", "Matte", "Column" };

fn bare(role: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, role, "AX")) role[2..] else role;
}

/// A role as it reads in a reply: "Button".
pub const bareRole = bare;

/// Roles an accessibility press does what a click would.
const pressed = [_][]const u8{ "Button", "CheckBox", "RadioButton", "PopUpButton", "MenuButton", "MenuItem", "MenuBarItem", "Link", "DisclosureTriangle", "Incrementor" };

pub fn pressable(role: []const u8) bool {
    return in(bare(role), &pressed);
}

/// Roles that are likely a control's label or icon, so its control is above.
pub fn insideControl(role: []const u8) bool {
    return in(bare(role), &.{ "StaticText", "Image" });
}

fn in(s: []const u8, list: []const []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

/// Whether the node gets a line (and a ref).
pub fn shown(n: Node) bool {
    const r = bare(n.role);
    if (in(r, &actionable)) return true;
    if (n.title.len > 0 or n.description.len > 0) return true;
    if (n.value.len > 0 and !in(r, &plumbing)) return true;
    if (in(r, &plumbing)) return false;
    // Static text with nothing in it, separators, and the like.
    return !std.mem.eql(u8, r, "StaticText") and !std.mem.eql(u8, r, "Splitter");
}

/// Writes `n`'s line: `  [12] Button "Save" (desc) value="…" @x,y wxh`.
pub fn writeLine(w: *std.Io.Writer, n: Node, ref: u32, depth: usize) !void {
    try w.splatByteAll(' ', @min(depth, 40) * 2);
    try w.print("[{d}] {s}", .{ ref, bare(n.role) });
    if (n.subrole.len > 0 and !std.mem.eql(u8, bare(n.subrole), bare(n.role))) try w.print("/{s}", .{bare(n.subrole)});
    if (n.title.len > 0) try quoted(w, " ", n.title, 120);
    if (n.description.len > 0 and !std.mem.eql(u8, n.description, n.title)) try quoted(w, " desc=", n.description, 120);
    if (n.value.len > 0 and !std.mem.eql(u8, n.value, n.title)) try quoted(w, " value=", n.value, 200);
    if (n.frame) |f| try w.print(" @{d:.0},{d:.0} {d:.0}x{d:.0}", .{ f[0], f[1], f[2], f[3] });
    if (!n.enabled) try w.writeAll(" disabled");
    if (n.focused) try w.writeAll(" focused");
    if (n.selected) try w.writeAll(" selected");
    try w.writeByte('\n');
}

/// `s` in quotes on one line, cut after `max` bytes at a character's start.
fn quoted(w: *std.Io.Writer, prefix: []const u8, s: []const u8, max: usize) !void {
    var end = @min(s.len, max);
    while (end < s.len and end > 0 and (s[end] & 0xc0) == 0x80) end -= 1;
    try w.writeAll(prefix);
    try w.writeByte('"');
    for (s[0..end]) |ch| switch (ch) {
        '\n' => try w.writeAll("\\n"),
        '"' => try w.writeAll("\\\""),
        '\r', '\t' => try w.writeByte(' '),
        else => try w.writeByte(ch),
    };
    if (end < s.len) try w.writeAll("…");
    try w.writeByte('"');
}

test "what a press reaches" {
    try std.testing.expect(pressable("AXButton") and pressable("AXLink"));
    try std.testing.expect(!pressable("AXTextArea") and !pressable("AXGroup"));
    try std.testing.expect(insideControl("AXStaticText") and !insideControl("AXTextArea"));
    try std.testing.expectEqualStrings("Button", bareRole("AXButton"));
}

test "lines name what can be acted on and skip plumbing" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expect(!shown(.{ .role = "AXGroup" }));
    try std.testing.expect(shown(.{ .role = "AXGroup", .title = "Sidebar" }));
    try std.testing.expect(shown(.{ .role = "AXButton" }));
    try std.testing.expect(!shown(.{ .role = "AXStaticText" }));
    try std.testing.expect(shown(.{ .role = "AXStaticText", .value = "Hello" }));
    try writeLine(&w, .{ .role = "AXButton", .title = "Save", .description = "Save", .frame = .{ 10, 20.4, 80, 24 }, .enabled = false }, 3, 1);
    try writeLine(&w, .{ .role = "AXTextField", .subrole = "AXSearchField", .value = "a \"b\"\nc", .focused = true }, 4, 0);
    try std.testing.expectEqualStrings(
        \\  [3] Button "Save" @10,20 80x24 disabled
        \\[4] TextField/SearchField value="a \"b\"\nc" focused
        \\
    , w.buffered());
    w = .fixed(&buf);
    const long: [300]u8 = @splat('x');
    try writeLine(&w, .{ .role = "AXStaticText", .value = &long }, 5, 0);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "x…\"\n"));
}
