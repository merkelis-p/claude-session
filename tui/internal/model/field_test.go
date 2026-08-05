package model

import (
	"encoding/json"
	"testing"
)

func TestFieldIsKnownGate(t *testing.T) {
	known := Known1(42)
	if !known.IsKnown() {
		t.Fatal("Known1's result should report IsKnown() == true")
	}
	if known.V != 42 {
		t.Fatalf("V = %d, want 42", known.V)
	}

	var unset Field[int]
	unset.State = Unknown
	if unset.IsKnown() {
		t.Fatal("a Field explicitly set to Unknown must not report IsKnown()")
	}
}

func TestFieldUnmarshalBareValueIsKnown(t *testing.T) {
	var f Field[int]
	if err := json.Unmarshal([]byte(`7`), &f); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !f.IsKnown() || f.V != 7 {
		t.Fatalf("got %+v, want a Known field with V=7", f)
	}
}

func TestFieldUnmarshalBareNullIsUnknownNotKnownZero(t *testing.T) {
	var f Field[int]
	if err := json.Unmarshal([]byte(`null`), &f); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if f.State != Unknown {
		t.Fatalf("State = %v, want Unknown", f.State)
	}
	if f.IsKnown() {
		t.Fatal("a bare JSON null must never decode as Known")
	}
	if f.V != 0 {
		t.Fatalf("V = %d, want the (unreachable via IsKnown) zero", f.V)
	}
}

func TestFieldUnmarshalWrappedFormEachState(t *testing.T) {
	cases := []struct {
		wire  string
		state FieldState
		value int
	}{
		{`{"value":2,"state":"known"}`, Known, 2},
		{`{"value":null,"state":"unknown"}`, Unknown, 0},
		{`{"value":null,"state":"notRun"}`, NotRun, 0},
		{`{"value":null,"state":"errored","note":"ps read failed"}`, Errored, 0},
		{`{"value":9,"state":"derived"}`, Derived, 9},
	}
	for _, c := range cases {
		var f Field[int]
		if err := json.Unmarshal([]byte(c.wire), &f); err != nil {
			t.Fatalf("%s: unmarshal: %v", c.wire, err)
		}
		if f.State != c.state {
			t.Errorf("%s: State = %v, want %v", c.wire, f.State, c.state)
		}
		if f.V != c.value {
			t.Errorf("%s: V = %d, want %d", c.wire, f.V, c.value)
		}
		if f.IsKnown() != (c.state == Known) {
			t.Errorf("%s: IsKnown() = %v", c.wire, f.IsKnown())
		}
	}

	var withNote Field[int]
	if err := json.Unmarshal([]byte(`{"value":null,"state":"errored","note":"ps read failed"}`), &withNote); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if withNote.Note != "ps read failed" {
		t.Fatalf("Note = %q, want %q", withNote.Note, "ps read failed")
	}
}

// Field's wrapped-form detection keys on the presence of a "state" member,
// not merely on the value being a JSON object — T itself can be a struct,
// and a bare object value of T (no "state" key) must still decode as
// Known, not be mistaken for the wrapper.
func TestFieldUnmarshalBareObjectWithoutStateKeyIsKnown(t *testing.T) {
	type point struct {
		X, Y int
	}
	var f Field[point]
	if err := json.Unmarshal([]byte(`{"X":1,"Y":2}`), &f); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !f.IsKnown() {
		t.Fatal("a bare struct value (no state key) must decode as Known")
	}
	if f.V != (point{1, 2}) {
		t.Fatalf("V = %+v, want {1 2}", f.V)
	}
}

func TestFieldUnmarshalRejectsUnrecognizedState(t *testing.T) {
	var f Field[int]
	err := json.Unmarshal([]byte(`{"value":1,"state":"nonsense"}`), &f)
	if err == nil {
		t.Fatal("expected an error for an unrecognized state, got nil")
	}
}

// The containing struct is what has to pre-seed NotRun for a key that
// never appears at all (see Runtime.UnmarshalJSON) — Field's own
// UnmarshalJSON is never invoked for an absent key, so this test documents
// that boundary rather than testing Field directly for it.
func TestFieldZeroValueWithoutDecodeIsKnownByGoZeroing(t *testing.T) {
	var f Field[int]
	if f.State != Known {
		t.Fatalf("Field[int]{}'s zero State = %v, want Known (the enum's zero value)", f.State)
	}
	// This is exactly why a struct with a Field member must never rely on
	// encoding/json's default zeroing for a key that might be absent: the
	// struct-level default has to be applied explicitly before decoding
	// (Runtime.UnmarshalJSON's alias-and-preseed pattern), or an absent key
	// silently reads back as Known/zero here.
}
