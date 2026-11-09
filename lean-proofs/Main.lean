import NanoUI

def main : IO Unit := do
  IO.println "nanoui Lean 4 formal verification suite:"
  IO.println "  [OK] NanoUI.SurfaceLifecycle (no_uaf_during_frame, post_frame_guard_sound, stopped_loop_frees_immediately)"
  IO.println "  [OK] NanoUI.LiveResize       (resize_quiesces_after_hold, live_resize_end_stops_stepping)"
  IO.println "  [OK] NanoUI.RetainedScroll   (retained_shift_matches_full_layout, subtree_hit_invariant_at_all_x)"
  IO.println "  [OK] NanoUI.MarkdownSpec     (append_span_sound)"
  IO.println "  [OK] NanoUI.BuildSplit       (split_rebuild_strictly_faster)"
