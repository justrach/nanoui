namespace NanoUI.NanomonRankings

/-!
# Nanomon's top-process cache

The optimization does NOT change selection, floating-point comparisons, tie
order, or rendering. It memoizes the original selector for an unchanged ordered
source and the exact (metric, output-capacity) key. This file proves that cache
protocol for an arbitrary selector, so no assumption about IEEE NaNs or sorting
is needed. Zig differential tests connect it to the actual selector and lifecycle.

This is a mathematical model, not extraction/verification of Zig machine code.
The crucial application obligation is to invalidate before any query observes a
new sample, a late refill, changed process fields, or a different source order.
App.order does so; tests exercise those paths. Frame rate is measured, not proved.
-/

structure Key where
  metric : Nat
  capacity : Nat
  deriving DecidableEq

structure State (Source Result : Type) where
  source : Source
  entries : Key → Option Result

variable {Source Result : Type}
variable (select : Source → Key → Result)

def empty (source : Source) : State Source Result := ⟨source, fun _ => none⟩

def Valid (s : State Source Result) : Prop :=
  ∀ key result, s.entries key = some result → result = select s.source key

-- Changing/reordering the source invalidates ALL metrics, not just the active
-- page. In Zig entries hold borrowed strings; old values must never be read.
def replaceSource (_s : State Source Result) (source : Source) : State Source Result :=
  empty source

def query (s : State Source Result) (key : Key) : Result × State Source Result :=
  match s.entries key with
  | some result => (result, s)
  | none =>
    let result := select s.source key
    (result, ⟨s.source, fun k => if k = key then some result else s.entries k⟩)

theorem empty_valid (source : Source) : Valid select (empty (Result := Result) source) := by
  intro key result h
  simp [empty] at h

theorem replacement_valid (s : State Source Result) (source : Source) :
    Valid select (replaceSource s source) := empty_valid select source

/-- Hits and misses return exactly the original selector's result. -/
theorem query_correct (s : State Source Result) (key : Key) (h : Valid select s) :
    (query select s key).1 = select s.source key := by
  cases he : s.entries key with
  | none => simp [query, he]
  | some result => simpa [query, he] using h key result he

/-- A miss establishes validity; a hit preserves it. -/
theorem query_preserves_valid (s : State Source Result) (key : Key) (h : Valid select s) :
    Valid select (query select s key).2 := by
  cases he : s.entries key with
  | some result => simpa [query, he] using h
  | none =>
    intro k result hk
    simp only [query, he] at hk ⊢
    by_cases eq : k = key
    · simpa [eq] using hk.symm
    · exact h k result (by simpa [eq] using hk)

/-- Output capacity is part of the key, not merely a prefix of another result.
    This matters for preserving the legacy selector's unusual IEEE NaN behavior. -/
theorem different_capacities_are_different_keys (m a b : Nat) (h : a ≠ b) :
    (Key.mk m a) ≠ (Key.mk m b) := by
  intro eq
  exact h (congrArg Key.capacity eq)

/-- A query records its result under the exact key. -/
theorem query_populates (s : State Source Result) (key : Key) (h : Valid select s) :
    (query select s key).2.entries key = some (select s.source key) := by
  cases he : s.entries key with
  | none => simp [query, he]
  | some result => simpa [query, he] using congrArg some (h key result he)

/-- Once populated, the next request is a hit (no selection computation). -/
theorem repeat_is_hit (s : State Source Result) (key : Key) (h : Valid select s) :
    query select (query select s key).2 key =
      (select s.source key, (query select s key).2) := by
  have filled := query_populates select s key h
  generalize hnext : (query select s key).2 = next at filled ⊢
  simp only [query, filled]

inductive Event (Source : Type) where
  | replace : Source → Event Source
  | request : Key → Event Source

def step (s : State Source Result) (event : Event Source) : State Source Result :=
  match event with
  | .replace source => replaceSource s source
  | .request key => (query select s key).2

/-- The invariant is established from an empty cache and preserved across any
    finite sequence of source replacements and requests, not just assumed for hits. -/
theorem trace_valid (events : List (Event Source)) (s : State Source Result)
    (h : Valid select s) : Valid select (events.foldl (step select) s) := by
  induction events generalizing s with
  | nil => exact h
  | cons event rest ih =>
    apply ih
    cases event with
    | replace source => exact replacement_valid select s source
    | request key => exact query_preserves_valid select s key h

/-- End-to-end correctness from initialization, without a validity hypothesis
    supplied by the caller: any trace followed by any request equals recomputation. -/
theorem arbitrary_trace_query_correct (initial : Source) (events : List (Event Source))
    (key : Key) :
    let s := events.foldl (step select) (empty (Result := Result) initial)
    (query select s key).1 = select s.source key := by
  apply query_correct
  exact trace_valid select events (empty initial) (empty_valid select initial)

/-- Clearing the source really clears cached rows, including removed processes. -/
theorem replacement_has_no_entries (s : State Source Result) (source : Source) (key : Key) :
    (replaceSource s source).entries key = none := rfl

/-- Requests larger than the fixed Zig cache use the selector directly. -/
def boundedQuery (limit : Nat) (s : State Source Result) (key : Key) : Result :=
  if key.capacity ≤ limit then (query select s key).1 else select s.source key

theorem bounded_query_correct (limit : Nat) (s : State Source Result) (key : Key)
    (h : Valid select s) : boundedQuery select limit s key = select s.source key := by
  unfold boundedQuery
  split
  · exact query_correct select s key h
  · rfl

end NanoUI.NanomonRankings
