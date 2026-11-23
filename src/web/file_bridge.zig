//! Register file controls with the semantic DOM and receive bounded bytes.
const std = @import("std");
const web = @import("web.zig");
const ui = @import("../ui/ui.zig");
const picker = @import("../file_picker.zig");

extern "nanoui_web" fn cancel_file(token: u32) void;
extern "nanoui_web" fn semantics_enabled() bool;

pub const Descriptor = struct {
    accept: []const u8,
    max_bytes: usize,
};

const Binding = struct {
    descriptor: Descriptor,
    context: ?*anyopaque,
    callback: picker.Callback,
    published: bool = false,
};

const Pending = struct {
    id: u64,
    context: ?*anyopaque,
    callback: picker.Callback,
    max_bytes: usize,
    token: u32,
    name_len: usize = 0,
    buffer: ?[]u8 = null,
};

pub const State = struct {
    buttons: std.AutoHashMapUnmanaged(u64, Binding) = .empty,
    pending: ?Pending = null,
    serial: u32 = 0,

    pub fn descriptor(state: *State, id: u64) ?Descriptor {
        const button = state.buttons.getPtr(id) orelse return null;
        button.published = true;
        return button.descriptor;
    }

    pub fn discardStale(state: *State, allocator: std.mem.Allocator) void {
        const pending = state.pending orelse return;
        if (state.buttons.get(pending.id)) |button| {
            if (button.published and button.context == pending.context and button.callback == pending.callback) return;
        }
        cancel_file(pending.token);
        state.clear(allocator);
    }

    fn clear(state: *State, allocator: std.mem.Allocator) void {
        if (state.pending) |request| if (request.buffer) |bytes| allocator.free(bytes);
        state.pending = null;
    }

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        state.clear(allocator);
        state.buttons.deinit(allocator);
    }
};

/// Call during each build of an enabled, labeled button. Keep ctx valid
/// until the callback runs or the button is removed and its next frame ends.
/// File slices are borrowed until the callback returns.
pub fn bind(c: *ui.Context, node: u32, options: picker.Options, ctx: ?*anyopaque, callback: picker.Callback) !void {
    const s = web.active orelse return error.NotMounted;
    if (&s.ctx != c or !c.building) return error.NotBuilding;
    if (node >= c.nodes.items.len) return error.InvalidNode;
    if (!semantics_enabled()) return error.Unsupported;
    try picker.validate(options);
    if (options.max_bytes > 64 * 1024 * 1024) return error.FileLimitTooLarge;
    const a = c.alloc();
    var filter: std.ArrayList(u8) = .empty;
    for (options.extensions) |extension| {
        if (filter.items.len != 0) try filter.append(a, ',');
        try filter.append(a, '.');
        try filter.appendSlice(a, extension);
    }
    try s.files.buttons.put(s.gpa, c.node(node).id, .{
        .descriptor = .{ .accept = filter.items, .max_bytes = options.max_bytes },
        .context = ctx,
        .callback = callback,
    });
}

export fn nanoui_web_file_begin(id: u64) u32 {
    const s = web.active orelse return 0;
    const state = &s.files;
    const button = state.buttons.get(id) orelse return 0;
    if (!button.published or state.pending != null) return 0;
    state.serial +%= 1;
    if (state.serial == 0) state.serial = 1;
    state.pending = .{
        .id = id,
        .context = button.context,
        .callback = button.callback,
        .max_bytes = button.descriptor.max_bytes,
        .token = state.serial,
    };
    return state.serial;
}

export fn nanoui_web_file_reserve(token: u32, name_len: usize, data_len: usize) usize {
    const s = web.active orelse return 0;
    const request = if (s.files.pending) |*pending| pending else return 0;
    if (request.token != token or request.buffer != null or name_len == 0 or name_len > 4096 or
        data_len > request.max_bytes) return 0;
    const buffer = s.gpa.alloc(u8, name_len + data_len) catch return 0;
    request.buffer = buffer;
    request.name_len = name_len;
    return @intFromPtr(buffer.ptr);
}

export fn nanoui_web_file_finish(token: u32, status: u32) void {
    const s = web.active orelse return;
    const request = s.files.pending orelse return;
    if (request.token != token) return;
    s.files.pending = null;
    const allocator = s.gpa;
    const buffer = request.buffer;
    defer if (buffer) |bytes| allocator.free(bytes);
    const result: picker.Result = switch (status) {
        0 => .cancelled,
        1 => blk: {
            const bytes = buffer orelse break :blk .{ .failed = .io };
            const name = bytes[0..request.name_len];
            if (!std.unicode.utf8ValidateSlice(name)) break :blk .{ .failed = .io };
            break :blk .{ .picked = .{ .name = name, .bytes = bytes[request.name_len..] } };
        },
        else => .{ .failed = std.enums.fromInt(picker.Failure, status) orelse .io },
    };
    request.callback(request.context, result);
    if (web.active == s) s.requestFrame();
}
