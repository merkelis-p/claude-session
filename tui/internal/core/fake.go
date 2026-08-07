package core

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/merkelis-p/claude-session/tui/internal/model"
)

// FakeClient is a Client backed by checked-in fixtures — no exec.Command
// anywhere in this type, no subprocess of any kind. NewFake's dir defaults
// it to the shared bash corpus (tests/fixtures/envelope), so a test
// exercising this package's own logic and the bash suite's JSON tests read
// the exact same documents. SnapshotBytes/PlanBytes let a caller hand it
// raw bytes directly — this package's own malformed/truncated/skewed
// variants (kept inline as []byte literals in client_test.go, never as
// files: testdata/ here holds only the argv-recording fixtures) — without
// touching disk at all.
type FakeClient struct {
	dir string
	bin string
	log *Log

	// SnapshotFile is read (relative to dir) when SnapshotBytes is nil.
	// Defaults to "full.json".
	SnapshotFile  string
	SnapshotBytes []byte

	// PlanBytes, when set, is what Plan decodes. Left nil, Plan returns
	// errNoFakePlan — there is no single canonical "the" plan fixture the
	// way there is for Snapshot's envelopes.
	PlanBytes []byte

	// ApplyResult is returned verbatim by Apply. Defaults to a plain
	// success (OK: true, Exit: 0).
	ApplyResult Result
}

var _ Client = (*FakeClient)(nil)

// NewFake returns a Client that serves dir's fixtures instead of spawning
// bash. dir is normally "../../../tests/fixtures/envelope" — the same
// full.json/empty.json/partial.json/unavailable.json corpus
// internal/model's own tests decode.
func NewFake(dir string) Client {
	return &FakeClient{
		dir:          dir,
		bin:          "claude-session",
		log:          &Log{},
		SnapshotFile: "full.json",
		ApplyResult:  Result{OK: true, Exit: 0},
	}
}

func (f *FakeClient) Log() *Log { return f.log }

func (f *FakeClient) Snapshot(ctx context.Context, only []Section) (model.Snapshot, error) {
	argv := snapshotArgv(f.bin, only)
	start := time.Now()

	b := f.SnapshotBytes
	if b == nil {
		var err error
		b, err = os.ReadFile(filepath.Join(f.dir, f.SnapshotFile))
		if err != nil {
			f.log.append(Entry{At: start, Argv: argv, Exit: -1, Stderr: err.Error(), Dur: time.Since(start)})
			return model.Snapshot{}, err
		}
	}

	snap, decErr := model.Decode(b)
	diag := ""
	if decErr != nil {
		diag = firstKB(b)
	}
	f.log.append(Entry{At: start, Argv: argv, Exit: 0, Stderr: diag, Dur: time.Since(start)})
	return snap, decErr
}

var errNoFakePlan = errors.New("core: fake client has no plan configured (set FakeClient.PlanBytes)")

func (f *FakeClient) Plan(ctx context.Context, m Mutation) (model.Plan, error) {
	argv := m.Argv(f.bin, PhasePlan, nil)
	start := time.Now()
	if f.PlanBytes == nil {
		f.log.append(Entry{At: start, Argv: argv, Exit: -1, Stderr: errNoFakePlan.Error(), Dur: time.Since(start)})
		return model.Plan{}, errNoFakePlan
	}
	p, err := model.DecodePlan(f.PlanBytes)
	f.log.append(Entry{At: start, Argv: argv, Exit: 0, Dur: time.Since(start)})
	return p, err
}

func (f *FakeClient) Apply(ctx context.Context, m Mutation, acks []string) (Result, error) {
	argv := m.Argv(f.bin, PhaseApply, acks)
	start := time.Now()
	f.log.append(Entry{At: start, Argv: argv, Exit: f.ApplyResult.Exit, Stderr: f.ApplyResult.Stderr, Dur: time.Since(start)})
	return f.ApplyResult, nil
}

func (f *FakeClient) Handoff(m Mutation) tea.Cmd {
	argv := handoffArgv(f.bin, m)
	f.log.append(Entry{At: time.Now(), Argv: argv, Exit: 0, Dur: 0})
	return func() tea.Msg { return HandoffMsg{} }
}

// --- recording ---------------------------------------------------------

// recordingClient wraps any Client and captures the exact argv of every
// invocation it makes, by diffing Log().Entries() before and after each
// delegated call. There is no separate argv-reconstruction to drift from
// what actually ran: the captured slice IS the Log's own Argv field, for
// whichever Entries appeared during this one call.
type recordingClient struct {
	inner Client
	calls *[][]string
}

var _ Client = (*recordingClient)(nil)

// NewRecording wraps c and returns a Client that behaves identically while
// also appending every invocation's argv to the returned slice, in call
// order — the fixture place tests assert against (recording_test.go),
// mirroring tests/harness.sh's install_fake_tmux "record every call's argv
// verbatim" pattern for the bash suite.
func NewRecording(c Client) (Client, *[][]string) {
	calls := &[][]string{}
	return &recordingClient{inner: c, calls: calls}, calls
}

func (r *recordingClient) capture(before int) {
	entries := r.inner.Log().Entries()
	for _, e := range entries[before:] {
		*r.calls = append(*r.calls, e.Argv)
	}
}

func (r *recordingClient) Snapshot(ctx context.Context, only []Section) (model.Snapshot, error) {
	before := len(r.inner.Log().Entries())
	snap, err := r.inner.Snapshot(ctx, only)
	r.capture(before)
	return snap, err
}

func (r *recordingClient) Plan(ctx context.Context, m Mutation) (model.Plan, error) {
	before := len(r.inner.Log().Entries())
	p, err := r.inner.Plan(ctx, m)
	r.capture(before)
	return p, err
}

func (r *recordingClient) Apply(ctx context.Context, m Mutation, acks []string) (Result, error) {
	before := len(r.inner.Log().Entries())
	res, err := r.inner.Apply(ctx, m, acks)
	r.capture(before)
	return res, err
}

func (r *recordingClient) Handoff(m Mutation) tea.Cmd {
	before := len(r.inner.Log().Entries())
	cmd := r.inner.Handoff(m)
	r.capture(before)
	return cmd
}

func (r *recordingClient) Log() *Log { return r.inner.Log() }
