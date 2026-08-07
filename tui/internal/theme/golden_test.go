package theme

import (
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/muesli/termenv"
)

// update regenerates the golden fixtures under testdata/golden instead of
// checking against them. Run with:
//
//	go test ./internal/theme/ -run TestGoldenPalettesAcrossProfiles -update
var update = flag.Bool("update", false, "update golden files in testdata/golden")

// goldenCase is one point in the profile x background grid the degrade
// ladder has to stay legible across: TrueColor, ANSI256, ANSI16 (termenv's
// ANSI) and mono (termenv's Ascii, also what NO_COLOR resolves to), each
// against a dark and a light background.
var goldenCases = []struct {
	name    string
	profile termenv.Profile
}{
	{"truecolor", termenv.TrueColor},
	{"ansi256", termenv.ANSI256},
	{"ansi16", termenv.ANSI},
	{"mono", termenv.Ascii},
}

// renderGolden dumps every state's styled glyph+word line, then a reverse
// video Selected row, for one Theme. It always uses the Unicode glyph set:
// the ASCII fallback is exercised by TestEveryStateHasADistinctGlyphAndWord
// and TestASCIIGlyphSetWhenLangIsNotUTF8 instead, so this file is about
// color legibility, not glyph selection.
func renderGolden(th Theme) string {
	var b strings.Builder
	b.WriteString(th.Describe())
	b.WriteString("\n\n")
	for s := Live; s <= Derived; s++ {
		b.WriteString(th.Style(s).Render(th.Glyph(s) + " " + th.Word(s)))
		b.WriteString("\n")
	}
	b.WriteString("\n")
	b.WriteString(th.Selected(" > selected row "))
	b.WriteString("\n")
	return b.String()
}

func goldenPath(name string) string {
	return filepath.Join("testdata", "golden", name+".txt")
}

// TestGoldenPalettesAcrossProfiles proves legibility (a distinct escape
// sequence per state, a reverse-video selected row) is reproduced exactly
// across TrueColor/ANSI256/ANSI16/mono, each on a dark and a light
// background — eight fixed points, none of which depend on the machine
// running the test, because Theme is constructed directly rather than
// through Resolve.
func TestGoldenPalettesAcrossProfiles(t *testing.T) {
	for _, gc := range goldenCases {
		for _, dark := range []bool{true, false} {
			bg := "light"
			if dark {
				bg = "dark"
			}
			name := gc.name + "_" + bg
			th := Theme{Dark: dark, Glyphs: Unicode, Profile: gc.profile}
			got := renderGolden(th)
			path := goldenPath(name)

			if *update {
				if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
					t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
				}
				if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
					t.Fatalf("writing golden %s: %v", path, err)
				}
				continue
			}

			want, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("reading golden %s: %v (run with -update to create it)", path, err)
			}
			if got != string(want) {
				t.Errorf("golden %s mismatch:\n got=%q\nwant=%q", name, got, string(want))
			}
		}
	}
}
