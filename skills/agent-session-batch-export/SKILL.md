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

Prefer the one-command entry point. It runs the whole pipeline and opens a
picker in a real terminal, spawning one if necessary:

```bash
bash scripts/pick-sessions.sh -o ./cur --agent codex --min-lines 20
```

That is the intended UX. The four stages below are the manual equivalent, and
what the entry point calls internally.

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

Codex marks those injected blocks as ordinary `message` items, so a reader that
selects on `payload.type == "message"` alone will also pull in ~80 lines of
system boilerplate. Restrict to `payload.role` of `user` or `assistant`.

`finalize` reads only the `decision` column, so a human overrides your
`suggested` value by editing one field.

## Verifying the corpus

`finalize` records `source`, `kept_as` and `sha256` per session. Confirm every
copy is byte-identical before handing the corpus on:

```bash
jq -r '.[] | "\(.source)\t\(.kept_as)"' /tmp/cur/manifest.json > /tmp/pairs.tsv
while IFS=$'\t' read -r s d; do cmp -s "$s" "$d" || echo "MISMATCH $s"; done < /tmp/pairs.tsv
```

Write the pair list to a file first. Feeding the loop from a process
substitution (`done < <(jq …)`) leaves `read` blocked on a pipe when the job is
backgrounded or interrupted, which hangs instead of failing.

The picker runs this check itself after finalizing and prints
`verified: N/N copies byte-identical`.

## Options

`scan`:
- `--agent claude|codex|both` (default `both`)
- `--workspace SUBSTR` — substring of the session's real cwd
- `--topic REGEX` — extended regex over extracted prose
- `--since YYYY-MM-DD`
- `--min-lines N` — drop stub sessions
- `--latest` — collapse a workspace's stale rollout files to the newest

`review`:
- `--ui fzf` (default when fzf is present) or `--ui tsv`
- `--resume` — keep decisions already in `decisions.tsv`

`finalize`:
- `--from FILE` — read a decisions TSV other than the default
- `--hardlink` — link instead of copy. Read-only analysis only: a downstream
  writer would corrupt the original through the link.

`validate` checks a TSV's column shape and tallies its decision column.

`pick-sessions.sh` accepts `-a/--agent`, `-w/--workspace`, `-t/--topic`,
`--since`, `-n/--min-lines`, `-o/--out`, `-y/--yes`, `--review-only`,
`--no-finalize`, `--stay`, `-h`.

## Output directory

`pick-sessions.sh` proposes a dated, agent-tagged default
(`./curated-<agent>-<YYYYmmdd-HHmm>`) and confirms it interactively:
Enter accepts, `e` then a path (Tab completes), `q` quits, or just type a path.
`-y` skips the prompt; a non-tty invocation skips it too, so scripted runs never
block. A fixed default would let consecutive runs pile into one directory and
the corpus would stop describing a single selection.

A second run with a smaller selection **replaces** `keep/` rather than adding to
it, so the corpus always equals the current decisions exactly.

## Data sources

| Agent | Path | Workspace field | Prose field |
|---|---|---|---|
| claude_code | `~/.claude/projects/<munged>/<uuid>.jsonl` | `.cwd` | `.message.content` (string, or array of `{type:"text",text}`) |
| codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `session_meta.payload.cwd` | `.payload.content[].text` where `payload.type=="message"` and `payload.role` is `user`/`assistant` |

Two rules follow, and both are load-bearing:

- **Read the workspace from the field, never the directory name.** claude
  replaces `/` with `-`, so `-home-nixos-workspace-cits4012-a1` is ambiguous
  between `…/cits4012/a1` and `…/cits4012-a1`.
- **Match topics against extracted prose only.** Matching raw JSONL line-bytes
  hits base64 attachments and `tool_result` payloads, producing confident
  garbage hits.

## WSL and Windows

There are two different "Windows" situations and they need different answers.
Both are handled automatically; this section is what to expect.

### Bash running inside WSL

The common case: you are in a WSL shell, `fzf` is available, and the sessions
you want to curate may live on either side (`~/.codex` in WSL, or
`/mnt/c/Users/<you>/.codex` on the Windows side — same file format, and the
script reads either).

If the shell has a real terminal, `pick-sessions.sh` just runs. If it does not
— invoked from a tool call, a CI step, or any non-interactive context — it
**opens its own terminal** and runs the picker there, in this order:

1. `wt.exe -- wsl.exe -d $WSL_DISTRO_NAME` — Windows Terminal (preferred)
2. `cmd.exe /c start … wsl.exe` — a plain console window
3. (native Linux desktops) `x-terminal-emulator`, `alacritty`, `kitty`,
   `wezterm`, `foot`, `gnome-terminal`, `konsole`, `xterm`
4. `tmux` — the last resort, because it supplies a real tty with no GUI

If nothing can be opened it prints the hand-edit TSV workflow instead of
pretending success. Launching a window is not the same as the user having
picked, so the spawned run prints its own result path once it is done; the
parent process exits immediately and does not claim to verify the child.

### Bash running natively on Windows (Git Bash / MSYS)

Here the whole script runs under MSYS, with no WSL in the picture.

Setup is two packages — MSYS already bundles the rest of the POSIX userland:

```bash
scoop install jq ripgrep          # or: winget install jqlang.jq BurntSushi.ripgrep.MSVC
```

`tmux` does not exist under MSYS, so it spawns **Windows Terminal running Git
Bash** instead, which gives the picker a real tty.

Point the scripts at the Windows-side session trees: `~/.codex` and
`~/.claude` resolve to `C:\Users\<you>\…`, which hold the same file formats.

## Maintainer notes

Development notes live in the repository, not in this directory — only
`SKILL.md` and `scripts/` are shipped to users. In the source repo that is
`docs/<skill-name>/`; for this skill:

```
docs/agent-session-batch-export/INTERNALS.md
```

It records why the scripts are written the way they are: the portability traps
(each of which fails *silently* if its handling is "simplified" away), the
verification coverage table, and how to drive the TUI headlessly for testing.
Read it before editing `scripts/`.

Two behaviours are easy to reintroduce by accident, so they are called out here
as well: **fields are split on `\x1f`, never on tab** (bash `read` collapses tab
as IFS whitespace, silently shifting every later column when a field is empty),
and **an `MSYS_NO_PATHCONV` prefix on a command exports to the whole child
tree** — which breaks `jq.exe`'s ability to open `/c/...` paths.
