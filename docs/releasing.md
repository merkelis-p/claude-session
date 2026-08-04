# CI and releasing

## This is an extension, not a port

There is no binary-release precedent anywhere in this project to copy from.
Before this change, claude-session had **zero git tags, zero GitHub releases,
and no `.github/` directory at all** — every install has always meant "clone
the repo and run `install.sh`" against whatever commit happened to be checked
out.

What follows is a deliberate extension of an existing CI *philosophy*
(explicit promotion instead of trigger chains, verify-before-ship, minimal
`permissions:`, heavy WHY comments, a first-class rollback path) already used
elsewhere in this maintainer's toolchain — not a port of some other project's
release pipeline. Nothing below was copied from a working release process,
because no working release process existed to copy.

## The three workflows

| File | Trigger | Purpose |
|---|---|---|
| `.github/workflows/ci.yml` | `pull_request` → `main`, or `workflow_dispatch` | Run the bash test suite on Linux and macOS; never on every push. |
| `.github/workflows/release.yml` | `workflow_dispatch` only | Tag an exact, CI-verified commit and publish a GitHub Release. Never automatic. |
| `.github/workflows/yank-release.yml` | `workflow_dispatch` only | Pull a bad release back without rewriting history. Never automatic. |

None of these run on a schedule, on `push`, or on another workflow completing.
Every mutating action in this repo's release lifecycle starts with a human
typing a `gh workflow run` command.

## Conventions carried over, and where this deviates

| Convention | Carried over from | Where it landed here |
|---|---|---|
| CI on `pull_request` + `workflow_dispatch`, never on every push | Existing CI philosophy: several development lanes push every commit; the local gate (`bash tests/run-tests.sh`) is the fast loop, CI on every push is waste | `ci.yml` triggers |
| Promotion is an explicit decision via an input, never inferred | Same philosophy: nothing ships because a chain of triggers happened to fire | `release.yml`'s `release_sha` input |
| Validate a SHA input's *shape* (40-hex) AND verify a successful CI run exists for that *exact* SHA via the GitHub API | Same philosophy: a promotion path must never ship a commit CI hasn't actually passed | `release.yml`'s `validate` job |
| Per-target `concurrency` group, `cancel-in-progress: false` for anything that ships; `cancel-in-progress: true` for CI itself | Same philosophy | `ci.yml` (`true`), `release.yml`/`yank-release.yml` (`false`, shared group so a yank can't interleave with a release) |
| Minimal `permissions:` per workflow | Same philosophy | `contents: read` for CI; `contents: write` (+`actions: read`) only where a tag/release is actually created |
| Heavy WHY comments, dated when a gate is temporary | Same philosophy | Throughout all three files |
| Rollback/undo as its own first-class, separately-dispatchable workflow | Same philosophy | `yank-release.yml` |

Deviations, all deliberate:

- **CI is one job with a `strategy.matrix` over `os`, not two separately
  named jobs.** The instruction asked for "a matrix including `ubuntu-latest`
  and `macos-latest`"; a real `strategy.matrix` reads that literally and keeps
  the OS-specific steps (Homebrew install, the bash-3.2 check, the skip
  allowlist) as `if: runner.os == '...'` conditionals inside one job rather
  than duplicated across two. Same coverage either way.
- **The `ref` input on `ci.yml`'s `workflow_dispatch` is actually wired to
  `actions/checkout`** (`ref: ${{ inputs.ref || github.ref }}`), rather than
  left as documentation-only. The description promises "defaults to the
  selected ref" — that only becomes true when a checkout step reads it.
- **No `go`, `go-macos`, or `contract` jobs yet.** The target design (once the
  Go TUI exists) calls for a Go test job, a native-darwin Go job, and a
  bash↔Go contract-test job. None of `tui/`, `tui/go.mod`, or
  `tests/test_json.sh` / `tests/test_tui_contract.sh` exist in this repository
  today. Adding those jobs now would make every CI run fail for a reason that
  has nothing to do with the change under review — the opposite of what CI on
  a PR is for. `ci.yml` ends with a clearly-marked, commented-out block
  showing the exact shape to add once `tui/` lands.
- **No `shellcheck` job.** It's requested for the CI's `bash` job. This is a
  3,300-line script that has never been shellchecked; turning it on cold, with
  no baseline pass or suppression file, would make CI fail on pre-existing
  style warnings unrelated to whatever change triggered the run — exactly the
  kind of noise this project's CI philosophy exists to avoid. `bash -n`
  (syntax only, matching the existing convention of validating scripts before
  shipping them) is included; shellcheck is a reasonable follow-up once
  someone has run it once locally and either fixed or deliberately suppressed
  what it finds.

## The macOS legs — why they matter, what they actually test

`lib/compat.sh` is the one piece of code in this repository that has *never
run on a real Mac*. Every test that exercises its darwin branch does so via
`CLAUDE_COMPAT_OS=darwin` plus a stub `stat`/`date` on `PATH`
(`tests/test_compat.sh`) — which proves the code *invokes* `stat -f '%m'`,
`date -r`, `date -j -f`, etc. with the right flags, and proves nothing about
whether those flags actually work against BSD's real `stat`/`date`/`ps`, or
whether the `perl -MCwd=abs_path` fallback behaves as expected. `ci.yml`'s
`macos-latest` leg is the first time any of that code runs for real.

### The bash 3.2 vs. bash 4+ decision

macOS ships bash 3.2 as `/bin/bash` (Apple stopped updating it for licensing
reasons); `bin/claude-session` and every file under `lib/` use `declare -A`
and require bash ≥ 4. `install.sh` is deliberately written to still *parse
and run* under 3.2, far enough to print a clean "you need bash ≥ 4" message
instead of dying on an opaque syntax error (see its own header comment). Two
different bash versions therefore matter for two different reasons, and
`ci.yml` tests both, in this order:

1. **Stock `/bin/bash` (3.2), tested first, before Homebrew's bash is
   installed.** A dedicated step runs `install.sh --dry-run` under
   `/bin/bash` with `PATH` restricted to `/usr/bin:/bin`, so `command -v bash`
   inside the script can only find the stock one. It asserts the script exits
   non-zero *with the expected guidance text*, not just "it exited non-zero"
   (a real syntax error would also exit non-zero, and that's exactly the
   failure mode being ruled out).
2. **A Homebrew-installed bash 5, for everything else.** The application test
   suite (`tests/run-tests.sh`, which exercises `bin/claude-session` and
   `lib/*.sh` directly) runs under `brew install bash` afterward. Running the
   *application* suite under stock 3.2 would prove nothing new — the code
   can't even be parsed by 3.2, which is already fully known and already
   documented in `README.md` ("Platform support"). A real macOS user is
   *told* to install a newer bash before any of this works; testing under
   what the README tells them to have, rather than what Apple ships in the
   box, is the version of "real macOS" that actually matches a working
   install.

Getting this backwards either way was the risk: testing only under stock 3.2
would report every real test as "can't even run" and hide genuine regressions
behind a wall of syntax errors; testing only under a pre-installed bash 5
would never notice if the 3.2-compatibility guard in `install.sh` broke.

### The expected-skip allowlist

`tests/run-tests.sh` already prints *which* checks were skipped, not just how
many — its own comment explains why: a skip reads exactly like a pass in a
green summary. That protects a human reading the log. `ci.yml` adds a second
layer that protects CI itself, specifically on macOS, specifically because
this is macOS's first real run: a step captures every `SKIP:` line the suite
printed and diffs it against a checked-in list of exactly the skip lines this
project has actually seen and understood. Anything not on that list fails the
job — a *new* skip must be looked at by a person, not silently absorbed into
"the suite passed."

The list lives inline in `ci.yml`'s "Check for unexpected skips (macOS)" step,
written as a `printf` list rather than a separate file, so it stays in the one
place someone reviewing a CI change will actually look. Today it contains the
only three `SKIP:` lines that exist anywhere in the test suite
(`tests/test_real_ps.sh`), all host-state-dependent (no matching process, no
live session, no orphan on the runner) rather than platform-dependent — they
are just as likely to fire on a freshly-provisioned `ubuntu-latest` runner
with no `~/.claude` data, but the strict gate is applied to macOS only, per
the instruction that scoped it there.

**To update it:** read a macOS CI run that reported a skip not already on the
list, understand *why* it happened (genuine host-state variance vs. a real
platform gap silently reducing coverage), and only then paste its exact text
into the `printf` list in `ci.yml` with a one-line reason above it. Never add
a line just to turn a red job green.

## Cutting a release

```
gh workflow run Release \
  -f version=v0.2.0 \
  -f release_sha=$(git rev-parse origin/main)
gh run watch
```

`release.yml`'s `validate` job, in order: checks `version` looks like
`v0.2.0` and `release_sha` is a full 40-hex SHA; calls the GitHub API to
confirm `ci.yml` has a successful run for that *exact* SHA (refuses
otherwise); checks out that SHA and confirms `VERSION=` in
`bin/claude-session` matches the requested version (catches a forgotten
version bump); confirms the tag doesn't already exist (refuses to release a
version twice). Only after all of that does anything get built or published.

### The Go build: today vs. after `tui/` lands

**There is no Go binary to build yet.** The TUI (`tui/`) does not exist in
this repository. `release.yml`'s `build` job is gated on
`needs.validate.outputs.has_tui`, which a `validate` step sets by checking
whether `tui/go.mod` exists **at the released SHA** — not on a hardcoded flag
someone has to remember to flip. Today that check is false, `build` reports
`skipped`, and `publish` still runs (a `skipped` dependency is treated the
same as `success` here, deliberately — see the `if:` on the `publish` job).

The practical effect right now: `release.yml` creates a tag and a GitHub
Release with **no binary assets** — just the annotated tag, the release
notes pulled verbatim from the matching `## [x.y.z]` section of
`CHANGELOG.md`, and (since there are no assets) no `SHA256SUMS` file either.
That is the correct behavior for a bash-only release, not a degraded one.

**The moment a future commit adds `tui/go.mod`,** the very next release run
against a SHA that includes it will automatically:

1. build `linux/amd64` (on `ubuntu-latest`) and `darwin/arm64` (on
   `macos-latest`) **natively — never cross-compiled**, using the exact
   `CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=... -X
   main.schemaMin=... -X main.schemaMax=..."` shape from the TUI design spec;
2. smoke-test each binary with `--check` on the runner that built it;
3. upload both as `claude-session-tui-linux-amd64` and
   `claude-session-tui-darwin-arm64` — that exact naming (binary name +
   target triple suffix) is the contract anything doing an automated download
   later (e.g. a future `install.sh` TUI-acquisition path) should expect;
4. compute a `SHA256SUMS` covering both, and attach everything to the release.

No edit to `release.yml` is required for that transition. What **should** be
reviewed at that point (flagged inline in the `build` job as "UNTESTED —
pre-written"): the actual module path under `tui/cmd/...`, whether `--check`
still prints the version the way this workflow's grep expects, and whether
`go-version-file: tui/go.mod` resolves correctly once that file exists.

### Version numbering

`VERSION=` in `bin/claude-session` is the single source of truth for what
version the code claims to be; the release tag is always `v$VERSION`. The
`validate` job refuses to proceed if they disagree, which means bumping
`VERSION=` (and adding the matching `CHANGELOG.md` section) is a required
part of preparing a release, not an optional courtesy.

## Yanking a release

```
gh workflow run "Yank release" \
  -f tag=v0.2.0 \
  -f confirm_tag=v0.2.0 \
  -f reason="binary segfaults on darwin/arm64, see #NN"
```

This matters more than a typical "delete a bad release" button because
`install.sh`'s curl-pipe path resolves GitHub's "latest" release by name —
a bad release doesn't just sit there unused, it keeps installing itself onto
every new machine until the release metadata itself changes. Yanking:

1. marks the release a **prerelease** (so "latest" moves back to the previous
   good release) and prepends a `YANKED: <reason>` notice to its notes;
2. **deletes every binary asset**, so a client holding a stale `SHA256SUMS`
   entry can never satisfy the checksum by re-downloading the yanked file;
3. **leaves the git tag in place** — no `git tag -d`, no `git push --delete`.
   History is not rewritten; the record of what once existed stays honest;
4. appends a `## YANKED: ...` entry to `CHANGELOG.md`, spliced in right below
   the file's preamble, via a **pull request** (never a direct push to
   `main`).

`tag`, `reason`, and `confirm_tag` are all required inputs; `confirm_tag` must
exactly match `tag` or the job refuses before touching anything. Re-typing the
tag is a small deliberate friction against yanking the wrong release out of
habit — a yank deletes assets, which is not something a follow-up run can undo
by itself.

## Secrets and permissions

**No custom secrets are required by any of these workflows.** Every API call
and every `gh`/`git` mutation uses the built-in `${{ github.token }}`
(`GITHUB_TOKEN`), scoped down per workflow via `permissions:`:

| Workflow | `permissions:` | Why |
|---|---|---|
| `ci.yml` | `contents: read` | Only ever reads the repo and runs tests. |
| `release.yml` | `contents: write`, `actions: read` | `contents: write` to push the tag and create the release; `actions: read` to query CI run history via the API. |
| `yank-release.yml` | `contents: write`, `pull-requests: write` | `contents: write` to edit the release, delete assets, and push the CHANGELOG branch; `pull-requests: write` to open the CHANGELOG PR. |

If this project ever needs to ship binaries somewhere `GITHUB_TOKEN` can't
reach (a package registry, a download mirror with its own auth), that secret
should be named after exactly what it authenticates to and documented here
before being referenced from a workflow — none of that exists today.
