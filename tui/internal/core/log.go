package core

import (
	"sync"
	"time"
)

// Entry is one subprocess invocation — enough to reconstruct exactly what
// ran, what it printed to stderr, how it exited, and how long it took. This
// is the Console's entire feed: Argv is always the literal slice that was
// (or, for a not-yet-run terminal handoff, will be) handed to exec, never a
// reconstruction from other state that could drift from what actually ran.
type Entry struct {
	At     time.Time
	Argv   []string
	Exit   int
	Stderr string
	Dur    time.Duration
}

// Log is every subprocess a Client instance has invoked, in call order.
// Safe for concurrent use: Snapshot is typically polled on its own timer
// while Plan/Apply run from user input and the Console can read Entries at
// any time from a third goroutine.
type Log struct {
	mu      sync.Mutex
	entries []Entry
}

// Entries returns every logged invocation, oldest first. The returned slice
// is a copy, so a caller ranging over it never races a concurrent append.
func (l *Log) Entries() []Entry {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]Entry, len(l.entries))
	copy(out, l.entries)
	return out
}

// append records e. Every exported Client method that spawns a process
// (Snapshot, Plan, Apply — exec.go; Handoff — handoff.go) calls this
// exactly once per invocation, before returning, so a failure is visible in
// the Console even when the caller only checks the returned error and
// moves on.
func (l *Log) append(e Entry) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.entries = append(l.entries, e)
}
