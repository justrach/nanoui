namespace NanoUI.BuildSplit

/-!
# Precompiled Runtime Split (`src/rt.zig` / `libnanoui-rt.a`)

Formalizes why splitting `nanoui` into a precompiled static runtime archive
`libnanoui-rt.a` (cost `R > 0`) and a thin view compilation unit `app_zcu.o`
(cost `V`) strictly reduces 1-line-edit rebuild time compared to monolithic
compilation (`V + R + L` vs `V + L`).
-/

structure BuildCosts where
  view_ms : Nat
  runtime_ms : Nat
  link_ms : Nat
  deriving DecidableEq, Repr

def monolithicRebuildMs (c : BuildCosts) : Nat :=
  c.view_ms + c.runtime_ms + c.link_ms

def splitRebuildMs (c : BuildCosts) : Nat :=
  c.view_ms + c.link_ms

/-- Theorem: For any non-zero runtime compilation cost (`runtime_ms > 0`),
    the split rebuild (`libnanoui-rt.a` cached) is strictly faster than the
    monolithic rebuild by exactly `runtime_ms`. -/
theorem split_rebuild_strictly_faster (c : BuildCosts) (h_rt : c.runtime_ms > 0) :
    splitRebuildMs c < monolithicRebuildMs c ∧
    monolithicRebuildMs c - splitRebuildMs c = c.runtime_ms := by
  unfold splitRebuildMs monolithicRebuildMs
  omega

end NanoUI.BuildSplit
