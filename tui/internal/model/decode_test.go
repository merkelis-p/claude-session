package model

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// The real envelopes come from the bash suite's fixtures, so there is
// exactly one corpus and a bash-side change that breaks the contract fails
// HERE too, not just in tests/test_json.sh.
const bashFixtures = "../../../tests/fixtures/envelope"

func mustDecode(t *testing.T, name string) Snapshot {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(bashFixtures, name+".json"))
	if err != nil {
		t.Fatalf("fixture %s: %v (run the bash suite's Task 6 first)", name, err)
	}
	snap, err := Decode(b)
	if err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}
	return snap
}

func readTestdata(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("testdata %s: %v", name, err)
	}
	return b
}

func TestDecodeRealEnvelopes(t *testing.T) {
	for _, name := range []string{"full", "empty", "unavailable", "partial"} {
		b, err := os.ReadFile(filepath.Join(bashFixtures, name+".json"))
		if err != nil {
			t.Fatalf("fixture %s: %v (run the bash suite's Task 6 first)", name, err)
		}
		snap, err := Decode(b)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if snap.SchemaVersion != 1 {
			t.Fatalf("%s: schemaVersion %d", name, snap.SchemaVersion)
		}
	}
}

// unavailable and empty-ok must stay DISTINGUISHABLE all the way through
// decode, or the renderer cannot honor the rule that they never look the
// same (docs/json-schema.md, "The four status values").
func TestUnavailableIsNotEmptyOK(t *testing.T) {
	un := mustDecode(t, "unavailable")
	ok := mustDecode(t, "empty")

	if un.Sections.Schedules.Status != "unavailable" {
		t.Fatal("status lost")
	}
	if un.Sections.Schedules.Reason == "" {
		t.Fatal("reason lost in decode")
	}
	if ok.Sections.Schedules.Status != "ok" || ok.Sections.Schedules.Reason != "" {
		t.Fatal("empty-ok picked up a reason")
	}
}

// A schemaVersion outside [SchemaMin, SchemaMax] must fail BEFORE any
// section is examined. testdata/skewed.json's own "sections" value is not
// even an object — if Decode ever looked at it before checking the
// version, this test would instead see a JSON-shape error, not
// ErrSchemaSkew.
func TestSchemaSkewIsAnError(t *testing.T) {
	b := readTestdata(t, "skewed.json")
	snap, err := Decode(b)
	if err == nil {
		t.Fatal("expected an error, got nil")
	}
	if !reflect.DeepEqual(snap, Snapshot{}) {
		t.Fatalf("expected the zero Snapshot on error, got %+v", snap)
	}
	if !errors.Is(err, ErrSchemaSkew) {
		t.Fatalf("expected errors.Is(err, ErrSchemaSkew), got %v", err)
	}
	var skew *SchemaSkewError
	if !errors.As(err, &skew) {
		t.Fatalf("expected a *SchemaSkewError in the chain, got %T: %v", err, err)
	}
	if skew.Got != 99 {
		t.Fatalf("Got = %d, want 99", skew.Got)
	}
	if skew.Want == "" {
		t.Fatal("Want is empty")
	}
}

// Truncated JSON must never come back as a zero Snapshot paired with a nil
// error — a caller that only checks err before trusting the result would
// otherwise silently accept an incomplete document.
func TestTruncatedJSONIsAnError(t *testing.T) {
	b := readTestdata(t, "truncated.json")
	snap, err := Decode(b)
	if err == nil {
		t.Fatal("expected an error decoding truncated JSON, got nil")
	}
	if !reflect.DeepEqual(snap, Snapshot{}) {
		t.Fatalf("expected the zero Snapshot on error, got %+v", snap)
	}
	var decErr *DecodeError
	if !errors.As(err, &decErr) {
		t.Fatalf("expected a *DecodeError in the chain, got %T: %v", err, err)
	}
	if decErr.Prefix == "" {
		t.Fatal("Prefix is empty")
	}
}

// A non-JSON body (an error page, a stray log line, anything that is not
// even syntactically JSON) must fail with the first 2 KB retained verbatim
// so the Console can show the caller what it actually got back.
func TestNonJSONIsAnErrorCarryingThePrefix(t *testing.T) {
	b := readTestdata(t, "badjson.txt")
	snap, err := Decode(b)
	if err == nil {
		t.Fatal("expected an error decoding non-JSON, got nil")
	}
	if !reflect.DeepEqual(snap, Snapshot{}) {
		t.Fatalf("expected the zero Snapshot on error, got %+v", snap)
	}
	var decErr *DecodeError
	if !errors.As(err, &decErr) {
		t.Fatalf("expected a *DecodeError in the chain, got %T: %v", err, err)
	}
	if decErr.Prefix != string(b) {
		t.Fatalf("Prefix did not retain the body verbatim:\n got:  %q\n want: %q", decErr.Prefix, string(b))
	}
	if !strings.Contains(decErr.Prefix, "internal error") {
		t.Fatalf("Prefix lost the body's own text: %q", decErr.Prefix)
	}
	if len(decErr.Prefix) > 2048 {
		t.Fatalf("Prefix is %d bytes, want <= 2048", len(decErr.Prefix))
	}
}

// An informational field the bash side's check never ran this poll (its
// JSON key is entirely absent, not merely null) must decode as NotRun —
// never as a Known zero, which would render exactly like a verified zero.
func TestMissingInformationalFieldDecodesAsNotRun(t *testing.T) {
	const doc = `{
		"schemaVersion": 1,
		"generatedAt": 1785927060,
		"elapsedMs": 1,
		"core": {"version": "0.2.0", "platform": "linux", "bash": "5.2.21(1)-release", "lib": "/home/u/.local/share/claude-helpers", "elapsedMsPrecision": "ms"},
		"sections": {
			"chats": {
				"checksRun": ["transcripts", "runtime"],
				"checksSkipped": [],
				"degraded": 0,
				"errors": [],
				"items": [{
					"sessionId": "sid-notrun-1",
					"account": "default",
					"accountDir": "/home/u/.claude",
					"transcriptPath": "/home/u/.claude/projects/-home-u-proj1/sid-notrun-1.jsonl",
					"transcriptPathSource": "sid-match",
					"title": {"value": "", "state": "unknown", "source": "none"},
					"cwd": null,
					"mtime": 1785927060,
					"runtime": {
						"present": true,
						"pid": 12345,
						"tmux": "(detached)",
						"attachable": false,
						"entrypoint": "claude",
						"status": "idle",
						"statusAgeSec": null,
						"bridgeSessionId": null,
						"alive": true
					},
					"flags": [],
					"provenance": null,
					"degraded": false,
					"degradedReason": null
				}],
				"limit": 200,
				"status": "ok",
				"titlesIndex": {"pending": 0, "resolved": 0, "state": "cold"},
				"total": 1,
				"truncated": false
			}
		}
	}`

	snap, err := Decode([]byte(doc))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(snap.Sections.Chats.Items) != 1 {
		t.Fatalf("expected 1 chat item, got %d", len(snap.Sections.Chats.Items))
	}
	rss := snap.Sections.Chats.Items[0].Runtime.RSS
	if rss.State != NotRun {
		t.Fatalf("rss.State = %v, want NotRun", rss.State)
	}
	if rss.IsKnown() {
		t.Fatal("rss.IsKnown() is true for a field whose check never ran")
	}
	if rss.V != 0 {
		t.Fatalf("rss.V = %d, want the unreachable zero", rss.V)
	}
}

// missing-critical.json's one chat item cannot resolve any of spec §6.7's
// six critical fields; CriticalMissing must name every one of them, in
// order, never drop the row, and never partially report.
func TestCriticalMissingNamesEveryMissingField(t *testing.T) {
	b := readTestdata(t, "missing-critical.json")
	snap, err := Decode(b)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(snap.Sections.Chats.Items) != 1 {
		t.Fatalf("expected 1 chat item, got %d", len(snap.Sections.Chats.Items))
	}
	chat := snap.Sections.Chats.Items[0]
	got := CriticalMissing(chat)
	want := []string{"sessionId", "account", "accountDir", "transcriptPath", "runtime.pid", "runtime.alive"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("CriticalMissing = %v, want %v", got, want)
	}
	if !chat.Degraded {
		t.Fatal("the fixture's own degraded flag should be true")
	}
}

// A Chat missing none of the six must report no critical fields at all —
// the companion case to the test above, proving CriticalMissing does not
// over-report on an ordinary row.
func TestCriticalMissingReportsNoneOnAHealthyRow(t *testing.T) {
	full := mustDecode(t, "full")
	for _, chat := range full.Sections.Chats.Items {
		if chat.Degraded {
			continue
		}
		if got := CriticalMissing(chat); len(got) != 0 {
			t.Fatalf("sid %s: CriticalMissing = %v, want none (chat.Degraded is false)", chat.SessionID, got)
		}
	}
}

// The real partial.json fixture already carries a row bash itself flagged
// as degraded (degradedReason "sessionId", exactly one field). Go's
// CriticalMissing, computed independently from the typed fields, must
// agree with that precomputed reason on real data, not just on the
// synthetic all-six-missing fixture above.
func TestCriticalMissingAgreesWithBashDegradedReason(t *testing.T) {
	partial := mustDecode(t, "partial")
	found := false
	for _, chat := range partial.Sections.Chats.Items {
		if !chat.Degraded {
			continue
		}
		found = true
		got := CriticalMissing(chat)
		want := strings.Fields(chat.DegradedReason)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("sid %q: CriticalMissing = %v, want %v (bash's own degradedReason %q)",
				chat.SessionID, got, want, chat.DegradedReason)
		}
	}
	if !found {
		t.Fatal("partial.json fixture has no degraded chat row to check")
	}
}

func TestFieldStateStringsRoundTrip(t *testing.T) {
	cases := []struct {
		state FieldState
		wire  string
	}{
		{Known, "known"},
		{Unknown, "unknown"},
		{NotRun, "notRun"},
		{Errored, "errored"},
		{Derived, "derived"},
	}
	for _, c := range cases {
		if got := c.state.String(); got != c.wire {
			t.Errorf("%v.String() = %q, want %q", c.state, got, c.wire)
		}

		b, err := json.Marshal(c.state)
		if err != nil {
			t.Fatalf("marshal %v: %v", c.state, err)
		}
		if string(b) != `"`+c.wire+`"` {
			t.Errorf("marshal %v = %s, want %q", c.state, b, c.wire)
		}

		var got FieldState
		if err := json.Unmarshal(b, &got); err != nil {
			t.Fatalf("unmarshal %s: %v", b, err)
		}
		if got != c.state {
			t.Errorf("round trip %v -> %s -> %v", c.state, b, got)
		}
	}

	if _, err := parseFieldState("nonsense"); err == nil {
		t.Fatal("expected an error for an unrecognized state, got nil")
	}
}

func TestDecodePlanRoundTrip(t *testing.T) {
	const doc = `{
		"schemaVersion": 1,
		"mutation": "transfer",
		"argv": ["transfer", "sid-1", "--to=alpha"],
		"target": {"kind": "chat", "sessionId": "sid-1", "account": "default"},
		"effects": [{"kind": "move", "text": "moves sid-1 from default to alpha"}],
		"willLose": [],
		"confirmations": [{"kind": "transfer", "digest": "abc123", "text": "move this chat to alpha?"}],
		"refusals": [],
		"warnings": []
	}`
	p, err := DecodePlan([]byte(doc))
	if err != nil {
		t.Fatalf("DecodePlan: %v", err)
	}
	if p.Mutation != "transfer" || p.Target.SessionID != "sid-1" || len(p.Confirmations) != 1 {
		t.Fatalf("unexpected Plan: %+v", p)
	}
}

func TestDecodePlanSchemaSkewIsAnError(t *testing.T) {
	p, err := DecodePlan([]byte(`{"schemaVersion": 99}`))
	if err == nil {
		t.Fatal("expected an error, got nil")
	}
	if !reflect.DeepEqual(p, Plan{}) {
		t.Fatalf("expected the zero Plan on error, got %+v", p)
	}
	if !errors.Is(err, ErrSchemaSkew) {
		t.Fatalf("expected errors.Is(err, ErrSchemaSkew), got %v", err)
	}
}
