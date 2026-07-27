#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
pass() { echo "PASS: $1"; }
fl()   { echo "FAIL: $1" >&2; fail=1; }

# --dry-run must plan without creating anything
tmp="$(mktemp -d)"
out="$(bash "$REPO/install.sh" --prefix="$tmp" --dry-run 2>&1)"; ec=$?
(( ec == 0 )) && pass "dry-run exits 0" || fl "dry-run exit $ec"
grep -qi 'dry-run' <<<"$out" && pass "dry-run announces itself" || fl "no dry-run notice"
grep -qE "$tmp/bin" <<<"$out" && pass "dry-run names the target bin dir" || fl "target bin dir not shown"
[[ ! -e "$tmp/bin/claude-session" ]] && pass "dry-run created nothing" || fl "dry-run wrote files"

# real copy install
out="$(bash "$REPO/install.sh" --prefix="$tmp" --copy --no-man 2>&1)"; ec=$?
(( ec == 0 )) && pass "copy install exits 0" || { fl "copy install exit $ec"; echo "$out" >&2; }
[[ -x "$tmp/bin/claude-session" ]] && pass "entrypoint installed executable" || fl "entrypoint missing"
[[ -f "$tmp/share/claude-helpers/compat.sh" ]] && pass "lib installed" || fl "lib missing"
[[ ! -L "$tmp/bin/claude-session" ]] && pass "copy mode really copies" || fl "copy mode made a symlink"

# The installed copy must be syntactically sound where it landed (installer mechanics).
bash -n "$tmp/bin/claude-session" 2>/dev/null && pass "installed entrypoint parses" || fl "installed entrypoint broken"

# Self-location + --version: hard assertions, not conditional. The finished
# code is imported into the repo, so these must always be real passes; a
# regression here must FAIL the suite, not quietly SKIP.
v="$("$tmp/bin/claude-session" --version 2>&1)"
grep -q 'claude-session [0-9]' <<<"$v" \
  && pass "--version reports the tool" \
  || fl "--version did not report the tool: $v"
grep -q "$tmp/share/claude-helpers" <<<"$v" \
  && pass "--version resolves the installed lib dir (self-location works outside \$HOME)" \
  || fl "lib dir not the installed one: $v"

# link mode
tmp2="$(mktemp -d)"
bash "$REPO/install.sh" --prefix="$tmp2" --link --no-man >/dev/null 2>&1
[[ -L "$tmp2/bin/claude-session" ]] && pass "link mode symlinks the entrypoint" || fl "link mode did not symlink"
[[ "$(readlink "$tmp2/bin/claude-session")" == "$REPO/bin/claude-session" ]] && pass "symlink points into the repo" || fl "symlink target wrong"

# uninstall removes installed files but never user data
mkdir -p "$tmp/cfgcanary"; echo keep > "$tmp/cfgcanary/accounts.conf"
bash "$REPO/uninstall.sh" --prefix="$tmp" >/dev/null 2>&1
[[ ! -e "$tmp/bin/claude-session" ]] && pass "uninstall removed the entrypoint" || fl "entrypoint survived uninstall"
[[ -f "$tmp/cfgcanary/accounts.conf" ]] && pass "uninstall left user data alone" || fl "uninstall touched user data"

rm -rf "$tmp" "$tmp2"
exit "$fail"
