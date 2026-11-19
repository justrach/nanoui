# Desktop/Mobile Shell, Overlays, and Interaction Patterns

UI construction conventions distilled from Harness (`src/window_chrome.zig`, `src/view_palette.zig`, `src/view.zig`) and `examples/gallery/`.

## 1. Seamless Window Chrome (`title_bar = .hidden`)

Create desktop windows with `.title_bar = .hidden` so content extends cleanly into the title bar:
- Set `c.title_bar_height = 38` (or `40` on desktop sidebars) so macOS traffic lights align inside your header strip (`window_lights.zig`).
- On macOS phone/compact previews, reserve top inset (`mac_top = if (builtin.os.tag == .macos) 28 else 0`) or `.safeArea()` on mobile targets so content clears system bars.
- For borderless auxiliary windows (`.decorations = false`), provide an explicit drag handle box via `c.leaf(.{ .grow = 1, .window_drag = true }, ...)`. Never add `.window_drag = true` on a normal decorated window's title region or OS dragging will conflict.

## 2. Responsive Shell: Sidebar + `ui.dock` vs. Compact Push Stack

Adapt automatically by window width (`const compact = c.size.w < 600;`) rather than branching on OS alone:
- **Desktop (`>= 600pt`):** Left navigation rail (`width = 200`, command palette search trigger pill at top, live count pills on key destinations) + multi-pane workspace using `ui.dock.Tree`, `ui.dock.State`, and `ui.dock.view`. Wrap `ui.dock.view` in a `grow().wFull()` host; if the host has no measured rect on frame 1 (`host.interaction().rect == null`), set `c.changed = true` once so frame 2 sizes splits accurately without a stale fallback.
- **Compact (`< 600pt`):** Mobile root list with glass header buttons (`>= 44pt` hit target) and pushed detail views animated with `ui.motion.present`. Inside dense multi-pane destinations (such as `Studio`), downgrade `ui.dock` into segmented `kit.tabs` (`Transcript | Inspector | Telemetry`) so every panel gets full mobile width.

## 3. Global Shortcuts & Preemption Order

Run global shortcut handling at the **top** of your root `view` before sidebar/content builders run:

```zig
pub fn handleShortcuts(p: *Palette, g: anytype, c: *ui.Context) void {
    if (c.shortcut(.{ .key = 'k', .cmd = true })) {
        p.toggle(c);
        return;
    }
    if (p.open) {
        // Consume Escape, Up, Down, Enter across Shortcut, Key, and AppKit TextOps.
        // Never allow underlying page shortcuts to fire while a modal is open.
        return;
    }
    if (c.focused_text == null) {
        // Safe zone for single-key or digit navigation shortcuts (`⌘1`..`⌘9`).
    }
}
```

Key cross-platform details:
- **`Shortcut.native()`:** Writing `.cmd = true` in `ui.Shortcut` automatically translates to Command on macOS/iOS and Control on Linux/Windows/Android inside `c.shortcut(...)`.
- **`ui.keys.label`:** Format comptime keycap hints with `ui.keys.label("⌘K")` -> `"⌘K"` on Apple and `"Ctrl+K"` on Linux/Windows.
- **Consume across all 3 input paths inside modals:** On macOS `AppKit`, arrows/Escape/Return reach focused text fields as `c.input.ops` (`move_up`, `move_down`, `cancel`, `insert_newline`); on Linux/Windows and `Tester`, they arrive as `c.input.key` or `c.input.shortcut`. Check all three inside modal navigation so focus stays consistent everywhere.

## 4. Modal Scrim Layering (`layer(10)` + `layer(11)`)

Build overlays (`⌘K` Command Palette, `kit.dialog`, `kit.sheet`) at the **end** of the root `view` so they sit outside clip rects and cover both desktop sidebars and pushed phone views:
- Render backdrop scrim at `.fixed().offset(0, 0).w(c.size.w).h(c.size.h).layer(10).bg(kit.tokens(c).overlay)` and close when `.interaction().clicked`.
- Render the floating card at `.fixed().offset(x, y).w(w).layer(11)` driven by `motion.present`. Because `layer(11)` sits above `layer(10)`, clicks inside the card never dismiss the backdrop.

## 5. Quiet Folded Tool Groups & Accessible Forms

- **Transcript readability (Harness pattern):** Keep routine tool/check output folded behind a single interactive summary row (`"Ran 3 checks · 18 ms"` with a rotating `chevron.right`), expanding into connected `kit.timelineItem` rows (`first`, `last`, `.gap(0)` parent) only on click.
- **Screen reader hygiene:** Give every `ui.textField` either an explicit `.placeholder` or a same-line static text caption immediately to its left (`"Password"`, `"Volume"`). Always set `.password = true` on secrets so `ui.access.tree` redacts values.
