//! The backtracking matcher. It has no native recursion except one level per nested
//! lookaround, keeps its stack on the heap, undoes captures from a log as it backtracks,
//! and counts steps so a pathological pattern fails rather than hangs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rc = @import("regexp_compile.zig");
const Program = rc.Program;
const Inst = rc.Inst;
const unicode = @import("regexp_unicode.zig");

pub const Failure = error{ OutOfMemory, TooComplex, Interrupted };

/// Called every so often; false stops the match (the deadline passed).
pub const Tick = struct {
    ctx: ?*anyopaque = null,
    f: ?*const fn (?*anyopaque) bool = null,
};

/// Debug builds step far slower, so the limit that means "this won't finish" is lower.
const step_limit: u64 = if (@import("builtin").mode == .debug) 20_000_000 else 1_000_000_000;
const stack_limit: usize = 32 * 1024 * 1024;

const Entry = union(enum) {
    /// Resume at pc, pos.
    branch: struct { pc: u32, pos: u32 },
    /// Undo a register write.
    reg: struct { i: u32, old: i32 },
    /// A single_loop's remaining choices: positions in [low, cur) are still to try.
    range: struct { pc: u32, low: u32, cur: u32 },
    /// A lazy single_loop can still consume one more.
    lazy: struct { pc: u32, pos: u32, count: u32, max: u32 },
};

fn isWordUnit(c: u32) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn isLineTerm(c: u32) bool {
    return c == '\n' or c == '\r' or c == 0x2028 or c == 0x2029;
}

pub fn classHas(cl: *const rc.Class, cp: u32) bool {
    if (cp < 128) return (cl.ascii[cp >> 6] >> @intCast(cp & 63)) & 1 != 0;
    var lo: usize = 0;
    var hi: usize = cl.ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const r = cl.ranges[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else return !cl.negate;
    }
    return cl.negate;
}

pub fn Matcher(comptime Unit: type) type {
    return struct {
        const Self = @This();
        prog: *const Program,
        text: []const Unit,
        regs: []i32,
        stack: std.ArrayList(Entry) = .empty,
        gpa: Allocator,
        steps: u64 = 0,
        unicode_mode: bool,
        tick: Tick,

        inline fn setReg(m: *Self, i: u32, v: i32) Failure!void {
            try m.push(.{ .reg = .{ .i = i, .old = m.regs[i] } });
            m.regs[i] = v;
        }

        inline fn push(m: *Self, e: Entry) Failure!void {
            if (m.stack.items.len >= stack_limit) return error.TooComplex;
            m.stack.append(m.gpa, e) catch return error.OutOfMemory;
        }

        /// The code point (or unit) at pos reading forward; advance is its width.
        inline fn read(m: *const Self, pos: usize) struct { cp: u32, width: u32 } {
            const c: u32 = m.text[pos];
            if (Unit == u16 and m.unicode_mode and c >= 0xD800 and c < 0xDC00 and pos + 1 < m.text.len) {
                const d: u32 = m.text[pos + 1];
                if (d >= 0xDC00 and d < 0xE000) return .{ .cp = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00), .width = 2 };
            }
            return .{ .cp = c, .width = 1 };
        }

        inline fn readBack(m: *const Self, pos: usize) struct { cp: u32, width: u32 } {
            const c: u32 = m.text[pos - 1];
            if (Unit == u16 and m.unicode_mode and c >= 0xDC00 and c < 0xE000 and pos >= 2) {
                const d: u32 = m.text[pos - 2];
                if (d >= 0xD800 and d < 0xDC00) return .{ .cp = 0x10000 + ((d - 0xD800) << 10) + (c - 0xDC00), .width = 2 };
            }
            return .{ .cp = c, .width = 1 };
        }

        /// Whether a one-width instruction accepts this character.
        inline fn single(m: *const Self, inst: Inst, cp: u32) bool {
            return switch (inst) {
                .char => |c| c == cp,
                .char2 => |c| c.a == cp or c.b == cp,
                .any => !isLineTerm(cp),
                .any_nl => true,
                .class => |i| classHas(&m.prog.classes[i], cp),
                else => unreachable,
            };
        }

        fn wordAt(m: *const Self, pos: isize) bool {
            if (pos < 0 or pos >= m.text.len) return false;
            const c: u32 = m.text[@intCast(pos)];
            if (isWordUnit(c)) return true;
            // With both i and u, U+017F and U+212A count as word characters.
            return m.prog.flags.ignore_case and m.unicode_mode and (c == 0x17F or c == 0x212A);
        }

        fn sameChar(m: *const Self, a: u32, b: u32) bool {
            if (a == b) return true;
            if (!m.prog.flags.ignore_case) return false;
            return unicode.toLower(a) == unicode.toLower(b) or unicode.toUpper(a) == unicode.toUpper(b);
        }

        /// Runs from pc at pos. True on match or look_end; `end_pos` holds where it ended.
        fn run(m: *Self, start_pc: u32, start_pos: u32, backward: bool, end_pos: *u32) Failure!bool {
            const insts = m.prog.insts;
            const base = m.stack.items.len;
            var pc = start_pc;
            var pos: u32 = start_pos;
            const len: u32 = @intCast(m.text.len);
            while (true) {
                m.steps += 1;
                if (m.steps & 0xFFFF == 0) {
                    if (m.steps > step_limit) return error.TooComplex;
                    if (m.tick.f) |f| {
                        if (!f(m.tick.ctx)) return error.Interrupted;
                    }
                }
                ok: {
                    switch (insts[pc]) {
                        .char, .char2, .any, .any_nl, .class => {
                            const inst = insts[pc];
                            if (backward) {
                                if (pos == 0) break :ok;
                                const r = m.readBack(pos);
                                if (!m.single(inst, r.cp)) break :ok;
                                pos -= r.width;
                            } else {
                                if (pos >= len) break :ok;
                                const r = m.read(pos);
                                if (!m.single(inst, r.cp)) break :ok;
                                pos += r.width;
                            }
                            pc += 1;
                            continue;
                        },
                        .split => |s| {
                            try m.push(.{ .branch = .{ .pc = s.second, .pos = pos } });
                            pc = s.first;
                            continue;
                        },
                        .jmp => |t| {
                            pc = t;
                            continue;
                        },
                        .save => |i| {
                            try m.setReg(i, @intCast(pos));
                            pc += 1;
                            continue;
                        },
                        .reset_caps => |r| {
                            var i = r.first * 2;
                            while (i < r.last * 2) : (i += 1) {
                                if (m.regs[i] != -1) try m.setReg(i, -1);
                            }
                            pc += 1;
                            continue;
                        },
                        .line_start => {
                            if (pos == 0 or (m.prog.flags.multiline and isLineTerm(m.text[pos - 1]))) {
                                pc += 1;
                                continue;
                            }
                        },
                        .line_end => {
                            if (pos == len or (m.prog.flags.multiline and isLineTerm(m.text[pos]))) {
                                pc += 1;
                                continue;
                            }
                        },
                        .word_boundary => |neg| {
                            const a = m.wordAt(@as(isize, pos) - 1);
                            const b = m.wordAt(pos);
                            if ((a != b) != neg) {
                                pc += 1;
                                continue;
                            }
                        },
                        .look => |l| {
                            const mark = m.stack.items.len;
                            var p2: u32 = 0;
                            const hit = try m.run(pc + 1, pos, l.behind, &p2);
                            if (hit != l.negate) {
                                if (l.negate) {
                                    try m.undoTo(mark);
                                } else {
                                    // Success keeps its captures but gives up its choices.
                                    m.dropBranches(mark);
                                }
                                pc = l.end;
                                continue;
                            }
                            try m.undoTo(mark);
                        },
                        .look_end => {
                            end_pos.* = pos;
                            return true;
                        },
                        .backref => |n| {
                            const s = m.regs[n * 2];
                            const e = m.regs[n * 2 + 1];
                            if (s < 0 or e < 0) {
                                pc += 1;
                                continue;
                            }
                            const a: u32 = @intCast(s);
                            const b: u32 = @intCast(e);
                            const w = b - a;
                            if (backward) {
                                if (pos < w) break :ok;
                                var k: u32 = 0;
                                while (k < w) : (k += 1) {
                                    if (!m.sameChar(m.text[a + k], m.text[pos - w + k])) break :ok;
                                }
                                pos -= w;
                            } else {
                                if (pos + w > len) break :ok;
                                var k: u32 = 0;
                                while (k < w) : (k += 1) {
                                    if (!m.sameChar(m.text[a + k], m.text[pos + k])) break :ok;
                                }
                                pos += w;
                            }
                            pc += 1;
                            continue;
                        },
                        .empty_mark => |r| {
                            try m.setReg(m.prog.ncaps * 2 + r, @intCast(pos));
                            pc += 1;
                            continue;
                        },
                        .empty_check => |r| {
                            // An iteration that consumed nothing must not repeat.
                            if (m.regs[m.prog.ncaps * 2 + r] != @as(i32, @intCast(pos))) {
                                pc += 1;
                                continue;
                            }
                        },
                        .counter_init => |r| {
                            try m.setReg(m.prog.ncaps * 2 + r, 0);
                            pc += 1;
                            continue;
                        },
                        .counter_loop => |c| {
                            const i = m.prog.ncaps * 2 + c.reg;
                            const n: u32 = @intCast(m.regs[i] + 1);
                            try m.setReg(i, @intCast(n));
                            if (n < c.min) {
                                pc = c.body;
                            } else if (n >= c.max) {
                                pc += 1;
                            } else if (c.greedy) {
                                try m.push(.{ .branch = .{ .pc = pc + 1, .pos = pos } });
                                pc = c.body;
                            } else {
                                try m.push(.{ .branch = .{ .pc = c.body, .pos = pos } });
                                pc += 1;
                            }
                            continue;
                        },
                        .single_loop => |l| {
                            const inst = insts[pc + 1];
                            var count: u32 = 0;
                            if (l.greedy) {
                                while (count < l.max and pos < len and m.single(inst, m.text[pos])) {
                                    pos += 1;
                                    count += 1;
                                }
                                m.steps += count;
                                if (count < l.min) break :ok;
                                if (count > l.min) {
                                    try m.push(.{ .range = .{ .pc = pc + 2, .low = pos - (count - l.min), .cur = pos } });
                                }
                            } else {
                                while (count < l.min) : (count += 1) {
                                    if (pos >= len or !m.single(inst, m.text[pos])) break :ok;
                                    pos += 1;
                                }
                                if (count < l.max) {
                                    try m.push(.{ .lazy = .{ .pc = pc, .pos = pos, .count = count, .max = l.max } });
                                }
                            }
                            pc += 2;
                            continue;
                        },
                        .match => {
                            end_pos.* = pos;
                            return true;
                        },
                    }
                }
                // Failed: back up to the most recent choice since this run began.
                while (true) {
                    if (m.stack.items.len == base) return false;
                    const top = &m.stack.items[m.stack.items.len - 1];
                    switch (top.*) {
                        .reg => |r| {
                            m.regs[r.i] = r.old;
                            m.stack.items.len -= 1;
                        },
                        .branch => |b| {
                            pc = b.pc;
                            pos = b.pos;
                            m.stack.items.len -= 1;
                            break;
                        },
                        .range => |*r| {
                            r.cur -= 1;
                            pc = r.pc;
                            pos = r.cur;
                            if (r.cur == r.low) m.stack.items.len -= 1;
                            break;
                        },
                        .lazy => |l| {
                            m.stack.items.len -= 1;
                            const inst = insts[l.pc + 1];
                            if (l.pos < len and m.single(inst, m.text[l.pos])) {
                                const next_count = l.count + 1;
                                if (next_count < l.max) {
                                    try m.push(.{ .lazy = .{ .pc = l.pc, .pos = l.pos + 1, .count = next_count, .max = l.max } });
                                }
                                pc = l.pc + 2;
                                pos = l.pos + 1;
                                break;
                            }
                        },
                    }
                }
            }
        }

        fn undoTo(m: *Self, mark: usize) Failure!void {
            while (m.stack.items.len > mark) {
                const e = m.stack.pop().?;
                if (e == .reg) m.regs[e.reg.i] = e.reg.old;
            }
        }

        /// Removes choice points above mark, keeping the undo log.
        fn dropBranches(m: *Self, mark: usize) void {
            var w = mark;
            for (m.stack.items[mark..]) |e| {
                if (e == .reg) {
                    m.stack.items[w] = e;
                    w += 1;
                }
            }
            m.stack.items.len = w;
        }
    };
}

/// Finds a match at or after `start` (exactly at it when sticky). regs receives capture
/// pairs and is reset for each attempt. Returns whether it matched.
pub fn exec(comptime Unit: type, gpa: Allocator, prog: *const Program, text: []const Unit, start: usize, sticky: bool, regs: []i32, tick: Tick) Failure!bool {
    var m = Matcher(Unit){
        .prog = prog,
        .text = text,
        .regs = regs,
        .gpa = gpa,
        .unicode_mode = prog.flags.unicode or prog.flags.unicode_sets,
        .tick = tick,
    };
    defer m.stack.deinit(gpa);
    var pos = start;
    while (pos <= text.len) {
        if (!sticky) {
            if (prog.first_unit) |u| {
                if (Unit == u8) {
                    if (u >= 0x80) return false;
                    const rel = std.mem.indexOfScalar(u8, text[pos..], @intCast(u)) orelse return false;
                    pos += rel;
                } else {
                    const rel = std.mem.indexOfScalar(Unit, text[pos..], @intCast(u)) orelse return false;
                    pos += rel;
                }
            }
        }
        @memset(regs, -1);
        m.stack.clearRetainingCapacity();
        var end: u32 = 0;
        if (try m.run(0, @intCast(pos), false, &end)) return true;
        if (sticky) return false;
        pos += 1;
        // Unicode mode doesn't start a match inside a surrogate pair.
        if (Unit == u16 and m.unicode_mode and pos < text.len and text[pos] >= 0xDC00 and text[pos] < 0xE000 and text[pos - 1] >= 0xD800 and text[pos - 1] < 0xDC00) pos += 1;
    }
    return false;
}
