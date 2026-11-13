//! nanoui's component kit, after GPUI Kit (longbridge/gpui-component):
//! buttons in its variants and sizes, tags, badges, avatars, alerts,
//! skeletons, spinners, progress and timeline rows; tooltips, popovers,
//! menus, dialogs, sheets and toasts drawn on layers over the page; tabs,
//! accordions, radio groups, selects, number inputs, breadcrumbs and pagination. Each
//! is a call in a frame, as nanoui's widgets are, styled from the theme
//! and moved with `ui.motion`.
//!
//!     if (kit.button(c, "Save", .{ .variant = .primary, .icon = "checkmark" }).clicked) save();
//!     if (kit.dialog(c, "confirm", &open, .{ .title = "Delete it?", .ok = "Delete" })) |d| {
//!         ui.text(c, "This can't be undone.", .{});
//!         if (d.end() == .ok) delete();
//!     }
const std = @import("std");
const ui = @import("../ui/ui.zig");
const Color = ui.Color;

pub const button_mod = @import("button.zig");
pub const button = button_mod.button;
pub const iconButton = button_mod.iconButton;
pub const ButtonOptions = button_mod.Options;
pub const Variant = button_mod.Variant;

const display = @import("display.zig");
pub const tag = display.tag;
pub const badge = display.badge;
pub const avatar = display.avatar;
pub const avatarGroup = display.avatarGroup;
pub const alert = display.alert;
pub const skeleton = display.skeleton;
pub const spinner = display.spinner;
pub const progress = display.progress;
pub const ring = display.ring;
pub const separator = display.separator;
pub const empty = display.empty;

const timeline = @import("timeline.zig");
pub const timelineItem = timeline.timelineItem;
pub const TimelineItemOptions = timeline.Options;

const overlay = @import("overlay.zig");
pub const Placement = overlay.Placement;
pub const tooltip = overlay.tooltip;
pub const popover = overlay.popover;
pub const Popover = overlay.Popover;
pub const menu = overlay.menu;
pub const MenuItem = overlay.MenuItem;

const dialog_mod = @import("dialog.zig");
pub const dialog = dialog_mod.dialog;
pub const Dialog = dialog_mod.Dialog;
pub const DialogResult = dialog_mod.Result;
pub const sheet = dialog_mod.sheet;

pub const Toaster = @import("toast.zig").Toaster;

const nav = @import("nav.zig");
pub const tabs = nav.tabs;
pub const TabsVariant = nav.TabsVariant;
pub const Section = nav.Section;
pub const breadcrumb = nav.breadcrumb;
pub const pagination = nav.pagination;
pub const accordion = nav.accordion;
pub const collapsible = nav.collapsible;

const form = @import("form.zig");
pub const radioGroup = form.radioGroup;
pub const select = form.select;
pub const numberInput = form.numberInput;
pub const field = form.field;

/// Sizes, as GPUI Kit's: extra small to large.
pub const Size = enum {
    xs,
    sm,
    md,
    lg,

    /// The text size at this size.
    pub fn text(s: Size) f32 {
        return switch (s) {
            .xs => 11,
            .sm => 12.5,
            .md => 14,
            .lg => 16,
        };
    }

    /// A control's height at this size.
    pub fn height(s: Size) f32 {
        return switch (s) {
            .xs => 22,
            .sm => 28,
            .md => 34,
            .lg => 42,
        };
    }
};

/// The kit's colors, from the window's theme.
pub const Tokens = struct {
    background: Color,
    foreground: Color,
    muted: Color,
    border: Color,
    surface: Color,
    surface_hover: Color,
    primary: Color,
    primary_hover: Color,
    primary_foreground: Color,
    danger: Color,
    success: Color,
    warning: Color,
    info: Color,
    /// Popovers, menus and dialogs, and the dimming behind a dialog.
    popover: Color,
    overlay: Color,
    shadow: Color,
    radius: f32 = 8,
};

pub fn tokens(c: *ui.Context) Tokens {
    const th = c.theme;
    return .{
        .background = th.background,
        .foreground = th.text,
        .muted = th.muted,
        .border = th.border,
        .surface = th.surface,
        .surface_hover = th.surface_hover,
        .primary = th.accent,
        .primary_hover = th.accent_hover,
        .primary_foreground = th.accent_text,
        .danger = th.danger,
        .success = th.success,
        .warning = if (th.dark) .hex(0xe0a33a) else .hex(0xc27c0e),
        .info = if (th.dark) .hex(0x5aa8f0) else .hex(0x2f78c4),
        .popover = th.surface,
        .overlay = Color.black.alpha(if (th.dark) 0.55 else 0.35),
        .shadow = th.shadow,
    };
}

/// A status's color: info, success, warning or danger.
pub const Status = enum { neutral, info, success, warning, danger };

pub fn statusColor(t: Tokens, s: Status) Color {
    return switch (s) {
        .neutral => t.muted,
        .info => t.info,
        .success => t.success,
        .warning => t.warning,
        .danger => t.danger,
    };
}

/// The SF Symbol a status shows.
pub fn statusIcon(s: Status) []const u8 {
    return switch (s) {
        .neutral => "info.circle",
        .info => "info.circle.fill",
        .success => "checkmark.circle.fill",
        .warning => "exclamationmark.triangle.fill",
        .danger => "xmark.octagon.fill",
    };
}

test {
    _ = @import("tests.zig");
    _ = @import("tests_timeline.zig");
}
