---
name: nanoui-app
description: Design, structure, test, and ship production multi-platform native Zig 0.17 desktop and mobile apps on nanoui using the architecture proven in Harness. Activate when building a new nanoui application, structuring background engines and main-thread state snapshots, designing multi-pane shells (sidebar, dock, command palette, quiet folded tool transcripts, responsive phone views), writing headless offscreen snapshot/script harnesses, or packaging signed releases.
---

# Building Production Apps on nanoui

Use this playbook when designing, structuring, testing, or packaging a full native desktop/mobile application on `nanoui` (Zig 0.17), distilled from the production architecture of Harness (`apps/nano/`).

## Non-Negotiable Principles

1. **Enforce the 600-line file ceiling from day one.**
   Split every concern by responsibility (`engine.zig`, `view.zig`, `view_palette.zig`, `window_chrome.zig`, `window_lifecycle.zig`, `motion_rules.zig`, `snap.zig`) before a file grows past 600 formatted lines. Run `zig build lines` after `zig fmt`.

2. **Keep UI state on the main thread; move I/O and workers behind snapshots.**
   AppKit, UIKit, GTK, Win32, and `ui.Context` run exclusively on the main thread. Background workers (network clients, SQLite, local subprocesses, agent runners) own their own threads, write bounded snapshot structs or queues, and wake the UI with `waker` / `objc.dispatchMain` (or `Tester.requestFrameFromAnyThread` in tests).

3. **Zero polling when idle.**
   Frames are drawn only on user input, window resize, worker wakeups, or active transitions. Once animations settle, assert in tests that `!t.ctx.animating` and `t.ctx.frame_in == null`. Never install a background timer just to "keep checking" state.

4. **Respect the per-frame arena vs. persistent allocator split.**
   `c.alloc()` and `c.print(...)` allocate in the frame arena, which resets every frame. Persistent state (`ui.TextBuffer`, cached filter indices, transcript entries, snapshot buffers) must use an explicit long-lived allocator (`gpa` or `std.heap.c_allocator`) with deterministic `deinit()`.

5. **Never show windows or drive the user's real input while testing.**
   Use `ui.Tester` in-process (both default GPU/Metal and `-Dportable=true` CPU), `--nanoui-snapshot` + `--nanoui-script`, and an optional app-specific headless snapshot runner (`snap.zig`) so CI and agents verify real pixels and accessibility trees offscreen.

## Canonical Production App Layout

```text
my-app/
  build.zig              # exe, unit tests, and optional headless snap binary
  build.zig.zon          # pins nanoui dependency cleanly
  src/
    main.zig             # App.create, WindowOptions, waker wiring, app.run()
    engine.zig           # Worker orchestration, bounded queues, snapshot swap
    view.zig             # Root shell, desktop/compact dispatch, global overlay host
    view_palette.zig     # Cmd/Ctrl+K palette overlay + shortcut preemption
    view_workspace.zig   # Main split / ui.dock workspace + inspector panels
    window_chrome.zig    # title_bar = .hidden, c.title_bar_height, traffic lights
    window_lifecycle.zig # Window placement, opacity/decorations, clean teardown
    motion_rules.zig     # Shared springs, durations, reduced-motion helpers
    snap.zig             # Headless offscreen scenario & PNG verification tool
    tests.zig            # ui.Tester layout, interaction, a11y, quiescence specs
```

## Build Loop

1. **Architecture first:** Decide which structs live on the main thread (UI navigation, open overlays, `TextBuffer`s, scroll state) vs. inside `Engine` (sockets, DB, background tasks). See [architecture.md](references/architecture.md).
2. **Shell & overlays next:** Build `WindowOptions` with `.title_bar = .hidden`, responsive `c.size.w < 600` adaptation, global shortcuts at the top of `view`, and layered scrim overlays (`layer(10)` / `layer(11)`). See [shell-and-patterns.md](references/shell-and-patterns.md).
3. **Offscreen verification alongside every widget:** Add `ui.Tester` specs covering desktop + phone widths, `ui.access.tree` labels/redaction, and settled idle quiescence (`!animating`, `frame_in == null`). See [testing-and-parity.md](references/testing-and-parity.md).
4. **Cross-platform CI & packaging:** Verify formatting, `lines`, portable CPU parity, Linux/Windows/iOS/Android targets, and isolated local CI sandboxes. See [packaging-and-release.md](references/packaging-and-release.md).

## Quick Reference Index

- **[Engine, Snapshots & Memory](references/architecture.md)** — Worker-to-UI sync, per-frame arena traps, `ui.key` stability, `TextBuffer.focus()`, dirty filter caching.
- **[Desktop/Mobile Shell & UI Patterns](references/shell-and-patterns.md)** — Chrome, responsive `ui.dock` vs `kit.tabs`, `⌘K` palette overlays, cross-platform shortcuts, folded tool transcripts, accessibility captions.
- **[Headless Testing & Renderer Parity](references/testing-and-parity.md)** — `ui.Tester`, `app_verbs`, `snap.zig` harness, Metal/GL/D3D11 vs `-Dportable=true` checks, a11y tree assertions.
- **[Cross-Compilation, CI & Releases](references/packaging-and-release.md)** — Multi-target build flags, pre-commit `check-snapshot.sh`, runner isolation, headless bundle smoke tests.
