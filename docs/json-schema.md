# The `--json` envelope

**Problem:** the TUI (`tui/`) polls claude-session for state instead of
parsing box-drawn text. Every `--json` document — the internal `_snapshot`
envelope and each verb's own `--json` output — is built from the same
section emitters in `lib/json.sh`, so the human rendering and the app can
never disagree about a judgment. This page documents that shared surface:
the envelope itself, the contract every section follows, and the field list
per section.

All paths and account names below are placeholders (`/home/u/...`,
`default`/`alpha`/`beta`) — nothing in this document, or in any fixture it
references, names a real machine.

## The envelope

```bash
claude-session _snapshot --json                          # every section
claude-session _snapshot --json --only=chats,ledger      # a subset
claude-session _snapshot --json --only=meta               # the preamble only, no sections
```

```json
{
  "schemaVersion": 1,
  "generatedAt": 1785900000,
  "elapsedMs": 42,
  "core": {
    "version": "0.2.0",
    "platform": "linux",
    "bash": "5.2.21(1)-release",
    "lib": "/home/u/.local/share/claude-helpers",
    "elapsedMsPrecision": "ms"
  },
  "sections": { "accounts": { … }, "chats": { … }, "…": { … } }
}
```

| field | type | notes |
|---|---|---|
| `schemaVersion` | number | bumped whenever a breaking change lands; the Go TUI pins a `schemaMax` and refuses to read past it (`tests/test_json.sh`'s own cross-check enforces the two stay in sync). |
| `generatedAt` | number | epoch **seconds**, not milliseconds — matches every other instant field in this document (ledger `transferTs`/`destMtime`, schedules `nextFire`/`lastFire`). |
| `elapsedMs` | number | wall-clock cost of building this envelope. |
| `core.elapsedMsPrecision` | `"ms"` \| `"s"` | bash ≥5 has `EPOCHREALTIME` (sub-second); bash 4 does not. An `elapsedMs` of `0` on a host that reports `"s"` precision means "could not measure to the millisecond", never "instant" — the precision field exists so a consumer never has to guess which. |
| `sections` | object | keyed by section name; present only for the sections `--only` selected (or all of them, the default). |

`--only` accepts a comma-separated subset of `meta accounts chats issues
processes ledger schedules`; an unknown name is a hard error (exit 2), never
a silently-empty section.

Every verb-level `--json` form (`accounts ls --json`, `transfer log --json`,
`schedule ls --json`, …) emits **exactly** its envelope section's document —
byte-identical, because both call the same `_json_section_*` function.
`--json` is gated per verb by `_JSON_READY_VERBS`, and — for verbs with more
than one subcommand — per subcommand too: `accounts add --json`,
`transfer undo --json`, and `schedule add --json` are all hard errors (exit
2), not silently-ignored flags. `--json` never prompts and never emits ANSI,
including under `FORCE_COLOR=1`.

## The section contract

Every section is an object shaped like this, regardless of which one:

```json
{
  "status": "ok",
  "checksRun": ["…"],
  "checksSkipped": [{"name": "…", "reason": "…"}],
  "errors": [],
  "items": [ … ]
}
```

| field | type | notes |
|---|---|---|
| `status` | string | one of the four values below. |
| `checksRun` | array of strings | the check catalogue this section can perform — present even when every one of them was skipped this run. |
| `checksSkipped` | array of `{name, reason}` | a check that did not run this time, and **why**. Never omitted in favor of a shorter `checksRun` — a skip has to be a value in the document, because it reads exactly like a pass once it reaches a summary line. |
| `errors` | array of strings | populated only when a check that DID run could not complete trustworthily (a corrupt ledger file, for example) — distinct from `checksSkipped`, which means a check never ran at all. |
| `items` | array | the section's actual rows; always present, always `[]` rather than omitted when there is nothing to report. |

### The four `status` values

| value | meaning |
|---|---|
| `ok` | every check that was expected to run either ran cleanly or was explicitly skipped (see `checksSkipped`); `items` may still be empty — an empty, working section and a section that could not run are different documents (see below). |
| `partial` | the check ran, but one or more individual rows could not resolve every field they need (see **criticality**, next) — `items` still carries every row, degraded ones included. |
| `unavailable` | the check's own precondition is missing on this host (no working `systemctl --user`, for example) — the check **could not run at all**, for every row, not just some. |
| `error` | a check that DID run failed to produce a trustworthy result (a ledger file that fails to parse as JSON) — `errors` names what went wrong. |

**The rule this whole design exists to enforce:** `unavailable` must never
render identically to an empty `ok`. A host with no working `systemctl
--user` yields `status:"unavailable"` with a `reason` field and `items:[]`;
a host with a working `systemctl --user` and zero configured schedules
yields `status:"ok"`, `items:[]`, and **no** `reason` field at all — the key
is absent, not `null`. `tests/test_json.sh` asserts both the presence and
the literal inequality of the two documents, not just their `status`
strings, because two documents that differ only in a status string one
reader might not check are still the render-alike bug this rule exists to
prevent.

## Field criticality

Every item-level field is either:

- **critical** — a consumer's core judgment about that row depends on it
  (can this chat be resumed, can this transfer be undone, is this schedule
  actually going to fire). A row that cannot resolve a critical field is
  still emitted — **never dropped** — with `degraded:true` and a
  `degradedReason` naming which field(s) failed, so a broken row still shows
  up as broken rather than silently vanishing from the list.
- **informational** — context or diagnostics; useful, but nothing downstream
  breaks if it comes back `null`/`"unknown"`.

The chats section is the one place this is backed by an explicit constant
(`CHAT_CRITICAL_FIELDS` in `lib/json.sh`): `sessionId account accountDir
transcriptPath runtime.pid runtime.alive` — the last two only when
`runtime.present` is `true` (a transcript-only chat has no runtime by
design, and that absence is not degradation). The other sections do not yet
carry their own degraded-row machinery; the critical/informational split
below is the same design principle applied by inspection, so a future
`degraded` implementation for those sections has a place to land without
renegotiating which fields matter.

## Tri-state fields

A field whose value this build cannot always determine is never just
`null` on its own — `null` alone cannot distinguish "checked, no value" from
"never checked" from "checked, and it failed". Those fields are an object:

```json
{ "value": null, "state": "unknown", "note": "optional, present when there's something specific to say" }
```

`state` is one of:

| state | meaning |
|---|---|
| `known` | `value` is populated and trustworthy. |
| `unknown` | not resolved this run (a title-index miss, a timer systemd never listed) — `value` is `null`. |
| `notRun` | the check that would populate this field did not execute at all this poll. |
| `errored` | the check ran and failed. |
| `derived` | `value` was computed from other fields rather than read directly (reserved for a future judgment field; nothing in this build sets it yet). |

`note` is optional — most `state:"unknown"` fields in this build carry no
`note` (the two-key `{value,state}` shape is what `title`, `rss`, `nextFire`,
and `lastFire` all actually emit today); it exists for a future field where
"unknown" alone would be too little explanation.

**Every comparison between two tri-state instants is between the `value`s,
never between formatted strings.** `nextFire`/`lastFire` (schedules) and
`destMtime`/`transferTs` (ledger) are all epoch **seconds** for exactly this
reason — comparing wall-clock strings across time zones is meaningless, and
an integer comparison is not.

## Sections

### `accounts`

One row per registered account (synthetic `default` first, then registry
order), so the app's pane order matches the CLI's.

| field | type | critical? | notes |
|---|---|---|---|
| `name` | string | critical | |
| `dir` | string | critical | the configured `CLAUDE_CONFIG_DIR`, reported even when it does not exist on disk — a missing directory is a fact about the account, not a reason to hide it. |
| `credentials` | boolean | critical | `.credentials.json` present — always the literal `true`/`false`, never omitted, never `"unknown"`. |
| `description` | string | informational | from `accounts.conf`; empty string, not `null`, when none was set. |

`checksSkipped` always names `quota-anchor` — quota-anchor tracking has no
storage in this build.

### `chats`

One row per live runtime session or on-disk transcript, across every
registered account, windowed to `CHAT_LIMIT` (200).

| field | type | critical? | notes |
|---|---|---|---|
| `sessionId` | string \| null | critical | `null` only for a runtime row whose session-state file lost its `sessionId` upstream — kept, not dropped. |
| `account` | string | critical | |
| `accountDir` | string | critical | |
| `transcriptPath` | string \| null | critical | |
| `transcriptPathSource` | `"sid-match"` \| `"cwd-fallback"` \| `""` | informational | a `cwd-fallback` resolution is a guess; the app renders it as one. |
| `title` | `{value, state, source}` | informational | `state` is `"known"`/`"unknown"` (a miss increments the section's `titlesIndex.pending`, resolved separately via `_titles`). |
| `cwd` | string \| null | informational | sourced from the live runtime record only, never read from the transcript itself (a per-row transcript read was measured at ~4.7s over a 195-row window; this field stays `null` for a transcript-only chat rather than pay that). |
| `mtime` | number \| null | informational | transcript file mtime, epoch seconds. |
| `runtime.present` | boolean | critical | |
| `runtime.pid` | number \| null | critical (when `present`) | |
| `runtime.tmux` | string \| null | informational | |
| `runtime.attachable` | boolean | informational | false for `(detached)`/`(vscode)`. |
| `runtime.entrypoint` | string \| null | informational | |
| `runtime.status` | string \| null | informational | |
| `runtime.statusAgeSec` | number \| null | informational | |
| `runtime.rss` | `{value, state}` | informational | MB; `state:"unknown"` when the pid isn't in this poll's `ps` map. |
| `runtime.bridgeSessionId` | string \| null | informational | |
| `runtime.alive` | boolean \| null | critical (when `present`) | |
| `flags` | array of `{kind, severity, text}` | informational | the same per-pid classification `ls` renders, plain text (no ANSI). |
| `provenance` | `{kind, from, ts}` \| null | informational | populated from the transfer ledger regardless of whether the chat is currently running. |
| `degraded` | boolean | — (meta) | true when any critical field above failed to resolve for this row. |
| `degradedReason` | string \| null | — (meta) | space-separated field names, when `degraded`. |

Section-level `titlesIndex: {state, resolved, pending}` reports the title
cache's health for THIS window only (`state` is `"warm"`/`"cold"` from the
index header alone) — never the whole-index lifetime stats, which is
`doctor`'s job, not a per-poll one.

### `issues` / `processes`

Both read the same underlying diagnostic rows `doctor` builds and split them
by kind: `issues` covers checks (1)-(5) and (8)-(9) (session-state
consistency, title-index health, upstream schema drift); `processes` covers
checks (6)-(7) (OS process-table scans: orphan processes, stuck builds),
which always run whether or not there is any Claude session to look at.

| field | type | critical? | notes |
|---|---|---|---|
| `kind` | string | informational | e.g. `same-chat-twice`, `orphan-process`. |
| `severity` | string | informational | e.g. `warning`, `error`. |
| `pid` | number \| null | informational | numeric, matching `chats.runtime.pid`'s own type. |
| `sessionId` | string \| null | informational | |
| `text` | string | informational | the same human-readable text `doctor` prints. |

`issues` skips every one of checks (1)-(5) by name (with reason "no Claude
session-state files to check") when there are no sessions at all; checks
(8)-(9) and both of `processes`' checks run unconditionally and are never
skipped for that reason.

### `ledger`

One row per transfer-log entry (`LEDGER_FILE`, override-able), newest first,
windowed to `TRANSFER_LIMIT` (50 by default, `0` = unbounded — the same
convention the `transfer` picker itself uses). `transfer log --json` emits
this section verbatim.

| field | type | critical? | notes |
|---|---|---|---|
| `id` | string | critical | |
| `sid` | string \| null | critical | |
| `title` | string | informational | the chat's title at transfer time, tab/newline-neutralized. |
| `from` / `to` | string | critical | account names. |
| `verb` | `"move"` \| `"copy"` \| `"undo"` | critical | |
| `undoOf` / `redoOf` | string \| null | informational | the ledger id this entry undoes/redoes. |
| `destExists` | boolean | critical | resolved fresh from disk this poll — `[[ -f <to's dir>/projects/*/<sid>.jsonl ]] `, never cached from the ledger write itself. |
| `sourceExists` | boolean | critical | same resolution, against `from`'s directory. |
| `transferTs` | number | critical | epoch seconds — the ledger entry's own `ts`, renamed here to sit next to `destMtime` unambiguously. |
| `destMtime` | number \| null | critical | epoch seconds; `null` when `destExists` is `false`. |
| `diverged` | boolean | critical | `destMtime > transferTs + 2` — the exact comparison `transfer undo` itself makes before it asks for confirmation (`lib/ledger.sh`'s `cmd_transfer_undo`), read from there rather than reimplemented. Always present, even when there is nothing to diverge from (`destExists:false` ⇒ `false`). |
| `undoable` | boolean | critical | `destExists && ` the entry has not already been undone by a later ledger entry (`undoOf` pointing back at this one) — the app's cue for whether to offer an "undo" action. |

A missing `LEDGER_FILE` is `status:"ok"`, `items:[]`, with `checksSkipped`
naming `endpoints` ("no ledger file yet") — a fresh box has no transfer
history, which is not a failure. A `LEDGER_FILE` that exists but fails to
parse as JSON is `status:"error"` with `errors` naming the problem — that
**is** a failure, and a different one from "empty".

### `schedules`

One row per `SCHED_DIR/*/meta`, joined against `systemctl --user
list-timers --output=json` for fire times and `systemctl --user show` for
unit state. `schedule ls --json` emits this section verbatim.

systemd is the only backend today (launchd is a separate spec), so a host
with no working `systemctl --user` cannot answer the question **at all** —
that is `status:"unavailable"` with a `reason`, covered above, never an
empty list.

| field | type | critical? | notes |
|---|---|---|---|
| `id` | string | critical | |
| `account` | string | critical | |
| `target` | `"chat"` \| `"new"` | critical | |
| `sid` | string \| null | critical (when `target=="chat"`) | `null` for `target=="new"`. |
| `whenKind` | `"every"` \| `"daily-at"` \| `"once"` | critical | |
| `whenVal` | string | critical | |
| `whenTz` | null | — | **honest unknown in this build**: always `null`. An unzoned wall-clock schedule is a defect, not a default — Task 12 fills this in and explains why. |
| `tzSource` | `"none"` | — | always `"none"` in this build. |
| `tzVerified` | `false` | — | always `false` in this build. |
| `pings` | null | — | how many times this schedule has actually fired; not tracked anywhere yet (systemd's own timer state has no counter, and computing one would mean a `journalctl` read this build does not do) — reported as an honest `null`, not guessed at. |
| `keepalive` | boolean | informational | |
| `mode` | string | informational | |
| `cwd` | string | informational | |
| `timeout` | string | informational | |
| `created` | number \| null | informational | epoch seconds. |
| `nextFire` | `{value, state}` | critical | epoch seconds; `state:"unknown"` (never epoch `0`) for a timer `list-timers` does not list, or lists with no next fire recorded. |
| `lastFire` | `{value, state}` | critical | same shape; `state:"unknown"` for a timer that has never fired. |
| `unitState` | string \| null | informational | the timer unit's `ActiveState`. |
| `drift` | `{state, reason, actualStart, evidence}` | critical (see below) | |

`drift.state` is one of `observed \| none \| unknown`, and **the app renders
a warning only for `"observed"`** — `"unknown"` must never be mistaken for a
pass. In this build `drift` is always the explicit unknown:

```json
"drift": { "state": "unknown",
           "reason": "work-window schedules and quota anchors are not in this build yet",
           "actualStart": null, "evidence": null }
```

work-window schedules and quota anchors — the two things a real drift
computation would compare against — do not exist yet; claiming
`drift:{state:"none"}` here would be a check reported as a pass without
ever having run. Task 14 replaces `reason` with the real computation.

## Performance

`tests/test_scan_fork_budget.sh` guards the interactive paths' fork counts
directly: `ls` and `doctor` stay within **jq ≤ 4, ps ≤ 3, tmux ≤ 1** for
`ls` (doctor's own budget is documented alongside it in that test). Every
`_json_section_*` emitter in this file follows the same discipline — one
`jq` per section, never per row — for the same reason: a per-row fork is how
this project's fork counts have blown their budget four separate times
before (see `lib/json.sh`'s and `lib/titleindex.sh`'s own header comments).

`_snapshot`'s own latency targets, measured end to end:

| call | target |
|---|---|
| `_snapshot --json --only=chats,issues,accounts` | ≤ 400 ms |
| the above **plus** `processes` | ≤ 800 ms |
| `ls` (human rendering, not `--json`) | ≤ 500 ms |

**If a measured p95 misses its target, the fix is the app's poll cadence,
never the target.** The app drops to a 5 s poll interval rather than the
target being waived — a slow poll that still answers correctly is
recoverable; a target quietly loosened to match whatever the code currently
does is how a regression stops being visible at all.
