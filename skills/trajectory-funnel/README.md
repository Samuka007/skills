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

## The seven stages

Cheap stages run before expensive ones: metadata → line scan → JSON parse.

| Stage | Predicate | Kills |
|---|---|---|
| L1 turns | user-turn floor | greeting stubs ("hi") |
| L2 tool_ratio | assistant tool_use share ceiling | tool-heavy coding runs when the interest is prose |
| L3 signature | thinking-signature ratio floor, **off by default** | sessions whose thinking blocks carry no signature (a relay or client stripped it) |
| L4 end_turn | last assistant `stop_reason == end_turn` | truncated sessions ending mid-tool-call |
| L5 length | user-message length distribution | scaffold noise (huge first prompt, tiny real request) |
| L6 topic | keyword/regex over extracted user prose | off-topic sessions (the only stage reading message bodies) |
| L7 dedup | 5-gram Jaccard over first user messages, cross-row | near-duplicate template clusters (keeps the longest) |

Every stage reports `(in, out, killed, skipped, reason)` — the printed funnel
table is the only decision surface you need for re-tuning.

### L3 signature: measured per session, gated by the pack

`trajectory-funnel` reads what the session file says; the threshold is
[`docs/trajectory-packs/PACK-SPEC.md`](../../docs/trajectory-packs/PACK-SPEC.md)
§ 4 and comes in through the pack, never from this code.

**The stage is off unless the pack sets `sig_ratio_min`.** No preset sets one,
so a run that does not ask for the layer behaves exactly as it did before it
existed. When it is off **its row is still printed**, with `OFF` where the kill
count would sit and the missing pack key named in the reason:

```
L3 signature         13   OFF       off (this pack sets no sig_ratio_min)
```

That is deliberate, and it is the property to preserve when extending this:
every stage keeps a row whether or not it ran. A reader auditing a delivered
batch has only this table, and if the row vanished, "this layer ran and skipped
codex" and "this layer never ran" would print identically. Turn the layer on
with:

```bash
python3 scripts/funnel.py run /tmp/cur/candidates.tsv /tmp/cur/.unused --in-place \
  --preset report --sig-ratio-min 0.30
```

Each session lands in one of three states, and the difference is the point:

| State | What the file shows | Verdict |
|---|---|---|
| `present` | thinking blocks with a non-empty `signature` | the ratio decides |
| `empty` | thinking blocks whose `signature` is `""` | fails the floor |
| `absent` | no thinking block at all — codex, or a client that never requested thinking | **skipped**, and the skip is recorded |

`empty` is not the same finding as `absent`. Anthropic returns `signature`
regardless of the `display` setting, so an empty signature means something in
the path removed it — a batch where every claude_code session reports `empty`
is a fact about the partner's relay, not about the model. Codex has no
`signature` field at all, so failing it would reject every codex session from a
purchase that explicitly covers both formats; it skips instead. `redacted_thinking`
is a safety-redaction block with no signature and is **not** a thinking block
here — a session carrying only redacted blocks reports `absent`, so it stays
distinguishable from one that was stripped.

`enrich` carries the same measurement as columns (`thinking_blocks`,
`signature_present`, `signature_empty`, `signature_ratio`, `signature_state`,
`redacted_blocks`) so the distribution can be seen before exporting.

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
counts, last stop reason, chars, signature state — without filtering),
`presets` (list them).

## Demo

![The picker reading a funnel's survivors: pre-selection, TAB override each way, ENTER, verified 2/2](../../docs/agent-session-batch-export/demo.gif)

The downstream half of this pipeline — the picker reading a funnel's survivors —
recorded on synthetic sessions:

```bash
asciinema play docs/agent-session-batch-export/demo.cast
```

It covers pre-selection, a human overriding the suggestion in both directions,
and the byte-identity check after `finalize`. GitHub cannot play an asciicast
(the player is a `<script>` embed, which its Markdown filters out), so the GIF
above is what renders inline; `asciinema play` is the interactive path. The
recording, that GIF and the reproduction script live in the sibling skill's
repo-only `docs/` directory:
[`demo-transcript.txt`](../../docs/agent-session-batch-export/demo-transcript.txt)
(text version) and [`demo.sh`](../../docs/agent-session-batch-export/demo.sh).

## Design rules (do not violate when extending)

- Python standard library only; streaming, never the whole corpus.
- Every stage reports `(in, out, killed, skipped, reason)`, and a `skip` stays
  distinguishable from a pass.
- Cheap stages before expensive ones: metadata < line scan < JSON parse.
- Unknown session formats are **skipped and counted**, never guessed.
- Thresholds are policy and live in the pack; a stage that needs one is gated
  off until the pack supplies it, prints `OFF` when it did not run, and **keeps
  its row either way** — a stage that never ran must not look like one that
  passed everything.
- Output stays compatible with the existing `screen.tsv` contract
  (candidates columns + `suggested` + `reason`).

The full stage docstring lives at the top of
[`scripts/funnel.py`](scripts/funnel.py).
