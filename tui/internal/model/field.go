package model

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// FieldState is the tri-state (really five-state) tag that travels with
// every value the bash side cannot always determine. Its zero value is
// Known ON PURPOSE — see Field's own comment for why that is safe: nothing
// outside this file constructs a FieldState by zero-valuing it and trusting
// the result without also having decoded (or explicitly set) a value.
type FieldState int

const (
	// Known means V is populated and trustworthy.
	Known FieldState = iota
	// Unknown means the check ran this poll but could not resolve a value
	// (a title-index miss, a timer systemd never listed).
	Unknown
	// NotRun means the check that would populate this field did not
	// execute at all this poll.
	NotRun
	// Errored means the check ran and failed.
	Errored
	// Derived means V was computed from other fields rather than read
	// directly. Reserved for a future judgment field; nothing in the
	// bash side sets it yet.
	Derived
)

// String is the wire spelling used by the bash emitters and documented in
// docs/json-schema.md — lowercase, "notRun" camelCased. It is also what a
// %v/%s of a FieldState prints, so a stray Printf during debugging reads
// the same word the JSON does.
func (s FieldState) String() string {
	switch s {
	case Known:
		return "known"
	case Unknown:
		return "unknown"
	case NotRun:
		return "notRun"
	case Errored:
		return "errored"
	case Derived:
		return "derived"
	default:
		return fmt.Sprintf("FieldState(%d)", int(s))
	}
}

func parseFieldState(s string) (FieldState, error) {
	switch s {
	case "known":
		return Known, nil
	case "unknown":
		return Unknown, nil
	case "notRun":
		return NotRun, nil
	case "errored":
		return Errored, nil
	case "derived":
		return Derived, nil
	default:
		return 0, fmt.Errorf("model: unrecognized field state %q", s)
	}
}

// MarshalJSON emits the same lowercase spelling the bash side reads. Nothing
// in this build re-serializes a Snapshot back to bash, but a FieldState
// sitting inside a value some future caller does log/marshal should not
// silently turn into a bare integer.
func (s FieldState) MarshalJSON() ([]byte, error) {
	return json.Marshal(s.String())
}

// UnmarshalJSON accepts only the wire strings above — an unrecognized state
// is a decode error, never a silent fallback to Known, because a fallback
// there is exactly the "check that did not run rendered as if it passed"
// bug this whole package exists to make impossible.
func (s *FieldState) UnmarshalJSON(b []byte) error {
	var str string
	if err := json.Unmarshal(b, &str); err != nil {
		return fmt.Errorf("model: field state: %w", err)
	}
	v, err := parseFieldState(str)
	if err != nil {
		return err
	}
	*s = v
	return nil
}

// Field wraps a value this build cannot always determine. It is deliberately
// awkward to unwrap: V is reachable directly (Go has no way to forbid that),
// but the zero value of T is never MEANINGFUL without also reading State —
// IsKnown is the one question that answers whether V is trustworthy, and
// theme.RenderField (a later task, in internal/theme) is meant to be the
// only place that prints V without going through it first.
//
// The zero value of Field[T] itself (State == Known, the enum's zero value)
// is intentionally never produced by decoding: UnmarshalJSON always sets an
// explicit state for whatever key it saw, and a KEY THAT NEVER APPEARED AT
// ALL is the containing type's responsibility to pre-seed as NotRun before
// decoding (see Runtime.UnmarshalJSON) — encoding/json does not visit a
// field it found no key for, so nothing else can supply that default.
type Field[T any] struct {
	V     T
	State FieldState
	Note  string
}

// IsKnown reports whether V was actually resolved this poll. Nothing else
// in this package should be trusted to answer that question.
func (f Field[T]) IsKnown() bool {
	return f.State == Known
}

// Known1 builds an already-known Field — for tests and for any future code
// that constructs a Snapshot in Go rather than decoding one. Named Known1,
// not Known, because the constant Known already owns that identifier.
func Known1[T any](v T) Field[T] {
	return Field[T]{V: v, State: Known}
}

// fieldWire mirrors the wrapped wire shape {"value":…, "state":…, "note":…}.
// State is a pointer so the probe below can tell "key present" apart from
// "key absent, decoded to the zero FieldState" — the same ambiguity Field
// itself exists to eliminate, one level up.
type fieldWire[T any] struct {
	Value json.RawMessage `json:"value"`
	State *FieldState     `json:"state"`
	Note  string          `json:"note"`
}

// UnmarshalJSON accepts both shapes the bash emitters use: the wrapped form
// {"value":…,"state":"known"} for anything that can be unmeasurable, and a
// bare value — which decodes as Known — for everything else. A bare JSON
// null (statusAgeSec, when the runtime scan has nothing to report) is its
// own third case: the key was present, so this is not "the check did not
// run" (NotRun), but no value ever came back either, so it decodes as
// Unknown rather than as a Known zero.
func (f *Field[T]) UnmarshalJSON(b []byte) error {
	trimmed := bytes.TrimSpace(b)

	if bytes.Equal(trimmed, []byte("null")) {
		var zero T
		f.V = zero
		f.State = Unknown
		f.Note = ""
		return nil
	}

	if len(trimmed) > 0 && trimmed[0] == '{' {
		var probe fieldWire[T]
		if err := json.Unmarshal(trimmed, &probe); err != nil {
			return fmt.Errorf("model: decoding field: %w", err)
		}
		if probe.State != nil {
			f.State = *probe.State
			f.Note = probe.Note
			valueTrimmed := bytes.TrimSpace(probe.Value)
			if len(valueTrimmed) == 0 || bytes.Equal(valueTrimmed, []byte("null")) {
				var zero T
				f.V = zero
			} else {
				var v T
				if err := json.Unmarshal(probe.Value, &v); err != nil {
					return fmt.Errorf("model: decoding field value: %w", err)
				}
				f.V = v
			}
			return nil
		}
		// An object with no "state" key is not the wrapped form — fall
		// through and decode the whole thing as a bare value of T (T may
		// itself be a struct or map).
	}

	var v T
	if err := json.Unmarshal(trimmed, &v); err != nil {
		return fmt.Errorf("model: decoding field: %w", err)
	}
	f.V = v
	f.State = Known
	return nil
}
