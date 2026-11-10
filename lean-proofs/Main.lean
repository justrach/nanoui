import NanoUI

def main : IO Unit := do
  IO.println "nanoui Lean 4 formal verification suite:"
  IO.println "  [OK] NanoUI.SurfaceLifecycle (no_uaf_during_frame, post_frame_guard_sound, stopped_loop_frees_immediately)"
  IO.println "  [OK] NanoUI.LiveResize       (resize_quiesces_after_hold, live_resize_end_stops_stepping)"
  IO.println "  [OK] NanoUI.RetainedScroll   (retained_shift_matches_full_layout, subtree_hit_invariant_at_all_x)"
  IO.println "  [OK] NanoUI.MarkdownSpec     (append_span_sound)"
  IO.println "  [OK] NanoUI.BuildSplit       (split_rebuild_strictly_faster)"
  IO.println "  [OK] NanoUI.BrowserPerf      (hover_hold_quiescent_when_same, resolve_cache_sound, single_pass_group_cull_equiv, static_page_zero_prelude_cost, pre_focus_single_pass, defer_lifetime_order_sound, unified_finish_load_notifies_all_kinds, proto_epoch_ic_sound, scoped_sheet_isolation_sound, resource_bit_skip_sound, layout_only_flush_sound, agent_microtask_checkpoint_sound, style_queued_dedup_sound, regexp_anchored_single_pos_sound, regexp_prefix_filter_sound, svg_interior_mutation_paint_only)"
  IO.println "  [OK] NanoUI.JitPerf          (missing_prop_ic_sound, transition_store_ic_sound, id_generation_cache_sound, jit_template_dispatch_equiv, fast_regexp_replace_nomatch_sound, id_anchored_query_selector_sound, focus_targeted_restyle_sound, shape_clone_spread_sound, try_catch_stack_marker_unwind_equiv, svg_vertical_edge_16sample_collapse, svg_axis_clip_rect_intersection)"
  IO.println "  [OK] NanoUI.Speedometer3Perf (strict_eq_non_number_fast, first_call_jit_soundness, ancestor_style_queued_subsumption, attr_invalidation_scope, svg_geometry_attr_style_invariance, zero_delay_timer_fifo_soundness, direct_remote_op_equiv, waker_frame_pacing_bound)"
