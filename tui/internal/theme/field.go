package theme

import "github.com/merkelis-p/claude-session/tui/internal/model"

// RenderField is the only place meant to unwrap a model.Field[T] into text.
// It is structured so that printing a non-Known field as a bare value is
// not a bug that could be introduced by a careless call site — it is not
// expressible at all: format(f.V) is reachable from exactly one branch, the
// Known one, and every other branch returns a glyph+word string that cannot
// be confused with a real value (never "", never "-", never a formatted
// zero value like "0").
func RenderField[T any](t Theme, f model.Field[T], format func(T) string) string {
	switch f.State {
	case model.Known:
		return format(f.V)
	case model.Derived:
		// V is meaningful here — it really was computed — so it is shown,
		// but always behind the "~" glyph and its "derived" word (§8.1):
		// the label is part of the value, not a footnote next to it, so a
		// derived number is never mistaken for one that was measured
		// directly.
		return withNote(t.Glyph(Derived)+" "+t.Word(Derived)+" "+format(f.V), f.Note)
	case model.Unknown:
		return withNote(t.Glyph(Unknown)+" "+t.Word(Unknown), f.Note)
	case model.NotRun:
		return withNote(t.Glyph(NotRun)+" "+t.Word(NotRun), f.Note)
	case model.Errored:
		// §9.6 has no dedicated row for "the check ran and failed" — it is
		// a model.FieldState, not a theme.State. This borrows Stale's
		// glyph (a failure reads the same whether the thing being reported
		// on stopped or the check itself did) paired with its own word, so
		// it is never mistaken for an actual Stale reading.
		return withNote(t.Glyph(Stale)+" errored", f.Note)
	default:
		// A FieldState this package does not know about yet must still
		// never fall through to a bare value.
		return withNote(t.Glyph(Unknown)+" "+t.Word(Unknown), f.Note)
	}
}

// withNote appends a caller's diagnostic note in parentheses when present.
// It never changes whether the result looks like a bare value — base is
// always already a glyph+word string by the time it reaches here.
func withNote(base, note string) string {
	if note == "" {
		return base
	}
	return base + " (" + note + ")"
}
