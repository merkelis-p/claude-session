package model

import (
	"encoding/json"
	"errors"
	"fmt"
)

// SchemaMin and SchemaMax bound the schemaVersion Decode accepts. The
// Makefile injects the bash side's own JSON_SCHEMA_VERSION into
// main.schemaMin/main.schemaMax (package main, not this one — see
// tui/Makefile) for the eventual binary; this package needs its own
// defaults so it decodes correctly on its own (go test ./internal/model/,
// no linker flags involved). 1/1 matches the schema version in
// tests/fixtures/envelope today. They are package-level vars, not
// constants, so a caller that DOES want to override them (main wiring
// them from the injected build-time strings, or a test) can.
var (
	SchemaMin = 1
	SchemaMax = 1
)

// ErrSchemaSkew is the sentinel a schema-version mismatch's error always
// wraps — check for it with errors.Is. The mismatch itself (which version
// was seen, which range was expected) travels on *SchemaSkewError; use
// errors.As to read Got/Want.
var ErrSchemaSkew = errors.New("model: schemaVersion outside the supported range")

// SchemaSkewError carries the specifics of a schema mismatch. Got is the
// schemaVersion the document declared; Want describes the accepted range
// as "min-max" (both bounds collapse to one number, e.g. "1-1", when
// SchemaMin == SchemaMax, which is the common case).
type SchemaSkewError struct {
	Got  int
	Want string
}

func (e *SchemaSkewError) Error() string {
	return fmt.Sprintf("model: schemaVersion %d is outside the supported range %s", e.Got, e.Want)
}

func (e *SchemaSkewError) Unwrap() error { return ErrSchemaSkew }

// DecodeError wraps a JSON parse failure (malformed JSON, or JSON of the
// wrong shape) together with the first 2 KB of the body that failed to
// parse, verbatim, so the Console can show a non-JSON response (an error
// page, a truncated pipe, a stray log line ahead of the document) exactly
// as it arrived rather than just "invalid character '<' looking for
// beginning of value."
type DecodeError struct {
	Err    error
	Prefix string
}

func (e *DecodeError) Error() string {
	return fmt.Sprintf("model: decode envelope: %v", e.Err)
}

func (e *DecodeError) Unwrap() error { return e.Err }

const decodeErrorPrefixLimit = 2048

func firstKB(b []byte) string {
	if len(b) <= decodeErrorPrefixLimit {
		return string(b)
	}
	return string(b[:decodeErrorPrefixLimit])
}

// unmarshalOrWrap is encoding/json.Unmarshal with a package-prefixed error,
// used by the section types' own UnmarshalJSON methods so a decode failure
// three levels into a Chat's runtime object reads as this package's error,
// not a bare "unexpected end of JSON input" with no indication of where.
func unmarshalOrWrap(b []byte, v any) error {
	if err := json.Unmarshal(b, v); err != nil {
		return fmt.Errorf("model: %w", err)
	}
	return nil
}

// envelopeVersionProbe reads only schemaVersion, ignoring every other key —
// Decode's schema check runs against this, never against a fully-decoded
// Snapshot, so a schema-skewed document is rejected before any section (in
// particular, before a section shape this decoder does not understand) is
// ever inspected.
type envelopeVersionProbe struct {
	SchemaVersion int `json:"schemaVersion"`
}

// Decode parses one `_snapshot --json` envelope.
//
// It rejects a schemaVersion outside [SchemaMin, SchemaMax] with an error
// wrapping ErrSchemaSkew (carrying Got/Want via *SchemaSkewError) BEFORE
// looking at sections at all — the version probe below is a separate,
// minimal decode step for exactly that reason.
//
// On any failure it returns the zero Snapshot together with a non-nil
// error; it never returns a partially-populated Snapshot with a nil error,
// because a caller that only checks `err != nil` before trusting the
// result would otherwise be reading a document that was never fully valid.
func Decode(b []byte) (Snapshot, error) {
	var probe envelopeVersionProbe
	if err := json.Unmarshal(b, &probe); err != nil {
		return Snapshot{}, &DecodeError{Err: err, Prefix: firstKB(b)}
	}
	if probe.SchemaVersion < SchemaMin || probe.SchemaVersion > SchemaMax {
		return Snapshot{}, &SchemaSkewError{
			Got:  probe.SchemaVersion,
			Want: schemaRangeText(),
		}
	}

	var snap Snapshot
	if err := json.Unmarshal(b, &snap); err != nil {
		return Snapshot{}, &DecodeError{Err: err, Prefix: firstKB(b)}
	}
	return snap, nil
}

func schemaRangeText() string {
	if SchemaMin == SchemaMax {
		return fmt.Sprintf("%d", SchemaMin)
	}
	return fmt.Sprintf("%d-%d", SchemaMin, SchemaMax)
}

// criticalChecks is spec §6.7's critical list for the chats section — the
// ONE place it lives in this package — paired with the predicate that
// decides whether a given Chat is missing each one. Keeping the name and
// the predicate together in one slice (rather than a name list plus a
// parallel if-chain someone could edit out of sync) is what makes "exactly
// one place" true structurally rather than just by convention.
var criticalChecks = []struct {
	name    string
	missing func(Chat) bool
}{
	{"sessionId", func(c Chat) bool { return c.SessionID == "" }},
	{"account", func(c Chat) bool { return c.Account == "" }},
	{"accountDir", func(c Chat) bool { return c.AccountDir == "" }},
	{"transcriptPath", func(c Chat) bool { return c.TranscriptPath == "" }},
	// runtime.pid / runtime.alive are only critical when a runtime is
	// actually present: a transcript-only chat has no runtime by design,
	// and that absence is not degradation (docs/json-schema.md, "chats").
	{"runtime.pid", func(c Chat) bool { return c.Runtime.Present && c.Runtime.PID == 0 }},
	// Alive is critical-missing only when a present runtime's aliveness was
	// NOT resolved (state unknown/notRun — the wire sent `null` or omitted
	// the key). A resolved `false` is a KNOWN-dead process (a stale session
	// file whose pid is gone), which bash reports as non-degraded — so this
	// must NOT flag it, or the TUI would badge every dead session as
	// "missing data" while bash considers it fine. Field[bool] is what makes
	// dead (Known false) and unresolved (Unknown) distinguishable here; a
	// plain bool collapsed them and produced exactly that disagreement.
	{"runtime.alive", func(c Chat) bool { return c.Runtime.Present && !c.Runtime.Alive.IsKnown() }},
}

// criticalFields is spec §6.7's critical list, in the order CriticalMissing
// checks and reports them — derived from criticalChecks above rather than
// maintained separately, so the two can never drift apart.
var criticalFields = func() []string {
	names := make([]string, len(criticalChecks))
	for i, c := range criticalChecks {
		names[i] = c.name
	}
	return names
}()

// CriticalMissing implements spec §6.7's critical list in exactly one
// place: it names every one of criticalFields that c cannot resolve, in
// that order. A row missing any of them is rendered degraded, with the
// reason — never dropped, because a row that vanishes from the list is
// indistinguishable from a chat that does not exist.
func CriticalMissing(c Chat) []string {
	var missing []string
	for _, check := range criticalChecks {
		if check.missing(c) {
			missing = append(missing, check.name)
		}
	}
	return missing
}
