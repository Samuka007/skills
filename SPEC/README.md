# SPEC index — trajectory-export skill family

**Where the spec lives.** Depends on what kind of spec it is, and each kind has
exactly one home:

- **A feature's Requirement / Specification / Acceptance** → the **GitHub issue
  body** (`gh issue view <n> --repo Samuka007/skills`). This index records what
  cannot live there: status, acceptance evidence, and decisions taken after the
  issue was written.
- **What we buy, and how a delivered batch is checked** → the files under
  `docs/session-export/`. Those are the buy-side specification and they are
  normative for every export item; the issues implement them.
- **How the skill family is laid out** → `docs/session-export/DESIGN.md`.

Rejected alternative: duplicating a spec into several files. Two copies drift —
one gets edited during review and the other does not, and a reader then cannot
tell which was agreed. One canonical location per kind, pointed at from here.

## Items

| # | Title | Status | Evidence |
|---|---|---|---|
| 1 | `funnel --in-place` integration mode | **done** | commit `aef33f4`; `test/funnel-e2e.sh` green (real tmux + fzf: `[1 candidates; 0 pre-selected]` → fill → `[1;1]` → ENTER → `verified 1/1`); `ty` + `ruff check` + `ruff format --check` clean |
| 2 | yolo mode (no-review export on explicit opt-out) | **done** | commit `33361ee`; `test/yolo-e2e.sh` green (32 checks, discriminating power proved by mutation); `accept.sh` + `shellcheck` + `funnel-e2e.sh` clean; PM re-ran the real entry point (`pick-sessions.sh -o DIR -y --review-only --yolo` → rule printed, 2 of 3 kept, manifest entries carry `mode=yolo`/`reviewed=false`/`approved_by=user-opt-out`, `verified 2/2`, gated path adds no such keys); closed |
| 3 | READMEs for both skills | **done** | commit `f027a36`; accepted (read end-to-end against SKILL.md and funnel.py, links resolve, synthetic-data smoke reproduces the documented 5→1 funnel table); closed |
| 4 | recorded select+export demo in README | **done** | cast/script/transcript in `a297d7f`, embedded by `608ed88`; accepted by re-running `docs/agent-session-batch-export/demo.sh` (rc=0, decisions.tsv shows human override both directions, 2/2 copies byte-identical); closed |
| 5 | SKILL.md: funnel mention + yolo escape clause | **done** | escape clause in `33361ee`, funnel subsection in `37c75dd`, wording corrected in `5c65d25` (the funnel leaves `suggested` empty; screening is still the agent's); `skills-ref validate` passes, 327 lines; closed |
| 6 | INTERNALS.md: record this round's traps | **done** | commit `38d54f0` (+96 lines: funnel contract section, yolo provenance and both silent defects, dev-tooling policy); `skills/**` byte-identical; closed |
| 7 | funnel `--in-place`: atomic candidates.tsv rewrite | **done** | commit `9f6e2f9` (no issue — found while auditing the code against its own comment); the archive held the original so the failure was recoverable, but the comment claimed atomicity the code did not have; `funnel-e2e.sh` + `yolo-e2e.sh` + ty/ruff re-run clean |
| 8 | Windows interactive picker through zellij | **done** | commit `65464bb`; `test/win-zellij-pick.sh` ran on the real machine (Windows Git Bash, installed copy, zellij 0.45.1) and asserted the pane: `[3 candidates; 1 pre-selected]` → Down+TAB → `3/3 (2)` → ENTER → `kept 2 of 3` → `verified: 2/2`; teardown clean (no session, no process, fixtures gone); closed |
| 9 | demo renders on GitHub | **done** | commit `f5fc821` (`docs/agent-session-batch-export/demo.gif`, 209 KiB, regenerable byte-identically via `agg`); GitHub's rendered HTML carries `<img src="…/raw/master/docs/…/demo.gif">` and the raw URL answers `content-type: image/gif`, 213680 bytes |
| 10 | repair the interactive suites | **done** | commit `08f10f1`; all suites green; `test-pick-tmux.sh` 1/8 → 16/16 |
| 11 | README: document `--yolo` | **done** | commit `cde2224` (issue #8, auto-closed); `### No-review export: --yolo` under Quickstart; statement-by-statement cross-check against SKILL.md § Escape clause found no disagreement; `test/yolo-e2e.sh` re-run green |
| 12 | buy-side pack family: design + specification | **in progress** | `docs/trajectory-packs/DESIGN.md` (layering, direction/theme packs, two run flows) and `docs/trajectory-packs/PACK-SPEC.md` (themes, layers, signature rule, manifest shape, deviations). Canonical copies live in those two files — the items below implement them |
| 13 | mechanism: thinking-signature stage, three-state | **done** | commits `b71bb1e` + `d7c4175` + `6ac4fea`; `test/signature-e2e.sh` 40 checks, discriminating power proved by four mutants; **PM acceptance on the real stores**: WSL claude — `8cf7839d` `present` (12 signed of 12, ratio 1.00), `ceb88c6c`/`5d7e9d93`/`2dda2dc4` `empty` (0 signed of 3-4 blocks, killed by the 0.30 floor), 24 sessions with no thinking block `skipped` not killed; Windows claude — `5086c350`/`69a754ca` `absent` with `redacted_blocks` 1; codex `absent` everywhere; closed |
| 14 | codex semantics: closure skip + injected-turn inflation | **done** | commit `5b05191` (issue #11, auto-closed); `test/codex-semantics-e2e.sh` 37/37, ty + ruff clean, sibling suites green. **PM acceptance on the real rollout** (`parse_codex` + `stage_end_turn` on `rollout-2026-09-15T12-54-23-…`): `user_turns` 2 → 1 with `injected_user_messages 1` recorded beside it, `first_user_msg` now `翻译 桃花源记 为日文`, and closure returns `('skip', 'no stop_reason in this format')` instead of passing on an empty string. The Windows selection is unchanged — 25 in, the same one out — but its L1 kill reasons are now truthful (`user_turns 1 < 5`, not `2 < 5`) |
| 15 | pack skill + driver (`trajectory-packs`) | **done** | packs `ce5e192`, driver `8e013e5` (issue #12, auto-closed). `test/pack-export-e2e.sh` 62/62. `shellcheck -S warning` clean. **PM acceptance on the real entry point**: jq/jaq resolved at startup, python3 probed by execution (`python3 -c ''`) not by `command -v`, thresholds read from the pack files (zero numeric literals in the driver that are thresholds — verified by reading the code). Usage gates confirmed: `--direction` with `--theme` exits 2 with usage message, nonexistent pack names the file it looked for, missing engine exits 1 naming all three skills with the `npx skills add` command. Real machine `--direction noncoding-multimodal` run: `0 sessions qualify` (WSL corpus is all coding work — correct zero, exits 0, nothing written). Export-and-delivery path exercised on byte-identical fixture copies by the suite. Note: `min_assistant_turns` has no funnel stage and is printed as NOT enforced; `multimodal` counters not emitted by the funnel → `n/a` in the manifest — both reported as gaps by the lane, not failures, and recorded in PACK-SPEC.md |
| 16 | delivery archive command | **done** | commit `dd42e2e` (issue #10, auto-closed); `test/delivery-e2e.sh` 61/61 on WSL and 65/65 under Windows Git Bash; **PM acceptance on the real entry point** (`curate-sessions.sh delivery -o DIR`): `writer: tar -czf (tar 1.35)`, `verify: 1/1 sha256-matched`, `read back: 2 members matching the corpus exactly`, and the extracted session `cmp`-identical to its source. The platform rule was corrected by measurement: Git Bash has no Info-ZIP `zip` and its `tar` is GNU (which writes a POSIX tar under a `.zip` name while exiting 0), so the `zip` format is produced by `bsdtar` and every rung's output is checked against its format's magic bytes |
| 17 | acceptance runs on real data (WSL signature, Windows codex) | **done** | `test/signature-real-wsl.sh` and `test/codex-translation-windows.sh` (commit `30ec3aa`). Windows codex: 25 sessions in, exactly 1 out — `翻译 桃花源记 为日文` — under a one-run override; under the shipped translation theme the selection is empty, which is the correct reading of the reference (it buys translation as multi-turn work) |
| 18 | `--no-dedup` inverts its own meaning | **open** | found by the item-14 lane, deliberately left unfixed as out of scope. `--no-dedup` sets the similarity threshold to `0.0` and the stage tests `jaccard >= threshold`, which is always true, so the flag meant to disable deduplication instead collapses every survivor into one. Acceptance: a funnel run with `--no-dedup` over N pairwise-distinct sessions keeps N, and the dedup row reports `killed 0` |
| 19 | `validate` cannot validate a decisions file | **open** | found by the item-20 run: the third-party agent tried it and got `unknown option`. Three defects in one command. Reproduce on a 9-column `decisions.tsv`: `validate DIR/decisions.tsv` → `unknown option: DIR/decisions.tsv`, rc=2, although the help says "sanity-check a candidates/decisions TSV"; `validate -o DIR` → `no such file: DIR/candidates.tsv`, rc=1, because `src="${FROM:-$CAND}"` resolves only `candidates.tsv` and can never reach a decisions file; `validate --from DIR/decisions.tsv` — the one working spelling, documented only under `finalize options` — prints `columns(9)`, `expected cols: 7`, `MALFORMED rows (expected 7 cols): 1`, because the awk branch reads `want = ($1 == "decision") ? 10 : 7` while a decisions TSV has 9 columns beginning with `agent`. It false-alarms on exactly the file it exists to check. Acceptance: `curate-sessions.sh validate DIR/decisions.tsv` exits 0 printing `shape ok (9 cols)` plus the decision tally, and `validate -o DIR` validates `decisions.tsv` when one is present |
| 20 | end-to-end: an unprimed third-party agent reaches the intended corpus | **done** | Windows codex 0.154.0 under `codex exec --dangerously-bypass-approvals-and-sandbox`, given only `docs/agent-session-batch-export/codex-e2e-prompt.txt` — which states no-review, no turn floor and non-coding, and never names the session being sought. The installed copy was reinstalled to HEAD first and verified byte-identical with CR=0. Codex read `SKILL.md`, used the documented `.ps1` wrappers, and ran `scan --agent both --min-lines 0` → `candidates: 34 (workspace='*' topic='*' since='*' min_lines=0)`, screened into `screen.tsv`, then `finalize --yolo` and `delivery`: `delivery: 3 session(s) + manifest.json`, `writer: /c/Windows/System32/tar.exe -a -cf (bsdtar)`, `verify: 3/3 manifest entries present and sha256-matched`. The three exported first messages were `对我的下载文件夹做只读，指定整理计划`, `你有图片生成能力吗？`, and **`翻译 桃花源记 为日文`**. PM verification independent of codex's report: archive magic `50 4b 03 04`, members `keep/` ×3 + `manifest.json`, every manifest sha256 recomputed against **the original session file** rather than the copy — all three matched — and each entry carries `mode=yolo`, `reviewed=false`, `approved_by=user-opt-out`. The bsdtar rung of item 16 was thereby exercised by a real caller rather than by a test |
| 21 | base skill + deterministic direction bundles | **dispatched** | **Requirement:** installable batch-export bundles must select sessions through the Python funnel, not LLM semantic screening; the base skill owns the funnel and all six themes, and a human-explicit direction skill such as `session-export-nocode` owns only the theme combination and invocation policy. `min_user_turns=0` means zero-turn sessions reach later stages but remain subject to every other stage. On Windows, missing Python is a prerequisite failure with an installation hint, not a fallback. Explicit `直接导出` / `无需确认` / `不用确认` / `无须确认` enables yolo; otherwise confirmation remains. Credential scanning is a deterministic funnel stage, while any final recheck is only an integrity consistency check, not an agent security boundary. **Specification:** cleanly absorb `trajectory-funnel`, themes, and the direction runner into `agent-session-batch-export`; add `session-export-nocode` as a separately installable direction skill selecting all six themes; remove the old `trajectory-packs`/standalone funnel publication boundary and rewrite item 20 as a non-acceptance of the LLM-screened path. Acceptance: `bash test/session-export-nocode-e2e.sh`, base and direction `skills-ref validate`, real WSL deterministic yolo run, and real Windows Git Bash run after Python preflight; both runs must show the same funnel-selected set on repeat and no agent-written keep/drop decisions |

## Decisions and constraints (apply to all future items)

- **Where each kind of truth lives (single source of truth).** Three things,
  three homes, never restated elsewhere:
  - **Buy-side numbers and口径** → `docs/session-export/PACK-SPEC.md`, and the
    theme JSON files under `skills/agent-session-batch-export/themes/`. Prose
    points at them; it does not repeat a threshold.
  - **Family layout and layering** → `docs/session-export/DESIGN.md`.
  - **Item status, acceptance evidence, and decisions taken after an issue was
    written** → this file, plus the issue body for the canonical requirement.
  A number in two places is a drift waiting to happen. When a document needs to
  state a threshold it names the theme key, not the value.
- **Signature is measured where the field exists, skipped where it does not.**
  Anthropic's documentation is explicit that a thinking block always carries
  `signature`, independent of `display`; an empty signature therefore means a
  client or relay stripped it, not that the model produced none. Measured
  locally: a WSL claude_code session on `claude-opus-5` carries 384-character
  signatures, a sibling session on `claude-opus-4-8-fast` carries empty ones
  while its thinking text is intact, and codex has no signature field at all.
  So: `empty` fails the ratio gate, `absent` skips it and says so. Details and
  the recorded reconciliation are in `PACK-SPEC.md` § 4.
- **Volume is reported, never gated.** A partner sees the qualifying count per
  theme before exporting and decides whether the job is worth running. A hard
  minimum wastes their time on a run that was never going to be accepted.
- **Credentials: detect and stop, never redact.** Redaction would break the
  byte-identity guarantee the delivery rests on. The interactive flow leaves
  flagged rows unselected; the unattended flow reports the count and requires an
  explicit `--allow-credentials` to proceed.
- **The interactive path is verified by driving a real TUI, on the platform it
  ships to.** Not optional, and not substitutable:
  - **Windows** — drive the real picker through **zellij** (`--test-spawn
    zellij`; `write-chars` / `send-keys` to act, `dump-screen` to read back).
    tmux does not exist under MSYS, so there is no alternative there.
  - **WSL / Linux** — drive it through **tmux or zellij** (the existing
    `test/*-tmux.sh` and `test/funnel-e2e.sh` are the shape to follow).

  Rationale: every failure this pipeline has produced was invisible to
  non-interactive checks and only appeared under a real terminal — the side-file
  funnel filter that filtered nothing, the scaffold header whose absence made
  the join abort and fzf render 0/0, the header text written into data rows, and
  a `--yolo` branch that printed "command not found" and exited 0 having written
  nothing. A non-interactive run of the same code proves nothing about what the
  user sees, because what the user sees is the part being asserted.

  The standard behind the rule: shipping on "the tests passed" while the first
  real use hits a defect is a broken promise. The customer does not care which
  layer was green; they care that it worked when they ran it. So the acceptance
  run for anything touching the picker is a real terminal, on the real platform,
  with the pane read back and asserted on — and a run that could not do that is
  reported as unverified, never as passed.

- **Distributed artifact is standard-library Python only.** Dev-time static
  analysis (`ty`, `ruff`) lives in `flake.nix`'s devShell and never reaches a
  user's machine. Rationale: the skill installs into other people's
  environments; a pip dependency is a support burden with no upside at this size.
- **Acceptance is a protocol, not a hand-run.** Every item names the command
  whose output proves it. The PM does not re-run what a subagent already ran;
  the PM runs the end-to-end path once, on the real entry point.
- **Test discipline.** A regression test earns its place only if it fails on a
  plausible bug. `test/funnel-e2e.sh` exists because three real failures (side-file
  filter, dropped scaffold header, header-as-data row) each passed every
  non-interactive check and only surfaced under a real tmux + fzf.
- **One writer per file.** Sibling tasks are given disjoint file scopes; shared
  files (SKILL.md, the scripts) have exactly one owner at a time.
- **The funnel does not pre-fill `suggested`.** After `run --in-place`, the
  rebuilt `screen.tsv` has empty suggestion columns, so the picker shows the
  survivors with nothing pre-selected. Considered pre-filling them with
  `suggested=keep, reason="funnel survivor"` and rejected: the column records a
  judgement made by reading the session, and a mechanical stage passing it is a
  different claim — merging the two makes the column unusable as a record of
  which is which. The convenience the pre-fill would buy is one keystroke
  (`ctrl-a` selects all rows in the picker, then ENTER).
- **GitHub renders images, not asciicasts.** An `.cast` cannot play in a README:
  the asciinema player is embedded with a `<script>` tag, and GitHub's markdown
  sanitizer strips `<script>` (GFM §6.11). asciinema's own guidance for hosts in
  that position is a GIF via `agg`, which is what ships
  (`docs/agent-session-batch-export/demo.gif`, regenerated byte-identically by
  the command in `demo.sh`). The `.cast` stays as the higher-fidelity original
  and the `asciinema play` line stays for anyone reading the repo locally.
- **A test that has not run recently is a claim, not a check.** When the output
  directory prompt was added, `test/test-outdir-tmux.sh` was written for it and
  `test/test-pick-tmux.sh` was not updated: its wait loop looked for the fzf
  header and timed out at the prompt, so seven assertions failed and one passed
  for the wrong reason (ESC at a bash prompt does nothing — it looked like "ESC
  wrote nothing"). The suite had been red since that commit and nobody saw it,
  because nothing runs the suites automatically. Two latent assertions behind it
  were also stale (a "select-all by default" that no shipped revision ever had,
  and a preview line that only appears on a screened run). Rule for the next
  change to the entry point: run the suites in the same session, and when a
  behaviour is added for a prompt or a flag, update every suite that drives that
  path rather than only the one written for the new behaviour.
- **Open question: `approved_by` records a claim, not a fact.** The manifest
  stamps `approved_by=user-opt-out` whenever `--yolo` was passed, so an agent
  that ran yolo without the user asking for it writes an untrue provenance
  record — the field cannot distinguish "the user opted out" from "the agent
  decided they had". Making it true would mean carrying the user's own words
  into the run (`--yolo --because "<quote>"`) or refusing yolo without one.
  Raised with the user; not decided, and nothing is built for it.

## Real-machine acceptance (Windows Git Bash)

**Scope of what is verified here: the non-interactive path only.** This run
exercised `--yolo`, which by design never opens the picker. It therefore says
nothing about the interactive picker on Windows — the fzf pane, its key
bindings, its pre-selection display, or the terminal spawn. Under the standard
above, the picker on Windows is **unverified** until it is driven through
zellij. That run is item 8 (issue #7).

Run against the copy installed by `npx skills add` into
`C:\Users\Samuka007\.agents\skills\agent-session-batch-export`, driven by the
Windows Git Bash (`C:\Program Files\Git\bin\bash.exe`) rather than WSL — that is
the environment the skill's Windows users have, and the one where MSYS argument
rewriting and CRLF hazards live.

Observed: yolo run exits 0 with the rule line `suggested=keep rows from
screen.tsv — keeping 2 of 3 — no picker`; `verified: 2/2 copies byte-identical`;
every manifest entry carries `mode=yolo`; the gated `finalize` run adds none of
the three provenance keys. Scratch fixtures lived under
`C:\Users\Samuka007\tmp-yolo-win` and were removed afterwards.
