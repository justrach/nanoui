namespace NanoUI.NanomonTemperatures

/-!
# Temperature read filtering and GUI publication protocol

Models `temperature.zig` and `sample_temp_async.zig`. The fold theorem requires
neither real-number arithmetic nor commutative addition: retained sensor values
are combined in the original order, so it applies to IEEE operations as well.
It assumes a supplied sequence of per-sensor observations; it does NOT claim
that independently read physical sensors form an atomic hardware snapshot.

The worker model treats a release/acquire-published Snapshot as one value.
Correct Zig atomics, main-queue serialization, integer/id round trips, and join semantics
remain implementation obligations, covered by deterministic threaded tests.
A private slot write may race stop; the model excludes unobservable stopped
completions, not physical writes. The dead/id guards prevent exposed publication,
and joining is still required before freeing memory.
This is not a verified compiler translation, a liveness theorem for HID calls,
or a guarantee that an OS scheduler can always meet a 120 Hz deadline.
-/

inductive Part where
  | none | cpu | gpu | soc
  deriving DecidableEq

structure Reading (Value : Type) where
  part : Part
  value : Option Value

variable {Value Acc : Type}

def applyReading (combine : Part → Acc → Value → Acc) (a : Acc) (r : Reading Value) : Acc :=
  match r.part, r.value with
  | .none, _ => a
  | _, none => a
  | part, some value => combine part a value

def relevant (r : Reading Value) : Bool := r.part != .none

/-- Discarded reads have no effect, even if their value is absent, NaN, etc. -/
theorem ignored_is_identity (combine : Part → Acc → Value → Acc) (a : Acc)
    (value : Option Value) : applyReading combine a ⟨.none, value⟩ = a := rfl

/-- Filtering unused reads preserves the complete ordered fold, with no
    reassociation, rounding assumption, or assumption that values are finite. -/
theorem filtered_fold_equivalent (combine : Part → Acc → Value → Acc)
    (readings : List (Reading Value)) (a : Acc) :
    (readings.filter relevant).foldl (applyReading combine) a =
      readings.foldl (applyReading combine) a := by
  induction readings generalizing a with
  | nil => rfl
  | cons r rest ih =>
    cases hp : r.part with
    | none => simp [relevant, hp, applyReading, ih]
    | cpu => simpa [relevant, hp] using ih (applyReading combine a r)
    | gpu => simpa [relevant, hp] using ih (applyReading combine a r)
    | soc => simpa [relevant, hp] using ih (applyReading combine a r)

structure State (Value : Type) where
  alive : Bool := true
  pending : Bool := false
  slot : Option Value := none
  latest : Option Value := none
  displayed : Option Value := none
  paused : Bool := false
  workerStarted : Bool := false
  joined : Bool := false

-- Request is the scheduling step AFTER the optional take of an already-ready
-- slot. Actual Worker.request does that take first, then coalesces if busy.
def request (s : State Value) : State Value :=
  if s.alive && !s.pending then { s with pending := true, workerStarted := true } else s

def complete (s : State Value) (value : Value) : State Value :=
  if s.alive && s.pending && s.slot.isNone then { s with slot := some value } else s

def take (s : State Value) : State Value :=
  if s.alive then
    match s.slot with
    | none => s
    | some value => { s with slot := none, latest := some value, pending := false }
  else s

def refresh (s : State Value) : State Value :=
  if s.alive && !s.paused then
    match s.latest with
    | none => s
    | some value => { s with displayed := some value }
  else s

def stop (s : State Value) : State Value := { s with alive := false }

def join (s : State Value) : State Value :=
  if !s.alive then { s with joined := true, pending := false, slot := none } else s

def canFree (s : State Value) : Bool := !s.alive && (!s.workerStarted || s.joined)

/-- Busy requests cannot start a second reader. -/
theorem busy_coalesces (s : State Value) (h : s.pending = true) : request s = s := by
  simp [request, h]

theorem no_request_after_stop (s : State Value) : request (stop s) = stop s := by
  simp [request, stop]

theorem no_completion_after_stop (s : State Value) (value : Value) :
    complete (stop s) value = stop s := by simp [complete, stop]

theorem ready_slot_not_overwritten (s : State Value) (old value : Value)
    (h : s.slot = some old) : complete s value = s := by
  simp [complete, h]

theorem no_publication_after_stop (s : State Value) : take (stop s) = stop s := by
  simp [take, stop]

/-- A blocked/incomplete read exposes neither new nor partial readings. -/
theorem incomplete_keeps_latest (s : State Value) (h : s.slot = none) :
    (take s).latest = s.latest := by simp [take, h]

/-- Publishing a complete snapshot copies precisely that value, never a merge
    of old CPU and new GPU/SoC fields. -/
theorem publication_is_whole (s : State Value) (value : Value)
    (ha : s.alive = true) (hs : s.slot = some value) :
    (take s).latest = some value ∧ (take s).pending = false := by
  simp [take, ha, hs]

theorem completion_does_not_change_display (s : State Value) (value : Value) :
    (complete s value).displayed = s.displayed := by
  unfold complete
  split <;> rfl

theorem pause_preserves_display (s : State Value) (h : s.paused = true) :
    (refresh s).displayed = s.displayed := by simp [refresh, h]

theorem resumed_refresh_uses_latest (s : State Value) (value : Value)
    (ha : s.alive = true) (hp : s.paused = false) (hl : s.latest = some value) :
    (refresh s).displayed = some value := by
  simp [refresh, ha, hp, hl]

theorem no_result_keeps_display (s : State Value) (h : s.latest = none) :
    (refresh s).displayed = s.displayed := by simp [refresh, h]

/-- Stop alone cannot permit freeing memory still reachable by the worker. -/
theorem running_worker_needs_join (s : State Value) (hs : s.workerStarted = true)
    (hj : s.joined = false) : canFree (stop s) = false := by
  simp [canFree, stop, hs, hj]

/-- Teardown prevents publication, joins, retires the id, then frees. -/
theorem teardown_permits_free (s : State Value) : canFree (join (stop s)) = true := by
  simp [canFree, join, stop]

/-- Joining a stopped worker does not resurrect a discarded result. -/
theorem teardown_clears_slot (s : State Value) : (join (stop s)).slot = none := by
  simp [join, stop]

/-- No background work is scheduled simply by displaying/taking a snapshot. -/
theorem display_does_not_schedule (s : State Value) : (refresh s).pending = s.pending := by
  unfold refresh
  split
  · cases s.latest <;> rfl
  · rfl

/-- A queued main wake carries an id, not a potentially freed owner pointer. -/
def lookupId (id : Nat) : List (Nat × Value) → Option Value
  | [] => none
  | (key, value) :: rest => if key = id then some value else lookupId id rest

def retireId (id : Nat) (entries : List (Nat × Value)) : List (Nat × Value) :=
  entries.filter (fun entry => entry.1 != id)

theorem retired_id_not_found (id : Nat) (entries : List (Nat × Value)) :
    lookupId id (retireId id entries) = none := by
  induction entries with
  | nil => rfl
  | cons entry rest ih =>
    by_cases h : entry.1 = id
    · simpa [retireId, h] using ih
    · simpa [retireId, h, lookupId] using ih

/-- The implementation fails before unsigned overflow rather than reusing ids. -/
theorem advancing_id_is_distinct (id : Nat) : id + 1 ≠ id :=
  Nat.ne_of_gt (Nat.lt_succ_self id)

def deliverWake (entries : List (Nat × State Value)) (id : Nat) : Option (State Value) :=
  (lookupId id entries).map take

theorem retired_wake_has_no_target (id : Nat) (entries : List (Nat × State Value)) :
    deliverWake (retireId id entries) id = none := by
  simp [deliverWake, retired_id_not_found]

end NanoUI.NanomonTemperatures
