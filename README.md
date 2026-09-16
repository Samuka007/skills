# skills

Personal Agent Skills, installable with [skills.sh](https://skills.sh) / `npx skills`.

```bash
npx skills add Samuka007/skills --list

# the base skill: scan, screen, review, copy, manifest, deliver
npx skills add Samuka007/skills --skill agent-session-batch-export -g

# a direction bundle needs the base skill too — there is no dependency field
# in the Agent Skills spec, so both are named (or use Select All)
npx skills add Samuka007/skills \
  --skill session-export-nocode --skill agent-session-batch-export -g
```

## Available

| Skill | What it does |
|---|---|
| [`agent-session-batch-export`](skills/agent-session-batch-export/SKILL.md) | Curate claude_code/codex session transcripts into a corpus of **raw `.jsonl`** trajectory material for agentic analysis. Scans candidates by workspace/topic, lets an agent screen them and a human mark keep/drop, then copies the kept sessions byte-for-byte with a sha256 manifest. |
| [`session-export-nocode`](skills/session-export-nocode/SKILL.md) | Export the non-code direction: six themes, selected by the base skill's deterministic funnel rather than by an agent reading prose. Invoked by hand; only an explicit opt-out phrase skips the confirmation. |

Two layers, one rule about where a change lands. The **base skill** owns the
mechanism (the funnel), the themes, and the pipeline. A **direction bundle**
owns only a theme list and its invocation policy — it restates no threshold, so
adding a purchase direction adds one small skill and changes no numbers.

Two published skills have been retired — `trajectory-packs`, and the engine
directory `trajectory-funnel` beside it — and replaced by the two above. The
installer copies and never removes, so a machine that installed the old one
still has it; [`docs/RELEASE-NOTES.md`](docs/RELEASE-NOTES.md) says what to
delete and what to install.

## Using

After install both skills live in `~/.agents/skills/`. Three entry points,
by who drives:

**Ask your agent.** Agents with skill discovery (codex, claude code, opencode,
…) find the installed skill from your request and drive the scripts for you.
Say what you want in plain words — what kind of sessions, what to exclude,
whether you will review the selection:

> 把我最近的非代码会话（翻译、改写这类）整理成一个可以直接交给别人的
> 语料包，不用人工审。

The selection on the direction path is deterministic — a Python funnel applies
the theme thresholds, the agent never judges prose. Skipping review is explicit
or absent: the launcher derives `--yolo` only from the exact phrases
`直接导出` / `无需确认` / `不用确认` / `无须确认`, and refuses the flag
passed by hand; anything else stops at a confirmation prompt.

**The direction command.** The non-code direction is human-invoked; the
launcher owns the opt-out policy above, so you never touch `--yolo` yourself:

```bash
bash ~/.agents/skills/session-export-nocode/scripts/session-export-nocode.sh \
  --request "直接导出非代码会话" \
  --out ./out
```

**Run the pipeline yourself.** Interactive, one command, lands in the fzf
picker; your ENTER finalizes and verifies every kept copy byte-identical in
one go. On Windows invoke the `.ps1` wrappers instead — they pin Git Bash and
declare the sessions are the Windows side's:

```bash
bash ~/.agents/skills/agent-session-batch-export/scripts/pick-sessions.sh \
  -o ./cur --agent codex --min-lines 20
```

Prerequisites: `jq` and `python3` (Windows Git Bash: `scoop install jq
python`). On Windows the `python3` on PATH is usually the Microsoft Store
stub, which is why the scripts probe by *executing* rather than by presence.

What every path produces: `OUT/keep/*.jsonl` (byte-identical originals),
`OUT/manifest.json` (sha256 + provenance per entry), and a delivery archive.
Stage-by-stage detail, the hand-off gate, and the interactive/headless
matrix: [skill README](skills/agent-session-batch-export/README.md).

## Layout

```
skills/<skill-name>/SKILL.md     # required, with YAML frontmatter  (shipped)
skills/<skill-name>/scripts/     # executable code                  (shipped)
skills/<skill-name>/themes/      # theme policy JSON: every threshold (shipped)

docs/<skill-name>/               # maintainer notes          (repo only)
docs/RELEASE-NOTES.md            # retirements, and what replaced them (repo only)
test/                            # test suites               (repo only)
```

`skills/<skill-name>/` is the published unit: `npx skills add` copies that
directory **whole**, so maintainer documentation must not live inside it. Each
skill's development notes go in `docs/<skill-name>/`, mirroring the skill name
so the mapping is one-to-one. The one exception is `docs/RELEASE-NOTES.md`:
a retirement outlives the skill it retires, so it belongs to no single skill.

Follows the [Agent Skills specification](https://agentskills.io/specification):

```bash
npx skills-ref validate ./skills/<skill-name>
```

## Development

```bash
nix develop                                       # tmux + shellcheck + ty + ruff
echo "--- non-interactive ---"
bash test/accept.sh skills/agent-session-batch-export /tmp/work
echo "--- interactive (real PTY) ---"
bash test/funnel-e2e.sh                           # funnel --in-place -> pick -> verified
bash test/ux-grounding.sh .                       # entry-point UX
bash test/test-fzf-tmux.sh skills/agent-session-batch-export /tmp/fzft
bash test/test-pick-tmux.sh "$PWD"                # whole one-command journey
bash test/test-outdir-tmux.sh                     # output-directory prompt flow
echo "--- interactive (Windows, run under Git Bash) ---"
bash test/win-zellij-pick.sh                      # real picker through zellij (issue #7)
echo "--- static ---"
bash test/shipped-install-refs.sh
shellcheck skills/<name>/scripts/*.sh
ty check skills/agent-session-batch-export/scripts/funnel.py
ruff check skills/agent-session-batch-export/scripts/funnel.py
```

The interactive tests need a real PTY (they drive tmux and read the pane back)
and skip themselves without one; they are the only tests that can see the
picker's actual output. On Windows the same class of test runs through zellij —
see [`SPEC/README.md`](SPEC/README.md) § Decisions. [`AGENTS.md`](AGENTS.md) has
how work here is accepted.

| Skill | Dev notes |
|---|---|
| `agent-session-batch-export` | [`docs/agent-session-batch-export/INTERNALS.md`](docs/agent-session-batch-export/INTERNALS.md) |
