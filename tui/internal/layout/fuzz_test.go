package layout

import (
	"strings"
	"testing"
)

// FuzzTruncate is seeded with the hostile corpus and hunts for any input
// that makes Truncate either overflow the requested width or leak a raw
// escape character through. Both would defeat the point of this package.
func FuzzTruncate(f *testing.F) {
	for _, s := range corpus {
		f.Add(s, 12)
	}
	f.Fuzz(func(t *testing.T, s string, w int) {
		if w < 0 || w > 400 {
			t.Skip()
		}
		got := Truncate(Sanitize(s), w, TruncRight)
		if Width(got) > w {
			t.Fatalf("Width(%q)=%d > w=%d", got, Width(got), w)
		}
		if strings.ContainsRune(got, 0x1b) {
			t.Fatalf("escape survived: %q", got)
		}
	})
}

// FuzzSanitize hunts for any input that leaves a raw C0, C1 or CSI-introducer
// byte in Sanitize's output. This is the property that makes it safe to run
// on untrusted text at the boundary rather than at every render site.
func FuzzSanitize(f *testing.F) {
	for _, s := range corpus {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		got := Sanitize(s)
		for _, r := range got {
			if r == 0x1b {
				t.Fatalf("Sanitize(%q) = %q: ESC survived", s, got)
			}
			if r < 0x20 {
				// Sanitize replaces \n/\r with ␊ and expands tabs, so no
				// raw C0 control -- including a bare ESC -- should ever
				// survive into its output.
				t.Fatalf("Sanitize(%q) = %q: raw C0 control %U survived", s, got, r)
			}
			if r >= 0x7f && r <= 0x9f {
				t.Fatalf("Sanitize(%q) = %q: raw C1/DEL control %U survived", s, got, r)
			}
		}
	})
}
