// Package theme is the adaptive palette and the glyph+word state encoding
// for the TUI. Meaning is never carried by color alone — SSH sessions,
// NO_COLOR, colorblind users and light backgrounds all break a color-only
// signal — so every State (see glyphs.go) renders as a glyph *and* a word,
// and RenderField (see field.go) structurally refuses to print a non-Known
// field as if it were a bare value.
//
// Resolve is pure: it takes the environment values a caller already read as
// plain arguments and never reads os.Getenv or probes the terminal itself.
// That purity is what makes the golden tests in golden_test.go deterministic
// — the same four arguments always produce the same Theme, on any machine.
package theme

import (
	"fmt"
	"io"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// Theme is the fully-resolved rendering configuration: which background
// family to adapt colors for, which glyph set to draw from, and how much
// color the terminal actually supports. It is a plain, comparable value —
// callers are free to construct one directly (tests do) rather than always
// going through Resolve.
type Theme struct {
	Dark    bool
	Glyphs  GlyphSet
	Profile termenv.Profile
}

// Resolve turns the environment values a caller already collected into a
// Theme. It is pure — no globals, no terminal probing — so every decision
// is a plain function of its four arguments:
//
//   - envTheme is CLAUDE_SESSION_THEME ("dark", "light", "auto", or "").
//     An explicit "dark"/"light" always wins, because real background
//     detection over SSH, inside tmux, or under screen routinely fails or
//     lies, and a pure function has no way to query the terminal to check.
//     "auto" (or anything else unrecognized) falls through to the default
//     below; Describe reports whichever value was actually resolved, so a
//     wrong default is visible instead of silently assumed.
//   - lang is the locale string (LANG, or LC_CTYPE if a caller prefers
//     that). Anything that does not look like a UTF-8 locale — LANG=C is
//     the canonical case — selects the ASCII glyph set so a terminal that
//     cannot decode the Unicode glyphs never has to try.
//   - term is $TERM. Combined with isTTY it selects how much color the
//     degrade ladder (TrueColor -> ANSI256 -> ANSI16 -> mono) assumes is
//     safe to emit.
//   - isTTY reports whether output is going to a real terminal at all. A
//     non-TTY (a pipe, a log file) always resolves to the mono profile:
//     nothing here can know what, if anything, will render the escapes on
//     the other end.
//
// NO_COLOR has no argument of its own: it is not a detection question, it
// is an instruction, so a caller that finds it set should override the
// returned Theme's Profile field directly (Theme{... Profile:
// termenv.Ascii}) rather than Resolve trying to guess it from term/isTTY.
// The mono profile this produces is the same one the degrade ladder's
// bottom rung uses, and both are verified by TestNoColorProducesNoEscapes
// to emit no escape sequences at all — the glyph+word table carries the
// whole signal at that point.
func Resolve(envTheme, lang, term string, isTTY bool) Theme {
	return Theme{
		Dark:    resolveDark(envTheme),
		Glyphs:  resolveGlyphs(lang),
		Profile: resolveProfile(term, isTTY),
	}
}

func resolveDark(envTheme string) bool {
	switch strings.ToLower(strings.TrimSpace(envTheme)) {
	case "light":
		return false
	case "dark":
		return true
	default:
		// "auto", "", or any unrecognized value: no signal available to a
		// pure function can tell real background darkness apart from a
		// terminal that simply did not answer, so this defaults to the
		// overwhelmingly common convention (dark) and leans on Describe to
		// make the guess visible rather than pretending it was measured.
		return true
	}
}

func resolveGlyphs(lang string) GlyphSet {
	if isUTF8Locale(lang) {
		return Unicode
	}
	return ASCII
}

func isUTF8Locale(lang string) bool {
	u := strings.ToUpper(lang)
	return strings.Contains(u, "UTF-8") || strings.Contains(u, "UTF8")
}

// resolveProfile maps $TERM and whether output is a TTY onto the four-rung
// degrade ladder. It is deliberately conservative: an unrecognized non-empty
// TERM on a real TTY gets 16-color ANSI rather than being assumed to support
// nothing, but anything not a TTY at all — a pipe, a redirected log — always
// gets mono, since there is no terminal on the other end to interpret color
// at all.
func resolveProfile(term string, isTTY bool) termenv.Profile {
	if !isTTY {
		return termenv.Ascii
	}
	t := strings.ToLower(strings.TrimSpace(term))
	switch {
	case t == "" || t == "dumb":
		return termenv.Ascii
	case strings.Contains(t, "256color"):
		return termenv.ANSI256
	case strings.Contains(t, "direct") || strings.Contains(t, "truecolor") || t == "xterm-kitty":
		return termenv.TrueColor
	default:
		return termenv.ANSI
	}
}

// statePalette gives each State an AdaptiveColor: a Light and a Dark hex, so
// the same call reads correctly on either background. Color here is always
// decoration, never the only signal — Glyph and Word (glyphs.go) already
// carry the full meaning on their own; these colors just make a healthy row
// easier to scan at a glance for the majority of users for whom color does
// carry information.
var statePalette = [...]lipgloss.AdaptiveColor{
	Live:    {Light: "#0F7B0F", Dark: "#3FB950"},
	Stale:   {Light: "#B42318", Dark: "#F85149"},
	Warn:    {Light: "#8A6D00", Dark: "#E3B341"},
	Ok:      {Light: "#0F7B0F", Dark: "#3FB950"},
	NA:      {Light: "#6E7781", Dark: "#8B949E"},
	Unknown: {Light: "#6E7781", Dark: "#8B949E"},
	NotRun:  {Light: "#57606A", Dark: "#6E7681"},
	Derived: {Light: "#0550AE", Dark: "#58A6FF"},
}

func colorFor(s State) lipgloss.AdaptiveColor {
	if s < Live || s > Derived {
		return lipgloss.AdaptiveColor{Light: "#000000", Dark: "#FFFFFF"}
	}
	return statePalette[s]
}

// renderer builds a private lipgloss.Renderer for this Theme's exact Dark
// and Profile values. It is created fresh (writing to io.Discard — nothing
// here ever writes to it, it only drives color math) rather than shared, so
// Style and Selected never depend on, or mutate, any package-level or
// global renderer state: two Themes used concurrently from different
// goroutines cannot interfere with each other, and nothing here probes a
// real terminal (SetColorProfile/SetHasDarkBackground mark the renderer's
// values as explicit, which is precisely what skips that probing).
func (t Theme) renderer() *lipgloss.Renderer {
	r := lipgloss.NewRenderer(io.Discard)
	r.SetColorProfile(t.Profile)
	r.SetHasDarkBackground(t.Dark)
	return r
}

// Style returns the lipgloss.Style for s: its AdaptiveColor resolved against
// this Theme's Dark flag and degraded to this Theme's Profile. Under the
// mono profile (termenv.Ascii) — which is what both the bottom of the
// degrade ladder and an explicit NO_COLOR override use — rendering through
// this Style never emits an escape sequence at all; see
// TestNoColorProducesNoEscapes.
func (t Theme) Style(s State) lipgloss.Style {
	return t.renderer().NewStyle().Foreground(colorFor(s))
}

// Selected marks s as the current row using reverse video rather than a
// filled background: reverse video swaps whatever foreground/background the
// terminal already has, so it is correct on a dark background and a light
// one without this package having to know which it is drawing on top of.
// Like Style, this is a no-op under the mono profile — no escapes, ever,
// when NO_COLOR (or an equivalent lack of color support) applies.
func (t Theme) Selected(s string) string {
	return t.renderer().NewStyle().Reverse(true).Render(s)
}

// Describe reports the Theme's fully-resolved values in one line, meant for
// Help: "what did we decide, and what does that imply." Because Resolve
// cannot truly detect background darkness over SSH/tmux/screen and instead
// defaults, this is what makes a wrong default visible and correctable
// (via CLAUDE_SESSION_THEME) instead of silently wrong.
func (t Theme) Describe() string {
	mode := "light"
	if t.Dark {
		mode = "dark"
	}
	glyphs := "unicode"
	if t.Glyphs == ASCII {
		glyphs = "ascii"
	}
	return fmt.Sprintf("theme=%s glyphs=%s color=%s", mode, glyphs, profileName(t.Profile))
}

func profileName(p termenv.Profile) string {
	switch p {
	case termenv.TrueColor:
		return "truecolor"
	case termenv.ANSI256:
		return "ansi256"
	case termenv.ANSI:
		return "ansi16"
	default:
		return "mono"
	}
}
