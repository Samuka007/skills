# trajectory-funnel

A deterministic multi-stage pre-filter over agent-session candidates. It sits
between a [`agent-session-batch-export`](../agent-session-batch-export/README.md)
`scan` (which enumerates every session matching metadata filters) and the
human/agent screening step, and answers one question cheaply: **of this
pile, which sessions are even worth attention?** A raw scan of a busy
machine can hold thousands of sessions — greeting stubs, tool-heavy coding
runs when you wanted prose, truncated files, scaffold noise, template
near-duplicates. Reading prose over all of that wastes the scarcest resource
in the pipeline: the agent's attention. The funnel kills the predictable
junk mechanically, stage by stage, so screening lands only on survivors.

Mechanism layer of the trajectory-export skill family. **The stage order and
the shape of each stage's predicate are fixed here; the parameters come from
the CLI** — normally transcribed by an agent from the presets below. The
agent never parses session JSONL itself: it reads the funnel table and the
enriched candidates TSV this script prints.

> Engine code in this repo, not an installable agent skill (there is no
> `SKILL.md` here); it is invoked from the sibling skill's pipeline. No
> third-party dependencies: Python 3 standard library only, runs anywhere
> `python3` runs, streaming (one session file in memory at a time).

## The six stages

Cheap stages run before expensive ones: metadata → line scan → JSON parse.

| Stage | Predicate | Kills |
|---|---|---|
| L1 turns | user-turn floor | greeting stubs ("hi") |
| L2 tool_ratio | assistant tool_use share ceiling | tool-heavy coding runs when the interest is prose |
| L3 end_turn | last assistant `stop_reason == end_turn` | truncated sessions ending mid-tool-call |
| L4 length | user-message length distribution | scaffold noise (huge first prompt, tiny real request) |
| L5 topic | keyword/regex over extracted user prose | off-topic sessions (the only stage reading message bodies) |
| L6 dedup | 5-gram Jaccard over first user messages, cross-row | near-duplicate template clusters (keeps the longest) |

Every stage reports `(in, out, killed, reason)` — the printed funnel table
is the only decision surface you need for re-tuning.

## Presets

```bash
python3 scripts/funnel.py presets
```

| Preset | For | Defaults (key ones) |
|---|---|---|
| `report` | reports / slides / writing / translation | min_turns 5, tool_ratio ≤ 0.15, end_turn required, topic keywords |
| `roleplay` | roleplay / creative writing | min_turns 10, tool_ratio ≤ 0.05, end_turn required, topic keywords |
| `coding` | coding sessions | tool_ratio ≤ 1.0, no end_turn / length / topic constraints, loose dedup |

Presets are data, not code — every parameter can be overridden by a flag.

## Quickstart

```bash
C=/path/to/agent-session-batch-export/scripts/curate-sessions.sh
F=/path/to/trajectory-funnel/scripts/funnel.py
OUT=/tmp/cur

bash $C scan -o $OUT --workspace myproject --min-lines 20   # -> OUT/candidates.tsv

# run the funnel and let the survivors BE the scan output (recommended)
python3 "$F" run "$OUT/candidates.tsv" "$OUT/.unused" --in-place --preset report

# now the normal review flow continues over the survivors only
bash $C review --ui tsv -o $OUT
```

`--in-place` is the integration contract with the picker: the fzf input IS
`OUTDIR/candidates.tsv`, so survivors must replace it (the full set is
archived as `candidates.full.tsv`, and the `screen.tsv` scaffold is rebuilt
from survivors with empty `suggested`/`reason` columns). A side-file filter
would silently do nothing to the interactive flow. Without `--in-place`,
survivors are written to the second path and inputs are left alone.

Overriding parameters is plain flags on `run`:

```bash
python3 "$F" run "$OUT/candidates.tsv" "$OUT/.unused" --in-place \
  --preset report --min-turns 8 --max-tool-ratio 0.10 \
  --topic-keywords "报告,ppt,总结" --no-dedup
```

Subcommands: `run` (filter), `enrich` (add computed columns — turns, tool
counts, last stop reason, chars — without filtering), `presets` (list them).

## Design rules (do not violate when extending)

- Python standard library only; streaming, never the whole corpus.
- Every stage reports `(in, out, killed, reason)`.
- Cheap stages before expensive ones: metadata < line scan < JSON parse.
- Unknown session formats are **skipped and counted**, never guessed.
- Output stays compatible with the existing `screen.tsv` contract
  (candidates columns + `suggested` + `reason`).

The full stage docstring lives at the top of
[`scripts/funnel.py`](scripts/funnel.py).
