/-
  NanoUI.IosTouchScroll
  Formal proofs for iOS touch scroll axis selection, slop-free start continuity,
  and 120 Hz ProMotion vs 60 Hz UIScrollView (0.998/ms) deceleration equivalence.
-/

namespace NanoUI.IosTouchScroll

inductive Axis where
  | x
  | y
  deriving DecidableEq, Repr

def touchSlop : Int := 10

/-- Slop-subtracted initial scroll displacement (`scroll_x.scrollStartDelta`). -/
def scrollStartDelta (total : Int) : Int :=
  if total > touchSlop then total - touchSlop
  else if total < -touchSlop then total + touchSlop
  else 0

theorem scrollStartDelta_continuous_at_slop :
    scrollStartDelta touchSlop = 0 ∧ scrollStartDelta (-touchSlop) = 0 := by
  decide

theorem scrollStartDelta_unit_step_past_slop :
    scrollStartDelta (touchSlop + 1) = 1 ∧ scrollStartDelta (-(touchSlop + 1)) = -1 := by
  decide

theorem scrollStartDelta_monotone (a b : Int) (h : a ≤ b) :
    scrollStartDelta a ≤ scrollStartDelta b := by
  unfold scrollStartDelta touchSlop
  split <;> split <;> omega

/-- Pure axis selection (`scroll_x.pickTouchAxis`). -/
def pickTouchAxis (canX canY : Bool) (tx ty : Int) : Option Axis :=
  let ax := Int.natAbs tx
  let ay := Int.natAbs ty
  let hx := canX && decide (ax > 10)
  let hy := canY && decide (ay > 10)
  if hx && hy then
    if ax > ay then some .x else some .y
  else if hx && decide (ax ≥ ay) then
    some .x
  else if hy && decide (ay ≥ ax) then
    some .y
  else
    none

theorem sub_slop_never_scrolls (canX canY : Bool) (tx ty : Int)
    (hx : Int.natAbs tx ≤ 10) (hy : Int.natAbs ty ≤ 10) :
    pickTouchAxis canX canY tx ty = none := by
  unfold pickTouchAxis
  have h1 : decide (Int.natAbs tx > 10) = false := decide_eq_false (by omega)
  have h2 : decide (Int.natAbs ty > 10) = false := decide_eq_false (by omega)
  simp [h1, h2]

theorem nested_row_routes_horizontal_drag_to_x (tx ty : Int)
    (hx : Int.natAbs tx > 10) (hdom : Int.natAbs tx > Int.natAbs ty) :
    pickTouchAxis true true tx ty = some .x := by
  unfold pickTouchAxis
  have h1 : decide (Int.natAbs tx > 10) = true := decide_eq_true hx
  by_cases hy : Int.natAbs ty > 10
  · have h2 : decide (Int.natAbs ty > 10) = true := decide_eq_true hy
    simp [h1, h2, hdom]
  · have h2 : decide (Int.natAbs ty > 10) = false := decide_eq_false hy
    have hge : decide (Int.natAbs tx ≥ Int.natAbs ty) = true := decide_eq_true (by omega)
    simp [h1, h2, hge]

/-- Exact rational numerator/denominator of `0.998^dt_ms = (499/500)^dt_ms`. -/
def decelNum (dtMs : Nat) : Nat := 499 ^ dtMs
def decelDen (dtMs : Nat) : Nat := 500 ^ dtMs

/-- Two 8 ms ProMotion (120 Hz) steps equal one 16 ms (60 Hz) step. -/
theorem promotion_120hz_matches_60hz_decel :
    decelNum 8 * decelNum 8 = decelNum 16 ∧
    decelDen 8 * decelDen 8 = decelDen 16 := by
  decide

end NanoUI.IosTouchScroll
