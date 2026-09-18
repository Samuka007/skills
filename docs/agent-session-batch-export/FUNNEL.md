# The funnel engine (`scripts/funnel.py`)

A deterministic multi-stage pre-filter over agent-session candidates. It sits
between a [`agent-session-batch-export`](../../skills/agent-session-batch-export/README.md)
`scan` (which enumerates every session matching metadata filters) and the
human/agent screening step, and answers one question cheaply: **of this
pile, which sessions are even worth attention?** A raw scan of a busy
machine can hold thousands of sessions — greeting stubs, tool-heavy coding
runs when you wanted prose, truncated files, scaffold noise, template
near-duplicates. Reading prose over all of that wastes the scarcest resource
in the pipeline: the agent's attention. The funnel kills the predictable
junk mechanically, stage by stage, so screening lands only on survivors.

Mechanism layer of the session-export skill family. **The stage order and
the shape of each stage's predicate are fixed here; the parameters come from
the global policy (`scripts/policy.json`), layered with theme, direction, and
flag overrides** — never from this code. The agent never parses session JSONL
itself: it reads the funnel table and the enriched candidates TSV this script
prints.

> Ships inside `agent-session-batch-export` as `scripts/funnel.py`. It was once
> a separate `trajectory-funnel` directory with no `SKILL.md`, which made it
> invisible to the installer while other skills told users to install it; that
> is why it now lives in the skill that uses it. No third-party dependencies:
> Python 3 standard library only, runs anywhere `python3` runs, streaming (one
> session file in memory at a time).

## The nine stages

Cheap stages run before expensive ones: metadata → line scan → JSON parse.

| Stage | Predicate | Kills |
|---|---|---|
| L1 turns | user-turn floor | greeting stubs ("hi") |
| L2 tool_ratio | assistant tool_use share ceiling | tool-heavy coding runs when the interest is prose |
| L3 signature | thinking-signature ratio floor, **off unless the merged policy carries `sig_ratio_min` (`--no-signature` clears it)** | sessions whose thinking blocks carry no signature (a relay or client stripped it) |
| L4 end_turn | last assistant `stop_reason == end_turn` | truncated sessions ending mid-tool-call; codex skips (no `stop_reason` field in the format); a claude_code session whose last assistant record lacks the field fails |
| L5 length | user-message length distribution | scaffold noise (huge first prompt, tiny real request) |
| L6 topic | keyword/regex over extracted user prose, **off when the active word list is empty or absent** | off-topic sessions (the only stage reading message bodies) |
| L7 noncode | coding-signal exclusion over user prose, **off unless `exclude_keywords` reaches it — a direction root `override`, `--exclude-keywords`, or an override file** | sessions that are coding work. "Mainly not code" is a negative property, so absence of coding signal is what qualifies — a positive keyword list cannot select a session like `你有图片生成能力吗？` |
| L8 credential | credential shapes over the **complete raw JSONL** | nothing: it annotates and never drops, because exporting the remainder would hide the finding. `--credential-hard-gate` turns any surviving hit into a whole-batch refusal (exit 3) |
| L9 dedup | 5-gram Jaccard over first user messages, cross-row | near-duplicate template clusters (keeps the longest) |

Every stage reports `(in, out, killed, skipped, reason)` — the printed funnel
table is the only decision surface you need for re-tuning.

### L3 signature: measured per session, gated by the merged policy

The funnel reads what the session file says; the threshold is
[`docs/session-export/PACK-SPEC.md`](../session-export/PACK-SPEC.md)
§ 4 and comes in through the merged policy, never from this code.

**The stage runs when the merged policy carries `sig_ratio_min` — the shipped
global policy does.** `--no-signature` clears the key for one run, and so does
an override file with `"sig_ratio_min": null`. When the key is absent **the
row is still printed**, with `OFF` where the kill count would sit and the
missing key named in the reason, so an auditor can tell a cleared layer from
a passed one.

That is deliberate, and it is the property to preserve when extending this:
every stage keeps a row whether or not it ran. A reader auditing a delivered
batch has only this table, and if the row vanished, "this layer ran and skipped
codex" and "this layer never ran" would print identically. Turn the layer off
with:

```bash
python3 scripts/funnel.py run /tmp/cur/candidates.tsv /tmp/cur/.unused --in-place \
  --no-signature
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

### L4 end_turn: codex skips, an absent claude stop_reason fails

Codex writes no `stop_reason` on any record, so the closure layer cannot judge
it at all: it skips, and the skip is printed in its own column with the reason
`no stop_reason in this format`. A delivered batch must be able to say "the
closure layer passed this file" and "the closure layer did not apply to this
file" as two different statements (PACK-SPEC § 5).

The two formats must not be symmetric: an absent `stop_reason` on a
**claude_code** session is a finding about the file — the format has the field,
so its absence at the last assistant record means that record was truncated or
rewritten — and the session **fails**. The stage reads the last record's value,
not the last non-empty one, so a truncated tail cannot inherit the closure of
an earlier turn.

### Codex's injected blocks are not user turns

Codex delivers its own `<environment_context>` (and `<user_instructions>`,
`<skills_instructions>`) blocks as ordinary `role: "user"` messages. The codex
adapter excludes any user message that is entirely one of those tagged blocks
from `user_turns`, `user_chars` and `user_texts`, matching the block
structurally — the whole message is the tagged block, never a substring test on
prose that merely mentions the tag. The excluded count is carried in `enrich`
as the `injected_user_messages` column next to `user_turns`, so the correction
is visible instead of silently folded into the number. This matters twice
downstream: `first_user_msg` is the first *real* request (the L6 topic stage
and L7 dedup both read it), and the policy's `min_user_turns` floor means
real turns, not injected ones.

## The five layers a `run` merges

There are no presets and no per-theme policy blocks. Every parameter of every
stage comes from one global policy — `scripts/policy.json`, the shared quality
standard — which the engine resolves beside itself and hard-requires: a
missing file is an error with the path in it, never a default. Four optional
layers delta that policy, merged per key, the later layer winning:

| Order | Layer | Source | What it is for |
|---|---|---|---|
| 1 | global policy | `scripts/policy.json` | the shared quality standard; the only layer that must exist |
| 2 | theme `override` | `override` in `themes/<name>.json` | per-theme calibration (translation's per-message floor, role-play's tool ceiling, coding's tool-heavy profile) |
| 3 | direction root `override` | `override` in the direction JSON | what the purchase constrains (the noncode direction's `exclude_keywords`) |
| 4 | direction entry `override` | an entry's `override` in the direction's `themes` array | a per-theme delta inside one direction |
| 5 | flags | `run` arguments and `--override-file FILE` | one-off overrides for a single run |

The per-key semantics are the same at every boundary:

- A value replaces the value under it whole — a number, a string, or a list.
- `"key": null` clears the key: the stage it feeds turns OFF, exactly as if
  no layer had ever supplied it.
- An empty list is an explicit clear, not a missing one: `"keywords": []`
  turns L6 OFF instead of passing everything. An absent word list behaves the
  same way, which is why a theme without keywords can never read as "selects
  everything".
- An unknown key is a hard error at every layer, so a typo cannot silently
  configure nothing. Old-format files are rejected the same way: a theme that
  still carries a `policy` block or a top-level `exclude_keywords`, and a
  direction whose `themes` entries are plain strings, fail with the migration
  named, not approximately.

The table header names what was merged, on one line:
`policy: standard   theme: translation   surviving 12 / 340` — the policy
name comes from the policy file, `theme: none` means the run carries no topic
constraint, and `surviving` is the row count in and out.

The policy also carries two keys no funnel stage consumes —
`min_assistant_turns` and `topic_match`. The engine reports them in a note, as
recorded but unenforced, rather than applying them silently; a stage that
starts consuming one moves it out of that note in the same change.

## Collection mode (`collect`)

`run` is a delivery posture: it kills. `collect` is the upstream half of the
two-stage split ([DESIGN.md § Collection and
labeling](../session-export/DESIGN.md)): recall first, zero model tokens,
and the only drops are the two unambiguous junk classes. Everything else
survives carrying its measurements.

```bash
python3 scripts/funnel.py collect CANDIDATES.tsv OUTDIR [--theme NAME] \
  [--max-first-prompt-chars N]
```

What it writes:

| File | Content |
|---|---|
| `OUTDIR/pool.tsv` | every kept row with the candidates columns plus **all** enrich and annotation columns |
| `OUTDIR/row-cards.jsonl` | one JSON row card per pool row (see below) |
| `OUTDIR/dropped.tsv` | each drop with `agent`, `session_file`, `reason`, `detail` |

The two drop classes, and nothing else:

- `unparseable` — both format adapters refuse the file (structurally dead
  rows: neither claude_code nor codex, or a file the OS cannot read).
- `exact_duplicate` — same `agent` and the same sha256 of the file's bytes;
  `detail` names the kept original.

`collect` reads **no** `policy.json` — the policy is a delivery-posture
standard, and collection applies no quality gate. No stage runs, nothing is
killed for turn counts, tool ratios, topic, or dedup: a zero-turn session
lands in the pool with `user_turns=0` visible in its row. `--theme NAME` does
not import the theme's thresholds; it only fills each card's `theme_hits`
with that theme's keywords hit over the same prose surface the L6 topic stage
reads (the first three user messages).

### The annotation columns

`enrich` (and every `pool.tsv`) appends these after the shipped enrich
columns. Each is mechanically derivable from the raw JSONL parse — no model,
no threshold, no kill anywhere in the engine:

| Column | Meaning |
|---|---|
| `tool_calls_missing_results` | tool calls with no paired result in the file |
| `tool_results_orphan` | results with no paired call |
| `tool_repeat_max` | most repeats of one (tool name, arguments digest) |
| `tool_error_streak_max` | longest run of consecutive failed tool results (claude `tool_result.is_error`; codex outputs opening with `error`, or a JSON envelope with a nonzero `metadata.exit_code`) |
| `verification_commands` | tool calls whose command text hits a test/verify pattern (pytest, cargo test, npm test, go test, make, tsc, lint, ruff, mypy, flake8 — the table lives at the top of `funnel.py`) |
| `refusal_proxy` | 1 when the first assistant message opens refusal-shaped (我不能 / I cannot / … — pattern table in the file) |
| `synthetic_wrapper` | 1 when the first real user message starts with a known packaging prefix ("The following is the Codex agent history", "Treat the transcript") |
| `single_shot` | 1 when the session is exactly one real user turn |
| `input_modalities` | comma subset of `text,code,image,document` observed in message content (a fenced code block marks `code`) |
| `capabilities` | distinct capability ids from the static tool-name map (`capability.code_execution`, `filesystem_read`, `web_search`, …) |
| `tools_unmapped` | distinct tool names the map does not know — how a new tool surfaces |
| `replay_blockers` | why a faithful replay would diverge: `missing_tool_results`, `truncated_output` (an explicit truncation marker in a tool output, or a claude session whose last assistant record carries no stop_reason), `external_service` (a live network capability) |

### Row cards

One self-contained JSON object per pool row — the cheapest surface a buyer's
own model can judge in a few hundred tokens:

```json
{"source": "...jsonl", "agent": "codex", "first_prompt": "…≤N chars…",
 "user_turns": 11, "assistant_turns": 28, "tool_uses": 75,
 "capabilities": "capability.code_execution", "input_modalities": "text,code",
 "single_shot": 0, "refusal_proxy": 0, "synthetic_wrapper": 0,
 "tool_calls_missing_results": 0, "tool_error_streak_max": 0,
 "verification_commands": 0, "theme_hits": ["翻译"]}
```

`first_prompt` truncates to `--max-first-prompt-chars` (default 2000); the
card intentionally carries the flags and counts, not the annotations' full
detail — the pool row beside it has everything.

## Quickstart

```bash
C=/path/to/agent-session-batch-export/scripts/curate-sessions.sh
F=/path/to/agent-session-batch-export/scripts/funnel.py
OUT=/tmp/cur

bash $C scan -o $OUT --workspace myproject --min-lines 20   # -> OUT/candidates.tsv

# run the funnel under the global policy and let the survivors BE the scan
# output (recommended); add --theme NAME for a topic word list
python3 "$F" run "$OUT/candidates.tsv" "$OUT/.unused" --in-place

# now the normal review flow continues over the survivors only
bash $C review --ui tsv -o $OUT
```

`--in-place` is the integration contract with the picker: the fzf input IS
`OUTDIR/candidates.tsv`, so survivors must replace it (the full set is
archived as `candidates.full.tsv`, and the `screen.tsv` scaffold is rebuilt
from survivors with empty `suggested`/`reason` columns). A side-file filter
would silently do nothing to the interactive flow. Without `--in-place`,
survivors are written to the second path and inputs are left alone.

Overriding parameters is plain flags on `run`, layered over the theme:

```bash
python3 "$F" run "$OUT/candidates.tsv" "$OUT/.unused" --in-place \
  --theme translation --min-turns 8 --max-tool-ratio 0.10 --no-dedup
```

L7's word list comes from whichever layer names it — a flag here, the
direction root `override` on the direction path:

```bash
python3 "$F" run "$OUT/candidates.tsv" "$OUT/.unused" --theme translation \
  --exclude-keywords "重构,调试,编译"
```

Subcommands: `run` (filter), `enrich` (add computed columns — turns, tool
counts, last stop reason, chars, signature state, the annotation columns —
without filtering), and `collect` (the collection posture above).

## Demo

![The picker reading a funnel's survivors: pre-selection, TAB override each way, ENTER, verified 2/2](demo.gif)

The downstream half of this pipeline — the picker reading a funnel's survivors —
recorded on synthetic sessions:

```bash
asciinema play docs/agent-session-batch-export/demo.cast
```

It covers pre-selection, a human overriding the suggestion in both directions,
and the byte-identity check after `finalize`. GitHub cannot play an asciicast
(the player is a `<script>` embed, which its Markdown filters out), so the GIF
above is what renders inline; `asciinema play` is the interactive path. The
recording, that GIF and the reproduction script sit beside this file:
[`demo-transcript.txt`](demo-transcript.txt)
(text version) and [`demo.sh`](demo.sh).

## Design rules (do not violate when extending)

- Python standard library only; streaming, never the whole corpus.
- Every stage reports `(in, out, killed, skipped, reason)`, and a `skip` stays
  distinguishable from a pass.
- Cheap stages before expensive ones: metadata < line scan < JSON parse.
- Unknown session formats are **skipped and counted**, never guessed.
- Thresholds are policy and live in the merged configuration (the global
  policy, then the overrides); a stage that needs one is gated off until the
  configuration supplies it, prints `OFF` when it did not run, and **keeps
  its row either way** — a stage that never ran must not look like one that
  passed everything.
- Output stays compatible with the existing `screen.tsv` contract
  (candidates columns + `suggested` + `reason`).

The full stage docstring lives at the top of
[`scripts/funnel.py`](../../skills/agent-session-batch-export/scripts/funnel.py).
