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
# Same reasoning, for `cmd_schedule_rm`'s plan/apply protocol (Task 10):
# tests/test_schedule_cmd.sh sources this file standalone and calls
# cmd_schedule_rm directly, never through the entrypoint, so plan.sh's
# builder functions (_plan_reset et al.) must be pulled in the same way.
if ! command -v _plan_reset >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plan.sh"
fi
# Same reasoning again, for _sched_tz_resolve's config.conf lookup: tests source
# this file standalone and call _sched_tz_resolve/cmd_schedule_add directly, so
# _cs_config_load/CS_CONFIG_VALS must never be silently missing.
if ! command -v _cs_config_load >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
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

# Bare (unzoned) systemd calendar-spec value(s) for one wall-clock schedule,
# one per output line — the single source of truth for the TEXT of an
# OnCalendar= value, shared by _sched_timer_lines (which appends the zone) and
# the validation call in cmd_schedule_add/_sched_retime (which validates the
# EXACT string before it is ever written — see _sched_tz_validate). `every` is
# a duration, not a calendar time, and is handled by its own branch in
# _sched_timer_lines instead of here. `days` is an optional systemd
# day-of-week prefix (e.g. "Mon..Fri"); empty means "every day", matching the
# pre-existing daily-at behavior exactly (bare "*-*-* HH:MM:00").
_sched_oncal_specs() {
  local kind="$1" val="$2" days="${3:-}"
  local dprefix=""; [[ -n "$days" ]] && dprefix="$days "
  case "$kind" in
    daily-at) printf '%s*-*-* %s:00\n' "$dprefix" "$val" ;;
    once)     printf '%s:00\n' "$val" ;;
    work-window)
      local start="${val%-*}" end="${val#*-}"
      printf '%s*-*-* %s:00\n%s*-*-* %s:00\n' "$dprefix" "$start" "$dprefix" "$end"
      ;;
    *) return 1 ;;
  esac
}

# Compile a friendly when-spec to systemd [Timer] directive lines. For `every`,
# the optional 3rd arg overrides the first-fire delay (OnActiveSec); it
# defaults to 1min when absent/empty. For every wall-clock kind (daily-at,
# once, work-window), the optional 5th arg is the zone NAME appended to every
# single OnCalendar= line this emits — never just the first — because an
# unzoned OnCalendar is read in the SYSTEM zone, which is the shipped defect
# this task fixes (see the file header of tests/test_schedule_tz.sh). Passing
# no zone (the bare low-level call some unit tests still make directly) keeps
# the old unzoned text; every real caller (cmd_schedule_add, _sched_retime)
# always resolves and passes one.
_sched_timer_lines() {
  local kind="$1" val="$2" first="${3:-}" days="${4:-}" zone="${5:-}"
  if [[ "$kind" == every ]]; then
    printf 'OnActiveSec=%s\nOnUnitActiveSec=%s\n' "${first:-1min}" "$val"
    return 0
  fi
  local spec any=0
  while IFS= read -r spec; do
    any=1
    if [[ -n "$zone" ]]; then printf 'OnCalendar=%s %s\n' "$spec" "$zone"
    else printf 'OnCalendar=%s\n' "$spec"
    fi
  done < <(_sched_oncal_specs "$kind" "$val" "$days")
  (( any )) || return 1
  printf 'Persistent=true\n'
}

_sched_validate_when() {
  local kind="$1" val="$2"
  case "$kind" in
    every)       [[ "$val" =~ ^[0-9]+(s|m|min|h|d|w)$ ]] || { echo "schedule: --every wants a systemd span like 5h, 30min" >&2; return 1; } ;;
    daily-at)    [[ "$val" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "schedule: --daily-at wants HH:MM (24h)" >&2; return 1; } ;;
    once)        [[ "$val" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])\ ([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "schedule: --once wants 'YYYY-MM-DD HH:MM'" >&2; return 1; } ;;
    work-window) [[ "$val" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "schedule: --work wants HH:MM-HH:MM (24h)" >&2; return 1; } ;;
    *) echo "schedule: pick a schedule — --every, --daily-at, --once, or --work" >&2; return 1 ;;
  esac
}

# ---- timezone resolution and validation -------------------------------------
# Resolve the zone a wall-clock schedule is anchored to: --tz, then config, then
# the host. Prints "<zone>\t<flag|config|host>" — the SOURCE travels with the
# value, because a host-derived zone has to be visible at every surface that
# shows the schedule. That visibility is the whole defence against the
# wrong-default trap: this server can be Etc/UTC while the user works in
# Europe/Vilnius, so the "obvious" default is exactly the wrong answer, and an
# invisible wrong answer is the failure mode this project keeps having to fix.
#
# --require refuses instead of falling back to the host, and is used by --work,
# whose entire purpose is landing pings inside the USER's day.
_sched_tz_resolve() {
  local require=0; [[ "${1:-}" == "--require" ]] && require=1
  if [[ -n "${SCHED_TZ:-}" ]]; then printf '%s\tflag' "$SCHED_TZ"; return 0; fi
  _cs_config_load
  local c="${CS_CONFIG_VALS[schedule_tz]:-}"
  if [[ -n "$c" ]]; then printf '%s\tconfig' "$c"; return 0; fi
  local host; host="$(_host_timezone)"
  if (( require )); then
    # Used by both `--work` (landing pings inside the user's day) and
    # `schedule retime` (moving a firing instant) — neither may fall back to
    # the host silently, so this message names every way to supply one
    # without assuming which caller is asking.
    { echo "schedule: this needs an explicit timezone — no default, because a wrong one would silently mis-time it."
      echo "  pass it:      --tz=Europe/Vilnius"
      echo "  or store it:  echo 'schedule_tz=Europe/Vilnius' >> $CS_CONFIG"
      echo "  this host is ${host:-unknown} — pass --tz=${host:-Etc/UTC} if that is genuinely what you meant."
    } >&2
    return 2
  fi
  printf '%s\thost' "$host"
}

# The host's zone as a NAME. Never an offset: this box can be UTC+2 in winter
# and UTC+3 in summer for the user's zone, and a stored offset would be
# silently wrong for half of every year, changing twice annually with no user
# action.
_host_timezone() {
  local z=""
  z="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [[ -z "$z" && -r /etc/timezone ]] && z="$(tr -d '[:space:]' < /etc/timezone)"
  [[ -z "$z" && -L /etc/localtime ]] && z="$(_readlink_f /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')"
  printf '%s' "${z:-Etc/UTC}"
}

# Validate the EXACT string that will be written, not a fragment of it. A zone
# that systemd would reject must never reach a unit file, and where we cannot
# ask systemd we still refuse an unknown zone rather than writing it unchecked.
SCHED_TZ_VERIFIED=0
_sched_tz_validate() {
  local zone="$1" oncal="$2"
  [[ "$zone" =~ ^[A-Za-z][A-Za-z0-9_+/-]*$ ]] \
    || { echo "schedule: --tz wants an IANA zone name like Europe/Vilnius (not an offset)" >&2; return 1; }
  if command -v systemd-analyze >/dev/null 2>&1; then
    local norm
    norm="$(systemd-analyze calendar "$oncal" 2>/dev/null | awk -F': +' '/Normalized/{print $2}')" \
      || { echo "schedule: systemd rejected the calendar spec '$oncal'" >&2; return 1; }
    [[ -n "$norm" ]] || { echo "schedule: systemd rejected the calendar spec '$oncal'" >&2; return 1; }
    [[ "$norm" == *"$zone"* ]] \
      || { echo "schedule: systemd normalized '$oncal' without the zone ('$norm') — refusing to write it" >&2; return 1; }
    SCHED_TZ_VERIFIED=1; return 0
  fi
  # No systemd-analyze: tzdata is the floor, and the result is marked unverified —
  # surfaced as `unverified` in schedule ls and in --json, never reported as valid.
  [[ -f "/usr/share/zoneinfo/$zone" ]] \
    || { echo "schedule: unknown timezone '$zone' (not in /usr/share/zoneinfo)" >&2; return 1; }
  SCHED_TZ_VERIFIED=0; return 0
}

# An HH:MM wall-clock time in a named zone, as an epoch INSTANT. Every
# comparison in this codebase uses instants; comparing wall-clock strings
# across zones is how the drift check would have become meaningless.
_sched_local_epoch() { TZ="$1" _parse_datetime "$(TZ="$1" date +%Y-%m-%d) $2:00"; }

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

# $6 = day-of-week filter (daily-at/work-window only), $7 = the resolved zone
# NAME for every wall-clock OnCalendar= line (see _sched_timer_lines).
_sched_write_units() {
  local id="$1" timeout="$2" kind="$3" val="$4" first="${5:-}" days="${6:-}" zone="${7:-}"
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
    _sched_timer_lines "$kind" "$val" "$first" "$days" "$zone"
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

  # ---- timezone: every wall-clock kind gets one, `every` gets none ---------
  # `--work` (work-window) REQUIRES an explicit zone (flag or config) — decision
  # #2: its whole purpose is landing pings inside THE USER's day, so a defaulted
  # host zone would defeat it silently. `daily-at`/`once` are the frozen
  # contract (re-run by setup scripts) and keep working with no zone, but the
  # resolved zone (falling back to the host as a last resort) is now written
  # explicitly into the unit and into meta — that is the actual fix for the
  # shipped defect (an unzoned OnCalendar is read in the SYSTEM zone).
  local when_tz="" tz_source="" tz_verified=0
  if [[ "${SCHED_WHEN_KIND:-}" != every ]]; then
    local zr
    if [[ "${SCHED_WHEN_KIND:-}" == work-window ]]; then
      zr="$(_sched_tz_resolve --require)" || exit 2
    else
      zr="$(_sched_tz_resolve)" || exit 2
    fi
    when_tz="${zr%%$'\t'*}"; tz_source="${zr#*$'\t'}"
    # Validate the FULL string(s) that will actually be written — every
    # OnCalendar= line this kind emits — BEFORE anything touches disk, so a
    # rejected zone means no unit (and no meta) is ever written at all.
    local spec
    while IFS= read -r spec; do
      _sched_tz_validate "$when_tz" "$spec $when_tz" || exit 2
    done < <(_sched_oncal_specs "${SCHED_WHEN_KIND:-}" "${SCHED_WHEN_VAL:-}" "${SCHED_DAYS:-}")
    tz_verified="$SCHED_TZ_VERIFIED"
  fi

  local id; id="$(_sched_new_id)"
  local d="$SCHED_DIR/$id"; mkdir -p "$d"
  printf '%s' "$prompt" > "$d/prompt.txt"
  { printf 'target=%q\nsid=%q\naccount=%q\nmode=%q\nmodel=%q\nkeepalive=%q\ncwd=%q\ntimeout=%q\nwhen_kind=%q\nwhen_val=%q\nfirst=%q\ncreated=%q\n' \
      "$target" "$sid" "$acct" "$mode" "$model" "$keepalive" "$cwd" "$timeout" "$SCHED_WHEN_KIND" "$SCHED_WHEN_VAL" "$first" "$(date +%s)"
    if [[ -n "$when_tz" ]]; then
      printf 'when_tz=%q\ntz_source=%q\ntz_verified=%q\n' "$when_tz" "$tz_source" "$tz_verified"
    fi
  } > "$d/meta"
  _sched_write_units "$id" "$timeout" "$SCHED_WHEN_KIND" "$SCHED_WHEN_VAL" "$first" "${SCHED_DAYS:-}" "$when_tz"
  systemctl --user daemon-reload
  systemctl --user enable --now "claude-schedule-$id.timer"
  local tz_note=""; [[ -n "$when_tz" ]] && tz_note=" ($when_tz${tz_source:+, from $tz_source})"
  echo "claude-session: scheduled '$id' — $SCHED_WHEN_KIND $SCHED_WHEN_VAL$tz_note, target=$target${sid:+ ($sid)}, account=$acct, mode=$mode"
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
  local svc="$SYSTEMD_USER_DIR/claude-schedule-$id.service"
  local timer="$SYSTEMD_USER_DIR/claude-schedule-$id.timer"
  local meta_dir="$SCHED_DIR/$id"

  # ${VAR:-0}, not a bare $VAR: tests/test_schedule_cmd.sh sources this file
  # and calls cmd_schedule_rm directly, without ever going through the
  # entrypoint's flag parsing — JSON_OUT/DRY_RUN/ASSUME_YES are simply unset
  # in that shell, and this file runs under `set -u`.
  _plan_reset "schedule.rm"
  _plan_argv claude-session schedule rm "$id"
  _plan_effect remove "$timer"
  _plan_effect remove "$svc"
  _plan_effect remove "$meta_dir"
  _plan_will_lose "the scheduled prompt '$id' (its unit files and metadata directory)"
  _plan_warn "the journal history for schedule $id (claude-session schedule log $id) is not preserved once the unit files are removed"

  if (( ${DRY_RUN:-0} == 1 )); then _plan_flush; exit 0; fi
  if (( ${ASSUME_YES:-0} == 1 )); then _plan_require_acks; fi

  systemctl --user disable --now "claude-schedule-$id.timer" 2>/dev/null || true
  rm -f "$svc" "$timer"
  rm -rf "${SCHED_DIR:?}/$id"
  systemctl --user daemon-reload 2>/dev/null || true
  echo "claude-session: removed schedule $id"
}

# Rewrite (or insert) one key=value line in a meta file, without disturbing any
# other line — used only for the three tz_* fields _sched_retime touches.
# Whole-file rewrite (filter + append), not `sed -i`: portable across the
# GNU/BSD sed differences this codebase already routes around elsewhere
# (compat.sh), and it is a handful of short lines, never worth a stream editor.
_sched_meta_settz() {
  local f="$1" tz="$2" src="$3" verified="$4" tmp="$1.tz.$$"
  grep -vE '^(when_tz|tz_source|tz_verified)=' "$f" > "$tmp" 2>/dev/null || true
  { cat "$tmp"
    printf 'when_tz=%q\ntz_source=%q\ntz_verified=%q\n' "$tz" "$src" "$verified"
  } > "$f"
  rm -f "$tmp"
}

# `schedule retime <id> --tz=<Zone>` — the ONLY way an existing wall-clock
# schedule's stored zone ever changes (decision #3: nothing on disk is
# rewritten silently). A plan/apply/ack mutation, same shape cmd_schedule_rm
# already uses: plan discloses BOTH firing instants (the current interpretation
# and the proposed one) because that disclosure is the entire point of not
# doing this silently — moving a firing time the user relies on requires
# having actually seen where it moves to.
cmd_schedule_retime() {
  local id="${1:-}"; [[ -n "$id" ]] || { echo "schedule retime: an id is required" >&2; exit 2; }
  local d="$SCHED_DIR/$id"
  [[ -d "$d" && -f "$d/meta" ]] || { echo "schedule retime: unknown schedule '$id'" >&2; exit 1; }
  local target="" sid="" account="" mode="" cwd="" timeout="" when_kind="" when_val="" \
        first="" model="" keepalive="" when_tz="" tz_source="" tz_verified=""
  # shellcheck disable=SC1091
  . "$d/meta"
  case "$when_kind" in
    daily-at|once|work-window) ;;
    *) echo "schedule retime: '$id' is when_kind=${when_kind:-?} — only wall-clock schedules (daily-at, once, work-window) carry a timezone; an 'every' interval schedule has none to retime" >&2; exit 2 ;;
  esac

  local zr; zr="$(_sched_tz_resolve --require)" || exit 2
  local new_tz="${zr%%$'\t'*}" new_src="${zr#*$'\t'}"

  # Validate the FULL string that will be written for every OnCalendar= line
  # this kind emits, exactly like cmd_schedule_add — a zone that fails even the
  # tzdata floor check must never reach a unit file.
  local spec new_verified=0
  while IFS= read -r spec; do
    _sched_tz_validate "$new_tz" "$spec $new_tz" || exit 2
  done < <(_sched_oncal_specs "$when_kind" "$when_val" "")
  new_verified="$SCHED_TZ_VERIFIED"

  local timer="$SYSTEMD_USER_DIR/claude-schedule-$id.timer"
  [[ -f "$timer" ]] || { echo "schedule retime: no timer unit on disk for '$id'" >&2; exit 1; }

  # The CURRENT interpretation: the stored zone if this schedule has one
  # already (re-zoning a previously-retimed schedule), else the host zone it
  # has been silently firing in all along.
  local cur_tz="${when_tz:-}"; [[ -z "$cur_tz" ]] && cur_tz="$(_host_timezone)"
  local cur_label="$when_tz"; [[ -z "$cur_label" ]] && cur_label="host $cur_tz"

  # The headline instant: work-window has two OnCalendar lines, so the plan
  # names the START of the window (its "9am" is the one a human anchors on).
  local hv="$when_val"
  case "$when_kind" in work-window) hv="${when_val%-*}" ;; once) hv="${when_val#* }" ;; esac

  local cur_epoch new_epoch cur_utc="unknown" new_utc="unknown"
  cur_epoch="$(_sched_local_epoch "$cur_tz" "$hv" 2>/dev/null)" || cur_epoch=""
  new_epoch="$(_sched_local_epoch "$new_tz" "$hv" 2>/dev/null)" || new_epoch=""
  [[ -n "$cur_epoch" ]] && cur_utc="$(TZ=UTC _epoch_to_human "$cur_epoch" '+%Y-%m-%d %H:%M')"
  [[ -n "$new_epoch" ]] && new_utc="$(TZ=UTC _epoch_to_human "$new_epoch" '+%Y-%m-%d %H:%M')"

  _plan_reset "schedule.retime"
  _plan_argv claude-session schedule retime "$id" "--tz=$new_tz"
  _plan_effect write "$timer"
  _plan_effect write "$d/meta"
  _plan_warn "schedule $id fires now at $hv:00 ($cur_label) = $cur_utc UTC"
  _plan_warn "it would fire at $hv:00 $new_tz = $new_utc UTC"

  local confirm_text="this moves schedule $id's firing instant from $cur_label to $new_tz"
  if [[ -n "$cur_epoch" && -n "$new_epoch" ]]; then
    local diff=$(( new_epoch - cur_epoch )) dir="later"
    (( diff < 0 )) && { diff=$(( -diff )); dir="earlier"; }
    local hh=$(( diff / 3600 )) mm=$(( (diff % 3600) / 60 ))
    if (( diff > 0 )); then
      _plan_warn "that is ${hh}h${mm}m $dir in UTC terms — confirm this is the change you want"
      confirm_text="this moves schedule $id's firing instant by ${hh}h${mm}m $dir (from $cur_label to $new_tz)"
    else
      _plan_warn "that is the SAME instant in UTC terms — only the recorded zone changes"
    fi
  fi
  _plan_confirm retime "$confirm_text"

  if (( ${DRY_RUN:-0} == 1 )); then _plan_flush; exit 0; fi
  if (( ${ASSUME_YES:-0} == 1 )); then _plan_require_acks; fi

  local bak="$d/unit.bak.$(date +%s)"
  cp "$timer" "$bak" 2>/dev/null || true

  _sched_write_units "$id" "$timeout" "$when_kind" "$when_val" "$first" "" "$new_tz"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user restart "claude-schedule-$id.timer" 2>/dev/null || true

  if ! grep -q "$new_tz" "$timer" 2>/dev/null; then
    cp "$bak" "$timer" 2>/dev/null || true
    systemctl --user daemon-reload 2>/dev/null || true
    echo "schedule retime: verification failed after rewriting '$id' — restored the previous unit" >&2
    exit 1
  fi

  _sched_meta_settz "$d/meta" "$new_tz" "$new_src" "$new_verified"
  echo "claude-session: retimed schedule '$id' to $new_tz (was: $cur_label) — backed up to $(basename "$bak")"
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

# Human `schedule ls` line for one wall-clock schedule's zone (decision #4:
# display never shows a bare wall-clock time again). Always names a zone —
# when none is stored (a legacy schedule predating this fix), it renders the
# HOST interpretation explicitly, labelled as an interpretation, never bare
# digits. When systemd-analyze can compute it, also shows the same instant in
# UTC whenever that differs from the schedule's own zone — e.g. Europe/Vilnius
# 09:00 is 06:00-07:00 UTC depending on DST, never the same digits.
_sched_ls_zone_line() {
  local id="$1" kind="$2" val="$3" tz="$4" src="$5"
  local hv="$val"
  case "$kind" in
    work-window) hv="${val%-*}" ;;
    once)        hv="${val#* }" ;;
  esac
  local zone note=""
  if [[ -n "$tz" ]]; then
    zone="$tz"
    case "$src" in
      host)   note=" (from this host's timezone — confirm that is really where you work)" ;;
      config) note=" (from schedule_tz in config.conf)" ;;
    esac
  else
    zone="$(_host_timezone)"
    note=" — legacy schedule, no stored timezone; interpreted as this host's $zone (claude-session schedule retime $id --tz=<Zone> to fix)"
  fi
  local line; printf -v line 'zone %s%s' "$zone" "$note"
  if command -v systemd-analyze >/dev/null 2>&1; then
    local ep; ep="$(_sched_local_epoch "$zone" "$hv" 2>/dev/null)" || ep=""
    if [[ -n "$ep" ]]; then
      local utc; utc="$(TZ=UTC _epoch_to_human "$ep" '+%H:%M')"
      [[ "$utc" != "$hv" ]] && line+=" — $hv $zone = $utc UTC"
    fi
  fi
  box_line "$(printf '    %b%s%b' "$DIM" "$line" "$N")"
}

cmd_schedule_ls() {
  # --json short-circuits before any human rendering: it emits the same
  # schedules section _snapshot's envelope would, verbatim.
  if (( JSON_OUT == 1 )); then _json_section_schedules; return 0; fi
  box_top "Scheduled prompts"
  shopt -s nullglob
  local any=0 d id
  for d in "$SCHED_DIR"/*/; do
    any=1; id="$(basename "$d")"
    local target="" sid="" account="" mode="" when_kind="" when_val="" when_tz="" tz_source="" tz_verified=""
    # shellcheck disable=SC1091
    . "$d/meta" 2>/dev/null || true
    # Pre-existing latent defect, surfaced by this task's own doctor fixture
    # (a hand-written `every1` meta with no prompt.txt, exactly the shape a
    # partially-written or hand-edited schedule has): under `set -euo
    # pipefail`, `prompt="$(head ... missing-file)"` is a plain assignment
    # whose exit status is `head`'s (1, ENOENT) even with stderr redirected —
    # tripping `set -e` and aborting `schedule ls` mid-loop, which silently
    # truncated the listing for every schedule after the missing-prompt one.
    # `|| true` keeps that one row's prompt an honest empty string instead of
    # crashing the whole command.
    local prompt=""; prompt="$(head -c 60 "$d/prompt.txt" 2>/dev/null)" || true
    box_line "$(printf '%b%s%b  %s %s  %b%s%b%s  %bmode%b %s' "$BOLD" "$id" "$N" "$when_kind" "$when_val" \
      "$C" "$target" "$N" "${sid:+ ($sid)}" "$DIM" "$N" "$mode")"
    box_line "$(printf '    %b%s%b' "$Y" "$(truncate_str "$prompt" 60)" "$N")"
    case "$when_kind" in
      daily-at|once|work-window) _sched_ls_zone_line "$id" "$when_kind" "$when_val" "$when_tz" "$tz_source" ;;
    esac
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

# Create (or skip, if one already exists) the keepalive schedule for one
# account. $2/$3 = when_kind/when_val — either `every <span>` (the original,
# interval-based keepalive) or `work-window <HH:MM-HH:MM>` (--work: land pings
# only inside the user's working day; requires an explicit zone, enforced by
# cmd_schedule_add's own resolution before this ever writes a unit).
_keepalive_one() {
  local acct="$1" kind="$2" val="$3"
  local existing
  if existing="$(_keepalive_existing_id "$acct")"; then
    echo "keepalive already set for $acct ($existing) — skipping"
    return 0
  fi
  SCHED_NEW=1 SCHED_CHAT="" SCHED_WHEN_KIND="$kind" SCHED_WHEN_VAL="$val" \
  ACCOUNT="$acct" CLAUDE_MODE=plan SCHED_MODEL=haiku SCHED_KEEPALIVE=1 \
  SCHED_CWD="${SCHED_CWD:-$HOME}" SCHED_TIMEOUT="${SCHED_TIMEOUT:-5m}" \
    cmd_schedule_add "hi" >/dev/null
  echo "keepalive created for $acct ($kind $val)"
}

# `schedule keepalive` — one self-pinging --new/plan/haiku "hi" schedule per
# account (or a single account via --account=), idempotent per account.
# --work=<HH:MM-HH:MM> switches it from an interval ping to a work-window one
# (pings at the start and end of the window); the zone requirement for that
# path is enforced earlier, by cmd_schedule's dispatch-time check, so a
# missing zone never gets this far.
cmd_schedule_keepalive() {
  local kind=every val="5h"
  [[ "${SCHED_WHEN_KIND:-}" == every && -n "${SCHED_WHEN_VAL:-}" ]] && val="$SCHED_WHEN_VAL"
  if [[ -n "${SCHED_WORK:-}" ]]; then kind=work-window; val="$SCHED_WORK"; fi
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
      _keepalive_one "$acct" "$kind" "$val"
    done < <(_all_accounts)
  else
    _keepalive_one "${ACCOUNT:-default}" "$kind" "$val"
  fi
}

cmd_schedule() {
  local sub="${1:-ls}"; shift || true

  # --work requires an explicit zone (flag or config) and refuses BEFORE
  # anything else runs — including the --json availability gate right below
  # — so the refusal (naming --tz=, schedule_tz, and the detected host zone)
  # is visible no matter how the caller invoked it. A defaulted host zone
  # here would silently defeat --work's entire reason to exist: landing pings
  # inside the USER's day (decision #2 — not re-opened).
  if [[ "$sub" == "keepalive" && -n "${SCHED_WORK:-}" ]]; then
    _sched_tz_resolve --require >/dev/null || exit 2
  fi

  # _JSON_READY_VERBS gates by verb ("schedule") as a whole; only `ls` (via
  # _json_section_schedules, called from cmd_schedule_ls above) actually
  # emits JSON. Without this subcommand-level check, `schedule add --json`
  # would pass the top-level guard and then silently run its ordinary
  # interactive path — the same failure mode cmd_accounts already guards
  # against for `accounts add/rm --json`, and cmd_transfer now guards for
  # every `transfer` subcommand but `log`.
  if (( JSON_OUT == 1 )) && [[ "$sub" != "ls" ]]; then
    # `rm`/`retime` build a plan (Task 10; this task) — --json is allowed
    # through for them too, but only alongside --dry-run/--yes, same rule
    # every other mutating verb applies (never bare, or a plan/apply-unaware
    # script could silently have --json ignored instead of erroring on it).
    if [[ ( "$sub" == "rm" || "$sub" == "retime" ) ]] && (( DRY_RUN == 1 || ASSUME_YES == 1 )); then
      :
    else
      echo "claude-session: --json is not available for 'schedule $sub' in this build" >&2
      exit 2
    fi
  fi
  case "$sub" in
    add)       cmd_schedule_add "$*" ;;
    ls)        cmd_schedule_ls ;;
    rm)        cmd_schedule_rm "${1:-}" ;;
    log)       cmd_schedule_log "${1:-}" ;;
    run)       cmd_schedule_run_now "${1:-}" ;;
    keepalive) cmd_schedule_keepalive ;;
    retime)    cmd_schedule_retime "${1:-}" ;;
    *)   echo "claude-session schedule: unknown subcommand '$sub' (add|ls|rm|log|run|keepalive|retime)" >&2; exit 2 ;;
  esac
}
