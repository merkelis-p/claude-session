// Package layout is the renderer's structural guarantee: a column
// declaration plus a pure solver, so that "does this row fit the frame" is
// answered in one place instead of re-derived at every call site.
//
// The package is deliberately inert: no terminal, no domain knowledge, no
// imports from the rest of this module. That is what lets it be built,
// tested and fuzzed on its own, and it is enforced by ../arch_test.go.
package layout

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/mattn/go-runewidth"
)

// Align controls which side of a cell absorbs the padding.
type Align int

const (
	Left Align = iota
	Right
)

// TruncSide controls which end of a cell's content is cut when it does not
// fit, and whether it is cut at all.
type TruncSide int

const (
	// TruncRight drops characters from the right and appends "…".
	TruncRight TruncSide = iota
	// TruncLeft drops characters from the left and prefixes "…", keeping the
	// tail of the content (e.g. a path's basename) visible.
	TruncLeft
	// TruncNone leaves content unchanged when it fits. When it does not, it
	// still must not break the frame, so Truncate falls back to TruncRight
	// rather than letting a fixed-width column (an id, say) overflow.
	TruncNone
)

// Column declares one table column. Min and Priority feed Solve; Align and
// Truncate feed Cell. Sticky columns are never dropped by Solve regardless
// of Priority.
type Column struct {
	Key      string
	Title    string
	Min      int
	Flex     int
	Priority int
	Align    Align
	Truncate TruncSide
	Sticky   bool
}

// Width returns the number of terminal cells s occupies: ANSI escape
// sequences are ignored and wide runes (CJK, most emoji) count as two. This
// is lipgloss.Width, exposed under this package's name so nothing here or
// downstream reaches for len() — byte length is wrong for UTF-8 and wrong
// again for ANSI escapes, and the user's data contains both.
func Width(s string) int {
	return lipgloss.Width(s)
}

// cluster is a base rune together with any zero-width runes (combining
// marks, joiners) that must never be separated from it: cutting between a
// base rune and its combining mark would change what the remaining text
// means, not just how much of it survived.
type cluster struct {
	runes []rune
	width int
}

func clusters(s string) []cluster {
	var out []cluster
	for _, r := range s {
		w := runewidth.RuneWidth(r)
		if w == 0 && len(out) > 0 {
			last := &out[len(out)-1]
			last.runes = append(last.runes, r)
			continue
		}
		out = append(out, cluster{runes: []rune{r}, width: w})
	}
	return out
}

func (c cluster) writeTo(b *strings.Builder) {
	for _, r := range c.runes {
		b.WriteRune(r)
	}
}

// Truncate fits s into w cells, cutting on the side named by side and
// marking the cut with "…". Content that already fits is returned
// unchanged — Truncate never adds an ellipsis to a string that did not need
// cutting. w<=0 always yields "". A cut that would otherwise leave a
// one-cell gap before the ellipsis (because the next cluster was too wide
// to fit in what remained) is padded with a space so the result's Width is
// always exactly w, never one short.
//
// The final width is verified against Width (the same ANSI/grapheme-aware
// measure the caller uses to check the invariant), not just against the
// rune-width sum accumulated while walking — the two can disagree for
// exotic sequences (e.g. certain emoji presentation forms), and a truncator
// that only trusts its own accounting could let such a case overflow the
// frame. When they disagree this falls back to a plain "…" padded with
// spaces: unambiguous width, always exactly w.
func Truncate(s string, w int, side TruncSide) string {
	if w <= 0 {
		return ""
	}
	if side == TruncNone {
		if Width(s) <= w {
			return s
		}
		// A fixed-width column that overflows must still not break the
		// frame: fall back to the same guarantee TruncRight gives.
		side = TruncRight
	}
	if Width(s) <= w {
		return s
	}

	target := w - 1 // reserve one cell for the ellipsis
	if target < 0 {
		target = 0
	}
	cs := clusters(s)

	var result string
	if side == TruncLeft {
		result = truncLeft(cs, target)
	} else {
		result = truncRight(cs, target)
	}
	return fitExactly(result, w)
}

func truncRight(cs []cluster, target int) string {
	var b strings.Builder
	cum := 0
	for _, c := range cs {
		if cum+c.width > target {
			break
		}
		c.writeTo(&b)
		cum += c.width
	}
	if cum < target {
		b.WriteString(strings.Repeat(" ", target-cum))
	}
	b.WriteRune('…')
	return b.String()
}

func truncLeft(cs []cluster, target int) string {
	cum := 0
	i := len(cs)
	for i > 0 {
		c := cs[i-1]
		if cum+c.width > target {
			break
		}
		cum += c.width
		i--
	}
	var b strings.Builder
	b.WriteRune('…')
	if cum < target {
		b.WriteString(strings.Repeat(" ", target-cum))
	}
	for _, c := range cs[i:] {
		c.writeTo(&b)
	}
	return b.String()
}

// fitExactly is the final backstop: whatever Width reports, force the
// result to exactly w. In the ordinary case (Width already agrees with the
// rune-width accounting) this is a no-op or a plain pad. In the disagreement
// case it discards the candidate and returns an ellipsis padded with
// spaces — content is lost, but the frame is never broken, and that
// trade-off only ever triggers on pathological input, never on the cases
// this package's own accounting handles correctly.
func fitExactly(s string, w int) string {
	got := Width(s)
	switch {
	case got == w:
		return s
	case got < w:
		return s + strings.Repeat(" ", w-got)
	default:
		if w == 1 {
			return "…"
		}
		return "…" + strings.Repeat(" ", w-1)
	}
}

// Pad grows s to width w by adding spaces on the side opposite a's meaning
// (Left-aligned content is padded on the right, and vice versa). Pad only
// grows: if s is already at least w cells wide it is returned unchanged —
// shrinking is Truncate's job, not Pad's. Cell always truncates first, so
// on the one path any cell actually takes this can't happen.
func Pad(s string, w int, a Align) string {
	if w <= 0 {
		return ""
	}
	cur := Width(s)
	if cur >= w {
		return s
	}
	gap := strings.Repeat(" ", w-cur)
	if a == Right {
		return gap + s
	}
	return s + gap
}

// Cell renders s into a column of exactly w cells: Sanitize strips anything
// that could move the cursor or clear the screen, Truncate makes it fit,
// Pad fills what's left. This is the only path any cell takes — Width(Cell(s,
// w, c)) == w always, for any s and any w > 0 — so a forgotten call site
// cannot reintroduce the overflow this package exists to prevent.
func Cell(s string, w int, c Column) string {
	return Pad(Truncate(Sanitize(s), w, c.Truncate), w, c.Align)
}
