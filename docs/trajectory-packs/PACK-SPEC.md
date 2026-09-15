# Pack specification — what we buy, and how it is checked

The buy-side record. A partner reads this to know what qualifies; we read it to
know what we agreed to. The reference for every threshold is the delivered
bundle `非coding_10session_demo` (2026-07-20), whose funnel report and manifest
are quoted below so the numbers have a single origin.

Layout and layering: `DESIGN.md` beside this file. Item status: `SPEC/README.md`.

## 1. What is being bought

Raw session files, byte-for-byte, as the agent tool wrote them. Not extracted
turns, not summaries, not a normalised form. The reason is verification: we
re-run the pack over the files we received and must get the same verdict, which
is only possible if the input is untouched.

One session may satisfy several themes. Counts per theme sum to more than the
session count — the reference bundle's coverage table behaves the same way.

## 2. Themes (the direction pack `noncoding-multimodal`)

Themes come from the reference bundle's own vocabulary. The bundle's report
groups them as role-play / 翻译 (translation) / 改写 (rewriting) / 生成
(generation) / 数据分析 (data analysis) / 多模态 (multimodal).

| Theme | Reference coverage | Gate |
|---|---:|---|
| generation | 5 of 10 | normal |
| role-play | 3 of 10 | normal |
| rewriting | 3 of 10 | normal |
| data analysis | 3 of 10 | normal |
| multimodal | 3 of 10 | **report-only** — counted and reported, never a pass/fail |
| translation | 2 of 10 | normal |

A theme carries a keyword list and threshold overrides; the direction pack
carries the theme set and the shared defaults. The reference bundle's own
delivered counts are above so a partner can see what a healthy batch looks like.

## 3. The screening layers

Straight from the reference bundle's funnel, in its order, with its numbers:

```
scan (all opus-4-8 sessions)                35110
criteria ①②③ pass                            5974   (17.02%)
strict signature pass                         4568   (13.01%)
non-coding (upstream heuristic)                179   ( 0.51%)
re-classified, coding contamination removed    140   ( 0.40%)
session closed (stop_reason=end_turn)          133   ( 0.38%)
real multi-turn (user_turns>=5)                132   ( 0.38%)
near-duplicate template clusters removed       108   ( 0.31%)
human verification, delivered                   10   ( 0.03%)
```

What each layer needs from a local session file, measured against the two
formats that actually exist on a partner's machine (claude_code and codex):

| Reference layer | Local signal — claude_code | Local signal — codex |
|---|---|---|
| criteria ①②③ (assistant turns, thinking present, sig_ratio) | `message.content[].type == "thinking"`; assistant record count | `response_item.payload.type == "reasoning"`; assistant message count |
| strict signature | `message.content[].signature` — non-empty | **absent** (codex returns `encrypted_content`, no signature field) |
| non-coding | tool_use absent or below ceiling: `message.content[].type == "tool_use"` | `payload.type in {function_call, custom_tool_call}` |
| session closed | last `message.stop_reason == "end_turn"` | **not judged** — a codex jsonl is a finished trajectory |
| real multi-turn | user messages, excluding the environment preamble | `event_msg.task_started` turns, excluding `environment_context` |
| dedup | 5-gram Jaccard over the first user message, keep longest | same |
| theme coverage | user prose keyword match | same |

Two measurements that shaped the table:

- **Thinking text is not the signal; the signature is.** Anthropic's own
  documentation states the `signature` field is returned regardless of the
  `display` setting — with `display: "omitted"` the `thinking` field is empty
  while the signature still carries the encrypted reasoning. So a layer that
  keys on thinking *text* measures the client's display setting, not the model's
  reasoning. Key on `signature`.
- **`redacted_thinking` is a different thing.** It is a safety-redaction block
  with a `data` field, not an omitted-but-signed thinking block. A session
  carrying only `redacted_thinking` has no signature to check. Measured on the
  Windows store: two sessions carry one such block each, both on
  `claude-opus-5`. They are counted separately (`redacted_blocks`) and belong to
  neither the `present` nor the `empty` class — folding them into `empty` would
  report a safety redaction as a relay defect.

## 4. Signature: measured, gated, and recorded

The gate follows the reference standard: a session whose signature ratio falls
below the pack's `sig_ratio_min` (0.30, from the reference) does not qualify.
The ratio is measurable only where thinking blocks exist, so the layer applies
as follows.

Because the signal is not uniform across formats, the manifest records which of
three states applied to each session:

| State | Meaning |
|---|---|
| `present` | at least one thinking block carries a non-empty `signature` — the ratio is computed and the floor decides |
| `empty` | thinking blocks exist but `signature` is an empty string — observed in a local claude_code session whose model was `claude-opus-4-8-fast`; a relay or client stripped it |
| `absent` | no thinking blocks at all — codex, and any client that never requested thinking |

`present` is not a claim that every block is signed. A session can be mixed —
measured in the implementation's own fixtures, three signed blocks and six empty
ones — and in that case the label is `present` while `signature_ratio` carries
the truth (0.33 there). The floor is what decides; the label only says whether a
ratio was computable at all. A batch where most sessions report `present` with a
low ratio is a batch from a relay that strips some blocks, which is exactly the
kind of finding this state exists to surface.

`empty` fails the layer. `absent` **skips** it and records the skip, the same
way codex skips the closure layer: a format that has no signature concept
cannot fail a signature test, and judging it as zero would exclude every codex
session from a purchase that explicitly covers both formats. A codex jsonl is
accepted on its CoT (`payload.type == "reasoning"`) and the rest of the pack.

Distinguishing `empty` from `absent` matters downstream: a batch where every
claude_code session reports `empty` points at the partner's relay, and that is a
finding about the channel, not about the data.

> **Decision, recorded.** Two instructions met here and this is how they were
> reconciled: "when the signature rate is too low it does not qualify, by the
> source standard" and "codex has no signature, keep the CoT". Applying the
> ratio to a format that has no signature field would reject all codex input,
> which contradicts buying claude_code and codex together. So the gate applies
> where the field exists, and a format without the concept records a skip. If
> the intent was to refuse codex input instead, this is the line to change.

## 5. What we do not judge

- **Codex session closure.** No `stop_reason` and no equivalent; `task_complete`
  exists but a codex jsonl is complete by construction. The layer is skipped for
  codex and the manifest records the skip rather than a pass.
- **Multimodal presence.** Measured across four local stores (61 files): zero
  native `{"type":"image"}` blocks. The only non-text payload seen was one
  base64 PDF `document` block. The theme stays in the pack as report-only, with
  two counters — `image_blocks` (native) and `document_blocks` (attachments) —
  because the reference bundle itself distinguishes those two forms. A zero is
  reported as a zero; it is not a failure and it is not padded.
- **Credentials, in the sense of "we scan and forget".** See § 7.

## 6. Delivery

One archive containing the kept session files verbatim plus a manifest. The
archive format follows the platform (`zip` on Windows, `tar.gz` elsewhere) and
the command picks it; the partner does not.

The manifest is a mapping, kept simple:

```json
{
  "schema_version": 1,
  "pack_id": "noncoding-multimodal",
  "pack_version": "1.0.0",
  "skill_version": "…",
  "direction": "noncoding-multimodal",
  "themes": ["role-play", "translation", "…"],
  "mode": "yolo" | "interactive",
  "reviewed": true | false,
  "counts": { "scanned": 0, "kept": 0, "per_theme": { "role-play": 0 } },
  "layers": [ { "name": "L1 turns", "in": 0, "out": 0, "killed": 0, "reason": "…" } ],
  "items": [
    {
      "source": "/abs/path/original.jsonl",
      "kept_as": "…/keep/claude--…--uuid.jsonl",
      "sha256": "…", "bytes": 0,
      "source_format": "claude_code" | "codex",
      "model": "…",
      "themes": ["role-play"],
      "signature": "present" | "empty" | "absent",
      "signature_ratio": 0.0,
      "image_blocks": 0, "document_blocks": 0,
      "first_ts": "…", "last_ts": "…"
    }
  ]
}
```

The serving provider is **not** recorded, despite being available (`codex`
writes `session_meta.payload.model_provider`, seen locally as `OpenAI` and
`sub2api`). It was proposed as a source-trustworthiness dimension and rejected:
a provider string is easy to set and easy to strip, so it would invite
conclusions the data does not support. The signature state in § 4 is a fact
about the file; a provider name is a claim about a channel.

Per-item `sha256` plus the archive are enough. A checksum of the archive alone
would prove the transfer was intact and nothing about whether the contents match
the manifest.

## 7. Credentials

A partner's sessions are their own machine's history and may contain their own
API keys. The reference manifest records `credential_hits: 0`, so the pipeline
scanned for them; this pack keeps that.

- Interactive flow: sessions with a credential hit are not pre-selected, and the
  row shows why.
- Unattended flow: the run reports how many sessions hit, and stops. Exporting
  them requires passing the explicit `--allow-credentials` flag, which is
  recorded in the manifest.

Redaction is not offered. It would break the byte-identity guarantee that the
whole delivery rests on.

## 8. Volume

Reported before exporting, never gated. The partner sees "this pack qualifies N
sessions, of which translation 1" and decides whether the job is worth running.
A hard minimum would waste their time on a run that was never going to be
accepted, and would forbid partial value.

## 9. Deviations from the reference, and why

| Reference | Here | Why |
|---|---|---|
| Input is an upstream vendor's batch of API-call records (`calls[]` envelopes) | Input is the partner's own `~/.claude/projects` and `~/.codex/sessions` jsonl | We now buy directly from partners who run an agent, not from a vendor who shipped us call logs |
| Kiro-source detection, stub-signature detection | Not ported | Those判据 targeted one upstream supplier's failure modes. Signature *ratio* is kept because it is a property of the local file; source fingerprinting is not, because there is no upstream vendor to fingerprint |
| `deepseek` dual annotation | Not ported | The reference itself dropped it: "对非coding 无判别力" |
| Report md + html + brief txt | Not produced | The reference's report existed to negotiate with a supplier. This pack *is* the negotiation; the manifest and the pre-export count carry the same facts to the person who needs them |
| Human verification of the final 10 | The partner's review gate (interactive) or their explicit opt-out (unattended) | We cannot read their sessions for them; who confirms the selection, and whether anyone did, is recorded in the manifest |
| A scaffold allowlist (§1.1 of the v2 spec) | Not ported | The reference dropped it as a coding-agent allowlist that conflicted with a non-coding requirement |

## 10. Acceptance of a delivered batch

Re-run the pack over the received files and compare against the manifest. Every
session the manifest lists must re-qualify, and every count must reproduce. A
batch that fails this is returned, not haggled over.

Two properties the acceptance depends on, both asserted by
`test/signature-e2e.sh` rather than left incidental:

- **Every stage keeps a row in the funnel table, whether or not it ran.** A
  stage the pack did not enable prints `OFF` where its kill count would sit, and
  names the pack key it is waiting for — `off (this pack sets no sig_ratio_min)`
  rather than a bare `off`. Without this, "never ran" and "ran and passed
  everything" are the same observation, and the audit above cannot distinguish
  a batch that cleared the signature layer from one where the layer was never
  switched on.
- **A skip is counted in its own column, next to the kill count.** A stage that
  applied to three sessions and skipped twenty-four prints both numbers.
