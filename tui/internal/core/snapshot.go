package core

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/merkelis-p/claude-session/tui/internal/model"
)

// allDataSections is every section _snapshot actually carries data for.
// SecMeta selects the preamble only and is deliberately excluded — it has
// no per-section status to degrade (lib/json.sh's _json_envelope: `meta)
// continue ;;`, skipped before any section fragment is built).
var allDataSections = []Section{SecAccounts, SecChats, SecIssues, SecProcesses, SecLedger, SecSchedules}

// snapshotArgv builds `<bin> _snapshot [--only=<comma-joined>] --json` —
// the same array-argv, long-form discipline as Mutation.Argv, for the one
// read verb that is not a Mutation.
func snapshotArgv(bin string, only []Section) []string {
	argv := []string{bin, "_snapshot"}
	if len(only) > 0 {
		names := make([]string, len(only))
		for i, s := range only {
			names[i] = string(s)
		}
		argv = append(argv, "--only="+strings.Join(names, ","))
	}
	return append(argv, "--json")
}

// sectionErrorSnapshot builds a Snapshot that renders every requested
// section (or, when only is empty — the default, every section) as
// StatusError with msg surfaced verbatim as that section's one error.
//
// This is never the zero Snapshot's bare, empty Items: an empty Items with
// a zero SectionStatus would render identically to a genuinely empty-ok
// section, which is exactly the confusion docs/json-schema.md's "The four
// status values" exists to make impossible. A read that failed must render
// as "error", never as "nothing here."
func sectionErrorSnapshot(only []Section, msg string) model.Snapshot {
	names := only
	if len(names) == 0 {
		names = allDataSections
	}
	errs := []model.SectionError{{Detail: msg}}
	var snap model.Snapshot
	for _, s := range names {
		switch s {
		case SecAccounts:
			snap.Sections.Accounts.Status, snap.Sections.Accounts.Errors = model.StatusError, errs
		case SecChats:
			snap.Sections.Chats.Status, snap.Sections.Chats.Errors = model.StatusError, errs
		case SecIssues:
			snap.Sections.Issues.Status, snap.Sections.Issues.Errors = model.StatusError, errs
		case SecProcesses:
			snap.Sections.Processes.Status, snap.Sections.Processes.Errors = model.StatusError, errs
		case SecLedger:
			snap.Sections.Ledger.Status, snap.Sections.Ledger.Errors = model.StatusError, errs
		case SecSchedules:
			snap.Sections.Schedules.Status, snap.Sections.Schedules.Errors = model.StatusError, errs
		case SecMeta:
			// meta selects the preamble only — nothing section-shaped to degrade.
		}
	}
	return snap
}

// Snapshot asks the bash core for one `_snapshot --json` envelope.
//
// A failure to even start the child, or a schemaVersion outside the
// supported range, is fatal and returned as a Go error — schema skew in
// particular is NEVER swallowed into a degraded-but-renderable Snapshot,
// and there is no fallback to some other, direct read: once the running
// binary and the bash core it talks to disagree about the schema, nothing
// this package decoded from either side can be trusted.
//
// Every other failure (a non-zero exit — the read itself refused or
// crashed; a stdout that is not valid JSON at all) degrades gracefully:
// every requested section renders as StatusError with the diagnostic text
// attached, and the method itself returns a nil error, so a single missed
// poll does not stop the app from rendering (or from polling again next
// cycle).
func (c *client) Snapshot(ctx context.Context, only []Section) (model.Snapshot, error) {
	argv := snapshotArgv(c.bin, only)
	start := time.Now()
	res, err := c.run(ctx, argv)
	dur := time.Since(start)
	if err != nil {
		c.log.append(Entry{At: start, Argv: argv, Exit: -1, Stderr: err.Error(), Dur: dur})
		return model.Snapshot{}, err
	}
	if res.Exit != 0 {
		c.log.append(Entry{At: start, Argv: argv, Exit: res.Exit, Stderr: res.Stderr, Dur: dur})
		return sectionErrorSnapshot(only, res.Stderr), nil
	}

	snap, decErr := model.Decode(res.Stdout)
	if decErr != nil {
		diag := res.Stderr
		if diag == "" {
			diag = firstKB(res.Stdout)
		}
		c.log.append(Entry{At: start, Argv: argv, Exit: res.Exit, Stderr: diag, Dur: dur})
		if errors.Is(decErr, model.ErrSchemaSkew) {
			return model.Snapshot{}, decErr
		}
		return sectionErrorSnapshot(only, diag), nil
	}

	c.log.append(Entry{At: start, Argv: argv, Exit: res.Exit, Stderr: res.Stderr, Dur: dur})
	return snap, nil
}
