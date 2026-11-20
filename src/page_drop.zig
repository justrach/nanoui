//! Platform-free routing, coordinate normalization, URI-list parsing, and
//! drag-session lifecycle for host-level file drops over a page webview.
const std = @import("std");
const testing = std.testing;
const window_types = @import("window_types.zig");

pub const Decision = window_types.PageDropDecision;
pub const Phase = window_types.PageDropPhase;
pub const Offer = window_types.PageDropOffer;
pub const Event = window_types.PageDropEvent;
pub const Config = window_types.PageFileDrop;

/// Converts OS-origin coordinates (`is_flipped == false`: AppKit bottom-left origin;
/// `is_flipped == true`: top-left origin such as GTK or flipped views) into
/// top-left, view-local logical points clamped to non-negative finite values.
pub fn toTopLeft(x: f64, y: f64, view_height: f64, is_flipped: bool) struct { x: f64, y: f64 } {
    const cx = if (std.math.isFinite(x)) x else 0;
    const raw_y = if (std.math.isFinite(y)) y else 0;
    const h = if (std.math.isFinite(view_height) and view_height > 0) view_height else 0;
    const cy = if (is_flipped) raw_y else h - raw_y;
    return .{ .x = cx, .y = cy };
}

/// Parses an RFC 2483 `text/uri-list` payload, keeping only `file://` URLs
/// (preserving UTF-8 / percent-encoding) and ignoring comments and non-file schemes.
/// Caller owns the returned slice and each duplicated URL string.
pub fn parseUriList(gpa: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |u| gpa.free(u);
        list.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!startsWithFileScheme(line)) continue;
        // Require either file:///path or file://host/path (never bare "file://").
        if (line.len <= "file://".len) continue;
        const copy = try gpa.dupe(u8, line);
        errdefer gpa.free(copy);
        try list.append(gpa, copy);
    }
    return try list.toOwnedSlice(gpa);
}

pub fn freeUrlSlice(gpa: std.mem.Allocator, urls: []const []const u8) void {
    for (urls) |u| gpa.free(u);
    if (urls.len > 0) gpa.free(urls);
}

pub fn startsWithFileScheme(url: []const u8) bool {
    return url.len >= 7 and std.ascii.eqlIgnoreCase(url[0..7], "file://");
}

/// Tracks a single page's active drag offer, routing decision, and navigation /
/// teardown epoch so stale offers, late async completions, and duplicate
/// deliveries cannot leak or fire after close or navigation.
pub const Session = struct {
    config: ?Config = null,
    active: bool = false,
    decision: Decision = .webview,
    epoch: u64 = 1,
    active_epoch: u64 = 0,
    closed: bool = false,

    pub fn init(cfg: ?Config) Session {
        return .{ .config = cfg };
    }

    pub fn isEnabled(self: *const Session) bool {
        return !self.closed and self.config != null;
    }

    /// Evaluates an incoming drag enter/update offer. Note `on_offer` runs on the
    /// UI thread and may reentrantly close/navigate; callers must tolerate dead state.
    pub fn onOffer(self: *Session, phase: Phase, x: f64, y: f64, urls: []const []const u8, has_file_candidates: bool) Decision {
        const cfg = self.config orelse return .webview;
        if (self.closed) return .reject;
        if (phase == .enter) {
            self.active = true;
            self.active_epoch = self.epoch;
        } else if (!self.active) {
            // If an active offer was cancelled by navigation mid-drag, do not
            // re-arm `.host` until a fresh `.enter` or `onCancel`/`onExit`.
            if (self.active_epoch != 0 and self.active_epoch != self.epoch) return .reject;
            self.active = true;
            self.active_epoch = self.epoch;
        }
        const captured_epoch = self.active_epoch;
        const next_decision: Decision = if (cfg.on_offer) |cb|
            cb(cfg.ctx, .{ .phase = phase, .x = x, .y = y, .urls = urls })
        else if (urls.len > 0 or has_file_candidates)
            .host
        else
            .webview;

        // Guard against reentrant close or navigation during `on_offer`.
        if (self.closed or !self.active or captured_epoch != self.epoch) {
            return if (self.closed) .reject else self.decision;
        }
        self.decision = next_decision;
        return next_decision;
    }

    /// Captures the current drag token before an asynchronous payload read
    /// (e.g., GTK 3 `drag-data-received`). Returns null if host cannot consume.
    pub fn beginAsyncDrop(self: *const Session) ?u64 {
        if (self.closed or self.config == null or !self.active) return null;
        if (self.decision != .host or self.active_epoch != self.epoch) return null;
        return self.active_epoch;
    }

    /// Delivers a synchronous drop immediately (or completes a tokenized async
    /// drop when `expected_epoch` is supplied). Clears active state *before*
    /// invoking `on_drop` to guarantee single delivery even on reentrancy.
    pub fn deliverDrop(self: *Session, expected_epoch: ?u64, x: f64, y: f64, urls: []const []const u8) bool {
        const cfg = self.config orelse return false;
        if (self.closed or !self.active) return false;
        if (self.decision != .host or self.active_epoch != self.epoch) return false;
        if (expected_epoch) |e| if (e != self.epoch) return false;

        // Clear drag state before invoking callback to prevent duplicate delivery
        // if the callback pumps events, navigates, or closes the page.
        self.active = false;
        self.active_epoch = 0;
        self.decision = .webview;
        return cfg.on_drop(cfg.ctx, .{ .x = x, .y = y, .urls = urls });
    }

    /// Clears active state without firing `on_cancel` when the drop was handed
    /// off to the underlying webview.
    pub fn finishWebviewDrop(self: *Session) void {
        self.active = false;
        self.active_epoch = 0;
        self.decision = .webview;
    }

    /// Ends the drag because the pointer left without dropping or OS cancelled it.
    pub fn onExit(self: *Session) void {
        if (!self.active) return;
        const cfg = self.config;
        self.active = false;
        self.active_epoch = 0;
        self.decision = .webview;
        if (!self.closed) {
            if (cfg) |c| if (c.on_cancel) |cb| cb(c.ctx);
        }
    }

    /// Called when the page navigates to another document/URL: cancels any
    /// in-flight drag offer so the originating document never receives a stale drop.
    pub fn onNavigate(self: *Session) void {
        self.epoch += 1;
        if (!self.active) return;
        const cfg = self.config;
        self.active = false;
        self.decision = .webview;
        // Keep `active_epoch` stale (< epoch) until exit or next `.enter`.
        if (!self.closed) {
            if (cfg) |c| if (c.on_cancel) |cb| cb(c.ctx);
        }
    }

    /// Called when the page closes: invalidates all future callbacks and async completions.
    pub fn onClose(self: *Session) void {
        if (self.closed) return;
        self.epoch += 1;
        const was_active = self.active;
        const cfg = self.config;
        self.closed = true;
        self.active = false;
        self.decision = .reject;
        self.config = null;
        if (was_active) {
            if (cfg) |c| if (c.on_cancel) |cb| cb(c.ctx);
        }
    }
};

test "topLeft coordinate conversion handles flipped and bottom-left AppKit views" {
    const bl = toTopLeft(42.5, 80.0, 200.0, false);
    try testing.expectApproxEqAbs(42.5, bl.x, 1e-6);
    try testing.expectApproxEqAbs(120.0, bl.y, 1e-6);

    const tl = toTopLeft(42.5, 80.0, 200.0, true);
    try testing.expectApproxEqAbs(42.5, tl.x, 1e-6);
    try testing.expectApproxEqAbs(80.0, tl.y, 1e-6);
}

test "parseUriList keeps file:// URLs with Unicode and escaping and rejects other schemes" {
    const raw =
        \\# comment line
        \\
        \\https://example.com/evil
        \\file:///tmp/hello%20world.png
        \\FILE:///Users/ada/caf%C3%A9/dir/
        \\mailto:a@b.test
        \\file://
        \\
    ;
    const urls = try parseUriList(testing.allocator, raw);
    defer freeUrlSlice(testing.allocator, urls);
    try testing.expectEqual(@as(usize, 2), urls.len);
    try testing.expectEqualStrings("file:///tmp/hello%20world.png", urls[0]);
    try testing.expectEqualStrings("FILE:///Users/ada/caf%C3%A9/dir/", urls[1]);
}

test "Session enforces routing decisions, single delivery, navigation cancel, and late async completion rejection" {
    const Ctx = struct {
        drops: usize = 0,
        cancels: usize = 0,
        close_in_drop: bool = false,
        sess: *Session = undefined,

        fn offer(p: ?*anyopaque, ev: Offer) Decision {
            _ = p;
            if (ev.urls.len == 0) return .webview;
            return if (std.mem.endsWith(u8, ev.urls[0], ".reject")) .reject else .host;
        }
        fn drop(p: ?*anyopaque, _: Event) bool {
            const c: *@This() = @ptrCast(@alignCast(p));
            c.drops += 1;
            if (c.close_in_drop) c.sess.onClose();
            return true;
        }
        fn cancel(p: ?*anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(p));
            c.cancels += 1;
        }
    };

    var ctx: Ctx = .{};
    var sess = Session.init(.{ .ctx = &ctx, .on_offer = Ctx.offer, .on_drop = Ctx.drop, .on_cancel = Ctx.cancel });
    ctx.sess = &sess;

    // Host consumes offer -> single delivery only.
    try testing.expectEqual(Decision.host, sess.onOffer(.enter, 10, 20, &.{"file:///a.png"}, true));
    try testing.expect(sess.deliverDrop(null, 10, 20, &.{"file:///a.png"}));
    try testing.expect(!sess.deliverDrop(null, 10, 20, &.{"file:///a.png"}));
    try testing.expectEqual(@as(usize, 1), ctx.drops);

    // Navigation mid-drag cancels active offer & rejects late async token.
    try testing.expectEqual(Decision.host, sess.onOffer(.enter, 10, 20, &.{"file:///b.png"}, true));
    const tok = sess.beginAsyncDrop().?;
    sess.onNavigate();
    try testing.expectEqual(@as(usize, 1), ctx.cancels);
    try testing.expect(!sess.deliverDrop(tok, 10, 20, &.{"file:///b.png"}));
    try testing.expectEqual(Decision.reject, sess.onOffer(.update, 12, 22, &.{"file:///b.png"}, true));

    // Exit resets offer cleanly, then new enter works.
    sess.onExit();
    try testing.expectEqual(Decision.reject, sess.onOffer(.enter, 5, 5, &.{"file:///x.reject"}, true));
    sess.onExit();
    try testing.expectEqual(@as(usize, 2), ctx.cancels);

    // Reentrant close inside on_drop succeeds without double cancel or double delivery.
    ctx.close_in_drop = true;
    try testing.expectEqual(Decision.host, sess.onOffer(.enter, 1, 2, &.{"file:///c.png"}, true));
    try testing.expect(sess.deliverDrop(null, 1, 2, &.{"file:///c.png"}));
    try testing.expectEqual(@as(usize, 2), ctx.drops);
    try testing.expect(sess.closed);
    try testing.expect(!sess.deliverDrop(null, 1, 2, &.{"file:///c.png"}));
}
