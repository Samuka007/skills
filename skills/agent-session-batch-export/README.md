# agent-session-batch-export

Curate claude_code / codex session transcripts into a small, provably
unmodified corpus of raw `.jsonl` trajectory material. The core guarantee:
**every kept file is a byte-identical copy of the original**, recorded in a
sha256 manifest. Nothing is re-rendered, summarized, or converted, so
downstream analysis reads the real trajectory — every tool call and result —
not a lossy view of it. No index, no daemon, no network: the core pipeline is
bash 3.2+ and the POSIX userland your machine already has.

> This README is the human overview. [`SKILL.md`](SKILL.md) is the
> agent-facing contract — pipeline stages, the `screen.tsv` format, the
> hand-off gate, verification — and is authoritative where the two differ.
> Maintainer notes: [`docs/agent-session-batch-export/INTERNALS.md`](../../docs/agent-session-batch-export/INTERNALS.md)
> (why the scripts are written the way they are).

## Pipeline

```
┌──────┐   ┌────────┐   ┌────────┐   ┌─────────────────────────┐   ┌──────────┐
│ scan │ ─►│ funnel │ ─►│ screen │ ─►│ review  (hand-off gate: │ ─►│ finalize │ ─► verify
└──────┘   └────────┘   └────────┘   │ the USER decides        │   └──────────┘
                                     │ keep/drop)              │
                                     └─────────────────────────┘
```

| Stage | Runs | Produces |
|---|---|---|
| scan | `curate-sessions.sh scan` | `OUT/candidates.tsv` |
| funnel *(optional here, mandatory on the direction path)* | `scripts/funnel.py` | rewrites `candidates.tsv` to the survivors, rebuilds the `screen.tsv` scaffold |
| screen | agent fills two columns | `OUT/screen.tsv` with `suggested` + `reason` per row |
| review | **the USER** | `OUT/decisions.tsv` — `decision=keep\|drop` per row |
| finalize | `curate-sessions.sh finalize` | `OUT/keep/*.jsonl` + `OUT/manifest.json` |
| verify | picker does it automatically | `verified: N/N copies byte-identical` |

`funnel` is `scripts/funnel.py`, shipped inside this skill: it shrinks a large
scan to the sessions worth attention before any human or agent reads prose. It
always reads the skill's global policy (`scripts/policy.json`); `--theme NAME`
adds a topic word list, and flags or an `--override-file` replace policy keys
per key. On the interactive path above it is optional — without it the
pipeline is exactly the four stages of `SKILL.md`, and with it everything
downstream of scan is
unchanged. On the **direction path** it is not optional: it *is* the selection.
Maintainer notes for the engine: [`docs/agent-session-batch-export/FUNNEL.md`](../../docs/agent-session-batch-export/FUNNEL.md).

## Direction export: the selection is deterministic

A **direction** is a purchase: a named set of themes, exported without an agent
judging prose. `scripts/export-direction.sh` runs it end to end — scan, one
funnel run per theme, union the survivors, then finalize and deliver:

```bash
bash scripts/export-direction.sh \
  --direction-file /path/to/direction.json -o ./out --yolo
```

Every threshold comes from the global policy, `scripts/policy.json`; theme
files carry identity — `keywords`, `label` — plus an optional per-key
`override`, and the direction file names themes plus the overrides that define
the purchase (the noncode direction's root `override` supplies the
`exclude_keywords` word list that defines "non-code"). There is no
`screen.tsv` step on this path, so there is no row for
an agent to fill and none for it to get wrong: the funnel's survivors are
written straight into `decisions.tsv`. An agent running this may read the funnel
table and abort on a catastrophic run; editing its output is not one of the
things it may do.

`python3` is a prerequisite, not a branch — the engine is Python and a semantic
fallback would make the selection unreproducible for the recipient. The script
probes by *executing* (`python3 -c ''`) because on Windows `python3` in PATH is
usually the Microsoft Store alias stub: a real file that exits 49 printing
"Python was not found", so a presence check passes while every call fails. When
that probe fails it prints `scoop install python` / `winget install
Python.Python.3.13` and stops.

Sessions carrying credential shapes refuse the whole batch (exit 3, nothing
written) unless `--allow-credentials` is passed, which is recorded in the
manifest. That is disclosure and determinism, not a security boundary: an agent
that rewrites its own artifacts is not stopped by it.

The shipped direction is [`session-export-nocode`](../session-export-nocode/SKILL.md).

## Quickstart

Entry point by what can see a terminal, not by preference.

**Interactive — you can open a terminal.** One command runs the whole
pipeline and lands in the fzf picker (spawning a terminal itself when run
headless); your ENTER inside fzf finalizes and verifies in one go:

```bash
bash scripts/pick-sessions.sh -o ./cur --agent codex --min-lines 20
```

**Full control / headless.** Run the stages yourself:

```bash
C=scripts/curate-sessions.sh
F=scripts/funnel.py                              # shipped inside this skill
OUT=/tmp/cur

# 1. scan — enumerate candidates -> $OUT/candidates.tsv
bash $C scan -o $OUT --workspace myproject --min-lines 20

# 2. funnel — shrink the pile to the survivors (global policy; optional)
python3 "$F" run "$OUT/candidates.tsv" "$OUT/.funnel-unused" --in-place
#    no --theme: the global policy alone filters turns, tools, length, dedup.
#    --theme translation adds that theme's topic word list. --in-place
#    replaces candidates.tsv with the survivors (full set archived as
#    candidates.full.tsv; the second path argument is unused in this mode)
#    and rebuilds screen.tsv with empty suggested/reason columns.

# 3. screen — fill suggested (keep|drop) + reason in $OUT/screen.tsv

# 4. review --ui tsv — emit decisions.tsv (no TUI, never blocks)
bash $C review --ui tsv -o $OUT

# 5. THE USER sets decision=keep|drop per row in decisions.tsv, then —
#    only as their delegate, after they approved — materialize:
bash $C finalize -o $OUT
```

On pure Linux with no desktop, hand the interactive step to the user as a
generated launcher instead of instructions: `bash $C package -o $OUT` writes
`$OUT/open-review.sh`, which they run in any terminal — it opens the picker
and finalizes with verification in one run.

The keep/drop decision is the user's, always: the agent's screening is a
recommendation. Details and the exact gate protocol live in
[`SKILL.md` § Hand-off gate](SKILL.md). `finalize` verifies byte-identity
(`cmp` + recorded sha256) for every kept session; the picker runs the same
check automatically after an interactive pick.

### No-review export: `--yolo`

When the user has explicitly opted out of reviewing the selection, `--yolo`
skips the picker and exports the screened `keep` rows — or all candidates when
nothing was screened:

```bash
bash scripts/pick-sessions.sh -o ./cur --agent codex --min-lines 20 --yolo
```

On the staged path the flag goes to finalize: `bash $C finalize -o $OUT --yolo`.
Nothing in the integrity chain is skipped — sha256 and `cmp` verify every copy,
exactly as after an interactive pick. What changes is the provenance record:
the manifest stamps `mode=yolo`, `reviewed=false`, `approved_by=user-opt-out`
on every entry, so a no-review export cannot masquerade as a reviewed one.

This is only for runs where the user explicitly opted out. The agent's rule —
what counts as an explicit opt-out, and what to do otherwise — is in
[`SKILL.md` § Escape clause](SKILL.md).

## Interaction surfaces

Which picker can run is decided by one question: **can a Windows-side
terminal be launched?**

| Environment | Interactive picker | No tty available |
|---|---|---|
| Windows Git Bash (native) | `scripts\pick-sessions.ps1` — spawns Windows Terminal running Git Bash | staged pipeline |
| WSL (Windows desktop reachable) | spawns Windows Terminal running `wsl.exe` | staged pipeline |
| Pure Linux / servers | none launched — the user's own terminal: `review --ui fzf`, or the `package`d `open-review.sh` launcher | staged pipeline or the packaged launcher |

On Windows, invoke the `.ps1` wrappers, not `bash xxx.sh`: the wrapper pins
Git Bash and IS the declaration that the sessions you want are on the
Windows side. Running the `.sh` inside WSL means Linux-side sessions. The
two intents are independent, and no script can infer them from the
environment. Setup on Git Bash is two packages (`scoop install jq ripgrep`);
MSYS bundles the rest.

Terminal spawns are *requested, not verified* — if no window appeared, run
the staged commands, which the entry point prints alongside every spawn.

## Demo

![Picker review flow: two rows pre-selected, a TAB override each way, ENTER, verified 2/2 byte-identical](../../docs/agent-session-batch-export/demo.gif)

The real picker flow, recorded on synthetic sessions (fabricated `.jsonl`, no
real transcript data): pre-selection from the screen, a human overriding the
agent's suggestion in both directions, ENTER, and the byte-identity check.

GitHub renders images but not asciicasts (the player needs a `<script>` tag,
which its Markdown filters out), so the animated GIF above — rendered from the
recording with `agg` and committed beside it — is what plays inline. The
recording itself stays the interactive version:

```bash
asciinema play docs/agent-session-batch-export/demo.cast
```

No asciinema? [`demo-transcript.txt`](../../docs/agent-session-batch-export/demo-transcript.txt)
is the same run captured as three labeled pane snapshots. Reproduce it with
`bash docs/agent-session-batch-export/demo.sh` (fixtures go to `/tmp/asbe-demo`,
safe to delete after).

## Coming from `trajectory-packs`

`trajectory-packs` and the engine directory beside it, `trajectory-funnel`, were
retired; this skill and [`session-export-nocode`](../session-export-nocode/SKILL.md)
replaced them. The installer copies a skill directory whole and never removes
one, so a machine that installed the old skill still has it — and still has it
after installing this one. That copy exits nonzero and writes nothing when run,
but its own repair command names two skills that no longer exist, and the
installer drops the names it cannot resolve while reporting
`Installed 2 skills ✓✓`.

Delete the retired copies and install the pair that replaced them:

```bash
rm -rf ~/.agents/skills/trajectory-packs ~/.agents/skills/trajectory-funnel

npx skills add Samuka007/skills \
  --skill session-export-nocode --skill agent-session-batch-export -g -y
```

[`docs/RELEASE-NOTES.md`](../../docs/RELEASE-NOTES.md) has the full account:
what replaced which part, and the base-skill-only install.

## Requirements

bash 3.2+ with a POSIX userland (awk, sed, find, stat, cmp, sort, cut, tr,
mktemp, sha256). Windows Git Bash bundles all of that; add `jq` and
`python3` via scoop or winget. `python3` is required, not optional: the
selection engine is `scripts/funnel.py`. The engine also hard-requires
`scripts/policy.json`, the shared quality standard, which ships inside the
skill — a copy missing that file stops with an error instead of guessing
defaults. Optional: `fzf` for the interactive review, `ripgrep` for faster
topic matching.

Sessions are read from `$HOME/.claude/projects` and `$HOME/.codex/sessions`
of the environment the script runs in — see
[`SKILL.md` § Data sources](SKILL.md) for the per-agent formats.
