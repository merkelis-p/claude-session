# shellcheck shell=bash
# Shared fixtures for claude-session test_*.sh scripts. Source it, don't run it.
set -uo pipefail

# Resolve the entrypoint under test: explicit $CS wins, then a repo checkout
# (../bin/claude-session relative to tests/), then whatever is on PATH. This
# makes the suite work from a fresh git checkout, a real ~/.local install, or
# a location-independence smoke copy (see run-tests.sh usage in the plan).
if [[ -z "${CS:-}" ]]; then
  _t_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -x "$_t_dir/../bin/claude-session" ]]; then
    CS="$(cd "$_t_dir/.." && pwd)/bin/claude-session"
  elif command -v claude-session >/dev/null 2>&1; then
    CS="$(command -v claude-session)"
  else
    echo "harness: cannot locate claude-session (set CS=/path/to/claude-session)" >&2
    exit 1
  fi
fi

# Resolve the real modules directory next to $CS (following symlinks, same
# logic the entrypoint itself uses), for (a) installing modules into the fake
# HOME below, and (b) tests that source schedule.sh/ledger.sh directly into
# their own shell to unit-test functions without going through $CS.
_cs_real="$CS"
while [[ -L "$_cs_real" ]]; do
  _cs_link="$(readlink "$_cs_real")"
  [[ "$_cs_link" == /* ]] && _cs_real="$_cs_link" || _cs_real="$(dirname "$_cs_real")/$_cs_link"
done
HELPERS_LIB_SRC=""
for _c in "$(dirname "$_cs_real")/../share/claude-helpers" "$(dirname "$_cs_real")/../lib"; do
  [[ -f "$_c/compat.sh" ]] && { HELPERS_LIB_SRC="$(cd "$_c" && pwd)"; break; }
done
# Abort loudly, exactly like the $CS guard above. An empty HELPERS_LIB_SRC used
# to just skip the module-install loop below, and the fake HOME then had no
# modules: every $CS invocation died with "cannot find its library directory"
# while the suite reported it as an ordinary content mismatch — and any
# assert_not_contains passed VACUOUSLY, because output with no titles in it
# also has no wrong titles in it. A misattributed failure plus a false PASS is
# strictly worse than refusing to run.
if [[ -z "$HELPERS_LIB_SRC" ]]; then
  echo "harness: cannot locate the modules dir next to $_cs_real" >&2
  echo "  looked in: ../share/claude-helpers, ../lib" >&2
  exit 1
fi
export HELPERS_LIB_SRC

setup_fake_home() {
  export HOME_REAL="$HOME"
  TEST_HOME="$(mktemp -d)"
  export TEST_HOME
  export HOME="$TEST_HOME"
  mkdir -p "$HOME/.claude/sessions" "$HOME/.config/claude-helpers" "$HOME/.local/share/claude-helpers"

  # Orphan-process detection (claude-session doctor) reads its process table
  # from $ORPHAN_PS_SRC when set, instead of the real `ps`. Default it to an
  # empty fixture so every test stays hermetic — whatever real orphan/daemon
  # processes happen to exist on the host running the tests must never leak
  # into a test's doctor/ls output. Tests exercising orphan detection itself
  # override this with their own fixture file.
  : > "$TEST_HOME/.fake_ps_empty"
  export ORPHAN_PS_SRC="$TEST_HOME/.fake_ps_empty"

  # Create a stub ui.sh with minimal necessary exports
  cat > "$HOME/.local/share/claude-helpers/ui.sh" <<'UI_STUB'
# Minimal ui.sh stub for tests
N=''; BOLD=''; DIM=''; Y=''; R=''; M=''; C=''
GLYPH_CHECK='✓'; GLYPH_DASH='—'; GLYPH_OK='●'; GLYPH_WARN='○'; GLYPH_FAIL='✕'; GLYPH_ALERT='⚠'

# No-op: the stub's palette is already blank and its glyphs already plain
# enough for assertions, unlike the real ui.sh this mirrors (see _ui_disable_color
# there). Must still exist — bin/claude-session calls it unconditionally under
# --json/CLAUDE_SESSION_UI=1, and set -euo pipefail turns a missing function
# into an immediate, wrongly-coded script exit instead of the real code path.
_ui_disable_color() { :; }

box_top() { echo ""; }
box_line() { echo "  $1"; }
box_blank() { echo ""; }
box_bottom() { echo ""; }
box_msg() { echo "  $2"; }

short_home() {
  local path="$1"
  echo "${path/#$HOME/~}"
}

truncate_str() {
  local s="$1" max="${2:-60}"
  if (( ${#s} > max )); then
    echo "${s:0:$((max-3))}..."
  else
    echo "$s"
  fi
}

owner_tmux() { return 1; }
ms_relative() { echo "0s"; }
UI_STUB

  # The entrypoint now self-locates its library relative to its own (real)
  # path, so without this it would load the REAL ui.sh instead of the stub
  # written above — and the stub's un-wrapped box_line output is what several
  # assertions match on. Point it at the fake HOME explicitly.
  export CLAUDE_HELPERS_LIB="$HOME/.local/share/claude-helpers"

  # Once the title/transfer logic is split into modules (see the extraction
  # task), the entrypoint sources them from $HOME/.local/share/claude-helpers/.
  # Install the real modules into the fake HOME so tests resolve them. Guarded
  # so this is a no-op before the split exists.
  # compat.sh MUST be in this list: the entrypoint sources it first, so a fake
  # HOME without it fails before any dispatch (ui.sh is the stub written above).
  # Sourced from $HELPERS_LIB_SRC (resolved next to $CS above), not
  # $HOME_REAL/.local/share/claude-helpers — the latter breaks when $CS points
  # at a repo checkout or a location-independence copy outside $HOME.
  local _m
  for _m in compat.sh titles.sh ledger.sh schedule.sh titleindex.sh json.sh; do
    [[ -n "$HELPERS_LIB_SRC" && -f "$HELPERS_LIB_SRC/$_m" ]] \
      && cp "$HELPERS_LIB_SRC/$_m" "$HOME/.local/share/claude-helpers/$_m"
  done
}

teardown_fake_home() {
  local p
  if [[ -n "${TEST_HOME:-}" && -f "$TEST_HOME/.fake_pids" ]]; then
    while IFS= read -r p; do
      kill "$p" 2>/dev/null || true
    done < "$TEST_HOME/.fake_pids"
  fi
  if [[ -n "${TEST_HOME:-}" && "$TEST_HOME" == /tmp/* ]]; then
    rm -rf "$TEST_HOME"
  fi
  export HOME="$HOME_REAL"
  unset ORPHAN_PS_SRC
  unset CLAUDE_HELPERS_LIB
}

assert_contains() {
  local haystack="$1" needle="$2" label="${3:-assert_contains}"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "FAIL: $label — expected to find: $needle" >&2
    echo "--- actual output ---" >&2
    echo "$haystack" >&2
    return 1
  fi
  echo "PASS: $label"
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="${3:-assert_not_contains}"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "FAIL: $label — did not expect to find: $needle" >&2
    echo "--- actual output ---" >&2
    echo "$haystack" >&2
    return 1
  fi
  echo "PASS: $label"
}

assert_eq() {
  local actual="$1" expected="$2" label="${3:-assert_eq}"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $label — expected [$expected] got [$actual]" >&2
    return 1
  fi
  echo "PASS: $label"
}

# Install a fake `claude` binary at the front of PATH: $1 = script body (default: no-op).
install_fake_claude() {
  local body="${1:-}"
  local stub_dir="$TEST_HOME/bin"
  mkdir -p "$stub_dir"
  if [[ -z "$body" ]]; then
    cat > "$stub_dir/claude" <<'CLAUDE_STUB'
#!/usr/bin/env bash
echo "fake claude ran, CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-<unset>}"
CLAUDE_STUB
  else
    printf '%s\n' "$body" > "$stub_dir/claude"
  fi
  chmod +x "$stub_dir/claude"
  export PATH="$stub_dir:$PATH"
}

# Write a fake per-account Claude session-state JSON file backed by a real,
# harmless background process (so the script's /proc/$pid alive-check passes
# without running real Claude). Prints the fake pid.
fake_session() {
  local acct_dir="$1" cwd="$2" bridge="${3:-}" sid="${4:-}"
  mkdir -p "$acct_dir/sessions"
  sleep 300 >/dev/null 2>&1 &
  local pid=$!
  echo "$pid" >> "$TEST_HOME/.fake_pids"
  [[ -z "$sid" ]] && sid="sid-$pid"
  jq -n --arg cwd "$cwd" --arg bridge "$bridge" --arg sid "$sid" \
    '{cwd: $cwd, entrypoint: "claude", status: "idle",
      sessionId: $sid, bridgeSessionId: $bridge, statusUpdatedAt: 0}' \
    | jq --argjson pid "$pid" '. + {pid: $pid}' \
    > "$acct_dir/sessions/$pid.json"
  echo "$pid"
}

# Write a fake transcript at the encoded project path for (acct_dir, cwd, sid).
# Remaining args are literal JSONL record lines, appended in order. Prints path.
fake_transcript() {
  local acct_dir="$1" cwd="$2" sid="$3"; shift 3
  local enc dir f line
  enc="$(sed 's#[/._]#-#g' <<<"$cwd")"
  dir="$acct_dir/projects/$enc"
  mkdir -p "$dir"
  f="$dir/$sid.jsonl"
  : > "$f"
  for line in "$@"; do printf '%s\n' "$line" >> "$f"; done
  echo "$f"
}

# Stub tmux: record calls; has-session honors $TMUX_EXISTING (space-separated names).
install_fake_tmux() {
  mkdir -p "$TEST_HOME/bin"
  cat > "$TEST_HOME/bin/tmux" <<'EOF'
#!/usr/bin/env bash
{ for _a in "$@"; do printf '%s\037' "$_a"; done; printf '\036'; } >> "${TMUX_CALLS:?}"
if [[ "$1" == "has-session" ]]; then
  for _e in ${TMUX_EXISTING:-}; do [[ "$3" == "$_e" ]] && exit 0; done
  exit 1
fi
exit 0
EOF
  chmod +x "$TEST_HOME/bin/tmux"
  export PATH="$TEST_HOME/bin:$PATH"
  export TMUX_CALLS="$TEST_HOME/.tmux_calls"; : > "$TMUX_CALLS"
  unset TMUX   # ensure _enter_session uses attach (not switch-client)
}

# Stub systemctl: record calls, always succeed.
install_fake_systemctl() {
  mkdir -p "$TEST_HOME/bin"
  cat > "$TEST_HOME/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
{ for _a in "$@"; do printf '%s ' "$_a"; done; printf '\n'; } >> "${SYSTEMCTL_CALLS:?}"
exit 0
EOF
  chmod +x "$TEST_HOME/bin/systemctl"
  export PATH="$TEST_HOME/bin:$PATH"
  export SYSTEMCTL_CALLS="$TEST_HOME/.systemctl_calls"; : > "$SYSTEMCTL_CALLS"
}

# A claude stub that records argv + config dir + cwd (for pass-through / scheduler tests).
install_recording_claude() {
  install_fake_claude 'printf "ARGS:"; for a in "$@"; do printf " %s" "$a"; done; printf "\n";
printf "CFG: %s\n" "${CLAUDE_CONFIG_DIR:-unset}"; printf "CWD: %s\n" "$PWD";
{ printf "argv:"; for a in "$@"; do printf " %s" "$a"; done; printf "\tcfg:%s\tcwd:%s\n" "${CLAUDE_CONFIG_DIR:-unset}" "$PWD"; } >> "${CLAUDE_CALLS:-/dev/null}"'
  export CLAUDE_CALLS="$TEST_HOME/.claude_calls"; : > "$CLAUDE_CALLS"
}
