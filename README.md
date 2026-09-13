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
skills/<skill-name>/SKILL.md     # required, with YAML frontmatter
skills/<skill-name>/scripts/     # optional executable code
```

Follows the [Agent Skills specification](https://agentskills.io/specification):

```bash
npx skills-ref validate ./skills/<skill-name>
```
