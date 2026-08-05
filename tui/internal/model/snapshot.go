// Package model is the Go side of the `--json` envelope documented in
// docs/json-schema.md: one struct tree per document, decoded through Decode
// (the envelope) or DecodePlan (a mutation's preview), plus the Field[T]
// machinery that keeps "the check did not run" a distinct, typed state from
// "the check ran and the answer was zero/empty/false" all the way from the
// bash emitter to whatever eventually renders it.
//
// This package is pure: no terminal, no process spawning, no imports from
// internal/core, internal/ui or internal/theme. ../arch_test.go enforces
// that. It does decoding and typing only — no width math, no rendering.
package model

// Snapshot is the root of the `_snapshot --json` envelope.
type Snapshot struct {
	SchemaVersion int      `json:"schemaVersion"`
	GeneratedAt   int64    `json:"generatedAt"`
	ElapsedMs     int      `json:"elapsedMs"`
	Core          Core     `json:"core"`
	Sections      Sections `json:"sections"`
}

// Core is the envelope's own preamble: build identity, not application data.
type Core struct {
	Version            string `json:"version"`
	Platform           string `json:"platform"`
	Bash               string `json:"bash"`
	Lib                string `json:"lib"`
	ElapsedMsPrecision string `json:"elapsedMsPrecision"`
}

// SectionStatus is one of the four values documented in
// docs/json-schema.md's "The four status values" table. The rule that whole
// document exists to enforce — unavailable must never render identically to
// an empty ok — is why this is its own type rather than a bare bool: a bool
// has no room for "the check's precondition is missing" as a state distinct
// from "the check ran and found nothing."
type SectionStatus string

const (
	StatusOK          SectionStatus = "ok"
	StatusPartial     SectionStatus = "partial"
	StatusUnavailable SectionStatus = "unavailable"
	StatusError       SectionStatus = "error"
)

// Skip is one entry of a section's checksSkipped: a check that did not run
// this poll, and why. Never collapsed into a shorter checksRun, because a
// skip reads exactly like a pass in a summary that only checks length.
type Skip struct {
	Name   string `json:"name"`
	Reason string `json:"reason"`
}

// SectionError is one entry of a section's errors array: a check that DID
// run but could not produce a trustworthy result. UnmarshalJSON also accepts
// a bare string (folded into Detail) because that is what the bash emitters
// send today (a corrupt ledger file, for one) — the object shape is what a
// future emitter can grow into without another decode-side migration.
type SectionError struct {
	Code   string `json:"code"`
	Detail string `json:"detail"`
	Path   string `json:"path"`
}

func (e *SectionError) UnmarshalJSON(b []byte) error {
	if len(b) > 0 && b[0] == '"' {
		var s string
		if err := unmarshalOrWrap(b, &s); err != nil {
			return err
		}
		e.Code, e.Path = "", ""
		e.Detail = s
		return nil
	}
	type alias SectionError
	var a alias
	if err := unmarshalOrWrap(b, &a); err != nil {
		return err
	}
	*e = SectionError(a)
	return nil
}

// Section is the metadata every section carries regardless of shape: status,
// what ran, what was skipped and why, what errored, and (for the sections
// that paginate) the window bookkeeping. It deliberately does NOT carry
// items — each section's rows are a different Go type (Chat, Account, …),
// so each section-specific type below embeds Section for this common part
// and adds its own Items.
type Section struct {
	Status        SectionStatus  `json:"status"`
	Reason        string         `json:"reason"`
	ChecksRun     []string       `json:"checksRun"`
	ChecksSkipped []Skip         `json:"checksSkipped"`
	Errors        []SectionError `json:"errors"`
	Limit         int            `json:"limit"`
	Total         int            `json:"total"`
	Degraded      int            `json:"degraded"`
	Truncated     bool           `json:"truncated"`
}

// Sections holds one field per envelope section. A section absent from the
// document (a `--only` subset that did not request it) simply decodes to
// its zero value — Section{} and a nil Items — never an error.
type Sections struct {
	Accounts  AccountsSection  `json:"accounts"`
	Chats     ChatsSection     `json:"chats"`
	Issues    IssuesSection    `json:"issues"`
	Ledger    LedgerSection    `json:"ledger"`
	Processes ProcessesSection `json:"processes"`
	Schedules SchedulesSection `json:"schedules"`
}

// --- accounts ----------------------------------------------------------

type AccountsSection struct {
	Section
	Items []Account `json:"items"`
}

type Account struct {
	Name        string `json:"name"`
	Dir         string `json:"dir"`
	Credentials bool   `json:"credentials"`
	Description string `json:"description"`
}

// --- chats ---------------------------------------------------------------

type ChatsSection struct {
	Section
	Items       []Chat      `json:"items"`
	TitlesIndex TitlesIndex `json:"titlesIndex"`
}

// TitlesIndex reports the title cache's health for this window only — see
// docs/json-schema.md's "chats" section for why it is deliberately not the
// whole-index lifetime stats.
type TitlesIndex struct {
	State    string `json:"state"`
	Resolved int    `json:"resolved"`
	Pending  int    `json:"pending"`
}

// Title is the {value, state, source} shape docs/json-schema.md documents
// for the chats.title field. It is not a Field[T]: the wire shape carries
// "source" instead of "note", so it gets its own small struct rather than
// forcing Field's wrapper to grow a case it does not otherwise need.
type Title struct {
	Value  string     `json:"value"`
	State  FieldState `json:"state"`
	Source string     `json:"source"`
}

// Flag is one entry of a chat's flags array — the same per-pid
// classification `ls` renders, as plain text.
type Flag struct {
	Kind     string `json:"kind"`
	Severity string `json:"severity"`
	Text     string `json:"text"`
}

// Provenance records where a chat came from, per the transfer ledger.
type Provenance struct {
	Kind string `json:"kind"`
	From string `json:"from"`
	Ts   int64  `json:"ts"`
}

// Chat is one row of the chats section: one live runtime session or
// on-disk transcript. See CriticalMissing (decode.go) for which of these
// fields spec §6.7 treats as critical.
type Chat struct {
	SessionID            string      `json:"sessionId"`
	Account              string      `json:"account"`
	AccountDir           string      `json:"accountDir"`
	TranscriptPath       string      `json:"transcriptPath"`
	TranscriptPathSource string      `json:"transcriptPathSource"`
	Title                Title       `json:"title"`
	Cwd                  string      `json:"cwd"`
	Mtime                int64       `json:"mtime"`
	Runtime              Runtime     `json:"runtime"`
	Flags                []Flag      `json:"flags"`
	Provenance           *Provenance `json:"provenance"`
	Degraded             bool        `json:"degraded"`
	DegradedReason       string      `json:"degradedReason"`
}

// Runtime is a chat's live-process view. Present and PID are plain types
// because Present gates whether the rest is even expected to resolve (a
// transcript-only chat has no runtime by design, and that absence is not
// degradation). Alive is Field[bool], NOT a plain bool: the bash side emits
// it as bare `true`/`false`/`null`, and those are three different facts —
// alive, KNOWN-dead (a stale session file whose pid is gone: a real, non-
// degraded state bash reports as `false`), and unresolved (`null`). A plain
// bool collapses known-dead and unresolved into the same Go zero, which made
// CriticalMissing flag every dead session as "missing runtime.alive" while
// bash considered it fine — a cross-language disagreement about what counts
// as degraded. StatusAgeSec and RSS stay Field[int] for the same reason:
// absent this poll must never render as a bare 0.
type Runtime struct {
	Present         bool        `json:"present"`
	PID             int         `json:"pid"`
	Tmux            string      `json:"tmux"`
	Attachable      bool        `json:"attachable"`
	Entrypoint      string      `json:"entrypoint"`
	Status          string      `json:"status"`
	StatusAgeSec    Field[int]  `json:"statusAgeSec"`
	RSS             Field[int]  `json:"rss"`
	BridgeSessionID string      `json:"bridgeSessionId"`
	Alive           Field[bool] `json:"alive"`
}

// UnmarshalJSON pre-seeds StatusAgeSec/RSS as NotRun before delegating to
// the default struct decode. encoding/json never visits a struct field
// whose JSON key is simply absent, so without this, a runtime object that
// omits "rss" entirely would leave Runtime.RSS at Field[int]{}'s zero value
// — State Known(0), V 0 — which is exactly the "check that did not run
// rendered as if it passed" bug this package exists to prevent. A key that
// IS present, even as a bare `null`, still overwrites the seed (see
// Field.UnmarshalJSON: bare null decodes as Unknown, not NotRun — the
// check ran and had nothing to report, which is a different fact from
// "did not run at all").
func (r *Runtime) UnmarshalJSON(b []byte) error {
	type alias Runtime
	a := alias{
		StatusAgeSec: Field[int]{State: NotRun},
		RSS:          Field[int]{State: NotRun},
		Alive:        Field[bool]{State: NotRun},
	}
	if err := unmarshalOrWrap(b, &a); err != nil {
		return err
	}
	*r = Runtime(a)
	return nil
}

// --- issues / processes ---------------------------------------------------

// Issue is one row shared by the issues and processes sections — they read
// the same underlying diagnostic rows `doctor` builds and split them by
// kind (session-state/title-index checks vs OS process-table scans).
type Issue struct {
	Kind      string `json:"kind"`
	Severity  string `json:"severity"`
	PID       int    `json:"pid"`
	SessionID string `json:"sessionId"`
	Text      string `json:"text"`
}

type IssuesSection struct {
	Section
	Items []Issue `json:"items"`
}

type ProcessesSection struct {
	Section
	Items []Issue `json:"items"`
}

// --- ledger ----------------------------------------------------------------

type LedgerSection struct {
	Section
	Items []LedgerEntry `json:"items"`
}

// LedgerEntry is one transfer-log row.
type LedgerEntry struct {
	ID           string `json:"id"`
	SID          string `json:"sid"`
	Title        string `json:"title"`
	From         string `json:"from"`
	To           string `json:"to"`
	Verb         string `json:"verb"`
	UndoOf       string `json:"undoOf"`
	RedoOf       string `json:"redoOf"`
	DestExists   bool   `json:"destExists"`
	SourceExists bool   `json:"sourceExists"`
	TransferTs   int64  `json:"transferTs"`
	DestMtime    int64  `json:"destMtime"`
	Diverged     bool   `json:"diverged"`
	Undoable     bool   `json:"undoable"`
}

// --- schedules ---------------------------------------------------------

type SchedulesSection struct {
	Section
	Items []ScheduleEntry `json:"items"`
}

// Drift reports whether a schedule fired later than its own recorded
// baseline. In this build it is always the explicit "unknown" — see
// docs/json-schema.md's schedules section for why "unknown" must never be
// mistaken for a pass.
type Drift struct {
	State       string  `json:"state"`
	Reason      string  `json:"reason"`
	ActualStart *int64  `json:"actualStart"`
	Evidence    *string `json:"evidence"`
}

// ScheduleEntry is one row of the schedules section, joined against
// systemd's timer/unit state. NextFire/LastFire are Field[int64] (epoch
// seconds) because "unknown" there means exactly what it means for rss: a
// timer systemd never listed, never a bare epoch 0.
type ScheduleEntry struct {
	ID         string       `json:"id"`
	Account    string       `json:"account"`
	Target     string       `json:"target"`
	SID        string       `json:"sid"`
	WhenKind   string       `json:"whenKind"`
	WhenVal    string       `json:"whenVal"`
	WhenTz     *string      `json:"whenTz"`
	TzSource   string       `json:"tzSource"`
	TzVerified bool         `json:"tzVerified"`
	Pings      *int         `json:"pings"`
	Keepalive  bool         `json:"keepalive"`
	Mode       string       `json:"mode"`
	Cwd        string       `json:"cwd"`
	Timeout    string       `json:"timeout"`
	Created    int64        `json:"created"`
	NextFire   Field[int64] `json:"nextFire"`
	LastFire   Field[int64] `json:"lastFire"`
	UnitState  string       `json:"unitState"`
	Drift      Drift        `json:"drift"`
}
