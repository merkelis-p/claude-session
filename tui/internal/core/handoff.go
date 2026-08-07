package core

import (
	"os"
	"os/exec"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// HandoffMsg is delivered once Bubble Tea regains control of the real
// terminal after a Handoff completes — either because the child (tmux
// attach, an interactive `claude /login`) exited, or because the
// switch-client fast path finished. Err is non-nil only if the child
// itself failed to start or exited non-zero. The app must force a full
// repaint on receipt regardless of Err: whatever ran in between left the
// real terminal in a state Bubble Tea's own screen bookkeeping knows
// nothing about.
type HandoffMsg struct {
	Err error
}

// handoffArgv builds the argv for the "run the bin itself, interactively"
// branch of a handoff: the same long-form, --flag=value discipline as
// Mutation.Argv, but WITHOUT --json/--dry-run/--yes/--ack — a handoff hands
// the real terminal to an interactive child (an `accounts add`'s `claude
// /login`); it does not speak the JSON envelope protocol at all.
func handoffArgv(bin string, m Mutation) []string {
	argv := make([]string, 0, 2+len(m.Args)+len(m.Flags)+1)
	argv = append(argv, bin, m.Verb)
	argv = append(argv, m.Args...)
	for _, f := range m.Flags {
		argv = append(argv, "--"+f.Name+"="+f.Value)
	}
	if m.Force {
		argv = append(argv, "--force")
	}
	return argv
}

// handoff is the free function Handoff delegates to — kept separate so
// client_test.go can exercise it directly without a full *client, and so
// FakeClient/recordingClient can share the same argv-building logic.
//
// attach is the one verb with an existing tmux session to move to
// (bin/claude-session's own _enter_session does exactly this dispatch:
// `exec tmux switch-client -t "$1"` inside tmux, `exec tmux attach -t "$1"`
// otherwise). Every other verb — in particular `accounts add`, which needs
// an interactive `claude /login` — always takes the tea.ExecProcess path:
// there is no existing session to switch to, so the real terminal has to
// go to a freshly-started child regardless of $TMUX.
func handoff(bin string, log *Log, m Mutation) tea.Cmd {
	if m.Verb == "attach" && os.Getenv("TMUX") != "" {
		target := attachTarget(m)
		argv := []string{"tmux", "switch-client", "-t", target}
		return func() tea.Msg {
			start := time.Now()
			cmd := exec.Command(argv[0], argv[1:]...)
			err := cmd.Run()
			log.append(Entry{At: start, Argv: argv, Exit: exitCode(err), Dur: time.Since(start)})
			return HandoffMsg{Err: err}
		}
	}

	var argv []string
	if m.Verb == "attach" {
		argv = []string{"tmux", "attach", "-t", attachTarget(m)}
	} else {
		argv = handoffArgv(bin, m)
	}

	// The true exit code and duration are not known until Bubble Tea
	// actually runs this (it suspends the program, hands the terminal to
	// the child, and only then resumes) — this records the DECIDED argv
	// now, with Exit -1 as "not yet run", so the Console shows what the app
	// chose to hand off to even if it is still on-screen.
	log.append(Entry{At: time.Now(), Argv: argv, Exit: -1, Dur: 0})
	cmd := exec.Command(argv[0], argv[1:]...)
	return tea.ExecProcess(cmd, func(err error) tea.Msg {
		return HandoffMsg{Err: err}
	})
}

// attachTarget is the already-resolved tmux session name to enter — Args[0]
// of an "attach" Mutation, per the same "positional args arrive already
// resolved from the row's own envelope fields" rule every other Mutation
// follows.
func attachTarget(m Mutation) string {
	if len(m.Args) > 0 {
		return m.Args[0]
	}
	return ""
}

// Handoff hands the real terminal to bash for one Mutation — an attach, or
// an `accounts add` that needs an interactive `claude /login`. See handoff
// above for the $TMUX-set/unset dispatch.
func (c *client) Handoff(m Mutation) tea.Cmd {
	return handoff(c.bin, c.log, m)
}
