#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
R="$REPO/README.md"; M="$REPO/man/claude-session.1"
for f in "$R" "$M"; do [[ -f "$f" ]] || { echo "FAIL: missing $f" >&2; fail=1; }; done

# Every own verb must be documented in BOTH the README and the man page.
for v in ls resume doctor kill accounts transfer schedule; do
  grep -q -- "$v" "$R" && echo "PASS: README documents '$v'" || { echo "FAIL: README missing verb '$v'" >&2; fail=1; }
  grep -q -- "$v" "$M" && echo "PASS: man documents '$v'"    || { echo "FAIL: man missing verb '$v'" >&2; fail=1; }
done
# Key flags, including the deliberate --version behavior change.
for f in --account --force --plain --launch --move --version --reap --all-accounts; do
  grep -q -- "$f" "$R" && echo "PASS: README documents '$f'" || { echo "FAIL: README missing flag '$f'" >&2; fail=1; }
  grep -q -- "$f" "$M" && echo "PASS: man documents '$f'"    || { echo "FAIL: man missing flag '$f'" >&2; fail=1; }
done
grep -q 'claude-session -- --version' "$M" && echo "PASS: man explains reaching Claude's own --version" \
  || { echo "FAIL: man must document 'claude-session -- --version'" >&2; fail=1; }

# Every docs/ page exists and is non-trivial.
for d in accounts transfer-ledger scheduler keepalive doctor-orphans troubleshooting platforms; do
  p="$REPO/docs/$d.md"
  if [[ -f "$p" ]] && (( $(wc -l < "$p") >= 20 )); then echo "PASS: docs/$d.md present"
  else echo "FAIL: docs/$d.md missing or too thin" >&2; fail=1; fi
  grep -q "docs/$d.md" "$R" && echo "PASS: README links docs/$d.md" || { echo "FAIL: README does not link docs/$d.md" >&2; fail=1; }
done

# No placeholders may ship.
if grep -rniE '\b(TODO|TBD|FIXME|XXX)\b' "$R" "$M" "$REPO/docs" >/dev/null 2>&1; then
  echo "FAIL: placeholder markers found in shipped docs" >&2
  grep -rniE '\b(TODO|TBD|FIXME|XXX)\b' "$R" "$M" "$REPO/docs" | head -5 >&2
  fail=1
else echo "PASS: no placeholders in docs"; fi

# macOS prerequisites must be stated where users will look.
grep -qi 'brew install bash' "$REPO/docs/platforms.md" && echo "PASS: platforms.md states the bash requirement" \
  || { echo "FAIL: platforms.md must tell macOS users to install bash 5" >&2; fail=1; }
exit "$fail"
