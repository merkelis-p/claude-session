package theme

// State is the shared vocabulary every renderer in this program draws from,
// whether the cell is reporting a domain fact ("is this process alive") or a
// field's own provenance ("did this check even run"). Keeping both kinds of
// meaning on one enum, with one glyph+word table (§9.6), is what lets a user
// learn the visual language once and reuse it everywhere instead of
// re-learning a second vocabulary for "the data about the data."
type State int

const (
	// Live means the thing being observed is currently running/fresh.
	Live State = iota
	// Stale means the thing being observed has stopped or aged out.
	Stale
	// Warn means a caller-defined condition wants attention. Word returns a
	// generic fallback ("warn") for this state; real call sites render the
	// caller's own flag word next to Glyph(Warn) instead of Word(Warn) — see
	// Word's doc comment.
	Warn
	// Ok means a check ran and the result is nominal.
	Ok
	// NA means the field structurally does not apply to this row (not that
	// it failed to be read — see Unknown for that).
	NA
	// Unknown means a check ran this poll but could not resolve a value.
	Unknown
	// NotRun means the check that would populate this field did not execute
	// at all this poll.
	NotRun
	// Derived means the value was computed from other fields rather than
	// read directly.
	Derived
)

// GlyphSet selects which character set Glyph draws from. ASCII exists so a
// non-UTF-8 locale (LANG=C and friends) never has to render a Unicode glyph
// it cannot decode correctly.
type GlyphSet int

const (
	Unicode GlyphSet = iota
	ASCII
)

// glyphRow is one line of the §9.6 table: State | Unicode | ASCII | Word.
// This is the single definition every renderer reads — nothing in this
// package or any caller should hardcode a glyph or word outside this table.
type glyphRow struct {
	unicode string
	ascii   string
	word    string
}

// glyphTable is §9.6, verbatim. Index by State.
//
// NotRun's ASCII glyph ("!") intentionally collides with Warn's ASCII glyph —
// that collision is exactly why the word must always accompany the glyph,
// never stand alone. The words themselves stay distinct (enforced by
// TestEveryStateHasADistinctGlyphAndWord), so the pair (glyph, word) is
// always enough to tell the two apart even where the bare glyph is not.
var glyphTable = [...]glyphRow{
	Live:    {unicode: "●", ascii: "*", word: "live"},
	Stale:   {unicode: "✕", ascii: "x", word: "stale"},
	Warn:    {unicode: "○", ascii: "!", word: "warn"},
	Ok:      {unicode: "✓", ascii: "+", word: "ok"},
	NA:      {unicode: "—", ascii: "-", word: "n/a"},
	Unknown: {unicode: "?", ascii: "?", word: "unknown"},
	NotRun:  {unicode: "!", ascii: "!", word: "not checked"},
	Derived: {unicode: "~", ascii: "~", word: "derived"},
}

// invalidRow is what Glyph/Word fall back to for a State outside the table.
// Nothing in this package produces such a State, but a renderer indexing
// with a bad value should get an obviously-wrong placeholder, never a panic
// and never something that could pass for a real glyph or word.
var invalidRow = glyphRow{unicode: "?", ascii: "?", word: "invalid state"}

func rowFor(s State) glyphRow {
	if s < Live || s > Derived {
		return invalidRow
	}
	return glyphTable[s]
}

// Glyph returns the single-character marker for s, from the Unicode or
// ASCII column depending on t.Glyphs. It is never empty for a valid State.
func (t Theme) Glyph(s State) string {
	row := rowFor(s)
	if t.Glyphs == ASCII {
		return row.ascii
	}
	return row.unicode
}

// Word returns the word that must always accompany Glyph — the glyph alone
// is never sufficient (see NotRun's ASCII collision with Warn above), so
// nothing in this package renders one without the other.
//
// For Warn specifically this returns a generic fallback ("warn"): the real
// flag word is a caller-supplied string (a timer's own failure reason, a
// scrape's own error class), which is not something a State constant can
// carry. Call sites rendering an actual Warn condition should pair
// Glyph(Warn) with their own flag word rather than Word(Warn); Word(Warn)
// exists so Warn still has a distinct, non-empty default when nothing more
// specific is available (and so it participates in the distinctness
// guarantee like every other state).
func (t Theme) Word(s State) string {
	return rowFor(s).word
}
