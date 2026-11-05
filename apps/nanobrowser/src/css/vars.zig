//! Custom properties: the scope each element sees, the substitution of `var()`
//! at computed time, and the cycle rule (a cycle makes every property in it
//! invalid, which reads as not set).
const std = @import("std");
const Allocator = std.mem.Allocator;
const tk = @import("tokenizer.zig");
const sheet = @import("sheet.zig");

const Token = tk.Token;

pub const Entry = struct {
    hash: u32,
    name: []const u8,
    /// Null: declared but invalid (a cycle, a failed `var()`, or `initial`):
    /// it hides what an ancestor set.
    value: ?[]const Token,
};

/// What an element declares, over what it inherits. Scopes are shared by
/// elements that declare nothing, and live in the engine's generation arena.
pub const Scope = struct {
    parent: ?*const Scope = null,
    entries: []const Entry = &.{},
    /// Those of `entries` declared here for properties that don't inherit
    /// (`@property`): what this scope's children have to put back.
    local: []const Entry = &.{},

    /// Found-and-null means invalid; not found is null too, for the caller
    /// these are the same.
    pub fn get(s: *const Scope, name: []const u8, hash: u32) ?[]const Token {
        var at: ?*const Scope = s;
        while (at) |x| : (at = x.parent) {
            for (x.entries) |*e| {
                if (e.hash == hash and std.mem.eql(u8, e.name, name)) return e.value;
            }
        }
        return null;
    }
};

/// `@property`'s rules, by name.
pub const Registered = std.StringHashMapUnmanaged(sheet.PropertyRule);

const State = enum(u8) { unvisited, visiting, done };

const Pending = struct {
    hash: u32,
    name: []const u8,
    raw: ?[]const Token,
    has_var: bool,
    /// Declared here, rather than put back to what it starts as.
    declared: bool = true,
    state: State = .unvisited,
    value: ?[]const Token = null,
};

/// Builds the scope for one element from its custom declarations in cascade
/// order; the last wins. The working list is reused between elements.
pub const Builder = struct {
    pending: std.ArrayList(Pending) = .empty,
    /// While set, a cycle through this entry is being unwound: every `var()`
    /// on the way fails, fallback or not, since the properties are invalid.
    cycle_root: ?*Pending = null,

    pub fn deinit(b: *Builder, gpa: Allocator) void {
        b.pending.deinit(gpa);
    }

    pub fn reset(b: *Builder) void {
        b.pending.clearRetainingCapacity();
    }

    pub fn add(b: *Builder, gpa: Allocator, d: *const sheet.Declaration, parent: ?*const Scope) Allocator.Error!void {
        var raw: ?[]const Token = d.value;
        var has_var = d.has_var;
        switch (d.wide) {
            .none => {},
            // Not inherited, and no initial value but "nothing".
            .initial => {
                raw = null;
                has_var = false;
            },
            // An inherited property's `unset` and `revert` are `inherit`.
            .inherit, .unset, .revert => {
                raw = if (parent) |p| p.get(d.name, d.hash) else null;
                has_var = false;
            },
        }
        for (b.pending.items) |*p| {
            if (p.hash == d.hash and std.mem.eql(u8, p.name, d.name)) {
                p.raw = raw;
                p.has_var = has_var;
                p.declared = true;
                return;
            }
        }
        try b.pending.append(gpa, .{ .hash = d.hash, .name = d.name, .raw = raw, .has_var = has_var });
    }

    /// A property that doesn't inherit, the parent's not coming down here.
    pub fn putBack(b: *Builder, gpa: Allocator, e: Entry, initial: ?[]const Token) Allocator.Error!void {
        try b.pending.append(gpa, .{ .hash = e.hash, .name = e.name, .raw = initial, .has_var = false, .declared = false });
    }

    /// The finished scope, in `arena`; `parent` itself when nothing was declared.
    /// `registered`: what `@property` said.
    pub fn finish(b: *Builder, arena: Allocator, parent: ?*const Scope, registered: *const Registered) Allocator.Error!?*const Scope {
        if (b.pending.items.len == 0) return parent;
        for (b.pending.items) |*p| _ = try b.resolve(arena, p, parent);
        const entries = try arena.alloc(Entry, b.pending.items.len);
        var local: std.ArrayList(Entry) = .empty;
        for (b.pending.items, entries) |*p, *e| {
            e.* = .{ .hash = p.hash, .name = p.name, .value = p.value };
            if (p.declared) if (registered.get(p.name)) |r| if (!r.inherits) try local.append(arena, e.*);
        }
        const s = try arena.create(Scope);
        s.* = .{ .parent = parent, .entries = entries, .local = local.items };
        return s;
    }

    fn resolve(b: *Builder, arena: Allocator, p: *Pending, parent: ?*const Scope) Allocator.Error!?[]const Token {
        switch (p.state) {
            .done => return p.value,
            .visiting => {
                b.cycle_root = p;
                return null;
            },
            .unvisited => {},
        }
        p.state = .visiting;
        var out: ?[]const Token = p.raw;
        if (p.has_var) if (p.raw) |raw| {
            const look: Lookup = .{ .builder = b, .arena = arena, .parent = parent };
            out = try substituteWith(arena, raw, &look);
        };
        p.state = .done;
        p.value = out;
        if (b.cycle_root == p) b.cycle_root = null;
        return out;
    }

    fn find(b: *Builder, name: []const u8, hash: u32) ?*Pending {
        for (b.pending.items) |*p| if (p.hash == hash and std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
};

const Lookup = struct {
    builder: ?*Builder = null,
    arena: Allocator,
    parent: ?*const Scope,

    fn get(l: *const Lookup, name: []const u8) Allocator.Error!?[]const Token {
        const hash = std.hash.Fnv1a_32.hash(name);
        if (l.builder) |b| if (b.find(name, hash)) |p| return b.resolve(l.arena, p, l.parent);
        const s = l.parent orelse return null;
        return s.get(name, hash);
    }
};

/// A value with its `var()`s replaced, in `arena`. Null: invalid at computed
/// time.
pub fn substitute(arena: Allocator, value: []const Token, scope: ?*const Scope) Allocator.Error!?[]const Token {
    const look: Lookup = .{ .arena = arena, .parent = scope };
    return substituteWith(arena, value, &look);
}

fn substituteWith(arena: Allocator, value: []const Token, look: *const Lookup) Allocator.Error!?[]const Token {
    var out: std.ArrayList(Token) = .empty;
    try out.ensureTotalCapacity(arena, value.len + 4);
    if (!try walk(arena, value, look, &out, 0)) return null;
    return out.items;
}

/// What the environment says of what `env()` names: a window has no insets here.
fn envDefault(name: []const u8) ?Token {
    const zero = [_][]const u8{ "safe-area-inset-top", "safe-area-inset-right", "safe-area-inset-bottom", "safe-area-inset-left", "safe-area-max-inset-top", "safe-area-max-inset-right", "safe-area-max-inset-bottom", "safe-area-max-inset-left", "keyboard-inset-top", "keyboard-inset-right", "keyboard-inset-bottom", "keyboard-inset-left", "keyboard-inset-width", "keyboard-inset-height", "titlebar-area-x", "titlebar-area-y", "titlebar-area-width", "titlebar-area-height" };
    for (zero) |z| if (std.ascii.eqlIgnoreCase(name, z)) return .{ .kind = .dimension, .num = 0, .text = "px" };
    return null;
}

fn walk(arena: Allocator, value: []const Token, look: *const Lookup, out: *std.ArrayList(Token), depth: u32) Allocator.Error!bool {
    if (depth > 32) return false;
    var i: usize = 0;
    while (i < value.len) {
        const t = value[i];
        const is_var = t.isFunction("var");
        const is_env = t.isFunction("env");
        if (!is_var and !is_env) {
            try out.append(arena, t);
            i += 1;
            continue;
        }
        // The arguments.
        var e = i + 1;
        var nest: u32 = 1;
        while (e < value.len) : (e += 1) {
            switch (value[e].kind) {
                .function, .lparen => nest += 1,
                .rparen => {
                    nest -= 1;
                    if (nest == 0) break;
                },
                else => {},
            }
        }
        const args = value[i + 1 .. @min(e, value.len)];
        i = e + 1;
        var a: usize = 0;
        while (a < args.len and args[a].kind == .whitespace) : (a += 1) {}
        if (a >= args.len) return false;
        const name_tok = args[a];
        if (name_tok.kind != .ident) return false;
        a += 1;
        while (a < args.len and args[a].kind == .whitespace) : (a += 1) {}
        var fallback: ?[]const Token = null;
        if (a < args.len) {
            if (args[a].kind != .comma) {
                // `env(name 1, ...)` has indices, which mean nothing here.
                if (is_var) return false;
                while (a < args.len and args[a].kind != .comma) : (a += 1) {}
            }
            if (a < args.len) fallback = args[a + 1 ..];
        }
        if (is_var) {
            if (try look.get(name_tok.text)) |v| {
                try out.appendSlice(arena, v);
                continue;
            }
            if (look.builder) |b| if (b.cycle_root != null) return false;
        }
        if (is_env and fallback == null) if (envDefault(name_tok.text)) |v| {
            try out.append(arena, v);
            continue;
        };
        const f = fallback orelse return false;
        if (!try walk(arena, f, look, out, depth + 1)) return false;
    }
    return true;
}
