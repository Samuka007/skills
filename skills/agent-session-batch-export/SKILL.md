---
name: agent-session-batch-export
description: "Curate claude_code/codex session transcripts into a corpus of RAW .jsonl trajectory material for agentic analysis. Scans candidates by workspace/topic, lets an agent screen them and a human mark keep/drop, then copies the kept sessions byte-for-byte with a sha256 manifest. Use when extracting trajectory material, building a dataset of past agent sessions, filtering sessions by workspace, project, or topic, or when the user wants to pick conversations to keep from their agent history."
license: MIT
compatibility: "Requires bash 3.2+ with a POSIX userland (awk, sed, find, stat, cmp, sort, cut, tr, mktemp, sha256). Windows Git Bash bundles all of that; add jq and ripgrep (rg) via scoop or winget. Optional: fzf for the interactive review step. Reads ~/.claude/projects and ~/.codex/sessions. Runs on Linux, macOS, and Windows Git Bash."
metadata:
  verified-platforms: "GNU/Linux; Windows (Git Bash via .ps1 wrappers) with scoop jq+ripgrep"
---

# Curate agent sessions into trajectory material

Turns a large pile of claude_code / codex transcripts into a small, provably
unmodified corpus that an agent can analyze.

`scripts/curate-sessions.sh` — no index, no daemon, no network, no Python.

The core property: **the kept files are byte-identical copies of the originals**,
each with a recorded sha256. Nothing is re-rendered, summarized, or converted,
so downstream analysis reads the real trajectory (every tool call and result),
not a lossy view of it.

## Pipeline

On Windows use `scripts\pick-sessions.ps1` / `scripts\curate-sessions.ps1`
(same arguments) — see Interaction surfaces for why. The `.sh` examples below
are the Linux/WSL/macOS spelling.

Pick the entry point by what can see a terminal, not by preference:

**Interactive shell (you or the user can see a terminal).** The one-command
entry point runs the whole pipeline and opens a picker, spawning a terminal if
necessary:

```bash
bash scripts/pick-sessions.sh -o ./cur --agent codex --min-lines 20
```

**Agent / headless / CI (no visible terminal).** Do NOT loop on the entry
point. Run the four stages; they are what the entry point calls internally, and
the staged path is fully supported (it is the same code):

```bash
C=scripts/curate-sessions.sh

# 1. scan — enumerate candidates -> OUT/candidates.tsv
bash $C scan -o /tmp/cur --workspace cits4012 --min-lines 20

# 2. screen — YOU read the candidates and annotate them (see Screening)
#
# 3. review --ui tsv — emit decisions.tsv (no TUI, never blocks)
bash $C review --ui tsv -o /tmp/cur

# 4. THE USER edits decisions.tsv: set decision=keep|drop per row.
#    STOP here and run the Hand-off gate first — never fill the
#    decision column yourself.
#
# 5. finalize — ONLY after user approval (gate step 3), as their delegate:
#    materialize -> OUT/keep/*.jsonl + OUT/manifest.json
bash $C finalize -o /tmp/cur
```

**When the user CAN open a terminal, but the agent cannot** (pure Linux, no
desktop): after stage 2, generate the one-click launcher and hand it over —
that IS the interactive review for this environment:

```bash
bash $C package -o /tmp/cur
# -> /tmp/cur/open-review.sh
# tell the user: open a terminal in /tmp/cur and run `bash open-review.sh`
```

The launcher opens the fzf picker over the screened candidates and, once the
user confirms, finalizes and verifies the corpus in the same run. One
interaction, done — the agent does scan+screen, the user does the keep/drop.

If you invoke the entry point from a headless context anyway, it refuses to
pretend: it prints this same staged sequence with your actual paths and exits
non-zero.

Each stage has one completion criterion:

| Stage | Done when |
|---|---|
| `scan` | `candidates.tsv` has one row per session that passed the metadata filters |
| screen | every row carries a `suggested` (`keep`/`drop`) and a one-line `reason` |
| `review` | `decisions.tsv` has a `decision` on every row |
| `finalize` | the user approved the keep/drop list (Hand-off gate), `manifest.json` lists every kept session, and each `kept_as` compares equal to its `source` |

### Pre-filter: `candidates.tsv` may already be funnel survivors

A deterministic pre-filter may already have run between `scan` and you. When it
has, its survivors **are** `candidates.tsv` — the full scan is archived beside
them as `candidates.full.tsv` — and `screen.tsv` was rebuilt for exactly those
rows, with its `suggested`/`reason` columns left empty for the screening step.
The funnel's recommendation is the row set itself: those survivors are the
sessions it judged worth attention, and screening them is still yours to do. The
rows you mark `keep` are what the picker pre-selects and what `--yolo` exports.
Everything downstream — `review`, `finalize`, the gate — reads the same files
either way. The engine is repo-only
(`skills/trajectory-funnel/scripts/funnel.py`) and does not ship with this skill.

## Screening (stage 2)

`scan` writes TWO files: `candidates.tsv` (7 columns, for reference) and
`screen.tsv` — the same rows plus two trailing columns, `suggested` and
`reason`, already headed and left empty. **Stage 2 is: edit `screen.tsv` in
place.** Do not invent another filename (a previous run's
`candidates.screen.tsv` is not a contract), do not write a new file from
scratch: `review` and `finalize` read exactly `OUT/screen.tsv` /
`OUT/decisions.tsv`. Fill, per row:

- `suggested`: `keep` or `drop` (exactly these two words)
- `reason`: one line of evidence (no tabs, no newlines — the file is TSV)

Then `review --ui tsv` converts it into `decisions.tsv` with
`decision` defaulted to your `suggested`; the human edits only the rows they
disagree with.

### Hand-off gate (stop here — this is not your decision)

The keep/drop decision belongs to the USER. Your screening is a
recommendation, never the decision. The two paths divide finalize's meaning:

- **Interactive** (`pick-sessions.sh` / `.ps1` entry / `open-review.sh`):
  the user's ENTER inside fzf IS the approval — finalize runs automatically
  right after and nothing more should be asked.
- **Headless**: `finalize` is the agent-delegated interface, and it is only
  legitimate AFTER the gate below has passed.

After stage 2 you MUST stop and put the choice in front of the user before
anything touches `decision` or runs `finalize`:

1. Present the screening summary: how many candidates, how many you marked
   keep, and the drop reasons (grouped, one line each).
2. **Then launch the interactive picker for them — that is the default, not
   an option to offer:** on Windows run `pick-sessions.ps1` (or `pick-sessions.sh`
   under WSL); a picker window opens over the screened list and the user's
   ENTER inside fzf finalizes and verifies in one go. YOU can start this
   yourself — do not merely describe it and fall back to asking for a text
   reply. Only when the picker cannot open (pure Linux, no desktop) hand the
   user the `package`d launcher: `curate-sessions.sh package`, then tell
   them to run `bash open-review.sh` in any terminal.
3. Text-only confirmation ("reply 确认导出") is the FALLBACK, for when the
   user explicitly declines the picker or no terminal can be opened. Fill
   nothing yourself: the user edits `decisions.tsv` (or tells you the exact
   changes), then and only then run `finalize` as their delegate.
   `review --ui tsv` prints this gate at its exit so it reaches every agent
   on the headless path.

Do NOT fill the `decision` column yourself and finalize. Two real runs did
exactly that: the user asked for an export and got one without ever seeing
the keep/drop list. An export the user did not approve is not a completed
task even when every copy verifies byte-identical.

### Escape clause: `--yolo` (explicit opt-out only)

If the user's own words explicitly opt out of review ("直接导出", "不用我看",
"just export it"), run `pick-sessions.sh --yolo` (or `finalize --yolo`): the
picker is skipped, the screened `keep` rows are exported (all candidates when
nothing was screened), and the manifest records `mode=yolo, reviewed=false,
approved_by=user-opt-out`. Integrity checks are NOT skipped — sha256 + cmp
still verify every copy. Yolo is legitimate ONLY on explicit wording: never
infer it from brevity, silence, or a busy-sounding user. Without the user's
own explicit opt-out, run the normal gate above.

Judge from the prose, not from the metadata row. Column 6 (`first_prompt`) is a
triage hint and can be blank: codex writes `<environment_context>`, AGENTS.md
and skills scaffolding as user messages, and those are stripped as scaffolding
rather than reported as content. A blank `first_prompt` means the session had
no human-authored opening turn — that is itself signal for `drop`.

Codex marks those injected blocks as ordinary `message` items, so a reader that
selects on `payload.type == "message"` alone will also pull in ~80 lines of
system boilerplate. Restrict to `payload.role` of `user` or `assistant`.

`finalize` reads only the `decision` column, so a human overrides your
`suggested` value by editing one field.

## Verifying the corpus

`finalize` records `source`, `kept_as` and `sha256` per session. Confirm every
copy is byte-identical before handing the corpus on:

```bash
jq -r '.[] | "\(.source)\t\(.kept_as)"' /tmp/cur/manifest.json > /tmp/pairs.tsv
while IFS=$'\t' read -r s d; do cmp -s "$s" "$d" || echo "MISMATCH $s"; done < /tmp/pairs.tsv
```

Write the pair list to a file first. Feeding the loop from a process
substitution (`done < <(jq …)`) leaves `read` blocked on a pipe when the job is
backgrounded or interrupted, which hangs instead of failing.

The picker runs this check itself after finalizing and prints
`verified: N/N copies byte-identical`.

## Options

`scan`:
- `--agent claude|codex|both` (default `both`)
- `--workspace SUBSTR` — substring of the session's real cwd
- `--topic REGEX` — extended regex over extracted prose
- `--since YYYY-MM-DD`
- `--min-lines N` — drop stub sessions

`review`:
- `--ui fzf` (default when fzf is present) or `--ui tsv` — tsv emits
  `decisions.tsv` for hand-editing, the headless path's step 3
- `--resume` — keep decisions already in `decisions.tsv`

`finalize`:
- `--from FILE` — read a decisions TSV other than the default
- `--yolo` — stamp the manifest `mode=yolo, reviewed=false` (no-review runs
  only; see the gate's escape clause)
- `--hardlink` — link instead of copy. Read-only analysis only: a downstream
  writer would corrupt the original through the link.

`validate` checks a TSV's column shape and tallies its decision column.

`pick-sessions.sh` accepts `-a/--agent`, `-w/--workspace`, `-t/--topic`,
`--since`, `-n/--min-lines`, `-o/--out`, `-y/--yes`, `--review-only`,
`--yolo`, `--no-finalize`, `--stay`, `-h`.

## Output directory

`pick-sessions.sh` proposes a dated, agent-tagged default
(`./curated-<agent>-<YYYYmmdd-HHmm>`) and confirms it interactively:
Enter accepts, `e` then a path (Tab completes), `q` quits, or just type a path.
`-y` skips the prompt; a non-tty invocation skips it too, so scripted runs never
block. A fixed default would let consecutive runs pile into one directory and
the corpus would stop describing a single selection.

A second run with a smaller selection **replaces** `keep/` rather than adding to
it, so the corpus always equals the current decisions exactly.

## Data sources

| Agent | Path | Workspace field | Prose field |
|---|---|---|---|
| claude_code | `~/.claude/projects/<munged>/<uuid>.jsonl` | `.cwd` | `.message.content` (string, or array of `{type:"text",text}`) |
| codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `session_meta.payload.cwd` | `.payload.content[].text` where `payload.type=="message"` and `payload.role` is `user`/`assistant` |

Two rules follow, and both are load-bearing:

- **Read the workspace from the field, never the directory name.** claude
  replaces `/` with `-`, so `-home-nixos-workspace-cits4012-a1` is ambiguous
  between `…/cits4012/a1` and `…/cits4012-a1`.
- **Match topics against extracted prose only.** Matching raw JSONL line-bytes
  hits base64 attachments and `tool_result` payloads, producing confident
  garbage hits.

## Interaction surfaces

This skill is the product; its interactive UX is defined per environment by
one question: **can a Windows-side terminal be launched?** The answer decides
everything else:

| Environment | Interactive picker | No tty available |
|---|---|---|
| Windows Git Bash (native) | spawns Windows Terminal running Git Bash | staged pipeline |
| WSL (Windows desktop reachable) | spawns Windows Terminal running `wsl.exe` | staged pipeline |
| Pure Linux / servers | none — no unified terminal to launch; if the caller already HAS a tty (the user runs `review --ui fzf` in their own terminal), that works | staged pipeline or the packaged launcher |

"Staged pipeline" is the non-interactive finish: screen → `review --ui tsv` →
edit → `finalize` (see Pipeline). On a headless run with no user terminal,
`curate-sessions.sh package` writes a one-click launcher the user can run in
their own terminal later — that is the interactive UX for pure Linux.

tmux/zellij are never used to launch windows for users; they exist only as an
undocumented internal test harness for agents driving the TUI
programmatically.

### Sessions live on both sides; scan reads the side whose HOME you are in

`scan` reads `$HOME/.claude/projects` and `$HOME/.codex/sessions` of the
environment the script runs in. Running inside WSL that is the Linux side; the
Windows-side trees (`/mnt/c/Users/<you>/.claude/projects`,
`/mnt/c/Users/<you>/.codex/sessions`) are the same file format but are NOT
scanned automatically. To include them, run the script against that HOME:

```bash
HOME=/mnt/c/Users/<you> bash $C scan -o /tmp/cur-win --agent both
```

(Fine to do from WSL — the format is identical, and `--workspace` matching
works the same because Windows cwds are normalised to `/` separators.)

### WSL: no visible terminal → the picker opens one on the Windows side

If the WSL shell has a real terminal, `pick-sessions.sh` just runs. If it does
not — invoked from a tool call, a CI step, or any non-interactive context — it
**requests a Windows-side terminal** and runs the picker there, in this order:

1. `wt.exe -- wsl.exe -d $WSL_DISTRO_NAME` — Windows Terminal (preferred)
2. `cmd.exe /c start … wsl.exe` — a plain console window

A spawn is **requested, not verified**: `wt.exe` exits 0 the moment the spawn
is delegated, so "requested" can still mean no visible window appeared
(disconnected desktop, service session). The parent therefore prints the
staged pipeline alongside the spawn message and exits 0; if no window showed
up, just run the staged commands it printed.

### Windows: bash running natively (Git Bash / MSYS)

The whole script runs under MSYS, no WSL involved — this is the native Windows
interaction surface. **On Windows, invoke the `.ps1` wrappers, not `bash
xxx.sh`:** `scripts\pick-sessions.ps1` / `scripts\curate-sessions.ps1` locate
Git Bash and re-exec the real script with it, so the caller's shell identity
(cmd, PowerShell, an agent whose `bash` resolves to WSL bash) is irrelevant.
Two entries, two intents: the `.ps1` wrappers mean "the sessions I want are
on the Windows side"; running the `.sh` inside WSL means Linux-side sessions.
No script can infer that intent from its environment, so do not pick the
entry point by whichever shell happens to be in PATH.

The wrappers fail with an install instruction when Git Bash is absent
(`winget install Git.Git`).

Setup is two packages — MSYS already bundles the rest of the POSIX userland:

```bash
scoop install jq ripgrep          # or: winget install jqlang.jq BurntSushi.ripgrep.MSVC
```

`pick-sessions.sh` with no tty spawns **Windows Terminal running Git Bash**,
which gives the picker a real tty.

Point the scripts at the Windows-side session trees: `~/.codex` and
`~/.claude` resolve to `C:\Users\<you>\…`, which hold the same file formats.
