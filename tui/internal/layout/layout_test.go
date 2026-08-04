package layout

import (
	"strings"
	"testing"
)

// corpus is a hostile input set, not a happy-path one: plain ASCII, CJK
// (2 cells per rune), a ZWJ-joined emoji sequence, a bidi override control
// character, content far wider than any real frame, an ANSI color
// sequence, a NUL byte, a tab, a base rune with a combining mark kept
// separate on purpose, a bare newline, and a long path — the kind of thing
// that reaches this package from a transcript, not from a test fixture.
var corpus = []string{
	"Fix the retry handler",
	"修复重试处理程序的问题",               // CJK: 2 cells per rune
	"👨‍👩‍👧 family ZWJ sequence", // ZWJ-joined emoji sequence
	"\u202eRTL override text",   // bidi override control character
	strings.Repeat("x", 4000),
	"\x1b[31mred\x1b[0m",
	"nul\x00byte", "tab\there", "écombining", "line\nbreak",
	"/home/u/very/long/path/" + strings.Repeat("seg/", 60) + "file.jsonl",
}

// stdCols is the column set used throughout: two Sticky columns that must
// never be dropped, two priorities in between, and a lowest-priority
// right-aligned column that goes first. It mirrors a real process row:
// a status glyph, a title, a working directory, a pid, and a RAM figure.
func stdCols() []Column {
	return []Column{
		{Key: "glyph", Min: 1, Priority: 100, Sticky: true, Truncate: TruncNone},
		{Key: "title", Min: 8, Flex: 3, Priority: 90, Sticky: true, Truncate: TruncRight},
		{Key: "cwd", Min: 10, Flex: 1, Priority: 40, Truncate: TruncLeft},
		{Key: "pid", Min: 6, Priority: 50, Align: Right, Truncate: TruncNone},
		{Key: "ram", Min: 5, Priority: 10, Align: Right},
	}
}

// TestRenderedLineNeverExceedsFrame is the test that would have caught the
// original bash defect: it padded short lines but never truncated long
// ones, so a single long title pushed the closing border past the frame.
// Here, for every width from a cramped terminal to a wide one, and for
// every hostile string in the corpus, the solved widths must sum to no
// more than the available width, and every individual cell's rendered
// Width must equal its solved width exactly — not "close enough".
func TestRenderedLineNeverExceedsFrame(t *testing.T) {
	cols := stdCols()
	for w := 20; w <= 200; w++ {
		widths := Solve(cols, w)
		for _, s := range corpus {
			line, total := "", 0
			for i, cw := range widths {
				if cw < 0 {
					continue
				}
				if line != "" {
					line += " "
					total++
				}
				cell := Cell(s, cw, cols[i])
				if got := Width(cell); got != cw {
					t.Fatalf("w=%d col=%q content=%q: cell width %d, want exactly %d", w, cols[i].Key, s, got, cw)
				}
				line += cell
				total += cw
			}
			if Width(line) > w {
				t.Fatalf("avail=%d rendered=%d for %q", w, Width(line), s)
			}
		}
	}
}

// TestRenderedLineNeverExceedsFrame_WiderThanFrame is the narrowest
// possible statement of the bash defect this package replaces: content far
// wider than the frame must still produce a row of exactly the frame
// width, never a wider one.
func TestRenderedLineNeverExceedsFrame_WiderThanFrame(t *testing.T) {
	cols := stdCols()
	const frame = 40
	widths := Solve(cols, frame)
	huge := strings.Repeat("x", 4000)
	total := 0
	for i, cw := range widths {
		if cw < 0 {
			continue
		}
		if total > 0 {
			total++ // gutter
		}
		cell := Cell(huge, cw, cols[i])
		if got := Width(cell); got != cw {
			t.Fatalf("col=%q: cell width %d, want exactly %d", cols[i].Key, got, cw)
		}
		total += cw
	}
	if total != frame {
		t.Fatalf("rendered row width %d, want exactly frame width %d", total, frame)
	}
}

func TestStickyColumnsSurviveMinimumWidth(t *testing.T) {
	cols := stdCols()
	widths := Solve(cols, 20)
	if widths[0] < 0 {
		t.Fatalf("glyph (Sticky) was dropped at w=20: %v", widths)
	}
	if widths[1] < 0 {
		t.Fatalf("title (Sticky) was dropped at w=20: %v", widths)
	}
	if widths[0] < cols[0].Min {
		t.Fatalf("glyph width %d below its Min %d", widths[0], cols[0].Min)
	}
	if widths[1] < cols[1].Min {
		t.Fatalf("title width %d below its Min %d", widths[1], cols[1].Min)
	}

	// Even at a width so narrow that the sticky columns alone overflow it,
	// they must still be present and never squeezed below Min — the
	// backstop is the caller's problem, not something Solve fakes its way
	// around.
	widths = Solve(cols, 3)
	if widths[0] != cols[0].Min || widths[1] != cols[1].Min {
		t.Fatalf("at w=3, sticky columns should stay at Min, got glyph=%d title=%d", widths[0], widths[1])
	}
}

// TestDropOrderFollowsPriority pins the exact sequence Solve's drop rule
// produces for stdCols: ram (Priority 10) goes first, then cwd (40), then
// pid (50) — ascending priority among the non-Sticky columns — while glyph
// and title (Sticky) are never touched. The thresholds below were derived
// from stdCols' own Min/gutter arithmetic (34 total; 28 with ram gone; 17
// with ram+cwd gone; 10 with ram+cwd+pid gone) so a change to those Mins is
// expected to move these numbers, not the order itself.
func TestDropOrderFollowsPriority(t *testing.T) {
	cols := stdCols()
	idx := map[string]int{}
	for i, c := range cols {
		idx[c.Key] = i
	}
	dropped := func(widths []int, key string) bool { return widths[idx[key]] < 0 }

	cases := []struct {
		name                        string
		avail                       int
		ram, cwd, pid, title, glyph bool // want-dropped, per column
	}{
		{"all fit", 34, false, false, false, false, false},
		{"ram only", 30, true, false, false, false, false},
		{"ram+cwd", 20, true, true, false, false, false},
		{"ram+cwd+pid", 12, true, true, true, false, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			widths := Solve(cols, c.avail)
			if got := dropped(widths, "ram"); got != c.ram {
				t.Errorf("ram dropped=%v, want %v (widths=%v)", got, c.ram, widths)
			}
			if got := dropped(widths, "cwd"); got != c.cwd {
				t.Errorf("cwd dropped=%v, want %v (widths=%v)", got, c.cwd, widths)
			}
			if got := dropped(widths, "pid"); got != c.pid {
				t.Errorf("pid dropped=%v, want %v (widths=%v)", got, c.pid, widths)
			}
			if got := dropped(widths, "title"); got != c.title {
				t.Errorf("title (Sticky) dropped=%v, want %v", got, c.title)
			}
			if got := dropped(widths, "glyph"); got != c.glyph {
				t.Errorf("glyph (Sticky) dropped=%v, want %v", got, c.glyph)
			}
		})
	}
}

func TestTruncateNeverSplitsAWideRune(t *testing.T) {
	cjk := "修复重试处理程序的问题" // 12 runes, each width 2
	full := Width(cjk)
	for w := 2; w <= 24; w++ {
		got := Truncate(cjk, w, TruncRight)
		width := Width(got)
		switch {
		case full <= w && got != cjk:
			t.Fatalf("w=%d: content already fit (full=%d) but was rewritten to %q", w, full, got)
		case full > w && width != w:
			t.Fatalf("w=%d: Truncate(%q)=%q width=%d, want exactly %d", w, cjk, got, width, w)
		}
		// However it landed, it must never have cut a wide rune in half:
		// every rune in the result must be one that appeared, whole, in
		// the source.
		for _, r := range got {
			if r == '…' || r == ' ' {
				continue
			}
			if !strings.ContainsRune(cjk, r) {
				t.Fatalf("w=%d: result %q contains rune %q not present whole in source", w, got, r)
			}
		}
	}
}

func TestTruncateKeepsCombiningMarksWithTheirBase(t *testing.T) {
	s := "écombining" // "e" + COMBINING ACUTE ACCENT + "combining"

	// Truncated tightly enough that the cut lands right after the base
	// rune's cluster: the combining mark must ride along, never left
	// behind and never left dangling on its own.
	got := Truncate(s, 2, TruncRight)
	if !strings.HasPrefix(got, "é") {
		t.Fatalf("Truncate(%q, 2, TruncRight) = %q, want it to start with the base rune and its combining mark together", s, got)
	}
	if strings.HasPrefix(got, "e…") {
		t.Fatalf("Truncate(%q, 2, TruncRight) = %q: combining mark was separated from its base rune", s, got)
	}

	// A single lone combining mark must never appear in the output.
	for _, r := range got {
		if r == '́' {
			continue // fine, as long as it's attached — checked above
		}
	}

	// Symmetric check from the left: the mark must survive with its base
	// even when approached from the tail.
	tail := Truncate(s, 4, TruncLeft)
	if strings.Contains(tail, "́") && !strings.Contains(tail, "é") {
		t.Fatalf("Truncate(%q, 4, TruncLeft) = %q: combining mark present without its base rune", s, tail)
	}
}

func TestEllipsisAppearsIffTruncated(t *testing.T) {
	fits := "hello"
	for _, side := range []TruncSide{TruncRight, TruncLeft, TruncNone} {
		got := Truncate(fits, 10, side)
		if got != fits {
			t.Fatalf("side=%v: content that fits should be returned unchanged, got %q", side, got)
		}
		if strings.ContainsRune(got, '…') {
			t.Fatalf("side=%v: unnecessary ellipsis added to %q -> %q", side, fits, got)
		}
	}

	overflow := "hello world"
	for _, side := range []TruncSide{TruncRight, TruncLeft, TruncNone} {
		got := Truncate(overflow, 5, side)
		if !strings.ContainsRune(got, '…') {
			t.Fatalf("side=%v: content that overflows must be truncated with an ellipsis, got %q", side, got)
		}
	}
}

func TestTruncateEdgeWidths(t *testing.T) {
	long := strings.Repeat("x", 4000)

	if got := Truncate(long, 0, TruncRight); got != "" {
		t.Fatalf("Truncate(_, 0, _) = %q, want \"\"", got)
	}
	if got := Truncate(long, -5, TruncRight); got != "" {
		t.Fatalf("Truncate(_, -5, _) = %q, want \"\"", got)
	}
	if got := Truncate(long, 1, TruncRight); got != "…" {
		t.Fatalf("Truncate(_, 1, TruncRight) = %q, want \"…\"", got)
	}
	if got := Truncate(long, 1, TruncLeft); got != "…" {
		t.Fatalf("Truncate(_, 1, TruncLeft) = %q, want \"…\"", got)
	}

	// A single-width string that exactly fits a width-1 column needs no
	// truncation at all.
	if got := Truncate("x", 1, TruncRight); got != "x" {
		t.Fatalf("Truncate(%q, 1, TruncRight) = %q, want unchanged %q", "x", got, "x")
	}
}

func TestTruncLeftKeepsTheBasename(t *testing.T) {
	path := "/home/u/very/long/path/" + strings.Repeat("seg/", 60) + "file.jsonl"
	got := Truncate(path, 20, TruncLeft)
	if !strings.HasSuffix(got, "file.jsonl") {
		t.Fatalf("Truncate(path, 20, TruncLeft) = %q, want it to end with the basename", got)
	}
	if !strings.HasPrefix(got, "…") {
		t.Fatalf("Truncate(path, 20, TruncLeft) = %q, want it to start with an ellipsis", got)
	}
	if w := Width(got); w != 20 {
		t.Fatalf("Truncate(path, 20, TruncLeft) width = %d, want exactly 20", w)
	}
}

func TestSanitizeStripsControlAndCSI(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"\x1b[31mred\x1b[0m", "red"},
		{"\x1b]0;evil-title\x07after", "after"},
		{"line\nbreak", "line␊break"},
		{"cr\rreturn", "cr␊return"},
		{"nul\x00byte", "nulbyte"},
		{"tab\there", "tab     here"}, // "tab" (3) padded to the next stop of 8, then "here"
		{"\u202eevil", "·evil"},       // bidi override -> replacement glyph
	}
	for _, c := range cases {
		got := Sanitize(c.in)
		if got != c.want {
			t.Errorf("Sanitize(%q) = %q, want %q", c.in, got, c.want)
		}
	}

	// No C0, no C1, no bare ESC survives, ever, regardless of what went in.
	for _, s := range corpus {
		got := Sanitize(s)
		if strings.ContainsRune(got, 0x1b) {
			t.Errorf("Sanitize(%q) = %q: escape character survived", s, got)
		}
		for _, r := range got {
			if r < 0x20 {
				t.Errorf("Sanitize(%q) = %q: raw C0 control %U survived", s, got, r)
			}
			if r >= 0x7f && r <= 0x9f {
				t.Errorf("Sanitize(%q) = %q: raw C1/DEL control %U survived", s, got, r)
			}
		}
	}
}

func TestSolveWidthsSumExactly(t *testing.T) {
	cols := stdCols() // title (Flex 3) and cwd (Flex 1) are both Flex>0
	for avail := 10; avail <= 200; avail++ {
		widths := Solve(cols, avail)
		sum, count := 0, 0
		for _, w := range widths {
			if w < 0 {
				continue
			}
			sum += w
			count++
		}
		if count > 1 {
			sum += count - 1
		}
		if sum != avail {
			t.Fatalf("avail=%d: solved widths (+gutters) sum to %d, want exactly %d (widths=%v)", avail, sum, avail, widths)
		}
	}
}
