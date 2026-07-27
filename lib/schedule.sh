# shellcheck shell=bash
# schedule.sh — prompt scheduling via systemd user timers, for claude-session.
# Sourced by the entrypoint after ledger.sh. Standalone-testable: its only
# entrypoint dependency (_account_dir_or_default / _account_config_dir) is
# called at dispatch time.

# Uses compat.sh's _next_clock_epoch/_timeout. The entrypoint already sources
# compat.sh before schedule.sh, but tests source this file standalone — pull
# in the sibling compat.sh (same directory as this file) when that hasn't
# happened yet, so those wrappers are never silently missing.
if ! command -v _next_clock_epoch >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"
fi

SCHED_DIR="${SCHED_DIR:-$HOME/.config/claude-helpers/schedules}"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"

_sched_new_id() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 3
  else printf '%06x' "$(( (RANDOM << 15 | RANDOM) & 0xffffff ))"; fi
}
_sched_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen
  elif command -v openssl >/dev/null 2>&1; then
    # Portable fallback (no /proc dependency): shape 16 random bytes from
    # openssl, which ships on both Linux and macOS, into a UUIDv4-like string.
    local h; h="$(openssl rand -hex 16)"
    printf '%s-%s-4%s-a%s-%s\n' \
      "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
  else
    printf '%08x-%04x-%04x-%04x-%012x\n' \
      "$(( RANDOM * RANDOM ))" "$RANDOM" "$RANDOM" "$RANDOM" "$(( RANDOM * RANDOM * (RANDOM + 1) ))"
  fi
}

# Compile a friendly when-spec to systemd [Timer] directive lines. For `every`,
# the optional 3rd arg overrides the first-fire delay (OnActiveSec); it
# defaults to 1min when absent/empty.
_sched_timer_lines() {
  local kind="$1" val="$2"
  case "$kind" in
    every)    printf 'OnActiveSec=%s\nOnUnitActiveSec=%s\n' "${3:-1min}" "$val" ;;
    daily-at) printf 'OnCalendar=*-*-* %s:00\nPersistent=true\n' "$val" ;;
    once)     printf 'OnCalendar=%s:00\nPersistent=true\n' "$val" ;;
    *) return 1 ;;
  esac
}

_sched_validate_when() {
  local kind="$1" val="$2"
  case "$kind" in
    every)    [[ "$val" =~ ^[0-9]+(s|m|min|h|d|w)$ ]] || { echo "schedule: --every wants a systemd span like 5h, 30min" >&2; return 1; } ;;
    daily-at) [[ "$val" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "schedule: --daily-at wants HH:MM (24h)" >&2; return 1; } ;;
    once)     [[ "$val" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])\ ([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "schedule: --once wants 'YYYY-MM-DD HH:MM'" >&2; return 1; } ;;
    *) echo "schedule: pick a schedule — --every, --daily-at, or --once" >&2; return 1 ;;
  esac
}

# Resolve the first-fire anchor from SCHED_AT (a HH:MM clock time — e.g. an
# account's 5h-limit reset) or SCHED_IN (a systemd span like 3h) into an
# OnActiveSec value; defaults to 1min when neither is set.
_sched_resolve_first() {
  if [[ -n "${SCHED_AT:-}" ]]; then
    local now target
    now="$(date +%s)"
    target="$(_next_clock_epoch "$SCHED_AT")" || { echo "schedule: --at wants HH:MM (24h)" >&2; return 1; }
    printf '%ss' "$(( target - now ))"
  elif [[ -n "${SCHED_IN:-}" ]]; then
    [[ "$SCHED_IN" =~ ^[0-9]+(s|m|min|h|d)$ ]] || { echo "schedule: --in wants a span like 3h, 90min" >&2; return 1; }
    printf '%s' "$SCHED_IN"
  else
    printf '1min'
  fi
}

_sched_write_units() {
  local id="$1" timeout="$2" kind="$3" val="$4" first="${5:-}"
  mkdir -p "$SYSTEMD_USER_DIR"
  cat > "$SYSTEMD_USER_DIR/claude-schedule-$id.service" <<EOF
[Unit]
Description=claude-session scheduled prompt $id

[Service]
Type=oneshot
TimeoutStartSec=$timeout
ExecStart=%h/.local/bin/claude-session _schedule-run $id
EOF
  { printf '[Unit]\nDescription=claude-session schedule timer %s\n\n[Timer]\n' "$id"
    _sched_timer_lines "$kind" "$val" "$first"
    printf '\n[Install]\nWantedBy=timers.target\n'
  } > "$SYSTEMD_USER_DIR/claude-schedule-$id.timer"
}

cmd_schedule_add() {
  local prompt="${1:-}"
  [[ -n "$prompt" ]] || { echo "schedule add: a prompt is required" >&2; exit 2; }
  local target sid=""
  if [[ -n "${SCHED_CHAT:-}" && "${SCHED_NEW:-0}" == 1 ]]; then echo "schedule add: --chat and --new are mutually exclusive" >&2; exit 2; fi
  if [[ -n "${SCHED_CHAT:-}" ]]; then target=chat; sid="$SCHED_CHAT"
  elif [[ "${SCHED_NEW:-0}" == 1 ]]; then target=new
  else echo "schedule add: pick a target — --chat=<sid> or --new" >&2; exit 2; fi
  _sched_validate_when "${SCHED_WHEN_KIND:-}" "${SCHED_WHEN_VAL:-}" || exit 2
  local acct="${ACCOUNT:-default}"; [[ -z "$acct" ]] && acct=default
  if [[ "$acct" != default ]]; then _account_config_dir "$acct" >/dev/null 2>&1 || { echo "schedule add: unknown account '$acct'" >&2; exit 2; }; fi
  local mode="${CLAUDE_MODE:-autopilot}" cwd="${SCHED_CWD:-$(pwd)}" timeout="${SCHED_TIMEOUT:-30m}"
  local model="${SCHED_MODEL:-}" keepalive="${SCHED_KEEPALIVE:-0}"
  local first; first="$(_sched_resolve_first)" || exit 2
  local id; id="$(_sched_new_id)"
  local d="$SCHED_DIR/$id"; mkdir -p "$d"
  printf '%s' "$prompt" > "$d/prompt.txt"
  { printf 'target=%q\nsid=%q\naccount=%q\nmode=%q\nmodel=%q\nkeepalive=%q\ncwd=%q\ntimeout=%q\nwhen_kind=%q\nwhen_val=%q\nfirst=%q\ncreated=%q\n' \
      "$target" "$sid" "$acct" "$mode" "$model" "$keepalive" "$cwd" "$timeout" "$SCHED_WHEN_KIND" "$SCHED_WHEN_VAL" "$first" "$(date +%s)"; } > "$d/meta"
  _sched_write_units "$id" "$timeout" "$SCHED_WHEN_KIND" "$SCHED_WHEN_VAL" "$first"
  systemctl --user daemon-reload
  systemctl --user enable --now "claude-schedule-$id.timer"
  echo "claude-session: scheduled '$id' — $SCHED_WHEN_KIND $SCHED_WHEN_VAL, target=$target${sid:+ ($sid)}, account=$acct, mode=$mode"
  echo "  manage:  claude-session schedule ls | log $id | rm $id"
}

cmd_schedule_run() {
  local id="${1:-}" d="$SCHED_DIR/${1:-}"
  [[ -n "$id" && -d "$d" ]] || { echo "schedule run: unknown id '$id'" >&2; exit 1; }
  local target="" sid="" account="" mode="" cwd="" timeout="" when_kind="" when_val="" created="" done="" model="" keepalive="" first=""
  # shellcheck disable=SC1091
  . "$d/meta"
  local prompt; prompt="$(cat "$d/prompt.txt")"
  local acct_dir; acct_dir="$(_account_dir_or_default "$account")"
  local pmode; case "$mode" in plan) pmode=plan ;; *) pmode=acceptEdits ;; esac
  local -a cargs
  if [[ "$target" == chat ]]; then
    cargs=(--resume "$sid" -p "$prompt" --permission-mode "$pmode")
  else
    local uuid; uuid="$(_sched_uuid)"
    cargs=(--session-id "$uuid" -p "$prompt" --permission-mode "$pmode")
    echo "schedule $id: new chat $uuid"
  fi
  [[ -n "${model:-}" ]] && cargs=(--model "$model" "${cargs[@]}")
  local rc=0
  ( cd "$cwd" && CLAUDE_CONFIG_DIR="$acct_dir" _timeout "$timeout" claude "${cargs[@]}" ) || rc=$?
  echo "schedule $id: claude exited rc=$rc"
  if [[ "$when_kind" == once ]]; then
    systemctl --user disable --now "claude-schedule-$id.timer" 2>/dev/null || true
    printf 'done=1\n' >> "$d/meta"
  fi
  return "$rc"
}

cmd_schedule_rm() {
  local id="${1:-}"; [[ -n "$id" ]] || { echo "schedule rm: an id is required" >&2; exit 2; }
  systemctl --user disable --now "claude-schedule-$id.timer" 2>/dev/null || true
  rm -f "$SYSTEMD_USER_DIR/claude-schedule-$id.service" "$SYSTEMD_USER_DIR/claude-schedule-$id.timer"
  rm -rf "${SCHED_DIR:?}/$id"
  systemctl --user daemon-reload 2>/dev/null || true
  echo "claude-session: removed schedule $id"
}

cmd_schedule_log() {
  local id="${1:-}"; [[ -n "$id" ]] || { echo "schedule log: an id is required" >&2; exit 2; }
  journalctl --user -u "claude-schedule-$id.service" --no-pager 2>&1 | tail -n 100
}

cmd_schedule_run_now() {
  local id="${1:-}"; [[ -n "$id" ]] || { echo "schedule run: an id is required" >&2; exit 2; }
  systemctl --user start "claude-schedule-$id.service"
  echo "claude-session: fired schedule $id (see: claude-session schedule log $id)"
}

cmd_schedule_ls() {
  box_top "Scheduled prompts"
  shopt -s nullglob
  local any=0 d id
  for d in "$SCHED_DIR"/*/; do
    any=1; id="$(basename "$d")"
    local target="" sid="" account="" mode="" when_kind="" when_val=""
    # shellcheck disable=SC1091
    . "$d/meta" 2>/dev/null || true
    local prompt; prompt="$(head -c 60 "$d/prompt.txt" 2>/dev/null)"
    box_line "$(printf '%b%s%b  %s %s  %b%s%b%s  %bmode%b %s' "$BOLD" "$id" "$N" "$when_kind" "$when_val" \
      "$C" "$target" "$N" "${sid:+ ($sid)}" "$DIM" "$N" "$mode")"
    box_line "$(printf '    %b%s%b' "$Y" "$(truncate_str "$prompt" 60)" "$N")"
  done
  (( any == 0 )) && box_line "$(printf '%bno schedules — add one: claude-session schedule add …%b' "$DIM" "$N")"
  box_bottom
  command -v systemctl >/dev/null 2>&1 && systemctl --user list-timers 'claude-schedule-*' --no-pager 2>/dev/null | head -n 20 || true
}


# Find an existing keepalive schedule for an account. Prints its id and
# returns 0 if found; returns 1 if none. Scans meta files without polluting
# the caller's scope (each meta is sourced inside a subshell).
_keepalive_existing_id() {
  local acct="$1" d
  shopt -s nullglob
  for d in "$SCHED_DIR"/*/; do
    local id; id="$(basename "$d")"
    local found
    found="$(
      local keepalive="" account=""
      # shellcheck disable=SC1091
      . "$d/meta" 2>/dev/null || true
      [[ "${keepalive:-0}" == 1 && "${account:-}" == "$acct" ]] && echo "$id"
    )"
    if [[ -n "$found" ]]; then echo "$found"; return 0; fi
  done
  return 1
}

# Create (or skip, if one already exists) the keepalive schedule for one account.
_keepalive_one() {
  local acct="$1" every="$2"
  local existing
  if existing="$(_keepalive_existing_id "$acct")"; then
    echo "keepalive already set for $acct ($existing) — skipping"
    return 0
  fi
  SCHED_NEW=1 SCHED_CHAT="" SCHED_WHEN_KIND=every SCHED_WHEN_VAL="$every" \
  ACCOUNT="$acct" CLAUDE_MODE=plan SCHED_MODEL=haiku SCHED_KEEPALIVE=1 \
  SCHED_CWD="${SCHED_CWD:-$HOME}" SCHED_TIMEOUT="${SCHED_TIMEOUT:-5m}" \
    cmd_schedule_add "hi" >/dev/null
  echo "keepalive created for $acct (every $every)"
}

# `schedule keepalive` — one self-pinging --new/plan/haiku "hi" schedule per
# account (or a single account via --account=), idempotent per account.
cmd_schedule_keepalive() {
  local every="5h"
  [[ "${SCHED_WHEN_KIND:-}" == every && -n "${SCHED_WHEN_VAL:-}" ]] && every="$SCHED_WHEN_VAL"
  if [[ "${SCHED_ALL_ACCOUNTS:-0}" == 1 ]]; then
    # --at/--in anchor a single account's reset time; each account resets at
    # a different time, so it makes no sense across --all-accounts. Warn and
    # fall back to the default 1min first-fire for all of them.
    if [[ -n "${SCHED_AT:-}" || -n "${SCHED_IN:-}" ]]; then
      echo "schedule keepalive: --at/--in only apply to a single account — ignoring for --all-accounts" >&2
      SCHED_AT=""; SCHED_IN=""
    fi
    local acct dir
    while IFS=$'\t' read -r acct dir; do
      _keepalive_one "$acct" "$every"
    done < <(_all_accounts)
  else
    _keepalive_one "${ACCOUNT:-default}" "$every"
  fi
}

cmd_schedule() {
  local sub="${1:-ls}"; shift || true
  case "$sub" in
    add)       cmd_schedule_add "$*" ;;
    ls)        cmd_schedule_ls ;;
    rm)        cmd_schedule_rm "${1:-}" ;;
    log)       cmd_schedule_log "${1:-}" ;;
    run)       cmd_schedule_run_now "${1:-}" ;;
    keepalive) cmd_schedule_keepalive ;;
    *)   echo "claude-session schedule: unknown subcommand '$sub' (add|ls|rm|log|run|keepalive)" >&2; exit 2 ;;
  esac
}
