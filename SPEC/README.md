# SPEC index — trajectory-export skill family

**Where the spec lives.** The canonical Requirement / Specification / Acceptance
for each item is the **GitHub issue body** (`gh issue view <n> --repo Samuka007/skills`).
This index records what cannot live in an issue: current status, the acceptance
evidence, and decisions taken after the issue was written.

Rejected alternative: duplicating each issue body into `SPEC/<n>.md`. Two copies
of a spec drift — the issue gets edited during review and the file does not, and
a reader then cannot tell which one was agreed. One canonical location, pointed
at from here.

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

## Decisions and constraints (apply to all future items)

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
