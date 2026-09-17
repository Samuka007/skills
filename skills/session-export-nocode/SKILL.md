---
name: session-export-nocode
description: "Human-invoked /session-export-nocode direction command for exporting non-code trajectory sessions after an explicit user request."
---

# Export the non-code direction

This is an explicit, human-invoked delivery action. The published frontmatter
uses only fields accepted by the Agent Skills specification, so
`disable-model-invocation` is not emitted: the current `skills-ref` validator
rejects that nonstandard field. The narrow description and the launcher keep
this direction user-invoked. Install it together with the base skill; Agent
Skills has no dependency field:

```bash
npx skills add Samuka007/skills \
  --skill session-export-nocode --skill agent-session-batch-export -g -y
```

## Run

Read the bundled [`direction.json`](direction.json) before invoking the
launcher. It is the direction's single metadata file. Its `themes` array
declares exactly these themes, each resolved by name against the base skill's
`themes/`:

`translation`, `rewriting`, `generation`, `role-play`, `data-analysis`,
`multimodal`.

Each entry is a `{ "theme": NAME }` object with an optional per-theme
`override`; the six shipped entries are plain names. What the purchase
constrains lives in the direction's root `override`: it supplies the
`exclude_keywords` word list — the coding-signal terms whose absence defines
"non-code". The direction carries no thresholds; the shared quality standard
is the base skill's `scripts/policy.json`, and no file in this skill restates
it.

Pass the user's complete request as one `--request` argument. Choose an output
directory, then run:

```bash
bash scripts/session-export-nocode.sh \
  --request "$FULL_USER_REQUEST" \
  --out "$OUT_DIR"
```

Forward the scan options when the user supplied them:
`--allow-credentials`, `--agent`, `--workspace`, `--since`, and `--min-lines`.
The launcher resolves the standard sibling installation of
`agent-session-batch-export` and calls its shared contract:

```text
agent-session-batch-export/scripts/export-direction.sh \
  --direction-file FILE --out DIR ...
```

The launcher is only an adapter. The base runner owns scanning, the Python
funnel, the policy thresholds and their overrides, credential checks,
selection, copying, manifests, and delivery. Do not implement or substitute
any of those stages here.

## Review policy

Append `--yolo` **only** when the user's own request contains one of these exact
phrases:

- `直接导出`
- `无需确认`
- `不用确认`
- `无须确认`

The phrase may occur in a longer request, but it must be one of those exact
sequences. Do not infer an opt-out from brevity, silence, or wording such as
`帮我导出`; do not pass `--yolo` for any other request. Without a listed phrase,
omit `--yolo` and leave the base runner's confirmation path intact.

Do not edit funnel output or any `candidates.tsv`, `screen.tsv`, or
`decisions.tsv` file. The funnel report may be inspected only for a catastrophic
run problem; it is not a decision surface and must not be rewritten. Never
choose keep/drop rows or create a second screening engine.

## Actionable failures

Surface the base runner's preflight output unchanged. If Python is unavailable
on Windows, show its `winget install Python.Python.3.13` hint and ask the user
whether to install it and retry. Never replace deterministic funnel screening
with semantic model screening.

If the runner refuses because credential-like content was found, tell the user
the reported count and offer the explicit `--allow-credentials` rerun. Do not
add that flag silently. If the base skill itself is missing, show the launcher's
install instruction and ask the user to install the two skills together.
