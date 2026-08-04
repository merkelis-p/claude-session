package tui_test

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// The import rules are structural guarantees, not conventions: layout and
// theme must stay pure so they can be fuzzed and golden-tested without a
// terminal, and ui/* must be unable to spawn a process so "every mutation
// goes through core" cannot be bypassed by accident.
var rules = []struct {
	pkg       string
	forbidden []string
}{
	{"internal/layout", []string{"internal/core", "internal/ui", "internal/model", "os/exec"}},
	{"internal/theme", []string{"internal/core", "internal/ui", "os/exec"}},
	{"internal/model", []string{"internal/core", "internal/ui", "internal/theme", "os/exec"}},
	{"internal/ui/shell", []string{"os/exec"}},
	{"internal/ui/chats", []string{"os/exec"}},
	{"internal/ui/confirm", []string{"os/exec"}},
	{"internal/ui/accounts", []string{"os/exec"}},
	{"internal/ui/ledger", []string{"os/exec"}},
	{"internal/ui/schedules", []string{"os/exec"}},
	{"internal/ui/processes", []string{"os/exec"}},
}

// TestImportRules asserts the dependency rules above. A package that does
// not exist yet cannot have violated anything, but it also has not been
// checked, so it must never be reported as though it passed: a check with
// nothing to check reports SKIP, not PASS.
func TestImportRules(t *testing.T) {
	for _, r := range rules {
		r := r
		t.Run(r.pkg, func(t *testing.T) {
			if _, err := os.Stat(r.pkg); os.IsNotExist(err) {
				t.Logf("SKIP %s: package does not exist yet", r.pkg)
				t.Skip()
			}
			out, err := exec.Command("go", "list", "-deps", "./"+r.pkg).CombinedOutput()
			if err != nil {
				t.Fatalf("go list -deps ./%s: %v\n%s", r.pkg, err, out)
			}
			// A forbidden entry matches any dependency whose import path
			// contains it, not just an exact package -- "internal/ui" must
			// catch "internal/ui/shell" too, or a pure package could reach
			// a terminal dependency through a subpackage and this check
			// would wave it through.
			deps := strings.Fields(string(out))
			for _, dep := range deps {
				for _, forbidden := range r.forbidden {
					if strings.Contains(dep, forbidden) {
						t.Errorf("%s imports %s (forbidden: %s)", r.pkg, dep, forbidden)
					}
				}
			}
		})
	}
}
