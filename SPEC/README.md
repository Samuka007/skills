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
| 2 | yolo mode (no-review export on explicit opt-out) | **in progress** | — |
| 3 | READMEs for both skills | **done** | commit `f027a36`; accepted (read end-to-end against SKILL.md and funnel.py, synthetic-data smoke reproduces the documented 5→1 funnel table) |
| 4 | recorded select+export demo in README | **in progress** | DemoRecorder running |

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
