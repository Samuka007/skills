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
nix develop                                    # tmux + shellcheck
bash test/accept.sh skills/<name> /tmp/work    # engine, non-interactive
bash test/ux-grounding.sh .                    # real-PTY TUI behaviour
shellcheck skills/<name>/scripts/*.sh
```

| Skill | Dev notes |
|---|---|
| `agent-session-batch-export` | [`docs/agent-session-batch-export/INTERNALS.md`](docs/agent-session-batch-export/INTERNALS.md) |
