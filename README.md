# skills

Personal Agent Skills, installable with [skills.sh](https://skills.sh) / `npx skills`.

```bash
npx skills add Samuka007/skills --list
npx skills add Samuka007/skills --skill agent-session-batch-export -g
```

## Available

| Skill | What it does |
|---|---|
| [`agent-session-batch-export`](skills/agent-session-batch-export/SKILL.md) | Curate claude_code/codex session transcripts into a corpus of **raw `.jsonl`** trajectory material for agentic analysis. Scans candidates by workspace/topic, lets an agent screen them and a human mark keep/drop, then copies the kept sessions byte-for-byte with a sha256 manifest. |

## Layout

```
skills/<skill-name>/SKILL.md     # required, with YAML frontmatter  (shipped)
skills/<skill-name>/scripts/     # executable code                  (shipped)

docs/<skill-name>/               # maintainer notes          (repo only)
test/                            # test suites               (repo only)
```

`skills/<skill-name>/` is the published unit: `npx skills add` copies that
directory **whole**, so maintainer documentation must not live inside it. Each
skill's development notes go in `docs/<skill-name>/`, mirroring the skill name
so the mapping is one-to-one.

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
shellcheck skills/<name>/scripts/*.sh
ty check skills/trajectory-funnel/scripts/funnel.py
ruff check skills/trajectory-funnel/scripts/funnel.py
```

The interactive tests need a real PTY (they drive tmux and read the pane back)
and skip themselves without one; they are the only tests that can see the
picker's actual output. On Windows the same class of test runs through zellij —
see [`SPEC/README.md`](SPEC/README.md) § Decisions. [`AGENTS.md`](AGENTS.md) has
how work here is accepted.

| Skill | Dev notes |
|---|---|
| `agent-session-batch-export` | [`docs/agent-session-batch-export/INTERNALS.md`](docs/agent-session-batch-export/INTERNALS.md) |
