#!/usr/bin/env bash
#
# uninstall.sh — remove an installed claude-session.
#
# Keep this bash-3.2-safe too (same reasoning as install.sh): no associative
# arrays, no `${var,,}`/`${var^^}`, no mapfile/readarray.
set -eu

PREFIX="$HOME/.local"
PURGE=0
DRY_RUN=0
FORCE=0

usage() {
  cat <<'EOF'
Usage: uninstall.sh [options]

  --prefix=DIR   install prefix that was used at install time (default: ~/.local)
  --purge        also delete user data: ~/.config/claude-helpers/ (accounts,
                 transfer ledger, schedule metadata) and any installed
                 claude-schedule-* systemd user timers. Prompts for
                 confirmation unless --force is given.
  --dry-run      print every action that would be taken; change nothing
  --force        with --purge, skip the interactive confirmation
  -h, --help     show this help and exit

Without --purge, uninstall.sh only removes the installed program files; it
never touches ~/.config/claude-helpers/ (account registry, transfer ledger,
schedule metadata) or any registered account's own Claude Code config dir.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --prefix=*) PREFIX="${arg#--prefix=}" ;;
    --purge) PURGE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "uninstall.sh: unknown option: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$PREFIX" in
  "~") PREFIX="$HOME" ;;
  "~/"*) PREFIX="$HOME/${PREFIX#\~/}" ;;
esac

_run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] $*"
  else
    echo "+ $*"
    "$@"
  fi
}

if [ "$DRY_RUN" -eq 1 ]; then
  echo "uninstall.sh: --dry-run: printing the plan, changing nothing"
fi

BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/share/claude-helpers"
MAN_DIR="$PREFIX/share/man/man1"
CONFIG_DIR="$HOME/.config/claude-helpers"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

# ---- remove installed program files (always) --------------------------------
# Only ever remove what install.sh creates. An earlier revision also deleted
# `claude-nudge`, which this package does not ship or install — on a machine
# where the user had written their own `~/.local/bin/claude-nudge`, uninstalling
# claude-session would have silently destroyed an unrelated personal script.
for entrypoint in claude-session; do
  if [ -e "$BIN_DIR/$entrypoint" ] || [ -L "$BIN_DIR/$entrypoint" ]; then
    _run rm -f "$BIN_DIR/$entrypoint"
  fi
done

if [ -d "$LIB_DIR" ]; then
  for f in "$LIB_DIR"/*.sh; do
    [ -e "$f" ] || continue
    _run rm -f "$f"
  done
  # Remove the lib dir itself only if it's now empty (real run) — under
  # --dry-run we can't know that without having actually deleted anything.
  if [ "$DRY_RUN" -eq 0 ]; then
    if [ -d "$LIB_DIR" ] && [ -z "$(ls -A "$LIB_DIR" 2>/dev/null)" ]; then
      _run rmdir "$LIB_DIR"
    fi
  else
    echo "[dry-run] rmdir $LIB_DIR (if empty afterwards)"
  fi
fi

if [ -d "$MAN_DIR" ]; then
  for name in claude-session; do
    f="$MAN_DIR/$name.1"
    [ -e "$f" ] && _run rm -f "$f"
  done
fi

echo "uninstall.sh: removed installed program files from $PREFIX"

# ---- user data: touched ONLY with --purge ------------------------------------
if [ "$PURGE" -eq 0 ]; then
  echo ""
  echo "uninstall.sh: left user data untouched:"
  [ -e "$CONFIG_DIR" ] && echo "  $CONFIG_DIR/  (accounts, transfer ledger, schedule metadata)"
  echo "  each registered account's own Claude Code config dir"
  echo "To also remove claude-session's own data, re-run with --purge."
  exit 0
fi

# ---- --purge: list, confirm, delete ------------------------------------------
purge_items=""
[ -f "$CONFIG_DIR/accounts.conf" ]      && purge_items="$purge_items $CONFIG_DIR/accounts.conf"
[ -f "$CONFIG_DIR/transfer-log.jsonl" ] && purge_items="$purge_items $CONFIG_DIR/transfer-log.jsonl"
[ -d "$CONFIG_DIR/schedules" ]          && purge_items="$purge_items $CONFIG_DIR/schedules/"

sched_units=""
if [ -d "$SYSTEMD_USER_DIR" ]; then
  for f in "$SYSTEMD_USER_DIR"/claude-schedule-*.service "$SYSTEMD_USER_DIR"/claude-schedule-*.timer; do
    [ -e "$f" ] || continue
    sched_units="$sched_units $f"
  done
fi

echo ""
echo "uninstall.sh: --purge will also delete:"
if [ -z "$purge_items$sched_units" ]; then
  echo "  (nothing found — no claude-helpers user data or schedule units exist)"
else
  for item in $purge_items $sched_units; do
    echo "  $item"
  done
fi
echo "uninstall.sh: this NEVER touches registered accounts' own Claude Code config dirs (credentials)."

if [ -z "$purge_items$sched_units" ]; then
  exit 0
fi

if [ "$DRY_RUN" -eq 0 ] && [ "$FORCE" -ne 1 ]; then
  printf 'Type y to confirm permanent deletion of the above: '
  read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "uninstall.sh: purge cancelled."; exit 1 ;;
  esac
fi

for f in $sched_units; do
  case "$(basename "$f")" in
    *.timer)
      id="$(basename "$f" .timer)"
      command -v systemctl >/dev/null 2>&1 && _run systemctl --user disable --now "$id.timer" 2>/dev/null || true
      ;;
  esac
  _run rm -f "$f"
done
if [ -n "$sched_units" ] && command -v systemctl >/dev/null 2>&1; then
  _run systemctl --user daemon-reload 2>/dev/null || true
fi

for item in $purge_items; do
  case "$item" in
    */) _run rm -rf "${item%/}" ;;
    *)  _run rm -f "$item" ;;
  esac
done

if [ "$DRY_RUN" -eq 0 ] && [ -d "$CONFIG_DIR" ] && [ -z "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ]; then
  _run rmdir "$CONFIG_DIR"
fi

echo "uninstall.sh: purge complete."
