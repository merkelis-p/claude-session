package theme

import (
	"fmt"
	"strings"
	"testing"

	"github.com/merkelis-p/claude-session/tui/internal/model"
	"github.com/muesli/termenv"
)

// Every State must render as a distinct glyph AND a distinct word in both
// GlyphSets. Unicode glyphs are pairwise distinct too; ASCII glyphs are not
// required to be (NotRun and Warn deliberately share "!" — see glyphs.go),
// which is exactly why the word must never be dropped.
func TestEveryStateHasADistinctGlyphAndWord(t *testing.T) {
	for _, gs := range []GlyphSet{Unicode, ASCII} {
		th := Theme{Glyphs: gs}
		seenG, seenW := map[string]State{}, map[string]State{}
		for s := Live; s <= Derived; s++ {
			g, w := th.Glyph(s), th.Word(s)
			if g == "" || w == "" {
				t.Fatalf("state %v has an empty glyph or word", s)
			}
			// Unknown, NotRun and n/a must be distinguishable from each
			// other: an empty cell is never produced for a value a row
			// should have.
			if prev, dup := seenW[w]; dup {
				t.Fatalf("states %v and %v share the word %q", prev, s, w)
			}
			seenW[w] = s
			if gs == Unicode {
				if prev, dup := seenG[g]; dup {
					t.Fatalf("states %v and %v share glyph %q", prev, s, g)
				}
				seenG[g] = s
			}
		}
	}
}

// The whole point of tri-state: a check that did not run cannot be printed
// as a value, so this is a test of an impossibility, enumerated over every
// non-Known state.
func TestRenderFieldRefusesNonKnownValues(t *testing.T) {
	th := Theme{Glyphs: ASCII}
	for _, st := range []model.FieldState{model.Unknown, model.NotRun, model.Errored} {
		got := RenderField(th, model.Field[int]{V: 0, State: st}, func(v int) string { return fmt.Sprint(v) })
		if got == "0" || got == "" || got == "-" {
			t.Fatalf("state %v rendered as %q — a non-run check must never look like a value", st, got)
		}
	}
}

// §8.1: the "~" and the label are part of the value — a Derived field must
// never render as if it were a plain, directly-measured one.
func TestDerivedNeverRendersWithoutItsLabel(t *testing.T) {
	for _, gs := range []GlyphSet{Unicode, ASCII} {
		th := Theme{Glyphs: gs}
		got := RenderField(th, model.Field[int]{V: 42, State: model.Derived}, func(v int) string { return fmt.Sprint(v) })
		if !strings.Contains(got, th.Glyph(Derived)) {
			t.Fatalf("derived value %q is missing its %q glyph", got, th.Glyph(Derived))
		}
		if !strings.Contains(got, th.Word(Derived)) {
			t.Fatalf("derived value %q is missing its %q label", got, th.Word(Derived))
		}
		if !strings.Contains(got, "42") {
			t.Fatalf("derived value %q lost the underlying value", got)
		}
		if got == "42" {
			t.Fatalf("derived value rendered as a bare %q, indistinguishable from a Known one", got)
		}
	}
}

// LANG=C (or any non-UTF-8 locale) must select the ASCII glyph set: box
// drawing / bullet-style Unicode glyphs mojibake on a terminal that cannot
// decode them.
func TestASCIIGlyphSetWhenLangIsNotUTF8(t *testing.T) {
	cases := []struct {
		lang string
		want GlyphSet
	}{
		{"C", ASCII},
		{"POSIX", ASCII},
		{"", ASCII},
		{"en_US.ISO-8859-1", ASCII},
		{"en_US.UTF-8", Unicode},
		{"C.UTF-8", Unicode},
		{"ja_JP.utf8", Unicode},
	}
	for _, c := range cases {
		got := Resolve("auto", c.lang, "xterm-256color", true)
		if got.Glyphs != c.want {
			t.Errorf("Resolve with LANG=%q: got Glyphs=%v, want %v", c.lang, got.Glyphs, c.want)
		}
	}
}

// CLAUDE_SESSION_THEME=dark|light must beat whatever the (necessarily
// unreliable, since Resolve cannot probe a terminal) default would have
// been, in both directions; "auto" must fall back to that default.
func TestThemeOverrideBeatsDetection(t *testing.T) {
	dflt := Resolve("auto", "en_US.UTF-8", "xterm-256color", true)

	light := Resolve("light", "en_US.UTF-8", "xterm-256color", true)
	if light.Dark {
		t.Fatalf("CLAUDE_SESSION_THEME=light did not override the resolved theme")
	}
	dark := Resolve("dark", "en_US.UTF-8", "xterm-256color", true)
	if !dark.Dark {
		t.Fatalf("CLAUDE_SESSION_THEME=dark did not override the resolved theme")
	}
	if light.Dark == dark.Dark {
		t.Fatalf("dark and light overrides resolved to the same Dark value")
	}
	auto := Resolve("auto", "en_US.UTF-8", "xterm-256color", true)
	if auto.Dark != dflt.Dark {
		t.Fatalf("auto did not reproduce the default detection result")
	}
	// An unrecognized value must behave like "auto", never like a silent
	// crash or a third, undocumented behavior.
	garbage := Resolve("not-a-real-value", "en_US.UTF-8", "xterm-256color", true)
	if garbage.Dark != dflt.Dark {
		t.Fatalf("unrecognized CLAUDE_SESSION_THEME did not fall back to the default")
	}
}

// NO_COLOR (surfaced as the mono/termenv.Ascii profile — see Resolve's doc
// comment) must produce zero escape sequences from Style or Selected: the
// glyph+word table is the whole signal at that point, not a supplement to
// color.
func TestNoColorProducesNoEscapes(t *testing.T) {
	for _, dark := range []bool{true, false} {
		th := Theme{Dark: dark, Glyphs: ASCII, Profile: termenv.Ascii}
		for s := Live; s <= Derived; s++ {
			out := th.Style(s).Render(th.Glyph(s) + " " + th.Word(s))
			if strings.ContainsRune(out, '\x1b') {
				t.Fatalf("mono theme leaked an escape sequence for state %v: %q", s, out)
			}
		}
		sel := th.Selected(" > selected row ")
		if strings.ContainsRune(sel, '\x1b') {
			t.Fatalf("mono theme leaked an escape sequence from Selected: %q", sel)
		}
	}
}

// Describe must name the values actually resolved, so a wrong background
// guess is visible in Help rather than silently assumed.
func TestDescribeNamesTheResolvedTheme(t *testing.T) {
	cases := []struct {
		th   Theme
		want []string
	}{
		{Theme{Dark: true, Glyphs: Unicode, Profile: termenv.TrueColor}, []string{"dark", "unicode", "truecolor"}},
		{Theme{Dark: false, Glyphs: ASCII, Profile: termenv.ANSI256}, []string{"light", "ascii", "ansi256"}},
		{Theme{Dark: true, Glyphs: ASCII, Profile: termenv.ANSI}, []string{"dark", "ascii", "ansi16"}},
		{Theme{Dark: false, Glyphs: Unicode, Profile: termenv.Ascii}, []string{"light", "unicode", "mono"}},
	}
	for _, c := range cases {
		got := c.th.Describe()
		for _, want := range c.want {
			if !strings.Contains(got, want) {
				t.Errorf("Describe() = %q, missing expected term %q", got, want)
			}
		}
	}
}
