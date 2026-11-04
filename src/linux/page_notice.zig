//! A window's content when its page cannot be shown: no WebKitGTK for this
//! GTK, which the user can fix. A native view, so the app still opens and
//! says what is missing.
const ui = @import("../ui/ui.zig");
const gtk = @import("gtk.zig");

pub const explanation = "Its window shows a web page, and WebKitGTK 2.40 or later is not installed for this GTK. Install it, then open the app again:";

const Notice = struct {
    fn build(_: *Notice, c: *ui.Context) void {
        const box = ui.div(c).column().sizeFull().gap(10).p(28);
        defer box.end();
        _ = ui.text(c, "This app needs WebKitGTK", .{ .size = 18, .weight = .semibold, .wrap = true });
        _ = ui.text(c, explanation, .{ .size = 13, .color = c.theme.muted, .wrap = true });
        _ = ui.text(c, package(gtk.v4), .{ .size = 13, .wrap = true });
        const close = ui.button(c, "Close", .{ .size = 13 });
        if (close.clicked) c.close_request = true;
    }
};

/// Debian's and Ubuntu's package; other distributions name it alike.
pub fn package(gtk4: bool) []const u8 {
    return if (gtk4)
        "sudo apt install libwebkitgtk-6.0-4 (or, with WebKitGTK 4.1, NANOUI_GTK=3)"
    else
        "sudo apt install libwebkit2gtk-4.1-0";
}

pub fn view() ui.View {
    return ui.View.init(@as(*Notice, @ptrFromInt(@alignOf(Notice))), Notice.build);
}
