# Headless Testing, Accessibility Verification, and Renderer Parity

Verification standards from Harness (`src/snap.zig`, `tests`) and `nanoui`'s test suite (`src/ui/tester.zig`, `src/ui/tests_access.zig`, `examples/gallery/tests.zig`).

## 1. Never Touch the Live Screen

During development and CI:
- **Prohibited:** Launching unscripted windowed GUIs on the developer desktop, posting synthetic mouse/keyboard OS events (`CGEventPost`, AppleScript clicks), reading the system clipboard, or capturing full-screen screenshots.
- **Required:** Run all view and interaction checks offscreen inside `ui.Tester` or via built-in `--nanoui-snapshot=<path.png> --nanoui-script="..."` flags, which hold windows hidden offscreen.

## 2. Core `ui.Tester` Checklist for Every App View

Include these four test categories in `tests.zig` and wire the test binary into `build.zig`'s `test` step (guarded by `if (!target.result.abi.isAndroid())` for host runs):

1. **Sweep every route at desktop and compact phone sizes:**
   ```zig
   for (pages) |page_id| {
       app.selectPage(page_id);
       t.settle(2);
       try testing.expect(t.ctx.nodes.items.len > 4);
   }
   t.resize(390, 844);
   t.settle(2);
   ```
2. **Prove idle quiescence (0% idle CPU):**
   For every non-continuous view, assert after `t.settle(2)`:
   ```zig
   try testing.expect(!t.ctx.animating);
   try testing.expect(t.ctx.frame_in == null);
   ```
   A failing check catches forgotten hover timers, infinite animations on static screens, or frames unconditionally setting `c.changed = true`.
3. **Exercise keyboard shortcuts, modals, and composited widgets:**
   - Send `_ = t.shortcut(.{ .key = 'k', .cmd = true })`, `t.typeText(...)`, `_ = t.shortcut(.{ .key = ui.Shortcut.enter })`, and `_ = t.shortcut(.{ .key = ui.Shortcut.escape })`.
   - Test dynamic foldouts, composer submit, and `ui.dock` layout invariants.
4. **Verify `ui.access.tree` (VoiceOver / Screen Reader correctness):**
   Run `ui.access.tree(&t.ctx, arena, &els)` in tests to prove:
   - Every visible control has a meaningful non-empty `label`.
   - Adjacent captions (`"Password"`, `"Volume"`) claim unlabeled controls and are not read twice.
   - `.password = true` fields always report `value == ""` and never leak secret strings or bullet counts.

## 3. Headless Scenario Runners (`snap.zig` + `--nanoui-*`)

For rich apps (like Harness's `src/snap.zig`) where you want deterministic seeded state across many screenshots:
- **Option A (`--nanoui-*` CLI flags):** Already built into every `nanoui.App` (`src/dev.zig`). Combine `--nanoui-snapshot=out.png` and `--nanoui-script="click:Studio;click:Ran 3 checks;wait:0.2"` on your real binary to inspect pixels with an image reader.
- **Option B (`snap.zig` + `Tester.app_verbs`):** Build a small dedicated executable importing your app's `View` + seeded `Engine` fixtures inside `ui.Tester`, attach custom `app_verbs` (e.g. `seed:long_thread`, `tab:inspector`) when needed, call `t.settle(2)` -> `t.screenshot(path)`, and inspect the rendered PNGs for clipping, overlap, and dark/light contrast.

## 4. Renderer Parity (`Metal` / `D3D11` / `OpenGL` vs. `-Dportable=true`)

Run tests under both the platform backend and the portable CPU rasterizer + TrueType text engine:
```sh
zig build test
zig build test -Dportable=true
```
Testing with `-Dportable=true` exercises the exact CPU glyph rasterizer and SDF/quad renderer used on headless Linux containers and software Windows fallback paths, catching layout metric drift before pushing to CI.
