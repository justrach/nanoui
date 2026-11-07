//! Date string parsing: ISO 8601 as specified, then a forgiving parser for the RFC 2822
//! and toString shapes ("Tue, 15 Nov 1994 08:12:31 GMT", "Nov 15 1994 08:12 PM", "11/15/1994").

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const date = @import("b_date.zig");

const nan = std.math.nan(f64);

const Cursor = struct {
    s: []const u8,
    i: usize = 0,

    fn digits(c: *Cursor, n: usize) ?f64 {
        if (c.i + n > c.s.len) return null;
        var v: f64 = 0;
        for (c.s[c.i..][0..n]) |d| {
            if (d < '0' or d > '9') return null;
            v = v * 10 + @as(f64, @floatFromInt(d - '0'));
        }
        c.i += n;
        return v;
    }
    fn eat(c: *Cursor, ch: u8) bool {
        if (c.i < c.s.len and c.s[c.i] == ch) {
            c.i += 1;
            return true;
        }
        return false;
    }
};

fn parseIso(vm: *Vm, s: []const u8) ?f64 {
    var c = Cursor{ .s = s };
    var year: f64 = undefined;
    if (c.eat('+') or (c.i < s.len and s[c.i] == '-')) {
        const neg = c.i < s.len and s[c.i] == '-';
        if (neg) c.i += 1;
        const y = c.digits(6) orelse return null;
        if (neg and y == 0) return null;
        year = if (neg) -y else y;
    } else {
        year = c.digits(4) orelse return null;
    }
    var month: f64 = 1;
    var day: f64 = 1;
    if (c.eat('-')) {
        month = c.digits(2) orelse return null;
        if (c.eat('-')) day = c.digits(2) orelse return null;
    }
    var h: f64 = 0;
    var m: f64 = 0;
    var sec: f64 = 0;
    var ms: f64 = 0;
    var has_time = false;
    var offset: ?f64 = null;
    if (c.i < s.len and (s[c.i] == 'T' or s[c.i] == 't' or s[c.i] == ' ')) {
        c.i += 1;
        has_time = true;
        h = c.digits(2) orelse return null;
        if (!c.eat(':')) return null;
        m = c.digits(2) orelse return null;
        if (c.eat(':')) {
            sec = c.digits(2) orelse return null;
            if (c.eat('.') or c.eat(',')) {
                var scale: f64 = 100;
                const start = c.i;
                while (c.i < s.len and s[c.i] >= '0' and s[c.i] <= '9') : (c.i += 1) {
                    ms += @as(f64, @floatFromInt(s[c.i] - '0')) * scale;
                    scale /= 10;
                }
                if (c.i == start) return null;
                ms = @floor(ms);
            }
        }
        if (c.eat('Z') or c.eat('z')) {
            offset = 0;
        } else if (c.i < s.len and (s[c.i] == '+' or s[c.i] == '-')) {
            const sign: f64 = if (s[c.i] == '-') -1 else 1;
            c.i += 1;
            const oh = c.digits(2) orelse return null;
            _ = c.eat(':');
            const om = c.digits(2) orelse return null;
            offset = sign * (oh * 60 + om);
        }
    }
    if (c.i != s.len) return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or h > 24 or m > 59 or sec > 59) return null;
    if (h == 24 and (m != 0 or sec != 0 or ms != 0)) return null;
    const t = date.makeDate(date.makeDay(year, month - 1, day), date.makeTime(h, m, sec, ms));
    if (offset) |o| return date.timeClip(t - o * 60000);
    // A date alone is UTC; a date with a time and no zone is local.
    return date.timeClip(if (has_time) date.localToUtc(vm, t) else t);
}

fn monthIndex(w: []const u8) ?f64 {
    if (w.len < 3) return null;
    const names = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
    for (names, 0..) |n, i| {
        if (std.ascii.eqlIgnoreCase(w[0..3], n)) return @floatFromInt(i);
    }
    return null;
}

fn isDayName(w: []const u8) bool {
    if (w.len < 3) return false;
    const names = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };
    for (names) |n| {
        if (std.ascii.eqlIgnoreCase(w[0..3], n)) return true;
    }
    return false;
}

fn zoneOffset(w: []const u8) ?f64 {
    const table = [_]struct { n: []const u8, off: f64 }{
        .{ .n = "gmt", .off = 0 },    .{ .n = "utc", .off = 0 },    .{ .n = "ut", .off = 0 },     .{ .n = "z", .off = 0 },
        .{ .n = "est", .off = -300 }, .{ .n = "edt", .off = -240 }, .{ .n = "cst", .off = -360 }, .{ .n = "cdt", .off = -300 },
        .{ .n = "mst", .off = -420 }, .{ .n = "mdt", .off = -360 }, .{ .n = "pst", .off = -480 }, .{ .n = "pdt", .off = -420 },
    };
    for (table) |t| {
        if (std.ascii.eqlIgnoreCase(w, t.n)) return t.off;
    }
    return null;
}

fn parseLoose(vm: *Vm, s: []const u8) f64 {
    var i: usize = 0;
    var nums: [3]f64 = undefined;
    var n_nums: usize = 0;
    var slash_form = false;
    var month: ?f64 = null;
    var h: f64 = 0;
    var mi: f64 = 0;
    var sec: f64 = 0;
    var offset: ?f64 = null;
    var pm: ?bool = null;
    var month_first = false;
    while (i < s.len) {
        const c = s[i];
        if (std.ascii.isAlphabetic(c)) {
            const st = i;
            while (i < s.len and std.ascii.isAlphabetic(s[i])) i += 1;
            const w = s[st..i];
            if (monthIndex(w)) |m| {
                month = m;
                if (n_nums == 0) month_first = true;
            } else if (isDayName(w)) {
                continue;
            } else if (std.ascii.eqlIgnoreCase(w, "am")) {
                pm = false;
            } else if (std.ascii.eqlIgnoreCase(w, "pm")) {
                pm = true;
            } else if (zoneOffset(w)) |o| {
                offset = o;
            } else {
                return nan;
            }
        } else if (c >= '0' and c <= '9') {
            const st = i;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
            const v = std.fmt.parseFloat(f64, s[st..i]) catch return nan;
            if (i < s.len and s[i] == ':') {
                h = v;
                i += 1;
                const ms = i;
                while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
                mi = std.fmt.parseFloat(f64, s[ms..i]) catch return nan;
                if (i < s.len and s[i] == ':') {
                    i += 1;
                    const ss = i;
                    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
                    sec = std.fmt.parseFloat(f64, s[ss..i]) catch return nan;
                }
            } else {
                if (n_nums >= 3) return nan;
                nums[n_nums] = v;
                n_nums += 1;
                if (i < s.len and s[i] == '/') slash_form = true;
            }
        } else if ((c == '+' or c == '-') and (offset != null or n_nums >= 2 or month != null) and i + 1 < s.len and s[i + 1] >= '0' and s[i + 1] <= '9') {
            const sign: f64 = if (c == '-') -1 else 1;
            i += 1;
            const st = i;
            while (i < s.len and ((s[i] >= '0' and s[i] <= '9') or s[i] == ':')) i += 1;
            var digits: [4]u8 = undefined;
            var nd: usize = 0;
            for (s[st..i]) |x| {
                if (x != ':' and nd < 4) {
                    digits[nd] = x;
                    nd += 1;
                }
            }
            const v = std.fmt.parseFloat(f64, digits[0..nd]) catch return nan;
            const minutes = if (nd <= 2) v * 60 else @floor(v / 100) * 60 + @mod(v, 100);
            offset = sign * minutes;
        } else if (c == '(') {
            while (i < s.len and s[i] != ')') i += 1;
            i += 1;
        } else {
            i += 1;
        }
    }
    var year: f64 = undefined;
    var day: f64 = undefined;
    var mon: f64 = undefined;
    if (month) |m| {
        mon = m;
        if (n_nums < 2) return nan;
        // "15 Nov 1994" or "Nov 15 1994"; a value over 31 can only be the year.
        if (nums[0] > 31) {
            year = nums[0];
            day = nums[1];
        } else {
            day = nums[0];
            year = nums[1];
        }
    } else if (slash_form and n_nums == 3) {
        mon = nums[0] - 1;
        day = nums[1];
        year = nums[2];
    } else {
        return nan;
    }
    if (year < 50) {
        year += 2000;
    } else if (year < 100) {
        year += 1900;
    }
    if (pm) |is_pm| {
        if (h > 12) return nan;
        if (is_pm and h < 12) h += 12;
        if (!is_pm and h == 12) h = 0;
    }
    if (mon < 0 or mon > 11 or day < 1 or day > 31 or h > 24 or mi > 59 or sec > 59) return nan;
    const t = date.makeDate(date.makeDay(year, mon, day), date.makeTime(h, mi, sec, 0));
    if (offset) |o| return date.timeClip(t - o * 60000);
    return date.timeClip(date.localToUtc(vm, t));
}

pub fn parse(vm: *Vm, s0: []const u8) f64 {
    const s = std.mem.trim(u8, s0, " \t\r\n");
    if (s.len == 0) return nan;
    if (parseIso(vm, s)) |t| return t;
    return parseLoose(vm, s);
}
