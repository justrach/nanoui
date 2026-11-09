namespace NanoUI.LiveResize

/-!
# Live-Resize Transaction & Display-Link Pacing (`src/ui/surface_pacing.zig`)

Formalizes the macOS live-resize pacing lessons from `nanoterm` / PR #135:
1. During live resize (`resizing = true`), only `setFrameSize` draws synchronously
   inside the CoreAnimation transaction (`presentsWithTransaction`).
2. `resizeStepping` stays active only for `hold_ms` (48ms) after the last
   `setFrameSize` geometry step, so an idle drag handle uses 0% CPU.
-/

structure ResizeState where
  resizing : Bool := false
  step_at_ms : Nat := 0
  hold_ms : Nat := 48
  deriving DecidableEq, Repr

def resizeStepping (r : ResizeState) (now_ms : Nat) : Bool :=
  r.resizing && r.step_at_ms > 0 && now_ms >= r.step_at_ms && (now_ms - r.step_at_ms < r.hold_ms)

def onSetFrameSize (r : ResizeState) (now_ms : Nat) : ResizeState :=
  { r with step_at_ms := if r.resizing then now_ms else r.step_at_ms }

def onLiveResizeEnd (r : ResizeState) : ResizeState :=
  { r with resizing := false, step_at_ms := 0 }

/-- Theorem 1: Once `now_ms >= step_at_ms + hold_ms`, `resizeStepping` is `false`
    even while the user holds the window edge still (`resizing = true`), preventing
    idle display-link polling during a paused resize drag. -/
theorem resize_quiesces_after_hold (r : ResizeState) (now_ms : Nat)
    (h_elapsed : now_ms - r.step_at_ms ≥ r.hold_ms) :
    resizeStepping r now_ms = false := by
  unfold resizeStepping
  have h_not_lt : ¬ (now_ms - r.step_at_ms < r.hold_ms) := Nat.not_lt.mpr h_elapsed
  simp [h_not_lt]

/-- Theorem 2: Ending live resize immediately clears `resizeStepping` for all timestamps. -/
theorem live_resize_end_stops_stepping (r : ResizeState) (now_ms : Nat) :
    resizeStepping (onLiveResizeEnd r) now_ms = false := by
  unfold resizeStepping onLiveResizeEnd
  simp

end NanoUI.LiveResize
