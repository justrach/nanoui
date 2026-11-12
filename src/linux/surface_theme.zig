//! Resolves the Linux surface's theme and rebuilds when the view changes it.
const frame = @import("../ui/frame.zig");
const themes = @import("../ui/theme.zig");
const Theme = themes.Theme;
const Surface = @import("surface.zig").Surface;

fn theme(self: *Surface) Theme {
    if (self.theme_override orelse self.theme_chosen) |t| return t;
    return if (@import("desktop.zig").isDark()) Theme.dark_theme else Theme.light;
}

pub fn build(self: *Surface, dt: f32, time: f64) frame.Result {
    const c = &self.ctx;
    var result = frame.run(c, self.view, &self.text, &self.instances, self.size, self.scale, theme(self), dt, time);
    // Resolve a new choice in the same frame, including the first one.
    if (!themes.sameChoice(self.theme_chosen, c.theme_chosen)) {
        self.theme_chosen = c.theme_chosen;
        result = frame.run(c, self.view, &self.text, &self.instances, self.size, self.scale, theme(self), dt, time);
    }
    return result;
}
