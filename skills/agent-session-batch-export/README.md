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
| funnel *(optional)* | `trajectory-funnel` (see below) | rewrites `candidates.tsv` to the survivors, rebuilds the `screen.tsv` scaffold |
| screen | agent fills two columns | `OUT/screen.tsv` with `suggested` + `reason` per row |
| review | **the USER** | `OUT/decisions.tsv` — `decision=keep\|drop` per row |
| finalize | `curate-sessions.sh finalize` | `OUT/keep/*.jsonl` + `OUT/manifest.json` |
| verify | picker does it automatically | `verified: N/N copies byte-identical` |

`funnel` is the pre-filter from the sibling [`trajectory-funnel`](../trajectory-funnel/README.md)
directory (engine code in this repo, not an installable skill): it shrinks a
large scan to the sessions worth attention before any human or agent reads
prose. It is optional — without it, the pipeline is exactly the four stages
of `SKILL.md`; with it, everything downstream of scan is unchanged.

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
F=skills/trajectory-funnel/scripts/funnel.py     # path to the sibling skill
OUT=/tmp/cur

# 1. scan — enumerate candidates -> $OUT/candidates.tsv
bash $C scan -o $OUT --workspace myproject --min-lines 20

# 2. funnel — shrink the pile to the survivors (report preset here; optional)
python3 "$F" run "$OUT/candidates.tsv" "$OUT/.funnel-unused" --preset report --in-place
#    --in-place replaces candidates.tsv with the survivors (full set archived
#    as candidates.full.tsv; the second path argument is unused in this mode)
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

## Requirements

bash 3.2+ with a POSIX userland (awk, sed, find, stat, cmp, sort, cut, tr,
mktemp, sha256). Windows Git Bash bundles all of that; add `jq` and
`ripgrep` via scoop or winget. Optional: `fzf` for the interactive review.
The optional funnel needs `python3` (standard library only).

Sessions are read from `$HOME/.claude/projects` and `$HOME/.codex/sessions`
of the environment the script runs in — see
[`SKILL.md` § Data sources](SKILL.md) for the per-agent formats.
