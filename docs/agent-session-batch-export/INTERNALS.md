# Internals: why the scripts are written this way

Maintainer documentation for the skill at
`skills/agent-session-batch-export/`. It lives here, in `docs/`, rather than
inside the skill directory because `npx skills add` ships the *entire* skill
directory to users — a maintainer doc there would be installed on every user's
machine and loaded as part of the skill's progressive-disclosure payload.

Not needed to *use* the skill; read this before *editing* it. Every item below
describes behaviour that fails **silently** on at least one supported platform,
so a rewrite that "simplifies" the handling away reintroduces a bug that will
not announce itself.

The handling for all of these is already in the scripts. This file is why it
exists.

## Portability traps

These apply to the engine (`scripts/curate-sessions.sh`).

1. **`jq` may be `jaq`**, a reimplementation lacking jq's argument-less `first`
   (it yields *every* element rather than `.[0]`) and `starts()`. The first
   shredded the TSV and made topic matching return zero hits. Workspace
   extraction uses `awk 'NR==1{print;exit}'`; scaffolding filtering lives in
   awk. Write no jq-only builtins.
2. **`stat` is overloaded.** GNU and Git Bash use `-c '%s %Y'`; macOS/BSD uses
   `-f '%z %m'`; MSYS ships both, and `/usr/bin/stat` there is a *file-info*
   tool. The script probes behaviour instead of trusting `uname`, and keeps the
   format string in its own variable — expanding `"-c %s %Y"` unquoted splits
   it and GNU `stat` then reads `%Y` as a filename.
3. **`sha256sum` is GNU-only.** macOS has `shasum -a 256`. Probed once.
4. **bash `read` collapses runs of IFS whitespace** (space, tab, newline), so a
   TSV row with an empty `reason` or `suggested` loses that field and every
   later column shifts left — which reported `kept 0` while 5 rows were
   selected. The machine-side split uses `\x1f` (unit separator, not IFS
   whitespace). The human-facing file stays tab-delimited.
5. **`sed -i` and `read -d` differ.** GNU `sed -i EXPR` vs BSD `sed -i '' EXPR`
   (behind `sed_inplace`); `read -d $'\0'` is the spelling bash 3.2 accepts.
6. **Windows Git Bash ships everything except `jq` and `rg`.** MSYS bundles a
   full POSIX userland (awk, sed, find, stat, sha256sum, shasum, cmp, ln,
   mktemp), so only those two need adding — `scoop install jq ripgrep` or
   `winget install jqlang.jq BurntSushi.ripgrep.MSVC` is the whole setup.
7. **MSYS rewrites POSIX-looking arguments into Windows paths.** A workspace of
   `/proj/beta` reached `jq` as `C:/Program Files/Git/proj/beta`, corrupting the
   `cwd` column. Disabling the rewrite globally is *also* wrong: `jq.exe` is a
   native binary and then cannot open the `/c/...` paths MSYS bash hands it,
   silently producing zero candidates. Hence `jqd()` — the exemption wraps only
   the call whose arguments are data, never the file operand.

   The same trap bit a *different* call site: `spawn_terminal` originally ran
   `MSYS_NO_PATHCONV=1 wt.exe …`. A variable prefix exports to the **entire
   subtree**, so the spawned bash and every `jq` it ran inherited it, `jq.exe`
   then could not open `/c/...`, and the picker's preview pane rendered blank —
   while the same preview run by hand printed correctly. Convert the paths with
   `cygpath` up front and invoke `wt.exe` with a clean environment instead.
8. **`jq -r` emits CRLF on Windows.** The CR rides along in the last field of a
   tab-separated read (a tab is IFS whitespace, so `read` strips it there; `\x1f`
   is not, so it does not). A path with a trailing CR makes `cmp` exit 2 — the
   same code as a missing file, which reads as "corrupt copy" when the copy is
   fine. Every field used verbatim is CR-stripped, and the printed verification
   recipe strips it too.
9. **Windows sessions record `C:\Users\x\proj`.** The derived `cwd` column has
   separators normalised to `/` so `--workspace` means the same thing on both
   platforms. The trajectory itself is never touched.
10. **Both discovery branches must feed one redirect.** With `> file` hanging
    off only the second `if`, the claude half leaked to stdout and the
    candidate file silently held codex alone.
11. **A documented option that was never implemented is a shipped bug.**
    `--latest` appeared in SKILL.md and in this file as if it existed; it was
    never in the code, and a user following the doc got `unknown option` —
    it did not even exist in git history, so it was never lost, it was never
    true. Docs may only describe what a test exercises.

## Traps specific to the picker (`scripts/pick-sessions.sh`)

12. **`--preview {n}` indexes the *display* row once `--with-nth` is set**, not
    the original fields. Verified by experiment: `--with-nth=3,1` with
    `--preview {1}` yielded the old third column. The picker passes the whole
    row (`{}`) and parses it itself, so the two can never disagree.
13. **`--with-nth` and the write-back row: verify per fzf version.** fzf
    0.74.3 returns the FULL original row on selection (verified via
    `--filter` and a real pty), which is why curate's `review` may keep
    `--with-nth=1,2,5,6` and read `$7`. An earlier note here claimed the
    write-back was also transformed — re-testing could not reproduce that on
    this version. The picker still avoids `--with-nth` (display order equals
    file order, returned row byte-identical by construction); do not "fix"
    curate's review off the old claim without re-measuring your fzf.
14. **`start:` fires before the input is loaded, so `start:select-all` selects
    nothing** — it looks like it worked and silently leaves `(0)` selected.
    `load:` fires after loading and does work (`--sync` also rescues `start:`).
    The picker binds `load:`.
15. **Selection actions act on the matched set, never on a row id**, so
    "pre-select these N rows" means positioning and toggling N times. Because
    the keeps are sorted to the top, that is the sequence
    `pos(1)+toggle+down+…+toggle+first`.
16. **fzf's default layout draws item 1 at the BOTTOM.** Sorted-keeps-first
    therefore looked like nothing had sorted. `--layout=reverse` puts item 1 on
    the top line, which is what a reader expects.
17. **The `(N)` in fzf's `N/M (N)` info line IS the selected count** —
    established by experiment, not by the docs. Use it to verify pre-selection;
    ENTER with nothing ticked still returns the *highlighted* row, not nothing.
18. **The `\x1f` rule from trap 4 applies to the picker's own readers too.**
    It was reintroduced there: a row with an empty `first_prompt` lost that field
    to IFS-whitespace collapsing, every later column shifted left, and 2 of 15
    selected sessions silently never reached the manifest.

    It was reintroduced a *third* time in the preview script, where the symptom
    was different and hid the cause: `$f` received the empty reason instead of
    the session path, so `jq` was handed a nonexistent file and the preview pane
    came up blank — for exactly the sessions with no first prompt. Any reader of
    a display row must use `\x1f`.
19. **fzf has no "focus the preview pane" concept.** The preview is read-only
    and cannot be tabbed into, so `TAB` cannot switch panes — `TAB` is only
    `toggle`. Preview scrolling is key-driven: `shift-↑/↓` is built in, and
    `PgUp/PgDn`, `alt-↑/↓`, `ctrl-o` are bound by the picker.
20. **A binding on a PRINTABLE key steals that keystroke from the query.**
    Binding `g:preview-top` made `g` untypeable in the search box (verified: the
    query stayed empty and the match count did not move). Preview keys must be
    non-printable.
21. **`enable-search` does NOT disable other bindings.** A claim once written
    in SKILL.md — that "once `/` enables search, space becomes an ordinary
    character" — was reasoning, never measured, and is false: `space:toggle`
    kept firing and ate the space. `unbind(space)` had to be part of the `/`
    action.
22. **Do not bind `esc`.** Stealing it removes the escape hatch; a user who
    cannot leave the mode is trapped.
23. **Judge "did fzf abort?" by its exit, not by tmux session liveness.** The
    shell outlives fzf, so `tmux has-session` reports alive either way — this
    produced a false "ESC is broken" regression during development. Write a
    marker file after fzf returns.
24. **Do not bind SPACE.** Two designs were tried and both cost more than they
    bought:
    - `space:toggle` — SPACE ate the space, so no query could contain one;
    - a modal `/`-search with `unbind(space)` — that works, but forces the user
      to track which mode they are in and to remember `ctrl-b` to leave it.

    Leaving SPACE **unbound** solves it outright: it is an ordinary character,
    so queries may contain spaces with no mode to enter or leave. The marking
    key is `TAB`, which has no character to steal. That is the current design.
25. **`--disabled` still accumulates typed characters into the query.** Pressing
    `/` then filtered on whatever had been typed beforehand (`al` -> 1/3 while
    `--disabled` had shown 3/3). Any future modal design needs `clear-query` in
    the enabling binding.
26. **fzf matches FUZZY, so "the match count did not change" is not evidence
    that a keystroke was lost.** Probing whether a space reached the query with
    rows `codex x` / `codexx` showed no change and looked like a swallowed
    space — but `x` fuzzy-matches `codexx` too, so the count could not move
    either way. A valid discriminator needs mutually exclusive results: rows
    `aa bb` / `aa cc` give 2/3 for `aa` and 1/3 for `aa bb`, which only the
    space can produce.
27. **The rendered query line trims its trailing space**, so asserting on its
    text cannot see a trailing space. Assert on an observable consequence.
28. **`read -e` that fails has already consumed the line.** A per-call fallback
    written as `read -e -r v || read -r v` reads TWICE at EOF: the first read
    takes the answer (and returns non-zero at end-of-input), the second eats the
    next input. Probe `read -e` support once at startup and use one call.
    Probing with an empty string is a false negative — an empty here-string is
    EOF, so probe with real content.
29. **`finalize` clears `keep/` before materializing.** Copying is additive, so
    a second run with a smaller selection left the earlier corpus in place:
    `keep/` held 12 files while the manifest listed 3. That reads as a bug and,
    worse, hands downstream analysis sessions the user had dropped. The corpus
    is derived state and must equal the current decisions exactly.
30. **Windows Terminal closes the window the moment the command returns**
    (`closeOnExit` defaults to graceful), so the result path is never readable.
    `--stay` holds it open, and it must be an EXIT `trap` rather than a `read`
    at the end — otherwise it is missing on exactly the paths that need it
    (abort, validation failure, crash).
31. **`tmux send-keys` races anything the script does first.** Typing `e` after
    a fixed `sleep 3` landed while `scan` was still running and was swallowed,
    which looked like "the edit branch is broken". Wait for the prompt text to
    appear on screen, then type.
32. **A `[role]` filter is not optional when reading codex prose.** Codex marks
    its injected blocks (`<app-context>`, the team preamble, multi-agent mode)
    as `payload.type == "message"` too, so selecting on that alone pulls ~80
    lines of boilerplate into the preview and pushes the real first exchange
    past the cut. Filter on `payload.role` (`user`/`assistant`).
33. **`@tsv` in `jq` escapes newlines inside a field.** A multi-line message
    then prints a literal `\n` instead of breaking the line. Decode `\n`, `\t`,
    `\r` and `\\` after reading the field.
34. **The picker splits the row on `\x1f` for the same reason as trap 4**, and
    also strips a trailing CR from every field before comparing paths — a CR
    makes `cmp` report a mismatch on a byte-identical copy.
35. **`set -u` plus a variable defined in one command block is a latent
    crash in every other block.** `TMP` was created inside `scan` only, so
    `review` (the default-UI command, and `--resume`) died with
    "TMP: unbound variable" before doing anything. Shared state belongs at
    the top; per-command state belongs to that command's block.
36. **A screening file is EXTERNAL INPUT, so it gets the same defenses as jq
    output.** A screen.tsv saved CRLF rode its CR onto `session_file`, the
    join regex never matched, and the entire screening arrived as empty
    suggestions; a tab inside `reason` shifted every later column and a kept
    session silently vanished at finalize. CR-strip and field-sanitize on
    ingest, on both sides of the join and in the finalize reader.
37. **The no-terminal fallback must reference a file that exists at that
    point.** The picker's headless fallback told the user to edit
    `decisions.tsv` — only written AFTER a successful pick — so following the
    printed instructions verbatim produced a garbage hand-edit and a finalize
    header failure. Print the staged sequence (review --ui tsv → edit →
    finalize) instead, and exit non-zero.
38. **A headless caller cannot attach to tmux.** `exec tmux attach` died with
    "open terminal failed: not a terminal" — after creating the session, so
    the run LOOKED alive while the process was gone and the staged fallback
    was unreachable. Create the session, print the attach command, return.
39. **Spawn "success" is delegation, not a window.** `wt.exe` exits 0 the
    moment the spawn is delegated; on a disconnected desktop no visible
    window ever appears. Report spawns as "requested", never "opened", and
    always print the staged escape hatch alongside.
40. **`bash < script` (stdin invocation) cannot read `$0` for a self-check.**
    The CRLF guard skips itself when `$0` is not a readable file — fail open
    there, or the guard adds a second confusing error to the first. Direct
    `./script` execution of a CRLF file dies in the KERNEL
    (`env: 'bash\r': No such file`), before bash parses anything: no in-file
    guard can catch that one, which is why SKILL.md says to invoke via
    `bash <script>`.
41. **CRLF guard lines must end in a comment.** A guard line ending in a
    quoted word grows a trailing CR under a CRLF smudge (the CR becomes part
    of the word); ending every guard line in `# CRLF-GUARD` swallows the CR
    into the comment instead. Verified by experiment: the guard survives its
    own CRLF file and exits 3 before any compound-command syntax error (bash
    parses incrementally).
42. **The product's interaction surface is defined by "can a Windows-side
    terminal be launched", not by host taxonomy.** The picker once cycled
    through Linux desktop terminals (`x-terminal-emulator`, `alacritty`,
    …) when every spawn failed — a silent gamble on processes a headless
    caller can neither see nor verify. Linux has no unified terminal-launch
    mechanism, so on pure Linux the product does NOT open windows at all:
    interaction is the user's own terminal (the `package`d launcher or
    `review --ui fzf`), and headless runs get the staged pipeline. The
    removed loop only ever fired where it could not work.
43. **A test harness must not be part of the product surface.** tmux/zellij
    spawning lives behind `--test-spawn tmux|zellij` — undocumented in
    SKILL.md and `usage()`, never auto-triggered, idempotent (kills a stale
    session of the same name first), and prints its own cleanup command. An
    auto-firing "last resort" harness made the product's behavior depend on
    what a box happened to have installed.
44. **Hand the interactive step back to the user with a generated launcher,
    not instructions.** `curate-sessions.sh package` writes
    `OUT/open-review.sh` into the bundle next to the TSVs (absolute engine
    path hardcoded at package time, fzf-checked, review → finalize → verify
    in one run). Telling an agent to "print the command the user should run"
    produced stale hand-transcribed paths; a generated file in the OUTDIR
    bundle cannot drift from the data it operates on.
45. **Two entry points on Windows, because the intent is not inferable.**
    The user's target sessions (Windows side vs Linux side) and the shell an
    agent's `bash` resolves to (Git Bash vs `system32\bash.exe` = WSL bash)
    are independent. No check inside the .sh can distinguish "WSL bash,
    user wants Linux-side sessions" (legitimate) from "WSL bash, user
    actually wanted Windows-side sessions" (wrong interpreter AND wrong
    tree) — shell identity does not encode intent. Hence the .ps1 wrappers:
    invoking `pick-sessions.ps1` IS the declaration "Windows side", and the
    wrapper pins Git Bash (Program Files → scoop shims → PATH minus
    system32), failing with `winget install Git.Git` when absent. Running a
    bare .sh under WSL bash remains the Linux-side path, not an error.
    Verified: PS 5.1 param pass-through with quoted paths, exit-code
    propagation, WSL-bash exclusion on the PATH probe.

## Verification coverage

Not "the checks passed" — what each check covers, so the gaps are visible:

| Area | Coverage |
|---|---|
| scan / workspace / topic / since / min-lines | 10-assertion suite, Linux + Windows |
| review `--ui tsv` | 10-assertion suite, Linux + Windows |
| **review `--ui fzf`** (the default) | real PTY under tmux, Linux: TUI renders, preview shows real prose, TAB selects, ctrl-a/d work, ESC aborts without writing. Windows: covered through a real zellij session (`dump-screen` reads the rendered pane back), so the keypress path and the preview render are both observed — not merely the data path. (2026-09-13: this command had been DEAD on every platform — TMP unbound, trap 35 — so earlier "verified" entries were exercised against a hand-shaped file, not this command's happy path. Fixed and re-verified.) |
| finalize byte-identity | `cmp` + recorded sha256, both platforms |
| cross-platform identity | same file, sha256 computed under WSL and Git Bash, equal |
| auto-spawn a terminal | Windows Git Bash: verified end-to-end. WSL: verified. Pure Linux: no spawn exists anymore (trap 42) — headless runs print the staged pipeline. |
| `package` launcher | generated on Linux, then run by hand in a user terminal: fzf opens over screened candidates, ENTER finalizes and verifies. |
| `--test-spawn` harness | tmux/zellij session created detached, driven via send-keys/write-chars, read back via capture-pane/dump-screen, reclaimed by the printed cleanup command. |

Known blind spots: macOS has never been run (only the BSD `stat`/`shasum`
branches were exercised via a stub).

### Driving the TUI from a script

`tmux` gives a real PTY on Linux. On Windows there is no tmux (`psmux` is a
separate port), but `zellij` works and can be driven headlessly:

```bash
zellij --session NAME action write-chars "<command>"   # type into the pane
zellij --session NAME action send-keys "Enter"         # commit it
zellij --session NAME action dump-screen               # read the rendered pane
zellij delete-session NAME --force                     # clean up
```

Three setup facts, all of which fail confusingly if missed:

- zellij's config on Windows lives at `%APPDATA%\Zellij\config\config.kdl`,
  **not** `~/.config/zellij/`. Confirm with `zellij setup --check`.
- `default_shell` must be a **Windows path** (`C:\Program Files\Git\bin\bash.exe`).
  A native `zellij.exe` cannot exec the MSYS spelling `/usr/bin/bash`, and
  silently gives you a pane with no shell in it.
- Set `show_release_notes false` and `show_startup_tips false`, or a first-run
  dialog swallows the typed command and the screen looks empty.

Facts a bare `dump-screen` cannot give you: whether the preview pane rendered
*prose* (it can be blank while the header renders fine), and whether a keystroke
was consumed. To be sure, have the command under test write a marker file and
read that.

## Adding a harness

Add one `discover()` branch emitting `agent <TAB> cwd <TAB> mtime <TAB> file`,
plus its prose extractor in both the `prose` and `first_prompt` functions.

`~/.omp/agent/sessions` is the obvious next one and is ~24k files / 8.4 GB, so
it must stream rather than accumulate.
