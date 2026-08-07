package core

import "strings"

// Flag is one long-form argument, always rendered --Name=Value. The app
// never emits the space form (`--account work`) anywhere, even after the
// bash side's own space-form parser is fixed: spec §14.1 records that form
// silently becoming a positional and running a transfer under the WRONG
// account, and the fix here is structural, not "remember not to" — Argv
// below has no code path that can produce anything else.
type Flag struct {
	Name  string
	Value string
}

// Phase selects which half of the plan/apply/ack protocol (lib/plan.sh)
// Argv builds for.
type Phase int

const (
	// PhasePlan builds the advisory preview: --dry-run, never --yes, never
	// --ack (acks is ignored entirely in this phase, even if the caller
	// passes some).
	PhasePlan Phase = iota
	// PhaseApply builds the real invocation: --yes, plus one --ack=<comma
	// -joined digests> when acks is non-empty (omitted entirely when it is
	// empty — never an empty --ack=).
	PhaseApply
)

// Mutation is one verb invocation, already resolved before it ever reaches
// Argv:
//
//   - Args are positional values read from the row's own envelope fields —
//     a real session id, an account name that already exists — never a
//     name Argv itself would have to look up or re-resolve.
//   - Flags are long-form-only options; Argv renders each as --Name=Value,
//     unconditionally.
//   - Force overrides one NAMED guard and is set ONLY from an explicit user
//     choice (a confirm dialog's own "override" button) — never a default,
//     never inferred from anything else about the mutation.
type Mutation struct {
	Verb  string
	Args  []string
	Flags []Flag
	Force bool
}

// Argv is a pure function: the same Mutation, phase and acks always produce
// the same argv, byte for byte. This is deliberately written and
// table-tested (client_test.go) before any exec code exists at all — it is
// exactly where both of spec §14.1's historical bug classes would
// reappear: a target that was not resolved before it reached the child
// process, or a flag that reached it space-separated and got silently
// parsed as a positional.
//
// Shape: [bin, verb, args..., --flag=value..., --json], then by phase
// --dry-run (plan) or --yes plus one --ack=<comma-joined> (apply, omitted
// when acks is empty), then --force last, and only when m.Force is true.
func (m Mutation) Argv(bin string, phase Phase, acks []string) []string {
	argv := make([]string, 0, 4+len(m.Args)+len(m.Flags))
	argv = append(argv, bin, m.Verb)
	argv = append(argv, m.Args...)
	for _, f := range m.Flags {
		argv = append(argv, "--"+f.Name+"="+f.Value)
	}
	argv = append(argv, "--json")

	switch phase {
	case PhasePlan:
		argv = append(argv, "--dry-run")
	case PhaseApply:
		argv = append(argv, "--yes")
		if len(acks) > 0 {
			argv = append(argv, "--ack="+strings.Join(acks, ","))
		}
	}

	if m.Force {
		argv = append(argv, "--force")
	}
	return argv
}
