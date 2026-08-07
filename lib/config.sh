# shellcheck shell=bash
# config.sh — ~/.config/claude-helpers/config.conf, the small set of user
# preferences that are not per-account and not per-schedule. Same convention as
# accounts.conf: plain `key=value` lines, re-read every invocation, hand-editable.
#
# Keys are ALLOWLISTED. A typo'd key is reported on stderr rather than ignored: a
# preference that silently did not apply is indistinguishable from one that did.
CS_CONFIG="${CS_CONFIG:-$HOME/.config/claude-helpers/config.conf}"
declare -A CS_CONFIG_VALS=()
_CS_CONFIG_LOADED=0
_CS_CONFIG_KEYS=" schedule_tz default_surface hints "
_cs_config_load() {
  (( _CS_CONFIG_LOADED )) && return 0
  _CS_CONFIG_LOADED=1
  # Cleared on every real (re)load, not just declared once at file-source time:
  # a caller that forces a reload (_CS_CONFIG_LOADED=0; _cs_config_load, e.g.
  # after config.conf changed on disk) means it for the FILE's current content
  # to win outright — a stale key from a previous load surviving a config.conf
  # that no longer sets it is the exact "invisible wrong default" this task
  # exists to eliminate, just relocated to the config reader itself.
  CS_CONFIG_VALS=()
  [[ -r "$CS_CONFIG" ]] || return 0
  local line k v
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    k="${line%%=*}"; v="${line#*=}"; k="${k// /}"
    case "$_CS_CONFIG_KEYS" in
      *" $k "*) CS_CONFIG_VALS[$k]="$v" ;;
      *) echo "claude-session: unknown key '$k' in $CS_CONFIG (known: ${_CS_CONFIG_KEYS# })" >&2 ;;
    esac
  done < "$CS_CONFIG"
}
