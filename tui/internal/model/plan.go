package model

import "encoding/json"

// Plan is the preview a mutating command emits before it acts: what it
// would touch, what it would do, what would be lost, and — for anything
// destructive enough to need one — the confirmation or refusal that stands
// between "planned" and "executed." No bash-side emitter for this exists
// yet; the shape here is what a future `--plan` mode is expected to
// produce, decoded the same way the envelope is (schema-checked first,
// never a partial value with a nil error).
type Plan struct {
	SchemaVersion int            `json:"schemaVersion"`
	Mutation      string         `json:"mutation"`
	Argv          []string       `json:"argv"`
	Target        Target         `json:"target"`
	Effects       []Effect       `json:"effects"`
	WillLose      []string       `json:"willLose"`
	Confirmations []Confirmation `json:"confirmations"`
	Refusals      []Refusal      `json:"refusals"`
	Warnings      []string       `json:"warnings"`
}

// Target names what a Plan's mutation acts on. Kind selects which of the
// other fields is populated ("chat" -> SessionID/Account, "account" ->
// Account, "schedule" -> ScheduleID), the same discriminated-union pattern
// ScheduleEntry.Target already uses on the envelope side.
type Target struct {
	Kind       string `json:"kind"`
	SessionID  string `json:"sessionId"`
	Account    string `json:"account"`
	ScheduleID string `json:"scheduleId"`
}

// Effect is one thing a Plan's mutation would do, in plain text — the Go
// side never re-derives what a mutation does from its Argv; it reads what
// the emitter says it will do.
type Effect struct {
	Kind string `json:"kind"`
	Text string `json:"text"`
}

// Confirmation is a yes/no gate a Plan's mutation needs before it may run:
// Kind selects the prompt, Digest is a stable identifier for "the user
// already answered this exact one," Text is what to show.
type Confirmation struct {
	Kind, Digest, Text string
}

// Refusal is a mutation's own hard "no": Code identifies which rule fired,
// Text explains it, and Override — when non-empty — names the flag that
// would let the caller force it anyway.
type Refusal struct {
	Code, Text, Override string
}

// DecodePlan parses one mutation's `--plan`-style JSON document. Its
// schema/error handling mirrors Decode exactly: a schemaVersion outside
// [SchemaMin, SchemaMax] is rejected before the rest of the document is
// examined, a malformed body's error carries the first 2 KB verbatim, and
// no path returns a partially-populated Plan alongside a nil error.
func DecodePlan(b []byte) (Plan, error) {
	var probe envelopeVersionProbe
	if err := json.Unmarshal(b, &probe); err != nil {
		return Plan{}, &DecodeError{Err: err, Prefix: firstKB(b)}
	}
	if probe.SchemaVersion < SchemaMin || probe.SchemaVersion > SchemaMax {
		return Plan{}, &SchemaSkewError{
			Got:  probe.SchemaVersion,
			Want: schemaRangeText(),
		}
	}

	var p Plan
	if err := json.Unmarshal(b, &p); err != nil {
		return Plan{}, &DecodeError{Err: err, Prefix: firstKB(b)}
	}
	return p, nil
}
