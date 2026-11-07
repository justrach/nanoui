//! Compiles a parsed regular expression to the backtracking machine's program.
//! Lookbehind bodies compile "backward": terms in reverse order, reading leftward.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rp = @import("regexp_parse.zig");
const Node = rp.Node;
const Range = rp.Range;
const unicode = @import("regexp_unicode.zig");

pub const Class = struct {
    /// Sorted, merged. With ignore_case, already closed over simple case mappings.
    ranges: []Range,
    negate: bool,
    /// Membership for ASCII, after negation.
    ascii: [2]u64,
};

pub const Inst = union(enum) {
    char: u32,
    /// With ignore_case: two spellings of one letter.
    char2: struct { a: u32, b: u32 },
    any,
    /// `.` with the s flag.
    any_nl,
    class: u32,
    split: struct { first: u32, second: u32 },
    jmp: u32,
    save: u32,
    /// Clears captures [first, last) at the start of each loop iteration.
    reset_caps: struct { first: u32, last: u32 },
    line_start,
    line_end,
    word_boundary: bool,
    look: struct { behind: bool, negate: bool, end: u32 },
    look_end,
    backref: u32,
    /// Remembers the position so an iteration that matched nothing can be stopped.
    empty_mark: u32,
    empty_check: u32,
    counter_init: u32,
    /// Bumps a counter; jumps back to body while below max, and leaves once at least min.
    /// Counters are registers, so backtracking restores them.
    counter_loop: struct { reg: u32, min: u32, max: u32, body: u32, greedy: bool },
    /// A greedy or lazy loop over the one-width matcher in the next instruction.
    single_loop: struct { min: u32, max: u32, greedy: bool },
    match,
};

pub const Program = struct {
    insts: []Inst,
    classes: []Class,
    ncaps: u32,
    /// Registers follow the capture slots.
    nregs: u32,
    names: []rp.GroupName,
    flags: rp.Flags,
    /// When every match must start with this unit: a fast scan for the first position.
    first_unit: ?u16,
    arena: std.heap.ArenaAllocator,
    refs: u32 = 1,

    pub fn release(p: *Program, gpa: Allocator) void {
        p.refs -= 1;
        if (p.refs != 0) return;
        var a = p.arena;
        a.deinit();
        gpa.destroy(p);
    }
};

const max_insts = 1 << 20;

const C = struct {
    a: Allocator,
    insts: std.ArrayList(Inst) = .empty,
    classes: std.ArrayList(Class) = .empty,
    backward: bool = false,
    ignore_case: bool,
    dot_all: bool,
    unicode_mode: bool,
    nregs: u32,
    names: []const rp.GroupName,

    fn emit(c: *C, i: Inst) rp.ParseError!u32 {
        if (c.insts.items.len >= max_insts) return error.Invalid;
        try c.insts.append(c.a, i);
        return @intCast(c.insts.items.len - 1);
    }
    inline fn pc(c: *C) u32 {
        return @intCast(c.insts.items.len);
    }

    fn charInst(c: *C, cp: u32) Inst {
        if (c.ignore_case) {
            const lo = unicode.toLower(cp);
            const up = unicode.toUpper(cp);
            if (lo != up) return .{ .char2 = .{ .a = lo, .b = up } };
        }
        return .{ .char = cp };
    }

    fn emitChar(c: *C, cp: u32) rp.ParseError!void {
        if (cp >= 0x10000 and !c.unicode_mode) {
            // A pattern's astral character outside unicode mode is two code units.
            const v = cp - 0x10000;
            const hi = 0xD800 + (v >> 10);
            const lo = 0xDC00 + (v & 0x3FF);
            if (c.backward) {
                _ = try c.emit(.{ .char = lo });
                _ = try c.emit(.{ .char = hi });
            } else {
                _ = try c.emit(.{ .char = hi });
                _ = try c.emit(.{ .char = lo });
            }
            return;
        }
        _ = try c.emit(c.charInst(cp));
    }

    fn addClass(c: *C, set: *rp.ClassSet) rp.ParseError!u32 {
        var rs: std.ArrayList(Range) = .empty;
        try rs.appendSlice(c.a, set.ranges.items);
        if (c.ignore_case) {
            for (set.ranges.items) |r| {
                // Closing huge ranges costs too much and adds nothing beyond the mapped blocks.
                const hi = @min(r.hi, 0x24F);
                var x = r.lo;
                while (x <= hi) : (x += 1) {
                    const lo = unicode.toLower(x);
                    const up = unicode.toUpper(x);
                    if (lo != x) try rs.append(c.a, .{ .lo = lo, .hi = lo });
                    if (up != x) try rs.append(c.a, .{ .lo = up, .hi = up });
                }
                if (r.lo <= 0x52F and r.hi >= 0x370) {
                    x = @max(r.lo, 0x370);
                    while (x <= @min(r.hi, 0x52F)) : (x += 1) {
                        const lo = unicode.toLower(x);
                        const up = unicode.toUpper(x);
                        if (lo != x) try rs.append(c.a, .{ .lo = lo, .hi = lo });
                        if (up != x) try rs.append(c.a, .{ .lo = up, .hi = up });
                    }
                }
            }
        }
        const merged = try unicode.normalized(c.a, rs.items);
        var ascii = [2]u64{ 0, 0 };
        for (merged.items) |r| {
            var x = r.lo;
            while (x <= r.hi and x < 128) : (x += 1) {
                ascii[x >> 6] |= @as(u64, 1) << @intCast(x & 63);
            }
        }
        if (set.negate) {
            ascii[0] = ~ascii[0];
            ascii[1] = ~ascii[1];
        }
        const i: u32 = @intCast(c.classes.items.len);
        try c.classes.append(c.a, .{ .ranges = merged.items, .negate = set.negate, .ascii = ascii });
        return i;
    }

    fn isSingle(c: *C, n: *const Node) bool {
        if (c.backward or c.unicode_mode) return false;
        return switch (n.*) {
            .char => |cp| cp < 0x10000,
            .any, .class => true,
            else => false,
        };
    }

    fn gen(c: *C, n: *const Node) rp.ParseError!void {
        switch (n.*) {
            .empty => {},
            .char => |cp| try c.emitChar(cp),
            .any => _ = try c.emit(if (c.dot_all) .any_nl else .any),
            .class => |set| {
                const i = try c.addClass(set);
                _ = try c.emit(.{ .class = i });
            },
            .seq => |list| {
                if (c.backward) {
                    var i = list.len;
                    while (i > 0) {
                        i -= 1;
                        try c.gen(list[i]);
                    }
                } else {
                    for (list) |x| try c.gen(x);
                }
            },
            .alt => |list| {
                var ends: std.ArrayList(u32) = .empty;
                for (list, 0..) |x, i| {
                    if (i + 1 < list.len) {
                        const sp = try c.emit(.{ .split = .{ .first = 0, .second = 0 } });
                        c.insts.items[sp].split.first = c.pc();
                        try c.gen(x);
                        try ends.append(c.a, try c.emit(.{ .jmp = 0 }));
                        c.insts.items[sp].split.second = c.pc();
                    } else {
                        try c.gen(x);
                    }
                }
                for (ends.items) |e| c.insts.items[e].jmp = c.pc();
            },
            .group => |g| {
                _ = try c.emit(.{ .save = g.index * 2 + @intFromBool(c.backward) });
                try c.gen(g.body);
                _ = try c.emit(.{ .save = g.index * 2 + @intFromBool(!c.backward) });
            },
            .backref => |i| _ = try c.emit(.{ .backref = i }),
            .named_backref => |name| {
                for (c.names) |g| {
                    if (std.mem.eql(u8, g.name, name)) {
                        _ = try c.emit(.{ .backref = g.index });
                        return;
                    }
                }
                return error.Invalid;
            },
            .line_start => _ = try c.emit(.line_start),
            .line_end => _ = try c.emit(.line_end),
            .word_boundary => |neg| _ = try c.emit(.{ .word_boundary = neg }),
            .look => |l| {
                const at = try c.emit(.{ .look = .{ .behind = l.behind, .negate = l.negate, .end = 0 } });
                const saved = c.backward;
                c.backward = l.behind;
                try c.gen(l.body);
                c.backward = saved;
                _ = try c.emit(.look_end);
                c.insts.items[at].look.end = c.pc();
            },
            .repeat => |r| try c.genRepeat(r.body, r.min, r.max, r.greedy, r.first_cap, r.last_cap),
        }
    }

    fn genRepeat(c: *C, body: *Node, min: u32, max: u32, greedy: bool, first_cap: u32, last_cap: u32) rp.ParseError!void {
        if (max == 0) return;
        if (c.isSingle(body)) {
            _ = try c.emit(.{ .single_loop = .{ .min = min, .max = max, .greedy = greedy } });
            try c.gen(body);
            return;
        }
        const has_caps = last_cap > first_cap;
        const reg = c.nregs;
        if (min == 0 and max == 1) {
            const sp = try c.emit(.{ .split = .{ .first = 0, .second = 0 } });
            const start = c.pc();
            if (has_caps) _ = try c.emit(.{ .reset_caps = .{ .first = first_cap, .last = last_cap } });
            try c.gen(body);
            const end = c.pc();
            c.insts.items[sp].split = if (greedy) .{ .first = start, .second = end } else .{ .first = end, .second = start };
            return;
        }
        if ((min == 0 or min == 1) and max == rp.max_repeat) {
            // x* and x+, the common shapes, without a counter.
            c.nregs += 1;
            if (min == 1) {
                if (has_caps) _ = try c.emit(.{ .reset_caps = .{ .first = first_cap, .last = last_cap } });
                try c.gen(body);
            }
            const sp = try c.emit(.{ .split = .{ .first = 0, .second = 0 } });
            const start = c.pc();
            if (has_caps) _ = try c.emit(.{ .reset_caps = .{ .first = first_cap, .last = last_cap } });
            _ = try c.emit(.{ .empty_mark = reg });
            try c.gen(body);
            _ = try c.emit(.{ .empty_check = reg });
            _ = try c.emit(.{ .jmp = sp });
            const end = c.pc();
            c.insts.items[sp].split = if (greedy) .{ .first = start, .second = end } else .{ .first = end, .second = start };
            return;
        }
        // The general {m,n}: a counter register drives the loop.
        const creg = c.nregs;
        const mark = c.nregs + 1;
        c.nregs += 2;
        _ = try c.emit(.{ .counter_init = creg });
        var skip: ?u32 = null;
        if (min == 0) skip = try c.emit(.{ .split = .{ .first = 0, .second = 0 } });
        const body_pc = c.pc();
        if (has_caps) _ = try c.emit(.{ .reset_caps = .{ .first = first_cap, .last = last_cap } });
        _ = try c.emit(.{ .empty_mark = mark });
        try c.gen(body);
        if (min == 0 or max == rp.max_repeat) _ = try c.emit(.{ .empty_check = mark });
        _ = try c.emit(.{ .counter_loop = .{ .reg = creg, .min = min, .max = max, .body = body_pc, .greedy = greedy } });
        if (skip) |sp| {
            const end = c.pc();
            c.insts.items[sp].split = if (greedy) .{ .first = body_pc, .second = end } else .{ .first = end, .second = body_pc };
        }
    }
};

fn firstUnit(insts: []const Inst, flags: rp.Flags) ?u16 {
    if (flags.ignore_case) return null;
    var i: usize = 0;
    while (i < insts.len) : (i += 1) {
        switch (insts[i]) {
            .save => continue,
            .char => |cp| return if (cp < 0x10000 and !(cp >= 0xD800 and cp < 0xE000)) @intCast(cp) else null,
            else => return null,
        }
    }
    return null;
}

pub const CompileResult = union(enum) { program: *Program, err: []const u8 };

/// Parses and compiles. The error message, if any, is a static string.
pub fn compile(gpa: Allocator, pattern: []const u32, flags: rp.Flags) Allocator.Error!CompileResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const umode = flags.unicode or flags.unicode_sets;
    var p = rp.Parser{ .a = a, .src = pattern, .flags = flags, .unicode_mode = umode };
    const root = p.parse() catch |e| switch (e) {
        error.Invalid => {
            arena.deinit();
            return .{ .err = p.message };
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    var c = C{
        .a = a,
        .ignore_case = flags.ignore_case,
        .dot_all = flags.dot_all,
        .unicode_mode = umode,
        .nregs = 0,
        .names = p.names.items,
    };
    const ncaps = p.next_group;
    (blk: {
        _ = c.emit(.{ .save = 0 }) catch |e| break :blk e;
        c.gen(root) catch |e| break :blk e;
        _ = c.emit(.{ .save = 1 }) catch |e| break :blk e;
        _ = c.emit(.match) catch |e| break :blk e;
        break :blk @as(rp.ParseError!void, {});
    }) catch |e| switch (e) {
        error.Invalid => {
            arena.deinit();
            return .{ .err = "Invalid regular expression: too large" };
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const prog = try gpa.create(Program);
    prog.* = .{
        .insts = c.insts.items,
        .classes = c.classes.items,
        .ncaps = ncaps,
        .nregs = c.nregs,
        .names = p.names.items,
        .flags = flags,
        .first_unit = firstUnit(c.insts.items, flags),
        .arena = arena,
    };
    return .{ .program = prog };
}
