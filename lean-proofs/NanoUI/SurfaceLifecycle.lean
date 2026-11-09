namespace NanoUI.SurfaceLifecycle

/-!
# Surface & Page Lifecycle Safety (`src/ui/surface.zig`, `src/ipc.zig`)

Formalizes the deferred-destruction state machine for `Surface` (during `frame()`)
and `Page` (during `ipc.handlePageMessage()`), proving:
1. **No Use-After-Free during a frame/call**: Calling `destroy` while `in_frame`
   (or `dispatching`) sets `dead = true` without tearing down or freeing the
   allocation until `finishFrame` runs.
2. **Post-frame event handler safety (Issue #108)**: Checking `zigPtrPresent`
   (`objc.getZig(Surface, obj) != null`) after `frame()` returns guarantees the
   surface was not torn down or freed inside the frame.
3. **Stopped-loop leak freedom (PR #143)**: Destroying a surface after the event
   loop has stopped (`app_running = false`) forces immediate reclamation even if
   pending wakes are queued.
-/

structure SurfaceState where
  in_frame : Bool := false
  dead : Bool := false
  force_destroy : Bool := false
  torn_down : Bool := false
  freed : Bool := false
  zig_attached : Bool := true
  pending_wakes : Nat := 0
  deriving DecidableEq, Repr

def finishDestroy (s : SurfaceState) : SurfaceState :=
  let s1 :=
    if !s.torn_down then
      { s with torn_down := true, zig_attached := false }
    else
      s
  if s1.force_destroy || s1.pending_wakes == 0 then
    { s1 with freed := true }
  else
    s1

def destroy (s : SurfaceState) (app_running : Bool) : SurfaceState :=
  let s1 := { s with dead := true, force_destroy := !app_running }
  if !s1.in_frame then finishDestroy s1 else s1

def beginFrame (s : SurfaceState) : SurfaceState :=
  if s.in_frame || s.dead then s else { s with in_frame := true }

def finishFrame (s : SurfaceState) : SurfaceState :=
  let s1 := { s with in_frame := false }
  if s1.dead then finishDestroy s1 else s1

/-- Theorem 1: If `destroy` is called while `in_frame = true` on a live surface,
    the surface remains un-freed and un-torn-down for the remainder of the frame. -/
theorem no_uaf_during_frame (s : SurfaceState) (app_running : Bool)
    (h_in : s.in_frame = true) (h_live : s.torn_down = false) (h_unfreed : s.freed = false) :
    (destroy s app_running).torn_down = false ∧ (destroy s app_running).freed = false := by
  unfold destroy
  simp [h_in, h_live, h_unfreed]

/-- Theorem 2: Once `finishFrame` completes after an in-frame `destroy`, the
    surface is torn down and `zig_attached` (`objc.getZig`) is cleared to `false`. -/
theorem finish_frame_clears_zig_ptr (s : SurfaceState) (app_running : Bool)
    (h_in : s.in_frame = true) (h_live : s.torn_down = false) :
    (finishFrame (destroy s app_running)).torn_down = true ∧
    (finishFrame (destroy s app_running)).zig_attached = false := by
  unfold destroy finishFrame finishDestroy
  cases app_running <;> simp [h_in, h_live]
  all_goals
    split <;> simp

/-- Theorem 3 (Issue #108 guard): In any event handler that runs a frame and
    checks `zig_attached = true` (`Surface.alive(tok)`) before
    touching `s`, the surface is guaranteed not to have been destroyed during
    the frame if it started attached and un-torn-down. -/
theorem post_frame_guard_sound (s : SurfaceState) (closed_in_frame : Bool) (app_running : Bool)
    (h_live : s.in_frame = false) (h_dead : s.dead = false)
    (h_torn : s.torn_down = false) (h_freed : s.freed = false) (h_zig : s.zig_attached = true) :
    let after := finishFrame (if closed_in_frame then destroy (beginFrame s) app_running else beginFrame s)
    after.zig_attached = true → after.torn_down = false ∧ after.freed = false := by
  cases closed_in_frame <;> cases app_running <;>
    simp [beginFrame, destroy, finishFrame, finishDestroy, h_live, h_dead, h_torn, h_freed, h_zig]
  all_goals
    split <;> simp

/-- Theorem 4 (PR #143): When the app run loop has stopped (`app_running = false`),
    `destroy` outside a frame immediately frees the surface regardless of `pending_wakes`. -/
theorem stopped_loop_frees_immediately (s : SurfaceState)
    (h_not_in_frame : s.in_frame = false) :
    (destroy s false).freed = true := by
  unfold destroy finishDestroy
  cases s.torn_down <;> simp [h_not_in_frame]

end NanoUI.SurfaceLifecycle
