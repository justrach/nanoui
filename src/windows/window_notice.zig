//! What a page's window shows when WebView2 is not on the machine.
const ui = @import("../ui/ui.zig");

/// The window's content when its page cannot be shown: no WebView2 on this
/// machine, which the user can fix. A native view, so the window opens and
/// says what is missing — with the download page one click away, and the
/// address itself for anyone who'd rather read it first.
const download_url = "https://developer.microsoft.com/microsoft-edge/webview2/";

pub fn fallbackView(_: []const u8) ui.View {
    const Notice = struct {
        fn build(_: *@This(), c: *ui.Context) void {
            const box = ui.div(c).column().center().sizeFull().gap(10).p(28);
            defer box.end();
            _ = ui.text(c, "This app needs Microsoft Edge WebView2", .{ .size = 18, .weight = .semibold });
            _ = ui.text(c, "It is not installed on this PC. Install the Evergreen Runtime, then open the app again.", .{ .size = 13, .color = c.theme.muted });
            const dl = ui.button(c, "Download WebView2", .{ .variant = .primary, .size = 14 });
            if (dl.clicked) _ = @import("desktop.zig").shell.openUrl(download_url);
            _ = ui.text(c, download_url, .{ .size = 11, .color = c.theme.muted });
            const close = ui.button(c, "Close", .{ .size = 13 });
            if (close.clicked) c.close_request = true;
        }
    };
    return ui.View.init(@as(*Notice, @ptrFromInt(@alignOf(Notice))), Notice.build);
}
