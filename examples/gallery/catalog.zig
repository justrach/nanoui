//! The gallery's pages by number, and their names. The demos come first
//! (`phone.pages`, in the order a phone lists them and ⌘1…⌘9 open them),
//! then the foundations, then a page per `nanoui.kit` component.
//!
//! On the desktop the sidebar files them under Foundations, Components and
//! Demos; the Typography demo is a foundation there, and the Kit demo's
//! single page gives way to the components' own.
const std = @import("std");
const phone = @import("phone.zig");

pub const demo_count = phone.pages.len;
/// Demos the desktop sidebar files elsewhere.
pub const typography = 2;
pub const kit_demo = 6;
pub const colors = demo_count;
pub const icons = demo_count + 1;
pub const first_component = demo_count + 2;

pub const Group = enum {
    buttons,
    display,
    timeline,
    navigation,
    forms,
    overlays,

    pub fn title(g: Group) []const u8 {
        return switch (g) {
            .buttons => "Buttons",
            .display => "Display",
            .timeline => "Timeline",
            .navigation => "Navigation",
            .forms => "Forms",
            .overlays => "Overlays",
        };
    }

    pub fn icon(g: Group) []const u8 {
        return switch (g) {
            .buttons => "hand.raised",
            .display => "app.badge",
            .timeline => "arrow.triangle.branch",
            .navigation => "sidebar.left",
            .forms => "text.cursor",
            .overlays => "rectangle.on.rectangle",
        };
    }
};

pub const group_count = std.enums.values(Group).len;

pub const Component = struct {
    /// Its page's name on the command line (`gallery button`).
    id: []const u8,
    name: []const u8,
    group: Group,
    /// The call, as the page's heading shows it.
    call: []const u8,
    file: []const u8,
};

pub const components = [_]Component{
    .{ .id = "button", .name = "Button", .group = .buttons, .call = "kit.button(c, label, .{ .variant, .size, .icon, .loading, .disabled, .pill, .glass })", .file = "src/kit/button.zig" },
    .{ .id = "icon-button", .name = "Icon button", .group = .buttons, .call = "kit.iconButton(c, icon, .{ .variant, .size, .tooltip })", .file = "src/kit/button.zig" },
    .{ .id = "tag", .name = "Tag", .group = .display, .call = "kit.tag(c, label, .{ .status, .outline, .pill, .icon, .size })", .file = "src/kit/display.zig" },
    .{ .id = "badge", .name = "Badge", .group = .display, .call = "kit.badge(c, count, .{ .dot, .max, .x, .y })", .file = "src/kit/display.zig" },
    .{ .id = "avatar", .name = "Avatar", .group = .display, .call = "kit.avatar(c, .{ .name, .image, .size, .ring })", .file = "src/kit/display.zig" },
    .{ .id = "kbd", .name = "Keycaps", .group = .display, .call = "kit.kbd(c, keys) · kit.kbdWith(c, keys, .{ .size, .color })", .file = "src/kit/kbd.zig" },
    .{ .id = "alert", .name = "Alert", .group = .display, .call = "kit.alert(c, .{ .status, .title, .description, .closable, .banner })", .file = "src/kit/display.zig" },
    .{ .id = "progress", .name = "Progress", .group = .display, .call = "kit.progress(c, value, .{ .status, .height, .width })", .file = "src/kit/display.zig" },
    .{ .id = "ring", .name = "Ring", .group = .display, .call = "kit.ring(c, value, .{ .size, .label, .color })", .file = "src/kit/display.zig" },
    .{ .id = "spinner", .name = "Spinner", .group = .display, .call = "kit.spinner(c, .{ .size, .color })", .file = "src/kit/display.zig" },
    .{ .id = "skeleton", .name = "Skeleton", .group = .display, .call = "kit.skeleton(c, .{ .width, .height, .radius, .circle })", .file = "src/kit/display.zig" },
    .{ .id = "separator", .name = "Separator", .group = .display, .call = "kit.separator(c, .{ .vertical, .label })", .file = "src/kit/display.zig" },
    .{ .id = "empty", .name = "Empty state", .group = .display, .call = "kit.empty(c, .{ .icon, .title, .description })", .file = "src/kit/display.zig" },
    .{ .id = "timeline", .name = "Timeline", .group = .timeline, .call = "kit.timelineItem(c, .{ .height, .first, .last, .color, .selected })", .file = "src/kit/timeline.zig" },
    .{ .id = "tabs", .name = "Tabs", .group = .navigation, .call = "kit.tabs(c, items, &selected, .{ .variant, .size })", .file = "src/kit/nav.zig" },
    .{ .id = "breadcrumb", .name = "Breadcrumb", .group = .navigation, .call = "kit.breadcrumb(c, items)", .file = "src/kit/nav.zig" },
    .{ .id = "pagination", .name = "Pagination", .group = .navigation, .call = "kit.pagination(c, &page, pages)", .file = "src/kit/nav.zig" },
    .{ .id = "accordion", .name = "Accordion", .group = .navigation, .call = "kit.accordion(c, id, title, index, &open) · kit.collapsible(c, id, title, &open)", .file = "src/kit/nav.zig" },
    .{ .id = "field", .name = "Field", .group = .forms, .call = "kit.field(c, label, .{ .hint, .err, .required })", .file = "src/kit/form.zig" },
    .{ .id = "radio-group", .name = "Radio group", .group = .forms, .call = "kit.radioGroup(c, options, &selected, .{ .horizontal, .disabled })", .file = "src/kit/form.zig" },
    .{ .id = "select", .name = "Select", .group = .forms, .call = "kit.select(c, id, options, &selected, .{ .placeholder, .width, .disabled })", .file = "src/kit/form.zig" },
    .{ .id = "number-input", .name = "Number input", .group = .forms, .call = "kit.numberInput(c, &value, .{ .min, .max, .step, .decimals, .width })", .file = "src/kit/form.zig" },
    .{ .id = "menu", .name = "Menu", .group = .overlays, .call = "kit.menu(c, id, &open, anchor, items, .{ .placement, .width, .glass, .safe_triangle = true, .debug })", .file = "src/kit/menu.zig" },
    .{ .id = "popover", .name = "Popover", .group = .overlays, .call = "kit.popover(c, id, &open, anchor, .{ .placement, .width, .glass })", .file = "src/kit/overlay.zig" },
    .{ .id = "tooltip", .name = "Tooltip", .group = .overlays, .call = "kit.tooltip(c, trigger, text, .{ .placement, .delay })", .file = "src/kit/overlay.zig" },
    .{ .id = "dialog", .name = "Dialog", .group = .overlays, .call = "kit.dialog(c, id, &open, .{ .title, .description, .ok, .cancel, .ok_variant })", .file = "src/kit/dialog.zig" },
    .{ .id = "sheet", .name = "Sheet", .group = .overlays, .call = "kit.sheet(c, id, &open, .{ .side, .size, .title })", .file = "src/kit/dialog.zig" },
    .{ .id = "toast", .name = "Toast", .group = .overlays, .call = "toaster.push(.{ .status, .title, .message, .duration })", .file = "src/kit/toast.zig" },
};

pub const page_count = first_component + components.len;

/// The component page `i` shows, if it shows one.
pub fn component(i: usize) ?Component {
    if (i < first_component or i >= page_count) return null;
    return components[i - first_component];
}

/// Page `i`'s name on the command line: `colors`, `icons`, a component's
/// id, or a demo's name in lower case (`studio`).
pub fn slug(buf: []u8, i: usize) []const u8 {
    if (i == colors) return "colors";
    if (i == icons) return "icons";
    if (component(i)) |comp| return comp.id;
    const name = phone.pages[i][0];
    return std.ascii.lowerString(buf[0..name.len], name);
}

pub fn find(name: []const u8) ?usize {
    var buf: [32]u8 = undefined;
    for (0..page_count) |i| if (std.ascii.eqlIgnoreCase(slug(&buf, i), name)) return i;
    return null;
}

/// The members of a sidebar group, as page numbers.
pub fn members(g: Group, out: *[components.len]usize) []usize {
    var n: usize = 0;
    for (components, 0..) |comp, k| if (comp.group == g) {
        out[n] = first_component + k;
        n += 1;
    };
    return out[0..n];
}

test "every page has a name that finds it" {
    var buf: [32]u8 = undefined;
    for (0..page_count) |i| try std.testing.expectEqual(@as(?usize, i), find(slug(&buf, i)));
    try std.testing.expectEqual(@as(?usize, null), find("nope"));
}
