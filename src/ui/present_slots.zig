//! The frames waiting for a drawable's presented handler. Core Animation
//! runs those handlers on its own thread, and can run them after the
//! renderer is gone: a window closed with frames still queued for the
//! display. So the slots live on the heap, shared by the renderer and the
//! handlers, and whichever of them is last frees them; once the renderer
//! has closed them a handler writes nothing (the log may be gone too).
const std = @import("std");
const FrameLog = @import("frame_log.zig").FrameLog;

pub const count = 16;

pub const Slot = struct {
    shared: *PresentSlots = undefined,
    log: ?*FrameLog = null,
    record_idx: usize = 0,
};

pub const PresentSlots = struct {
    gpa: std.mem.Allocator,
    slots: [count]Slot = @splat(.{}),
    next: usize = 0,
    /// The renderer, plus one per handler not yet run.
    refs: std.atomic.Value(usize) = .init(1),
    lock: std.atomic.Value(bool) = .init(false),
    /// Set by `close`: no handler may touch a log any more.
    closed: bool = false,

    pub fn create(gpa: std.mem.Allocator) !*PresentSlots {
        const self = try gpa.create(PresentSlots);
        self.* = .{ .gpa = gpa };
        return self;
    }

    /// Takes the next slot for a frame recorded at `record_idx` of `log`,
    /// held until its handler calls `presented`.
    pub fn take(self: *PresentSlots, log: *FrameLog, record_idx: usize) *Slot {
        _ = self.refs.fetchAdd(1, .monotonic);
        self.acquire();
        defer self.release();
        const slot = &self.slots[self.next];
        self.next = (self.next + 1) % count;
        slot.* = .{ .shared = self, .log = log, .record_idx = record_idx };
        return slot;
    }

    /// The handler of the frame in `slot`: `t` is when it reached the
    /// display (0 if it never did).
    pub fn presented(slot: *Slot, t: f64) void {
        const self = slot.shared;
        self.acquire();
        if (!self.closed) if (slot.log) |log| log.setPresented(slot.record_idx, t);
        self.release();
        self.unref();
    }

    /// The renderer is going: handlers still to run only drop their hold.
    pub fn close(self: *PresentSlots) void {
        self.acquire();
        self.closed = true;
        self.release();
        self.unref();
    }

    fn unref(self: *PresentSlots) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.gpa.destroy(self);
    }

    fn acquire(self: *PresentSlots) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(self: *PresentSlots) void {
        self.lock.store(false, .release);
    }
};

test "a presented handler after the renderer closed touches no log, and frees the slots" {
    const gpa = std.testing.allocator;
    var log = try FrameLog.init(gpa, null);
    defer log.deinit();
    const a = log.append(record(1));
    const b = log.append(record(2));

    const shared = try PresentSlots.create(gpa);
    const early = shared.take(&log, a);
    const late = shared.take(&log, b);
    PresentSlots.presented(early, 5);
    try std.testing.expectEqual(@as(f64, 5), log.records.items[a].presented_t);

    // The window closes with `late` still queued for the display: its
    // handler runs after, and must neither write nor leak (the testing
    // allocator fails a leak or a double free).
    shared.close();
    PresentSlots.presented(late, 6);
    try std.testing.expectEqual(@as(f64, 0), log.records.items[b].presented_t);
}

test "closing with no handler outstanding frees the slots" {
    const shared = try PresentSlots.create(std.testing.allocator);
    shared.close();
}

fn record(t: f64) @import("frame_log.zig").Record {
    return .{ .t = t, .kind = .input, .interval_ms = 0, .duration = 0, .dt = 0, .build_ms = 0, .layout_ms = 0, .paint_ms = 0, .after_frame_ms = 0, .drawable_wait_ms = 0, .encode_ms = 0, .sync = false, .nodes = 0, .instances = 0, .atlas_reset = false };
}
