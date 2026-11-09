namespace NanoUI.RetainedScroll

/-!
# Retained Scroll Scene Equivalence (`src/ui/retain.zig`)

Proves two key properties of `nanoui`'s retained scroll fast path:
1. **Translation Equivalence**: Layout places a scroll child with natural offset `y0`
   at `y0 - prev` in frame 0 and `y0 - next` in frame 1. Shifting the retained
   instance by `dy = next - prev` (`y_shifted = (y0 - prev) - (next - prev)`) is
   identically equal to `y0 - next` over `Int`.
2. **Full-Width Hit Preservation (Issue #115)**: Shifting all subtree hit rectangles
   without a right-edge `x` cutoff preserves hit testing across the entire width of
   the scroll container, including right-aligned action buttons.
-/

def layoutY (y0 : Int) (scroll_y : Int) : Int :=
  y0 - scroll_y

def shiftedY (y_prev : Int) (prev : Int) (next : Int) : Int :=
  y_prev - (next - prev)

/-- Theorem 1: Shifting the previous frame's laid-out y coordinate by `dy = next - prev`
    produces the exact same y coordinate as running a full layout pass at `next`. -/
theorem retained_shift_matches_full_layout (y0 prev next : Int) :
    shiftedY (layoutY y0 prev) prev next = layoutY y0 next := by
  unfold shiftedY layoutY
  omega

/-- Theorem 2: Two consecutive retained scroll shifts by `prev -> mid` and `mid -> next`
    compose to a single shift `prev -> next` without drift. -/
theorem retained_shift_composes (y0 prev mid next : Int) :
    shiftedY (shiftedY (layoutY y0 prev) prev mid) mid next = layoutY y0 next := by
  unfold shiftedY layoutY
  omega

structure HitRect where
  x : Int
  y : Int
  w : Int
  h : Int
  in_subtree : Bool
  deriving DecidableEq, Repr

def containsPoint (r : HitRect) (px py : Int) : Bool :=
  decide (r.x ≤ px ∧ px < r.x + r.w ∧ r.y ≤ py ∧ py < r.y + r.h)

def shiftHit (r : HitRect) (dy : Int) : HitRect :=
  if r.in_subtree then { r with y := r.y - dy } else r

/-- Theorem 3 (Issue #115): Any subtree hit rect—including a right-aligned button at
    `x >= view_right - 12`—contains `(px, py - dy)` after `shiftHit r dy` if and only if
    it contained `(px, py)` before scrolling. -/
theorem subtree_hit_invariant_at_all_x (r : HitRect) (px py dy : Int)
    (h_sub : r.in_subtree = true) :
    containsPoint (shiftHit r dy) px (py - dy) = containsPoint r px py := by
  unfold shiftHit containsPoint
  have h_y1 : (r.y - dy ≤ py - dy) ↔ (r.y ≤ py) := by omega
  have h_y2 : (py - dy < r.y - dy + r.h) ↔ (py < r.y + r.h) := by omega
  simp [h_sub, h_y1, h_y2]

end NanoUI.RetainedScroll
