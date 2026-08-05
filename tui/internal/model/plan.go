package model

import "encoding/json"

// Plan is the preview a mutating command emits before it acts: what it
// would touch, what it would do, what would be lost, and — for anything
// destructive enough to need one — the confirmation or refusal that stands
// between "planned" and "executed." The bash side emits it from lib/plan.sh
// (`<verb> --json --dry-run`); the field shapes here are verified against a
// real emitted plan in testdata/plan-transfer-move.json, decoded the same
// way the envelope is (schema-checked first, never a partial value with a
// nil error).
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

// Target names what a Plan's mutation acts on. The bash emitter
// (_plan_target, lib/plan.sh) fills whichever fields apply to the verb and
// leaves the rest empty — a transfer/undo populates all four, a reap
// populates none. These tags match the emitted keys exactly: account, sid,
// title, dest (NOT the sessionId/kind/scheduleId an earlier guess used,
// which silently dropped sid/title/dest on every real plan).
type Target struct {
	Account string `json:"account"`
	SID     string `json:"sid"`
	Title   string `json:"title"`
	Dest    string `json:"dest"`
}

// Effect is one thing a Plan's mutation would do: Kind is the operation
// (write/remove/kill/rewrite) and Path is the object it acts on (a file
// path, or a pid for kill). The Go side never re-derives what a mutation
// does from its Argv; it reads what the emitter says. The key is `path`,
// matching lib/plan.sh's _plan_effect — an earlier `text` tag decoded every
// effect with an empty object, losing which file/pid each one touched.
type Effect struct {
	Kind string `json:"kind"`
	Path string `json:"path"`
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
