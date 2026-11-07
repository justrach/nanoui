//! Helpers for the table-driven tests: evaluate JS, compare the result as a string.

const std = @import("std");
const js = @import("js.zig");

pub const Case = struct { src: []const u8, want: []const u8 };

/// Evaluates each src in a fresh VM and compares ToString of the result.
pub fn expectAll(cases: []const Case) !void {
    // Hundreds of fresh VMs: the fast allocator here, leak checks are in tests_gc.zig.
    const gpa = std.heap.smp_allocator;
    var failed: usize = 0;
    for (cases) |c| {
        const vm = try js.Vm.create(gpa);
        defer vm.deinit();
        expectOne(vm, c) catch {
            failed += 1;
        };
    }
    if (failed != 0) {
        std.debug.print("{d} of {d} cases failed\n", .{ failed, cases.len });
        return error.TestFailed;
    }
}

pub fn expectOne(vm: *js.Vm, c: Case) !void {
    const v = vm.eval(c.src, "test.js") catch |e| {
        if (e == error.Thrown) {
            std.debug.print("\nFAILED: {s}\n  threw: {s}\n", .{ c.src, vm.exceptionString() });
        } else {
            std.debug.print("\nFAILED: {s}\n  error: {s}\n", .{ c.src, @errorName(e) });
        }
        return error.TestFailed;
    };
    vm.runJobs();
    const s = vm.toStringSlice(v) catch |e| {
        std.debug.print("\nFAILED: {s}\n  toString: {s}\n", .{ c.src, @errorName(e) });
        return error.TestFailed;
    };
    if (!std.mem.eql(u8, s, c.want)) {
        std.debug.print("\nFAILED: {s}\n  want: {s}\n  got:  {s}\n", .{ c.src, c.want, s });
        return error.TestFailed;
    }
}

/// Like expectAll for async code: runs the script, drains microtasks, then evaluates
/// the global `out` and compares that.
pub fn expectOut(cases: []const Case) !void {
    const gpa = std.heap.smp_allocator;
    var failed: usize = 0;
    for (cases) |c| {
        const vm = try js.Vm.create(gpa);
        defer vm.deinit();
        runOut(vm, c) catch {
            failed += 1;
        };
    }
    if (failed != 0) {
        std.debug.print("{d} of {d} cases failed\n", .{ failed, cases.len });
        return error.TestFailed;
    }
}

fn runOut(vm: *js.Vm, c: Case) !void {
    _ = vm.eval(c.src, "test.js") catch |e| {
        std.debug.print("\nFAILED: {s}\n  threw: {s}\n", .{ c.src, if (e == error.Thrown) vm.exceptionString() else @errorName(e) });
        return error.TestFailed;
    };
    vm.runJobs();
    try expectOne(vm, .{ .src = "String(out)", .want = c.want });
}
