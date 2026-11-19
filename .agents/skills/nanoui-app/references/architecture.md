# Engine, Snapshots, and Memory Discipline

Patterns distilled from Harness (`src/engine.zig`, `src/view.zig`) and `examples/gallery/` for running fast background work while keeping UI rendering deterministic and allocation-safe.

## 1. The Engine-Snapshot Boundary

Keep UI view code purely reactive to a main-thread snapshot synchronized at the start of `view`:

```zig
pub const AppState = struct {
    engine: Engine,
    generation: u64 = 0,
    // Main-thread mirror copied from Engine only when `generation` advances:
    items: std.ArrayList(Summary) = .empty,
    search_matches: std.ArrayList(u32) = .empty,

    pub fn view(s: *AppState, c: *ui.Context) void {
        s.syncFromEngine(c);
        // Build immutable UI pass from main-thread mirror only.
    }
};
```

Rules for worker communication:
- **Wake, never poll:** When a worker commits a new snapshot revision, increment an atomic counter and call `c.waker.wake(c.waker.ctx)` (from main-window setup) or dispatch onto the main thread (`objc.dispatchMain`). Wait for wakeups rather than setting periodic `c.frameIn(...)` heartbeats.
- **Keep locks microsecond-short:** Copy lightweight structs or swap double-buffered slices under the engine mutex; never hold a lock during layout, shaping, or painting.
- **Avoid transient `sync` allocation churn:** Compare `s.generation == s.engine.generation.load(.acquire)` first so steady-state hover/scroll frames skip copying completely.

## 2. Per-Frame Arena vs. Persistent Allocators

In every `nanoui` view function:
- `c.alloc()` and `c.print(...)` allocate inside `Context.arena`, which resets cleanly at the start of every frame.
- **Safe in frame arena:** Temporary slices passed immediately to `ui.text`, `ui.button`, `ui.key`, or `canvas.polyline` during the current frame build.
- **Unsafe in frame arena (use-after-free bug):** Storing slices from `c.alloc()` or `c.print()` inside struct fields (`g.matches`, cached search results, tab labels kept across frames). Any field that outlives the current `view` call must allocate with an explicit long-lived allocator (`gpa` or `std.heap.c_allocator`) and release in `deinit()`.

Example (from `examples/gallery/main.zig` `syncMatches`):
- Store `matches: std.ArrayList(u32)` and `matches_for: std.ArrayList(u8)` with `std.heap.c_allocator`.
- Compare `std.mem.eql(u8, s.matches_for.items, filter.text())` at the top of the frame. Only rebuild when the filter string actually changes so scrollbar drags stay O(1) in visible rows.

## 3. Stable Identities (`ui.key`) and Focus Transfer

Interactions (`clicked`, hover fades, scroll offsets, `ui.motion` springs, `TextField` selection/undo) read the **previous frame's** box tree by hashed ID.

- **Dynamic or reordered lists:** Always call `ui.key(c, ...)` with a stable domain ID before opening a row box:
  ```zig
  for (items) |*it| {
      ui.key(c, c.print("item-{d}", .{it.id}));
      const row = ui.div(c).row().wFull()...;
      defer row.end();
  }
  ```
- **Index keys vs. identity keys:** Array index keys (`"step-0"`) work for fixed-order arrays, whereas mutable/deletable lists need pointer addresses (`@intFromPtr(it)`) or domain IDs so deleting row 0 does not transfer its hover/animation state onto row 1.
- **Programmatic focus (`TextBuffer.focus()`):** Do not call `c.focus = ...` manually on frame N before a modal exists. Call `buf.focus()` (`want_focus = true`), and the `ui.textField` bound to `&buf` claims keyboard focus deterministically on the frame it mounts (see `palette.zig` `Palette.toggle`).

## 4. Bounds and Fixed-Capacity Ring Buffers

Prefer fixed-size ring buffers or bounded `ArrayList`s for UI activity logs, recent prompts, and frame-time telemetry arrays (`[8]f32`, `[6][96]u8`). Bounded buffers prevent unbounded RSS growth during long sessions and let view code render without fallible allocations inside tight UI loops.
