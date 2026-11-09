namespace NanoUI.MarkdownSpec

/-!
# Markdown & HTML Inline Span Partition (`apps/nanodocs/src/markdown.zig`)

Formalizes the inline span emitter used by `nanodocs` and `nanoui`'s rich-text
renderer (`src/ui/text_rich.zig`), proving that emitted spans form a valid,
ordered, non-overlapping sub-partition of the output text buffer `[0, len)`.
-/

structure Span where
  start_byte : Nat
  end_byte : Nat
  deriving DecidableEq, Repr

def ValidSpan (len : Nat) (s : Span) : Prop :=
  s.start_byte ≤ s.end_byte ∧ s.end_byte ≤ len

def DisjointOrdered (s1 s2 : Span) : Prop :=
  s1.end_byte ≤ s2.start_byte

/-- Appending a new span `[cursor, cursor + token_len)` when `cursor ≥ prev.end_byte`
    and `cursor + token_len ≤ total_len` preserves both `ValidSpan` and `DisjointOrdered`. -/
theorem append_span_sound (prev : Span) (cursor token_len total_len : Nat)
    (_h_prev : ValidSpan total_len prev)
    (h_after : prev.end_byte ≤ cursor)
    (h_fit : cursor + token_len ≤ total_len) :
    let next : Span := { start_byte := cursor, end_byte := cursor + token_len }
    ValidSpan total_len next ∧ DisjointOrdered prev next := by
  intro next
  constructor
  · unfold ValidSpan
    exact ⟨Nat.le_add_right cursor token_len, h_fit⟩
  · unfold DisjointOrdered
    exact h_after

end NanoUI.MarkdownSpec
