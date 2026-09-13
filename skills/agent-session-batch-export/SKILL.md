---
name: agent-session-batch-export
description: "Curate claude_code/codex session transcripts into a corpus of RAW .jsonl trajectory material for agentic analysis. Scans candidates by workspace/topic, lets an agent screen them and a human mark keep/drop, then copies the kept sessions byte-for-byte with a sha256 manifest. Use when extracting trajectory material, building a dataset of past agent sessions, filtering sessions by workspace, project, or topic, or when the user wants to pick conversations to keep from their agent history."
license: MIT
compatibility: "Requires bash 3.2+ with a POSIX userland (awk, sed, find, stat, cmp, sort, cut, tr, mktemp, sha256). Windows Git Bash bundles all of that; add jq and ripgrep (rg) via scoop or winget. Optional: fzf for the interactive review step. Reads ~/.claude/projects and ~/.codex/sessions. Runs on Linux, macOS, and Windows Git Bash."
metadata:
  verified-platforms: "GNU/Linux; Windows Git Bash (MINGW64) with scoop jq+ripgrep"
---

# Curate agent sessions into trajectory material

Turns a large pile of claude_code / codex transcripts into a small, provably
unmodified corpus that an agent can analyze.

`scripts/curate-sessions.sh` — no index, no daemon, no network, no Python.

The core property: **the kept files are byte-identical copies of the originals**,
each with a recorded sha256. Nothing is re-rendered, summarized, or converted,
so downstream analysis reads the real trajectory (every tool call and result),
not a lossy view of it.

## Pipeline

Run the stages in order. Stage 2 is yours to perform; the rest are commands.

```bash
C=scripts/curate-sessions.sh

# 1. scan — enumerate candidates -> OUT/candidates.tsv
bash $C scan -o /tmp/cur --workspace cits4012 --min-lines 20

# 2. screen — YOU read the candidates and annotate them (see Screening)
#
# 3. review — human keep/drop -> OUT/decisions.tsv
bash $C review --ui fzf -o /tmp/cur      # multi-select, full-prose preview
bash $C review --ui tsv -o /tmp/cur      # no TUI: emit the TSV to hand-edit

# 4. finalize — materialize -> OUT/keep/*.jsonl + OUT/manifest.json
bash $C finalize -o /tmp/cur
```

Each stage has one completion criterion:

| Stage | Done when |
|---|---|
| `scan` | `candidates.tsv` has one row per session that passed the metadata filters |
| screen | every row carries a `suggested` (`keep`/`drop`) and a one-line `reason` |
| `review` | `decisions.tsv` has a `decision` on every row |
| `finalize` | `manifest.json` lists every kept session, and each `kept_as` compares equal to its `source` |

## Screening (stage 2)

Read `candidates.tsv`, open the sessions that matter, then add two columns:
`suggested` (`keep` / `drop`) and `reason` (one line of evidence). Write the
annotated file back for the human.

Judge from the prose, not from the metadata row. Column 6 (`first_prompt`) is a
triage hint and can be blank: codex writes `<environment_context>`, AGENTS.md
and skills scaffolding as user messages, and those are stripped as scaffolding
rather than reported as content. A blank `first_prompt` means the session had
no human-authored opening turn — that is itself signal for `drop`.

`finalize` reads only the `decision` column, so a human overrides your
`suggested` value by editing one field.

## Verifying the corpus

### What has actually been verified

Not "the checks passed" — what each check covers, so the gaps are visible:

| Area | Coverage |
|---|---|
| scan / workspace / topic / since / min-lines | 10-assertion suite, Linux + Windows |
| review `--ui tsv` | 10-assertion suite, Linux + Windows |
| **review `--ui fzf`** (the default) | real PTY under tmux, Linux: TUI renders, preview shows real prose, TAB selects, ctrl-a/d work, ESC aborts without writing. Windows: fzf present but no PTY driver, so only the data path (list consumable by `fzf`, preview command emits prose) is covered — not the keypress interaction. |
| finalize byte-identity | `cmp` + recorded sha256, both platforms |
| cross-platform identity | same file, sha256 computed under WSL and Git Bash, equal |

Known blind spots: the fzf keypress path is unverified on Windows; macOS has
never been run (only the BSD `stat`/`shasum` branches were exercised via a stub).

`finalize` records `source`, `kept_as` and `sha256` per session. Confirm every
copy is byte-identical before handing the corpus on:

```bash
jq -r '.[] | "\(.source)\t\(.kept_as)"' /tmp/cur/manifest.json > /tmp/pairs.tsv
while IFS=$'\t' read -r s d; do cmp -s "$s" "$d" || echo "MISMATCH $s"; done < /tmp/pairs.tsv
```

Write the pair list to a file first. Feeding the loop from a process
substitution (`done < <(jq …)`) leaves `read` blocked on a pipe when the job is
backgrounded or interrupted, which hangs instead of failing.

## Options

`scan`:
- `--agent claude|codex|both` (default `both`)
- `--workspace SUBSTR` — substring of the session's real cwd
- `--topic REGEX` — extended regex over extracted prose
- `--since YYYY-MM-DD`
- `--min-lines N` — drop stub sessions

`review`:
- `--ui fzf` (default when fzf is present) or `--ui tsv`
- `--resume` — keep decisions already in `decisions.tsv`

`finalize`:
- `--from FILE` — read a decisions TSV other than the default
- `--hardlink` — link instead of copy. Read-only analysis only: a downstream
  writer would corrupt the original through the link.

`validate` checks a TSV's column shape and tallies its decision column.

## Data sources

| Agent | Path | Workspace field | Prose field |
|---|---|---|---|
| claude_code | `~/.claude/projects/<munged>/<uuid>.jsonl` | `.cwd` | `.message.content` (string, or array of `{type:"text",text}`) |
| codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `session_meta.payload.cwd` | `.payload.content[].text` where `payload.type=="message"` |

Two rules follow, and both are load-bearing:

- **Read the workspace from the field, never the directory name.** claude
  replaces `/` with `-`, so `-home-nixos-workspace-cits4012-a1` is ambiguous
  between `…/cits4012/a1` and `…/cits4012-a1`.
- **Match topics against extracted prose only.** Matching raw JSONL line-bytes
  hits base64 attachments and `tool_result` payloads, producing confident
  garbage hits.

## Portability traps

Each of these fails *silently* on at least one supported platform, so a
rewrite that "simplifies" the handling away reintroduces the bug. All are
already handled in the script; this section is why the handling exists.

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
8. **`jq -r` emits CRLF on Windows.** The CR rides along in the last field of a
   tab-separated read (a tab is IFS whitespace, so `read` strips it there; `\x1f`
   is not, so it does not). A path with a trailing CR makes `cmp` exit 2 — the
   same code as a missing file, which reads as "corrupt copy" when the copy is
   fine. Every field used verbatim is CR-stripped, and the printed verification
   recipe strips it too.
9. **Windows sessions record `C:\Users\x\proj`.** The derived `cwd` column has
   separators normalised to `/` so `--workspace` means the same thing on both
   platforms. The trajectory itself is never touched.
10. **Both discovery branches must feed one redirect.** With `> file` hanging off
   only the second `if`, the claude half leaked to stdout and the candidate
   file silently held codex alone.
11. **`--latest`** collapses a workspace's stale rollout files to the newest.

## Adding a harness

Add one `discover()` branch emitting `agent <TAB> cwd <TAB> mtime <TAB> file`,
plus its prose extractor in both the `prose` and `first_prompt` functions.

`~/.omp/agent/sessions` is the obvious next one and is ~24k files / 8.4 GB, so
it must stream rather than accumulate.
