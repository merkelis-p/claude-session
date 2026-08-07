package core

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"time"

	"github.com/merkelis-p/claude-session/tui/internal/model"
)

// rawPrefixLimit mirrors internal/model's own DecodeError.Prefix cap
// (decode.go's decodeErrorPrefixLimit) — a non-JSON stdout keeps exactly
// the same "first 2 KB" model already promises for a malformed envelope
// body, one number, not two independently-chosen limits that could drift
// apart.
const rawPrefixLimit = 2048

func firstKB(b []byte) string {
	if len(b) <= rawPrefixLimit {
		return string(b)
	}
	return string(b[:rawPrefixLimit])
}

// runResult is one completed child's raw output, before anything has
// classified it as success, a degraded section, a plan refusal, or a fatal
// schema skew — that classification is each exported method's own job
// (Snapshot below in snapshot.go; Plan/Apply below in this file).
type runResult struct {
	Stdout []byte
	Stderr string
	Exit   int
}

// run is the JSON-protocol exec site: the only place Snapshot, Plan and
// Apply spawn a process. Argv is always the slice its caller built
// (snapshotArgv or Mutation.Argv) — never a shell string: no
// interpolation, no "sh -c". Both of spec §14.1's historical bug classes
// came from ambiguous argument routing, so nothing on this path ever
// assembles a command line as text.
//
// NO_COLOR=1 and CLAUDE_SESSION_UI=1 travel in the child's environment —
// the contract with the bash core (see docs referenced from bin/
// claude-session's own flag handling): never prompt on stdin, never
// colorize, diagnostics to stderr only. stdin is /dev/null, so the child
// can never block waiting on a human this process has no way to reach.
//
// A non-zero exit is NOT reported as a Go error here — it is the bash
// core's own, ordinary way of saying "refused" or "a guard tripped", and
// the caller is the one that knows how to classify it (a degraded section
// for Snapshot, a plan refusal or the apply/ack protocol's exit 3 for
// Plan/Apply). Only a failure to even start the child, or a canceled
// context, is a Go error here.
func (c *client) run(ctx context.Context, argv []string) (runResult, error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Env = append(os.Environ(), "NO_COLOR=1", "CLAUDE_SESSION_UI=1")

	devnull, err := os.Open(os.DevNull)
	if err != nil {
		return runResult{}, err
	}
	defer devnull.Close()
	cmd.Stdin = devnull

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	runErr := cmd.Run()

	var exitErr *exec.ExitError
	switch {
	case runErr == nil:
		return runResult{Stdout: stdout.Bytes(), Stderr: stderr.String(), Exit: 0}, nil
	case errors.As(runErr, &exitErr):
		return runResult{Stdout: stdout.Bytes(), Stderr: stderr.String(), Exit: exitErr.ExitCode()}, nil
	default:
		// Failed to even start (bad bin, context already canceled, …) — a
		// real Go error, not a classification job for the caller.
		return runResult{Stdout: stdout.Bytes(), Stderr: stderr.String()}, runErr
	}
}

// exitCode is exec.ExitError's code, or -1 for anything that is not a
// process exiting non-zero (failed to start, canceled context, nil).
func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	return -1
}

// Plan asks the bash core to preview a mutation: `<verb> ... --json
// --dry-run`. THE PLAN IS ADVISORY; the guards live in bash and re-run in
// full at Apply time (lib/plan.sh's own header) — this only decodes what
// bash already decided to show.
//
// A non-zero exit or a stdout that will not decode is reported as a plain
// Go error (Plan has no per-section "still render it, just degraded"
// concept the way Snapshot does — it is one preview for one confirm
// dialog). A schemaVersion outside the supported range is always fatal,
// wrapping model.ErrSchemaSkew — never a fallback to some other read.
func (c *client) Plan(ctx context.Context, m Mutation) (model.Plan, error) {
	argv := m.Argv(c.bin, PhasePlan, nil)
	start := time.Now()
	res, err := c.run(ctx, argv)
	dur := time.Since(start)
	if err != nil {
		c.log.append(Entry{At: start, Argv: argv, Exit: -1, Stderr: err.Error(), Dur: dur})
		return model.Plan{}, err
	}
	if res.Exit != 0 {
		c.log.append(Entry{At: start, Argv: argv, Exit: res.Exit, Stderr: res.Stderr, Dur: dur})
		return model.Plan{}, fmt.Errorf("core: %s: exit %d: %s", m.Verb, res.Exit, res.Stderr)
	}

	plan, decErr := model.DecodePlan(res.Stdout)
	diag := res.Stderr
	if decErr != nil && diag == "" {
		diag = firstKB(res.Stdout)
	}
	c.log.append(Entry{At: start, Argv: argv, Exit: res.Exit, Stderr: diag, Dur: dur})
	return plan, decErr
}

// Apply asks the bash core to actually perform a mutation: `<verb> ...
// --json --yes --ack=...`.
//
// Exit 3 is the plan/apply/ack protocol's own refusal (lib/plan.sh's
// _plan_require_acks): "you have not acknowledged a disclosed condition."
// Bash re-emits the FRESH plan — recomputed against current state, not the
// stale one the human already saw — on stdout when it exits 3, and this
// decodes that into Result.Plan rather than treating it as a hard error.
// It is never retried automatically: this method calls run exactly once,
// full stop; only a human choosing to re-confirm (a fresh Plan call, fresh
// acks, a new Apply call) tries again. The same "decode whatever plan bash
// re-emitted" handling also covers a plain refusal exit (e.g. exit 2, a
// hard --force-only guard) that flushes a plan for the same reason.
//
// A schemaVersion outside the supported range is always fatal, exactly as
// in Plan — never swallowed into Result.
func (c *client) Apply(ctx context.Context, m Mutation, acks []string) (Result, error) {
	argv := m.Argv(c.bin, PhaseApply, acks)
	start := time.Now()
	res, err := c.run(ctx, argv)
	dur := time.Since(start)
	if err != nil {
		c.log.append(Entry{At: start, Argv: argv, Exit: -1, Stderr: err.Error(), Dur: dur})
		return Result{}, err
	}

	var plan *model.Plan
	var skew error
	if p, decErr := model.DecodePlan(res.Stdout); decErr == nil {
		plan = &p
	} else if errors.Is(decErr, model.ErrSchemaSkew) {
		skew = decErr
	}

	diag := res.Stderr
	if diag == "" && plan == nil && len(res.Stdout) > 0 {
		diag = firstKB(res.Stdout)
	}
	c.log.append(Entry{At: start, Argv: argv, Exit: res.Exit, Stderr: diag, Dur: dur})

	if skew != nil {
		return Result{}, skew
	}
	return Result{OK: res.Exit == 0, Exit: res.Exit, Stderr: res.Stderr, Plan: plan}, nil
}
