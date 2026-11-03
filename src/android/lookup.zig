//! Host names on Android. Zig 0.17.0's std asks DNS servers itself on
//! Linux without glibc, from /etc/resolv.conf, which Android doesn't
//! have: its resolver (private DNS, a VPN's servers, each network's) is
//! bionic's getaddrinfo. `io` is an Io.Threaded that looks names up there;
//! the rest is Threaded's own. (getaddrinfo can't be canceled: a lookup
//! runs to its end.)
const std = @import("std");
const Io = std.Io;
const HostName = Io.net.HostName;

/// Threaded's functions, but for looking names up.
const vtable: Io.VTable = blk: {
    var t: Io.Threaded = .init_single_threaded;
    var v = t.io().vtable.*;
    v.netLookup = lookup;
    break :blk v;
};

/// `t`'s Io, looking host names up with the system.
pub fn io(t: *Io.Threaded) Io {
    return .{ .userdata = t, .vtable = &vtable };
}

fn lookup(userdata: ?*anyopaque, host_name: HostName, resolved: *Io.Queue(HostName.LookupResult), options: HostName.LookupOptions) HostName.LookupError!void {
    const t: *Io.Threaded = @ptrCast(@alignCast(userdata));
    const t_io = t.io();
    defer resolved.close(t_io);
    lookupAll(t_io, host_name.bytes, resolved, options) catch |err| switch (err) {
        // `resolved` is open until this returns.
        error.Closed => unreachable,
        else => |e| return e,
    };
}

fn lookupAll(t_io: Io, name: []const u8, resolved: *Io.Queue(HostName.LookupResult), options: HostName.LookupOptions) (HostName.LookupError || Io.QueueClosedError)!void {
    var name_buf: [HostName.max_len:0]u8 = undefined;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    var port_buf: [8]u8 = undefined;
    const port = std.fmt.bufPrintSentinel(&port_buf, "{d}", .{options.port}, 0) catch unreachable;
    const hints: std.c.addrinfo = .{
        .flags = .{ .CANONNAME = options.canonical_name_buffer != null, .NUMERICSERV = true },
        .family = if (options.family) |f| switch (f) {
            .ip4 => std.c.AF.INET,
            .ip6 => std.c.AF.INET6,
        } else std.c.AF.UNSPEC,
        .socktype = std.c.SOCK.STREAM,
        .protocol = std.c.IPPROTO.TCP,
        .addrlen = 0,
        .canonname = null,
        .addr = null,
        .next = null,
    };
    var res: ?*std.c.addrinfo = null;
    const rc = std.c.getaddrinfo(name_buf[0..name.len :0], port, &hints, &res);
    switch (@backingInt(rc)) {
        0 => {},
        @backingInt(std.c.EAI.NONAME), @backingInt(std.c.EAI.NODATA) => return error.UnknownHostName,
        @backingInt(std.c.EAI.AGAIN), @backingInt(std.c.EAI.FAIL) => return error.NameServerFailure,
        @backingInt(std.c.EAI.FAMILY) => return error.AddressFamilyUnsupported,
        @backingInt(std.c.EAI.MEMORY) => return error.SystemResources,
        else => return error.Unexpected,
    }
    defer if (res) |r| std.c.freeaddrinfo(r);
    var canon: ?[]const u8 = null;
    var it = res;
    while (it) |info| : (it = info.next) {
        if (info.canonname) |c| if (canon == null) {
            canon = std.mem.sliceTo(c, 0);
        };
        const addr = info.addr orelse continue;
        try resolved.putOne(t_io, .{ .address = switch (addr.family) {
            std.c.AF.INET => blk: {
                const in: *const std.c.sockaddr.in = @ptrCast(@alignCast(addr));
                break :blk .{ .ip4 = .{ .bytes = @bitCast(in.addr), .port = options.port } };
            },
            std.c.AF.INET6 => blk: {
                const in6: *const std.c.sockaddr.in6 = @ptrCast(@alignCast(addr));
                break :blk .{ .ip6 = .{ .bytes = in6.addr, .port = options.port, .flow = in6.flowinfo, .interface = .{ .index = in6.scope_id } } };
            },
            else => continue,
        } });
    }
    if (options.canonical_name_buffer) |buf| {
        const n = canon orelse name;
        @memcpy(buf[0..n.len], n);
        try resolved.putOne(t_io, .{ .canonical_name = .{ .bytes = buf[0..n.len] } });
    }
}
