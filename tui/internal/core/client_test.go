package core

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/merkelis-p/claude-session/tui/internal/model"
)

// The real envelopes come from the bash suite's fixtures, so there is
// exactly one corpus — same constant, same path depth, as
// internal/model/decode_test.go's bashFixtures.
const bashFixtures = "../../../tests/fixtures/envelope"

// fakePlanJSON is a plan document shaped exactly like the real emitter's
// (verified structurally against internal/model/testdata/plan-transfer-move.json,
// which internal/model's own tests decode against a real bash-emitted
// fixture) — reused below both as a fake bash core's canned exit-3 response
// and as a FakeClient.PlanBytes value.
const fakePlanJSON = `{
  "schemaVersion": 1,
  "mutation": "transfer.move",
  "argv": ["claude-session", "transfer", "dbb7ea9b-1111-2222-3333-444455556666", "--to=work", "--from=default"],
  "target": {"account": "work", "sid": "dbb7ea9b-1111-2222-3333-444455556666", "title": "A chat", "dest": "/home/u/.claude-work/projects/-home-u-proj/dbb7ea9b-1111-2222-3333-444455556666.jsonl"},
  "effects": [{"kind": "write", "path": "/home/u/.claude-work/projects/-home-u-proj/dbb7ea9b-1111-2222-3333-444455556666.jsonl"}],
  "willLose": ["the source copy under 'default' (reversible: claude-session transfer undo <id>)"],
  "confirmations": [{"kind": "move", "digest": "a91f3c", "text": "disclosed condition text"}],
  "refusals": [],
  "warnings": []
}`

// writeScript writes body as an executable file in a fresh temp dir and
// returns its path — this package's stand-in for "the bash core", the same
// convention tests/harness.sh's own install_fake_tmux/install_fake_claude
// use for the bash suite (a small stub script recording or canning
// behavior), just generated per-test instead of checked into testdata/
// (testdata/ here holds only the argv-recording fixtures — see
// recording_test.go).
func writeScript(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "fake-claude-session")
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatalf("write fake script: %v", err)
	}
	return path
}

func newTestClient(bin string) *client {
	return &client{bin: bin, log: &Log{}}
}

// --- Step 1: Argv is pure, table-tested, before any exec code exists -----

func TestArgvIsExplicitAndLongForm(t *testing.T) {
	m := Mutation{Verb: "transfer", Args: []string{"dbb7ea9b-1111-2222-3333-444455556666"},
		Flags: []Flag{{"to", "work"}, {"from", "default"}}}
	got := m.Argv("claude-session", PhaseApply, []string{"a91f3c"})
	want := []string{"claude-session", "transfer", "dbb7ea9b-1111-2222-3333-444455556666",
		"--to=work", "--from=default", "--json", "--yes", "--ack=a91f3c"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q want %q", got, want)
	}
	// Never the space form: `--account work` silently became a positional and ran
	// under the WRONG ACCOUNT. The app never relies on the space-form parser even
	// after it is fixed.
	for _, a := range got {
		if strings.HasPrefix(a, "--") && strings.Contains(a, " ") {
			t.Fatalf("space-form flag: %q", a)
		}
	}
}

func TestArgvNeverIncludesForceUnlessExplicitlyChosen(t *testing.T) {
	m := Mutation{Verb: "transfer", Args: []string{"sid"}, Flags: []Flag{{"to", "work"}}}
	for _, a := range m.Argv("cs", PhaseApply, nil) {
		if a == "--force" {
			t.Fatal("--force appeared unbidden")
		}
	}
	m.Force = true
	if !slices.Contains(m.Argv("cs", PhaseApply, nil), "--force") {
		t.Fatal("--force not passed when chosen")
	}
}

func TestPlanPhaseUsesDryRunAndNeverYes(t *testing.T) {
	m := Mutation{Verb: "kill", Args: []string{"1234"}}
	// Pass acks anyway: the plan phase must ignore them entirely, not just
	// happen to omit --ack because the caller passed none.
	got := m.Argv("claude-session", PhasePlan, []string{"a91f3c"})
	want := []string{"claude-session", "kill", "1234", "--json", "--dry-run"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q want %q", got, want)
	}
	for _, a := range got {
		if a == "--yes" || strings.HasPrefix(a, "--ack=") {
			t.Fatalf("plan phase argv carried an apply-only flag: %q in %q", a, got)
		}
	}
}

func TestApplyPassesEveryAck(t *testing.T) {
	m := Mutation{Verb: "doctor", Args: []string{"--reap"}}
	got := m.Argv("claude-session", PhaseApply, []string{"a91f3c", "b2c4d6"})
	want := []string{"claude-session", "doctor", "--reap", "--json", "--yes", "--ack=a91f3c,b2c4d6"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q want %q", got, want)
	}
	// Zero acks must never render an empty --ack=.
	none := m.Argv("claude-session", PhaseApply, nil)
	for _, a := range none {
		if strings.HasPrefix(a, "--ack=") {
			t.Fatalf("--ack present with zero acks: %q in %q", a, none)
		}
	}
}

// --- No shell string is ever constructed -----------------------------------

// TestNoShellStringEverConstructed greps every non-test source file in this
// package for the two shapes a shell-string smuggling attempt would take:
// an explicit "sh -c"/"bash -c" invocation, or an exec.Command/CommandContext
// call passed a single argument (the classic "one big interpolated string"
// smell — a real argv-slice call always has a comma before the closing
// paren). Test files are excluded on purpose: writeScript above and
// TestPackageDoesNotImportThemeOrUI below legitimately spawn processes as
// test scaffolding, which is not the "one exec site in the shipped binary"
// contract this test guards.
func TestNoShellStringEverConstructed(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	// Matches exec.Command(/exec.CommandContext( followed by exactly one
	// argument (no comma) before the closing paren.
	singleArg := regexp.MustCompile(`exec\.(Command|CommandContext)\(\s*[^,()\n]*\)`)
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("read %s: %v", f, err)
		}
		// Strip full-line "//" comments before scanning: the package's own
		// doc comments explain, in prose, exactly what NOT to do (mentioning
		// "sh -c" the way this test's own comment above does), which must
		// not itself trip the check.
		var codeOnly strings.Builder
		for _, line := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "//") {
				continue
			}
			codeOnly.WriteString(line)
			codeOnly.WriteByte('\n')
		}
		src := codeOnly.String()
		lower := strings.ToLower(src)
		if strings.Contains(lower, "sh -c") || strings.Contains(lower, "bash -c") {
			t.Errorf("%s: contains a shell -c invocation", f)
		}
		for _, m := range singleArg.FindAllString(src, -1) {
			t.Errorf("%s: exec.Command(Context) called with a single argument (shell-string smell): %s", f, m)
		}
	}
}

// TestPackageDoesNotImportThemeOrUI is this package's own half of the
// import-direction guarantee ../arch_test.go enforces from the outside for
// every OTHER package (arch_test.go currently has no internal/core-specific
// row of its own — see task-16-report.md). core is allowed — required — to
// import os/exec and bubbletea; it must never import internal/theme or
// internal/ui.
func TestPackageDoesNotImportThemeOrUI(t *testing.T) {
	out, err := exec.Command("go", "list", "-deps", ".").CombinedOutput()
	if err != nil {
		t.Fatalf("go list -deps .: %v\n%s", err, out)
	}
	deps := strings.Fields(string(out))
	for _, dep := range deps {
		for _, forbidden := range []string{"internal/theme", "internal/ui"} {
			if strings.Contains(dep, forbidden) {
				t.Errorf("internal/core imports %s (forbidden: %s)", dep, forbidden)
			}
		}
	}
}

// --- exec.go: environment, stdin, logging, classification -----------------

func TestChildEnvironment(t *testing.T) {
	bin := writeScript(t, `#!/bin/sh
stdin_eof=1
if read -r _line; then stdin_eof=0; fi
printf 'NO_COLOR=%s CLAUDE_SESSION_UI=%s STDIN_EOF=%s' "$NO_COLOR" "$CLAUDE_SESSION_UI" "$stdin_eof"
`)
	c := newTestClient(bin)
	res, err := c.run(context.Background(), []string{bin})
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	out := string(res.Stdout)
	if !strings.Contains(out, "NO_COLOR=1") {
		t.Errorf("NO_COLOR not 1 in child env: %q", out)
	}
	if !strings.Contains(out, "CLAUDE_SESSION_UI=1") {
		t.Errorf("CLAUDE_SESSION_UI not 1 in child env: %q", out)
	}
	if !strings.Contains(out, "STDIN_EOF=1") {
		t.Errorf("child's stdin was not immediately EOF (not /dev/null): %q", out)
	}
}

// TestEverySubprocessIsLogged drives two real invocations through Snapshot
// (exec.go's run has no Log of its own — see snapshot.go/exec.go: each
// exported method appends its own Entry right after run returns, so the
// diagnostic text can fold in a decode failure's raw prefix when there is
// one) and checks the Log those two calls leave behind: one entry per
// call, in order, each carrying its own argv/exit/stderr/duration.
func TestEverySubprocessIsLogged(t *testing.T) {
	okSnapshot := `{"schemaVersion":1,"generatedAt":1,"elapsedMs":1,"core":{},"sections":{}}`
	okBin := writeScript(t, "#!/bin/sh\nprintf '"+okSnapshot+"'\nexit 0\n")
	failBin := writeScript(t, "#!/bin/sh\nprintf 'boom' >&2\nexit 7\n")

	c := newTestClient(okBin)
	if got := c.Log().Entries(); len(got) != 0 {
		t.Fatalf("fresh client has %d log entries, want 0", len(got))
	}

	if _, err := c.Snapshot(context.Background(), []Section{SecChats}); err != nil {
		t.Fatalf("Snapshot 1: %v", err)
	}
	c.bin = failBin
	if _, err := c.Snapshot(context.Background(), []Section{SecAccounts}); err != nil {
		t.Fatalf("Snapshot 2: %v", err)
	}

	entries := c.Log().Entries()
	if len(entries) != 2 {
		t.Fatalf("len(Entries()) = %d, want 2", len(entries))
	}
	if entries[0].At.After(entries[1].At) {
		t.Fatalf("entries not chronological: %v then %v", entries[0].At, entries[1].At)
	}
	if !reflect.DeepEqual(entries[0].Argv, []string{okBin, "_snapshot", "--only=chats", "--json"}) {
		t.Fatalf("entries[0].Argv = %q", entries[0].Argv)
	}
	if entries[0].Exit != 0 {
		t.Fatalf("entries[0].Exit = %d, want 0", entries[0].Exit)
	}
	if !reflect.DeepEqual(entries[1].Argv, []string{failBin, "_snapshot", "--only=accounts", "--json"}) {
		t.Fatalf("entries[1].Argv = %q", entries[1].Argv)
	}
	if entries[1].Exit != 7 {
		t.Fatalf("entries[1].Exit = %d, want 7", entries[1].Exit)
	}
	if entries[1].Stderr != "boom" {
		t.Fatalf("entries[1].Stderr = %q, want %q", entries[1].Stderr, "boom")
	}
	for _, e := range entries {
		if e.Dur < 0 {
			t.Fatalf("negative duration: %v", e.Dur)
		}
	}
}

// --- Snapshot: graceful degradation vs. fatal schema skew ------------------

func TestNonZeroExitFromASnapshotMakesTheSectionError(t *testing.T) {
	bin := writeScript(t, "#!/bin/sh\nprintf 'guard tripped, see stderr' >&2\nexit 1\n")
	c := newTestClient(bin)
	snap, err := c.Snapshot(context.Background(), []Section{SecChats})
	if err != nil {
		t.Fatalf("Snapshot returned a hard error for an ordinary non-zero exit: %v", err)
	}
	if snap.Sections.Chats.Status != model.StatusError {
		t.Fatalf("chats.Status = %q, want %q", snap.Sections.Chats.Status, model.StatusError)
	}
	if len(snap.Sections.Chats.Errors) == 0 || !strings.Contains(snap.Sections.Chats.Errors[0].Detail, "guard tripped") {
		t.Fatalf("chats.Errors did not surface stderr verbatim: %+v", snap.Sections.Chats.Errors)
	}
}

func TestNonJSONStdoutKeepsTheRawPrefix(t *testing.T) {
	const raw = "claude-session: internal error — an emitter produced invalid JSON, this is a stray diagnostic line, not an envelope at all"
	bin := writeScript(t, "#!/bin/sh\nprintf '"+raw+"'\nexit 0\n")

	c := newTestClient(bin)
	snap, err := c.Snapshot(context.Background(), nil)
	if err != nil {
		t.Fatalf("Snapshot returned a hard error for malformed (but not schema-skewed) stdout: %v", err)
	}
	// Never an empty list: every section _snapshot would have populated by
	// default must render as an error, never as a bare StatusOK with nil
	// Items (which would look exactly like a genuinely empty-ok section).
	for _, s := range allDataSections {
		sec, ok := sectionOf(snap, s)
		if !ok {
			t.Fatalf("no case for section %q", s)
		}
		if sec.Status != model.StatusError {
			t.Fatalf("section %q status = %q, want %q (non-JSON stdout must never look like ok/empty)", s, sec.Status, model.StatusError)
		}
	}
	entries := c.Log().Entries()
	if len(entries) != 1 {
		t.Fatalf("len(Entries()) = %d, want 1", len(entries))
	}
	if !strings.Contains(entries[0].Stderr, "internal error") {
		t.Fatalf("the raw stdout prefix did not reach the Log: %q", entries[0].Stderr)
	}
}

// sectionOf reads back one section's common Section fields by name, so
// TestNonJSONStdoutKeepsTheRawPrefix can loop over allDataSections instead
// of repeating the same six-way switch snapshot.go's sectionErrorSnapshot
// already has.
func sectionOf(snap model.Snapshot, s Section) (model.Section, bool) {
	switch s {
	case SecAccounts:
		return snap.Sections.Accounts.Section, true
	case SecChats:
		return snap.Sections.Chats.Section, true
	case SecIssues:
		return snap.Sections.Issues.Section, true
	case SecProcesses:
		return snap.Sections.Processes.Section, true
	case SecLedger:
		return snap.Sections.Ledger.Section, true
	case SecSchedules:
		return snap.Sections.Schedules.Section, true
	}
	return model.Section{}, false
}

func TestSchemaSkewFromFirstSnapshotIsFatal(t *testing.T) {
	bin := writeScript(t, `#!/bin/sh
printf '{"schemaVersion":99,"generatedAt":1,"elapsedMs":1,"core":{},"sections":"opaque"}'
exit 0
`)
	c := newTestClient(bin)
	snap, err := c.Snapshot(context.Background(), nil)
	if err == nil {
		t.Fatal("expected a fatal error for a schema-skewed snapshot, got nil")
	}
	if !errors.Is(err, model.ErrSchemaSkew) {
		t.Fatalf("expected errors.Is(err, model.ErrSchemaSkew), got %v", err)
	}
	if !reflect.DeepEqual(snap, model.Snapshot{}) {
		t.Fatalf("expected the zero Snapshot on schema skew, got %+v", snap)
	}
	// No fallback to direct reads: this package has exactly one way to read
	// the bash core (run, above) and Snapshot took it exactly once.
	if got := len(c.Log().Entries()); got != 1 {
		t.Fatalf("len(Entries()) = %d, want exactly 1 (no fallback attempt)", got)
	}
}

// --- Apply: exit 3 carries the fresh plan, never retried automatically ----

func TestExitThreeReturnsTheFreshPlan(t *testing.T) {
	// counterFile is incremented by the script itself (one line appended per
	// invocation) rather than inferred from the Log: Apply logs exactly one
	// Entry per CALL by construction (client_test.go/exec.go), which would
	// not catch a retry hidden BEHIND that one log line — this counts the
	// real subprocess launches directly, so an accidental retry-on-refusal
	// cannot hide from the test the way it hid from an earlier, Log-based
	// version of this same check (caught while drafting this task; see
	// task-16-report.md).
	dir := t.TempDir()
	counterFile := filepath.Join(dir, "calls")
	bin := writeScript(t, "#!/bin/sh\necho x >> '"+counterFile+"'\ncat <<'EOF'\n"+fakePlanJSON+"\nEOF\nexit 3\n")
	c := newTestClient(bin)
	m := Mutation{Verb: "transfer", Args: []string{"dbb7ea9b-1111-2222-3333-444455556666"},
		Flags: []Flag{{"to", "work"}, {"from", "default"}}}

	res, err := c.Apply(context.Background(), m, nil)
	if err != nil {
		t.Fatalf("Apply returned a hard error for exit 3: %v", err)
	}
	if res.OK {
		t.Fatal("res.OK = true for exit 3")
	}
	if res.Exit != 3 {
		t.Fatalf("res.Exit = %d, want 3", res.Exit)
	}
	if res.Plan == nil {
		t.Fatal("res.Plan is nil — the fresh plan bash re-emitted was dropped")
	}
	if res.Plan.Mutation != "transfer.move" {
		t.Fatalf("res.Plan.Mutation = %q, want transfer.move", res.Plan.Mutation)
	}

	// Never retried automatically: the child ran exactly once for this one
	// Apply call.
	calls, err := os.ReadFile(counterFile)
	if err != nil {
		t.Fatalf("read counter file: %v", err)
	}
	if got := len(strings.Split(strings.TrimSpace(string(calls)), "\n")); got != 1 {
		t.Fatalf("child process ran %d times, want exactly 1 (no automatic retry): %q", got, calls)
	}
	if got := len(c.Log().Entries()); got != 1 {
		t.Fatalf("len(Entries()) = %d, want exactly 1", got)
	}
}

func TestApplySchemaSkewIsFatal(t *testing.T) {
	bin := writeScript(t, `#!/bin/sh
printf '{"schemaVersion":99,"mutation":"x","sections":"opaque"}'
exit 3
`)
	c := newTestClient(bin)
	res, err := c.Apply(context.Background(), Mutation{Verb: "transfer", Args: []string{"sid"}}, nil)
	if !errors.Is(err, model.ErrSchemaSkew) {
		t.Fatalf("expected errors.Is(err, model.ErrSchemaSkew), got %v", err)
	}
	if !reflect.DeepEqual(res, Result{}) {
		t.Fatalf("expected the zero Result on schema skew, got %+v", res)
	}
}

// --- FakeClient: the shared bash fixture corpus -----------------------------

func TestFakeClientServesTheBashFixtures(t *testing.T) {
	if _, err := os.Stat(filepath.Join(bashFixtures, "full.json")); err != nil {
		t.Skipf("bash fixtures not available: %v (run from tui/internal/core, repo checked out whole)", err)
	}

	c := NewFake(bashFixtures)
	snap, err := c.Snapshot(context.Background(), nil)
	if err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	if snap.SchemaVersion != 1 {
		t.Fatalf("schemaVersion = %d, want 1", snap.SchemaVersion)
	}

	want, err := model.Decode(mustRead(t, filepath.Join(bashFixtures, "full.json")))
	if err != nil {
		t.Fatalf("decode full.json directly: %v", err)
	}
	if !reflect.DeepEqual(snap, want) {
		t.Fatalf("FakeClient's Snapshot != model.Decode(full.json) directly")
	}

	fc := c.(*FakeClient)
	fc.SnapshotFile = "unavailable.json"
	snap2, err := c.Snapshot(context.Background(), nil)
	if err != nil {
		t.Fatalf("Snapshot(unavailable): %v", err)
	}
	if snap2.Sections.Schedules.Status != model.StatusUnavailable {
		t.Fatalf("unavailable.json's schedules.Status = %q, want unavailable", snap2.Sections.Schedules.Status)
	}
}

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return b
}

func TestHandoffNeverBuildsAShellString(t *testing.T) {
	log := &Log{}
	// attach + $TMUX set: the switch-client fast path.
	t.Setenv("TMUX", "/tmp/tmux-0/default,1234,0")
	cmd := handoff("claude-session", log, Mutation{Verb: "attach", Args: []string{"work-proj"}})
	if cmd == nil {
		t.Fatal("Handoff returned a nil tea.Cmd")
	}
	msg := cmd()
	hm, ok := msg.(HandoffMsg)
	if !ok {
		t.Fatalf("Handoff message type = %T, want HandoffMsg", msg)
	}
	// tmux is very unlikely to be reachable in a test sandbox — Err is
	// expected here; what matters is argv shape, checked via the Log below.
	_ = hm

	entries := log.Entries()
	if len(entries) != 1 {
		t.Fatalf("len(Entries()) = %d, want 1", len(entries))
	}
	want := []string{"tmux", "switch-client", "-t", "work-proj"}
	if !reflect.DeepEqual(entries[0].Argv, want) {
		t.Fatalf("switch-client argv = %q, want %q", entries[0].Argv, want)
	}

	// attach + $TMUX unset: tea.ExecProcess wraps `tmux attach -t <target>`.
	// Do not invoke the returned tea.Cmd here — it hands over the real
	// terminal, unusable in a test sandbox — only check the intent Handoff
	// logged before returning.
	log2 := &Log{}
	t.Setenv("TMUX", "")
	_ = handoff("claude-session", log2, Mutation{Verb: "attach", Args: []string{"work-proj"}})
	entries2 := log2.Entries()
	if len(entries2) != 1 {
		t.Fatalf("len(Entries()) = %d, want 1", len(entries2))
	}
	wantAttach := []string{"tmux", "attach", "-t", "work-proj"}
	if !reflect.DeepEqual(entries2[0].Argv, wantAttach) {
		t.Fatalf("attach argv = %q, want %q", entries2[0].Argv, wantAttach)
	}

	// accounts add: always the bin-exec path, --json/--dry-run/--yes/--ack
	// never appear (a handoff is not the JSON protocol).
	log3 := &Log{}
	_ = handoff("claude-session", log3, Mutation{Verb: "accounts", Args: []string{"add", "alpha"}})
	entries3 := log3.Entries()
	wantAccounts := []string{"claude-session", "accounts", "add", "alpha"}
	if !reflect.DeepEqual(entries3[0].Argv, wantAccounts) {
		t.Fatalf("accounts add argv = %q, want %q", entries3[0].Argv, wantAccounts)
	}
	for _, a := range entries3[0].Argv {
		if a == "--json" || a == "--yes" || a == "--dry-run" || strings.HasPrefix(a, "--ack=") {
			t.Fatalf("accounts add argv carried a JSON-protocol flag: %q", a)
		}
	}
}
