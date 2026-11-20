//! Webview host file-drop interception + file-picker fallback example.
//! Dropped files go to Zig (`PageOptions.file_drop`), never exposing raw paths
//! automatically to JS; only sanitized metadata (name + scheme) is sent via IPC.
const std = @import("std");
const nanoui = @import("nanoui");

const DropEvent = struct {
    count: usize,
    names: []const u8,
    source: []const u8,
};

const HostDrops = nanoui.Event("host_drops", DropEvent);

const Picker = struct {
    gpa: std.mem.Allocator,
    window: *nanoui.Window = undefined,

    pub fn pickFiles(self: *Picker) !void {
        const paths = (try nanoui.dialog.open(self.gpa, .{ .title = "Import files", .multiple = true })) orelse return;
        defer nanoui.dialog.freePaths(self.gpa, paths);
        emitSanitized(self.window, self.gpa, paths, "picker");
    }
};

const DropState = struct {
    gpa: std.mem.Allocator,
    window: *nanoui.Window = undefined,
    retained: std.ArrayList([]u8) = .empty,

    fn deinit(self: *DropState) void {
        for (self.retained.items) |s| self.gpa.free(s);
        self.retained.deinit(self.gpa);
    }

    fn onOffer(_: ?*anyopaque, offer: nanoui.PageDropOffer) nanoui.PageDropDecision {
        // Intercept OS file drags (`urls.len > 0`); leave text/internal drags to webview.
        return if (offer.urls.len > 0 or offer.phase == .enter) .host else .webview;
    }

    fn onDrop(ctx: ?*anyopaque, ev: nanoui.PageDropEvent) bool {
        const self: *DropState = @ptrCast(@alignCast(ctx));
        for (self.retained.items) |s| self.gpa.free(s);
        self.retained.clearRetainingCapacity();
        for (ev.urls) |u| {
            const copy = self.gpa.dupe(u8, u) catch continue;
            self.retained.append(self.gpa, copy) catch self.gpa.free(copy);
        }
        emitSanitized(self.window, self.gpa, self.retained.items, "drop");
        return self.retained.items.len > 0;
    }
};

fn emitSanitized(win: *nanoui.Window, gpa: std.mem.Allocator, items: anytype, src: []const u8) void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    for (items, 0..) |item, i| {
        if (i > 0) aw.writer.writeAll(", ") catch return;
        aw.writer.writeAll(std.fs.path.basename(item)) catch return;
    }
    HostDrops.emit(win, .{ .count = items.len, .names = aw.written(), .source = src });
}

const html =
    \\<!doctype html><meta charset="utf-8"><title>Page Drop</title>
    \\<style>body{font:15px system-ui;margin:28px;background:#111;color:#eee}
    \\button{padding:8px 14px;border-radius:8px;border:1px solid #444;background:#222;color:#fff;cursor:pointer}
    \\#out{margin-top:16px;padding:14px;border:1px dashed #555;border-radius:10px}</style>
    \\<h1>Host File Drop (Webview)</h1>
    \\<p>Drop files anywhere on this window or use the native picker fallback:</p>
    \\<button id="pick">Choose Files...</button>
    \\<div id="out">Waiting for files...</div>
    \\<script type="module">
    \\import { Picker, onHostDrops } from "/nanoui.js";
    \\document.getElementById("pick").onclick = () => Picker.pickFiles();
    \\onHostDrops(({ count, names, source }) => {
    \\  document.getElementById("out").textContent = `${source}: ${count} item(s) -> ${names}`;
    \\});
    \\</script>
;

const assets = [_]nanoui.Asset{
    .{ .path = "/index.html", .data = html },
};

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "PageDrop" });
    defer app.destroy();

    var picker: Picker = .{ .gpa = init.gpa };
    var drops: DropState = .{ .gpa = init.gpa };
    defer drops.deinit();

    try app.bind(&picker);
    try app.registerEvent(HostDrops);

    const win = try app.newWindow(.{
        .title = "Page File Drop",
        .width = 640,
        .height = 420,
        .content = .{ .page = .{
            .url = "/",
            .assets = &assets,
            .file_drop = .{
                .ctx = &drops,
                .on_offer = DropState.onOffer,
                .on_drop = DropState.onDrop,
            },
        } },
    });
    picker.window = win;
    drops.window = win;
    try app.run();
}
