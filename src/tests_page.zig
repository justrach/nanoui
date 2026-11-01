//! The pieces of a page that are the same whoever draws it: the origin,
//! the URLs it serves, and the bridge every webview gets.
const std = @import("std");
const page = @import("page.zig");

const testing = std.testing;

test "a page's types are the browser's" {
    try testing.expectEqualStrings("text/html; charset=utf-8", page.mimeType("/index.html"));
    try testing.expectEqualStrings("text/css; charset=utf-8", page.mimeType("/a.css"));
    try testing.expectEqualStrings("application/octet-stream", page.mimeType("/a.unknown"));
}

test "an absolute URL loads as it is, a path joins the origin" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/index.html", page.pathOf(page.fullUrl(&buf, "/index.html")));
    try testing.expectEqualStrings("https://example.com/", page.fullUrl(&buf, "https://example.com/"));
    try testing.expectEqualStrings("/", page.pathOf(page.origin));
    // A foreign URL is nobody's path: it comes back as the root (a 404).
    try testing.expectEqualStrings("/", page.pathOf("https://example.com/evil"));
}

test "the bridge posts through whichever webview the page is in" {
    // One file for every platform: it picks WebView2's `postMessage` when the
    // page has it, and WKWebView's message handler otherwise.
    try testing.expect(std.mem.indexOf(u8, page.bridge_js, "chrome.webview") != null);
    try testing.expect(std.mem.indexOf(u8, page.bridge_js, "webkit") != null);
    try testing.expect(std.mem.indexOf(u8, page.bridge_js, "__nanoui_setPages") != null);
}
