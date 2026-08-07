package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// readGoldenArgv loads one of this package's own argv-recording fixtures —
// testdata/ here holds only these; the envelope fixtures a FakeClient
// serves come from ../../../tests/fixtures/envelope (see client_test.go's
// bashFixtures).
func readGoldenArgv(t *testing.T, name string) [][]string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("golden %s: %v", name, err)
	}
	var got [][]string
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("golden %s: %v", name, err)
	}
	return got
}

// TestRecordingCapturesExactArgv is the place-test fixture check: NewRecording
// must capture, argv for argv, exactly what the wrapped Client logged — the
// same guarantee TestArgvIsExplicitAndLongForm proves for Mutation.Argv in
// isolation (client_test.go), now proven end to end through the Client
// interface, against a golden fixture (testdata/place-transfer-argv.json)
// the same way the bash suite's own tests assert against
// install_fake_tmux's recorded calls (tests/harness.sh).
func TestRecordingCapturesExactArgv(t *testing.T) {
	fake := NewFake(bashFixtures).(*FakeClient)
	fake.PlanBytes = []byte(fakePlanJSON)

	rec, calls := NewRecording(fake)

	m := Mutation{
		Verb:  "transfer",
		Args:  []string{"dbb7ea9b-1111-2222-3333-444455556666"},
		Flags: []Flag{{"to", "work"}, {"from", "default"}},
	}

	if _, err := rec.Plan(context.Background(), m); err != nil {
		t.Fatalf("Plan: %v", err)
	}
	if _, err := rec.Apply(context.Background(), m, []string{"a91f3c"}); err != nil {
		t.Fatalf("Apply: %v", err)
	}

	want := readGoldenArgv(t, "place-transfer-argv.json")
	if !reflect.DeepEqual(*calls, want) {
		t.Fatalf("recorded argv =\n%q\nwant\n%q", *calls, want)
	}
}

// TestRecordingIsTransparent proves NewRecording is a spy, not a
// substitute: the values it returns must be identical to what the wrapped
// Client itself returns, call for call.
func TestRecordingIsTransparent(t *testing.T) {
	fake := NewFake(bashFixtures).(*FakeClient)
	fake.ApplyResult = Result{OK: true, Exit: 0}
	rec, _ := NewRecording(fake)

	direct, directErr := fake.Snapshot(context.Background(), nil)
	viaRecording, recErr := rec.Snapshot(context.Background(), nil)

	if (directErr == nil) != (recErr == nil) {
		t.Fatalf("error presence differs: direct=%v recording=%v", directErr, recErr)
	}
	if !reflect.DeepEqual(direct, viaRecording) {
		t.Fatalf("recording changed the returned Snapshot")
	}
}

// TestRecordingCapturesOnlyNewEntriesPerCall guards the before/after Log
// diff itself: two Snapshot calls through the same recording wrapper must
// append exactly one argv per call, never re-capturing an earlier one and
// never dropping one.
func TestRecordingCapturesOnlyNewEntriesPerCall(t *testing.T) {
	fake := NewFake(bashFixtures).(*FakeClient)
	rec, calls := NewRecording(fake)

	if _, err := rec.Snapshot(context.Background(), []Section{SecChats}); err != nil {
		t.Fatalf("Snapshot 1: %v", err)
	}
	if len(*calls) != 1 {
		t.Fatalf("after 1 call, len(calls) = %d, want 1", len(*calls))
	}
	if _, err := rec.Snapshot(context.Background(), []Section{SecAccounts}); err != nil {
		t.Fatalf("Snapshot 2: %v", err)
	}
	if len(*calls) != 2 {
		t.Fatalf("after 2 calls, len(calls) = %d, want 2", len(*calls))
	}
	if !containsFlag((*calls)[0], "--only=chats") {
		t.Fatalf("calls[0] = %q, want it to carry --only=chats", (*calls)[0])
	}
	if !containsFlag((*calls)[1], "--only=accounts") {
		t.Fatalf("calls[1] = %q, want it to carry --only=accounts", (*calls)[1])
	}
	if reflect.DeepEqual((*calls)[0], (*calls)[1]) {
		t.Fatalf("calls[0] and calls[1] are identical: %q", (*calls)[0])
	}
}

func containsFlag(argv []string, flag string) bool {
	for _, a := range argv {
		if a == flag {
			return true
		}
	}
	return false
}
