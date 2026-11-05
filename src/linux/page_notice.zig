//! A window's content when its page cannot be shown, for a reason the user
//! can fix: no WebKitGTK for this GTK, or a WebKitGTK whose sandbox can't
//! start. A native view, so the app still opens and says what is wrong.
const ui = @import("../ui/ui.zig");
const gtk = @import("gtk.zig");
const wk = @import("webkit.zig");

pub const explanation = "Its window shows a web page, and WebKitGTK 2.40 or later is not installed for this GTK. Install it, then open the app again:";
pub const sandbox_explanation = "Its window shows a web page, and WebKitGTK 6.0 can't start here: this system won't let its sandbox, bubblewrap, run. Install WebKitGTK 4.1, which doesn't use it, then open the app again:";
pub const sandbox_fix = "sudo apt install libwebkit2gtk-4.1-0 (or, if it's installed, NANOUI_GTK=3)";

const Notice = struct {
    sandbox: bool,

    fn build(self: *Notice, c: *ui.Context) void {
        const box = ui.div(c).column().sizeFull().gap(10).p(28);
        defer box.end();
        _ = ui.text(c, if (self.sandbox) "This app can't start WebKitGTK" else "This app needs WebKitGTK", .{ .size = 18, .weight = .semibold, .wrap = true });
        _ = ui.text(c, if (self.sandbox) sandbox_explanation else explanation, .{ .size = 13, .color = c.theme.muted, .wrap = true });
        _ = ui.text(c, if (self.sandbox) sandbox_fix else package(gtk.v4), .{ .size = 13, .wrap = true });
        const close = ui.button(c, "Close", .{ .size = 13 });
        if (close.clicked) c.close_request = true;
    }
};

var missing: Notice = .{ .sandbox = false };
var sandbox: Notice = .{ .sandbox = true };

/// Debian's and Ubuntu's package; other distributions name it alike.
pub fn package(gtk4: bool) []const u8 {
    return if (gtk4)
        "sudo apt install libwebkitgtk-6.0-4 (or, with WebKitGTK 4.1, NANOUI_GTK=3)"
    else
        "sudo apt install libwebkit2gtk-4.1-0";
}

pub fn view() ui.View {
    return if (wk.blocked) sandboxView() else missingView();
}

pub fn missingView() ui.View {
    return ui.View.init(&missing, Notice.build);
}

pub fn sandboxView() ui.View {
    return ui.View.init(&sandbox, Notice.build);
}
