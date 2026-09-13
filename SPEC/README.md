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
| 5 | SKILL.md: funnel mention + yolo escape clause | **half done** | escape clause landed with #2 (`33361ee`); the funnel subsection is still missing — `grep -n -i funnel SKILL.md` finds nothing |
| 6 | INTERNALS.md: record this round's traps | **registered** | funnel contract, yolo provenance, dev-tooling policy |

## Decisions and constraints (apply to all future items)

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
