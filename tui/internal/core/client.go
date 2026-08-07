// Package core is the ONLY package in this binary that spawns a process.
// Every rule spec §7.1 states about how the bash core is invoked is
// enforced here, once, by construction: argv is always an array (mutation.go's
// Mutation.Argv, snapshot.go's snapshotArgv), long flags are always
// --flag=value (never the space form that once silently became a
// positional and ran a mutation under the wrong account — spec §14.1), the
// target a Mutation acts on arrives already resolved from the row's own
// envelope fields, and --force only ever appears when a human chose it
// explicitly.
//
// exec.go's run is the one place that actually calls exec.CommandContext for
// the JSON-protocol reads/writes; handoff.go's handoff is the other exec
// site, for handing the real terminal to something interactive (tmux,
// `claude /login`). Nothing on either path ever builds a shell string —
// client_test.go's TestNoShellStringEverConstructed greps the package for
// exactly that.
//
// This package imports internal/model (the envelope/plan types it decodes
// into) and charmbracelet/bubbletea (Handoff's return type). It does NOT
// import internal/theme or internal/ui — see client_test.go's
// TestPackageDoesNotImportThemeOrUI, the in-package half of the guarantee
// ../arch_test.go enforces from the outside for every other package.
package core

import (
	"context"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/merkelis-p/claude-session/tui/internal/model"
)

// Section names one slice of the `_snapshot --json` envelope, matching
// lib/json.sh's own --only vocabulary exactly (JSON_SECTIONS_ALL plus the
// "meta"-selects-the-preamble-only keyword lib/json.sh's _json_envelope
// special-cases). SecMeta carries no section-level status of its own — it
// selects core-preamble-only, no sections at all.
type Section string

const (
	SecMeta      Section = "meta"
	SecAccounts  Section = "accounts"
	SecChats     Section = "chats"
	SecIssues    Section = "issues"
	SecProcesses Section = "processes"
	SecLedger    Section = "ledger"
	SecSchedules Section = "schedules"
)

// Result is Apply's own outcome.
//
// It is defined here, in core, rather than as model.Result: internal/model
// has no such type (grepped before writing this), and apply's stdout
// carries nothing structured to decode on the ordinary success path — only
// the plan/apply/ack protocol's exit-3 refusal (lib/plan.sh's
// _plan_require_acks) re-emits a document, a FRESH Plan recomputed against
// current state. Plan is consequently the only field here that ever comes
// from model; OK/Exit/Stderr are this package's own classification of what
// the child process did.
type Result struct {
	OK     bool
	Exit   int
	Stderr string
	Plan   *model.Plan
}

// Client is the app's only way to talk to the bash core: read a Snapshot,
// preview a Mutation, apply one, or hand the real terminal over for
// something interactive. Snapshot/Plan/Apply funnel through exec.go's run;
// Handoff funnels through handoff.go's handoff. Nothing else in the binary
// spawns a process.
type Client interface {
	Snapshot(ctx context.Context, only []Section) (model.Snapshot, error)
	Plan(ctx context.Context, m Mutation) (model.Plan, error)
	Apply(ctx context.Context, m Mutation, acks []string) (Result, error)
	Handoff(m Mutation) tea.Cmd
	Log() *Log
}

// client is the real Client: every method spawns bin as a child process.
type client struct {
	bin string
	log *Log
}

var _ Client = (*client)(nil)

// New builds the real Client, bound to bin (normally an absolute path to
// the claude-session bash script) and a schemaVersion range.
//
// schemaMin/schemaMax are the bash core's own JSON_SCHEMA_VERSION range,
// injected at link time into package main (tui/Makefile's LDFLAGS: -X
// main.schemaMin=... -X main.schemaMax=...) and threaded through here into
// model.SchemaMin/SchemaMax — the package-level vars internal/model's own
// Decode/DecodePlan check every document against (see
// internal/model/decode.go's comment on those vars: "a caller that DOES
// want to override them ... can"). This is that caller: it is what makes
// the running binary check against the bash it is ACTUALLY talking to,
// never model's own build-time default (1/1, chosen only so `go test
// ./internal/model/` works standalone with no linker flags involved).
func New(bin string, schemaMin, schemaMax int) Client {
	model.SchemaMin = schemaMin
	model.SchemaMax = schemaMax
	return &client{bin: bin, log: &Log{}}
}

func (c *client) Log() *Log { return c.log }
