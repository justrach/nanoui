//! Pixel-level overflow audit, not a replacement renderer. The same native
//! frame is rendered with and without numeral glyph instances. Any changed
//! pixel must be inside the fixed inset clip AND on the solid black pill.
const std = @import("std");
const ui = @import("nanoui").ui;

pub const Audit = struct {
    frames: usize = 0,
    changed: usize = 0,
    top_edge: usize = 0,
    bottom_edge: usize = 0,

    pub fn frame(a: *Audit, t: *ui.Tester) !void {
        const original = try t.gpa.dupe(@TypeOf(t.instances.items[0]), t.instances.items);
        defer t.gpa.free(original);
        defer @memcpy(t.instances.items, original);
        const full = try t.render(t.gpa);
        defer full.deinit(t.gpa);
        // gpu.Kind.text is 1 in the public renderer instance ABI. This
        // dedicated view has no other text, icons, or glyph instances.
        for (t.instances.items) |*inst| if (inst.kind == 1) {
            if (!std.mem.eql(f32, &inst.clip, &.{ 400, 233, 560, 329 })) return error.WrongNumeralClip;
            inst.color[3] = 0;
        };
        const bare = try t.render(t.gpa);
        defer bare.deinit(t.gpa);
        for (0..full.height) |y| for (0..full.width) |x| {
            const at = (y * full.width + x) * 4;
            const with = full.bytes[at..][0..4];
            const without = bare.bytes[at..][0..4];
            if (std.mem.eql(u8, with, without)) continue;
            if (x < 400 or x >= 560 or y < 233 or y >= 329) return error.NumeralOutsideInset;
            if (without[0] != 0 or without[1] != 0 or without[2] != 0) return error.NumeralOutsideSolidPill;
            a.changed += 1;
            if (y == 233) a.top_edge += 1;
            if (y == 328) a.bottom_edge += 1;
        };
        a.frames += 1;
    }

    pub fn report(a: Audit) !void {
        if (a.frames != 480 or a.changed == 0 or a.top_edge == 0 or a.bottom_edge == 0) return error.IncompleteClipAudit;
        std.debug.print("CLIP AUDIT PASS: {d} native frames; {d} numeral-affected pixels; {d} touch top inset row, {d} bottom inset row; ZERO differences outside inset or on nonblack pill background.\n", .{ a.frames, a.changed, a.top_edge, a.bottom_edge });
    }
};
