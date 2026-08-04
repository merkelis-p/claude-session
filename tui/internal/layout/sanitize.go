package layout

import (
	"strings"
	"unicode"

	"github.com/charmbracelet/x/ansi"
	"github.com/mattn/go-runewidth"
)

// Sanitize runs at the BOUNDARY, on every string entering the model — not at
// each render site. Titles come from user prompts and Claude's auto-titles: a
// transcript whose title contains "\033[2J\033[H" would clear the viewer's
// screen, and one containing a bare "\r" could overwrite the line it is
// printed on. Two independent defenses cover this: bash emitters never
// produce ANSI (spec §6.6, enforced by tests/test_json.sh) and the app
// strips anyway.
//
// It runs in two passes. The first removes ANSI CSI ("\x1b[…") and OSC
// ("\x1b]…" terminated by BEL or ST) sequences whole, payload included —
// ansi.Strip understands the escape grammar, so an OSC "set title" sequence
// loses its text argument along with its control bytes, not just the bytes
// that happen to be < 0x20. The second pass is a defensive net over
// whatever that leaves: every remaining C0/C1 control character is either
// given the special handling below (tab, \n, \r) or dropped outright, tabs
// are expanded to the next stop of 8, and any rune Unicode does not
// consider printable — unassigned code points included — becomes "·" so
// the reader can see something was there rather than have it vanish
// silently. Zero-width joiners/non-joiners are the one exception: unlike a
// bidi override they cannot move or hide text, and stripping them would
// break otherwise-ordinary emoji sequences (a ZWJ family emoji, a flag)
// into their separate parts.
func Sanitize(s string) string {
	s = ansi.Strip(s)

	var b strings.Builder
	b.Grow(len(s))
	col := 0
	for _, r := range s {
		switch {
		case r == '\t':
			n := 8 - col%8
			b.WriteString(strings.Repeat(" ", n))
			col += n
		case r == '\n' || r == '\r':
			b.WriteRune('␊')
			col++
		case r == '\u200c' || r == '\u200d':
			// ZWNJ / ZWJ: required for correct emoji and script shaping,
			// harmless unlike bidi overrides. Zero width, so col is
			// unaffected.
			b.WriteRune(r)
		case r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f):
			// Remaining C0 (tab/\n/\r are handled above), DEL, and all C1:
			// these carry no glyph of their own to stand in for, so they are
			// dropped rather than replaced.
		case !unicode.IsPrint(r):
			b.WriteRune('·')
			col++
		default:
			b.WriteRune(r)
			col += runewidth.RuneWidth(r)
		}
	}
	return b.String()
}
