#!/usr/bin/env bash
#
# install.sh — installer for claude-session.
#
# IMPORTANT: this script must run under bash 3.2 (macOS's stock /bin/bash) far
# enough to report the "needs bash >= 4" message cleanly, instead of dying on
# an opaque syntax error. Do not use associative arrays, `${var,,}`/`${var^^}`,
# `mapfile`/`readarray`, or any other bash-4-only feature anywhere in this file.
set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

PREFIX="$HOME/.local"
MODE="copy"      # copy | link
NO_MAN=0
RUN_TESTS=0
DRY_RUN=0
FORCE=0

usage() {
  cat <<'EOF'
Usage: install.sh [options]

  --prefix=DIR   install prefix (default: ~/.local)
  --link         symlink bin/lib into the repo instead of copying (development)
  --copy         copy bin/lib into the prefix (default; for end users)
  --no-man       skip installing the man page
  --run-tests    run tests/run-tests.sh after installing
  --dry-run      print every action that would be taken; change nothing
  --force        overwrite existing non-symlink files at the destination
  -h, --help     show this help and exit

Examples:
  ./install.sh
  ./install.sh --prefix=/usr/local --run-tests
  ./install.sh --link              # development: keep files editable in the repo
  ./install.sh --dry-run           # see the plan without touching anything
EOF
}

for arg in "$@"; do
  case "$arg" in
    --prefix=*) PREFIX="${arg#--prefix=}" ;;
    --link) MODE="link" ;;
    --copy) MODE="copy" ;;
    --no-man) NO_MAN=1 ;;
    --run-tests) RUN_TESTS=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "install.sh: unknown option: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Expand a leading ~ ourselves: `--prefix=~/foo` is not a shell assignment word,
# so bash never tilde-expands it for us.
case "$PREFIX" in
  "~") PREFIX="$HOME" ;;
  "~/"*) PREFIX="$HOME/${PREFIX#\~/}" ;;
esac

# ---- echo-or-execute helper -------------------------------------------------
# Every filesystem-changing action in this script MUST go through _run so that
# --dry-run can announce it without performing it.
_run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] $*"
  else
    echo "+ $*"
    "$@"
  fi
}

if [ "$DRY_RUN" -eq 1 ]; then
  echo "install.sh: --dry-run: printing the plan, changing nothing"
fi

# ---- platform detection -----------------------------------------------------
UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
case "$UNAME_S" in
  Linux)  OS=linux ;;
  Darwin) OS=darwin ;;
  *)
    echo "install.sh: unsupported platform '$UNAME_S' — only Linux and macOS are supported." >&2
    exit 1
    ;;
esac

# ---- bash >= 4 requirement --------------------------------------------------
# claude-session uses `declare -A` at top level; bash 3.2 (macOS's shipped
# bash) dies on that with an opaque error. Resolve the bash that a plain
# `#!/usr/bin/env bash` invocation would find, so this also catches the case
# where install.sh itself is run with an old /bin/bash but a newer bash is
# already on PATH (e.g. via Homebrew) — and vice versa.
BASH_BIN="$(command -v bash 2>/dev/null || echo /bin/bash)"
BASH_MAJOR="$("$BASH_BIN" -c 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)"
case "$BASH_MAJOR" in
  ''|*[!0-9]*) BASH_MAJOR=0 ;;
esac
if [ "$BASH_MAJOR" -lt 4 ]; then
  echo "install.sh: claude-session needs bash >= 4 (found bash $BASH_MAJOR at $BASH_BIN)." >&2
  if [ "$OS" = darwin ]; then
    echo "  macOS ships bash 3.2. Install a newer one:  brew install bash" >&2
    echo "  then re-run this installer — the shebang picks up the newer bash from PATH." >&2
  else
    echo "  install a current bash from your package manager and re-run." >&2
  fi
  exit 1
fi

# ---- required dependencies ---------------------------------------------------
REQUIRED_DEPS="jq tmux awk sed grep ps find date stat"
missing=""
for dep in $REQUIRED_DEPS; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    missing="$missing $dep"
  fi
done
if [ -n "$missing" ]; then
  echo "install.sh: missing required dependencies:$missing" >&2
  if [ "$OS" = darwin ]; then
    echo "  install with:  brew install$missing" >&2
  else
    echo "  install with:  sudo apt-get install -y$missing     (Debian/Ubuntu)" >&2
    echo "            or:  sudo dnf install -y$missing         (Fedora/RHEL)" >&2
    echo "            or:  sudo pacman -S --needed$missing     (Arch)" >&2
  fi
  exit 1
fi
echo "install.sh: all required dependencies present ($REQUIRED_DEPS)"

# ---- optional dependencies: report exactly which features degrade ----------
_degrades() { echo "install.sh: optional: $1" >&2; }

if ! command -v openssl >/dev/null 2>&1 && ! command -v uuidgen >/dev/null 2>&1; then
  _degrades "no openssl or uuidgen — transfer/ledger IDs fall back to a weaker random source"
fi
if ! command -v fzf >/dev/null 2>&1; then
  _degrades "no fzf — 'resume'/'kill' pickers and doctor preview fall back to plain numbered prompts"
fi
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  _degrades "no timeout or gtimeout — time-capped operations will run unbounded instead"
fi
if ! command -v perl >/dev/null 2>&1; then
  _degrades "no perl — symlink-chain path resolution falls back to a plainer method"
fi
case "$OS" in
  darwin)
    if ! command -v launchctl >/dev/null 2>&1; then
      _degrades "no launchctl — 'schedule'/'keepalive' (prompt scheduling) will not work"
    fi
    ;;
  *)
    if ! systemctl --user status >/dev/null 2>&1; then
      _degrades "no working 'systemctl --user' — 'schedule'/'keepalive' (prompt scheduling) will not work"
    fi
    ;;
esac

# ---- install layout ----------------------------------------------------------
BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/share/claude-helpers"
MAN_DIR="$PREFIX/share/man/man1"

_run mkdir -p "$BIN_DIR"
_run mkdir -p "$LIB_DIR"

# install_file SRC DST MODE_BITS
# Refuses to clobber an existing non-symlink target unless --force was given.
install_file() {
  local src="$1" dst="$2" bits="$3"
  if [ -e "$dst" ] && [ ! -L "$dst" ] && [ "$FORCE" -ne 1 ]; then
    echo "install.sh: refusing to overwrite existing file: $dst (pass --force)" >&2
    exit 1
  fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    _run rm -f "$dst"
  fi
  if [ "$MODE" = "link" ]; then
    _run ln -s "$src" "$dst"
  else
    _run cp "$src" "$dst"
    _run chmod "$bits" "$dst"
  fi
}

echo "install.sh: installing bin/ (mode: $MODE) -> $BIN_DIR"
for f in "$REPO_DIR"/bin/*; do
  [ -e "$f" ] || continue
  install_file "$f" "$BIN_DIR/$(basename "$f")" 755
done

echo "install.sh: installing lib/ (mode: $MODE) -> $LIB_DIR"
for f in "$REPO_DIR"/lib/*.sh; do
  [ -e "$f" ] || continue
  install_file "$f" "$LIB_DIR/$(basename "$f")" 644
done

if [ "$NO_MAN" -eq 1 ]; then
  echo "install.sh: --no-man: skipping man page"
else
  found_man=0
  for f in "$REPO_DIR"/man/*.1; do
    [ -e "$f" ] || continue
    found_man=1
    _run mkdir -p "$MAN_DIR"
    install_file "$f" "$MAN_DIR/$(basename "$f")" 644
  done
  if [ "$found_man" -eq 0 ]; then
    echo "install.sh: no man page found under $REPO_DIR/man — skipping"
  fi
fi

# ---- PATH check ---------------------------------------------------------------
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "install.sh: warning: $BIN_DIR is not on your PATH." >&2
    echo "  add this to your shell profile (~/.bashrc, ~/.zshrc, ~/.profile, ...):" >&2
    echo "    export PATH=\"$BIN_DIR:\$PATH\"" >&2
    ;;
esac

# ---- verify -------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] $BIN_DIR/claude-session --version"
else
  echo "+ $BIN_DIR/claude-session --version"
  if verify_out="$("$BIN_DIR/claude-session" --version 2>&1)"; then
    echo "install.sh: installed entrypoint responds:"
    echo "$verify_out" | sed 's/^/  /'
  else
    echo "install.sh: warning: '$BIN_DIR/claude-session --version' did not succeed (continuing anyway)." >&2
    echo "  this is expected if --version isn't wired up in the installed code yet." >&2
  fi
fi

# ---- optional test run --------------------------------------------------------
if [ "$RUN_TESTS" -eq 1 ]; then
  if [ -f "$REPO_DIR/tests/run-tests.sh" ]; then
    _run bash "$REPO_DIR/tests/run-tests.sh"
  else
    echo "install.sh: --run-tests: $REPO_DIR/tests/run-tests.sh not present yet; skipping" >&2
  fi
fi

# ---- next steps ----------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  echo "install.sh: dry-run complete — nothing was changed."
else
  echo "install.sh: done."
  echo ""
  echo "Next steps:"
  echo "  claude-session accounts add work   # register an account and log in"
  echo "  claude-session ls                  # see your sessions"
fi
