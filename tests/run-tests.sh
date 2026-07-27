#!/usr/bin/env bash
# Run every test_*.sh; per-file PASS/FAIL plus totals. Non-zero if any fails.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
rc=0 files=0 asserts=0 skips=0
for t in test_*.sh; do
  out="$(bash "$t" 2>&1)"; ec=$?
  n="$(grep -c '^PASS' <<<"$out")"
  s="$(grep -c '^SKIP' <<<"$out")"
  files=$((files+1)); asserts=$((asserts+n)); skips=$((skips+s))
  if (( ec == 0 )); then
    printf 'PASS  %-34s %3s assertions%s\n' "$t" "$n" \
      "$( (( s > 0 )) && printf ', %s skipped' "$s")"
    # Show WHICH checks were skipped, not just how many. A skipped check reads
    # exactly like a passed one in a green summary, so an environment-dependent
    # gap (a macOS host with no spaced-comm process, no systemd, no orphans)
    # would otherwise be indistinguishable from full coverage.
    (( s > 0 )) && grep '^SKIP' <<<"$out" | sed 's/^/        /'
  else
    printf 'FAIL  %-34s %3s assertions\n' "$t" "$n"
    grep '^FAIL' <<<"$out" | sed 's/^/        /'
    rc=1
  fi
done
printf -- '----\n%s files, %s assertions%s, %s\n' "$files" "$asserts" \
  "$( (( skips > 0 )) && printf ', %s skipped' "$skips")" \
  "$( (( rc == 0 )) && echo 'ALL GREEN' || echo 'FAILURES PRESENT')"
exit "$rc"
