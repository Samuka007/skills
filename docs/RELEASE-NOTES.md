# Release notes

What changed in the copies of these skills that are already on other machines,
and what a machine holding an older copy has to do.

Two properties of the installer shape everything below:

- **It copies a skill directory whole, and never removes one.** A skill that
  leaves this repository stays on every machine that installed it, and nothing
  run from here can reach those copies.
- **It drops a name it cannot resolve, and still reports success.** Recorded
  when the cutover below was verified on Windows (`SPEC/README.md` item 22): a
  command asking for three skills, one of which no longer exists, answers
  `Selected 2 skills … Installed 2 skills ✓✓`. The counts describe what the
  installer found, not what the command asked for, so following an instruction
  that names a retired skill looks like it worked.

A retirement therefore has to be announced here and repeated in the
replacement's own `README.md`: of those two surfaces, only the README is
carried to a partner's machine.

## `trajectory-packs` and `trajectory-funnel` retired

| Retired | What it was | Replaced by |
|---|---|---|
| `trajectory-packs` | the pack skill: six theme packs and the driver that expanded them | `agent-session-batch-export` (the base skill) and `session-export-nocode` (the shipped direction bundle) |
| `trajectory-funnel` | the selection engine, in a directory of its own | `skills/agent-session-batch-export/scripts/funnel.py` |

The pack layer's job — export a named set of themes with no agent reading prose
— is `export-direction.sh` now, and the engine lives inside the skill that uses
it instead of in a second directory that had to be installed alongside. The
reasoning is in [`session-export/DESIGN.md`](session-export/DESIGN.md) § Why
this was three layers, and is now two.

### On a machine that installed the retired skill

`~/.agents/skills/trajectory-packs` is still there. Running it fails closed: it
exits nonzero and writes nothing. What it prints as the fix is the problem —

```bash
npx skills add Samuka007/skills --skill trajectory-packs --skill trajectory-funnel --skill agent-session-batch-export -g -y
```

Do not run that. Two of its three names are not in this repository any more, the
installer will drop them silently, and it will report `Installed 2 skills ✓✓`.
Delete the retired copies and install the replacements instead:

```bash
ls ~/.agents/skills                       # what the old installs left behind
rm -rf ~/.agents/skills/trajectory-packs ~/.agents/skills/trajectory-funnel

npx skills add Samuka007/skills \
  --skill session-export-nocode --skill agent-session-batch-export -g -y
```

`~/.agents/skills` is one directory on every platform; Windows Git Bash
resolves it to `C:\Users\<you>\.agents\skills`. Those two paths sit beside the
skills that replaced them, never inside, so removing them removes only retired
copies. `trajectory-funnel` never carried a `SKILL.md`, which means the
installer could not select it and a copy is usually absent — it is named in the
removal command because the old instructions told people to install it, and a
copy somebody placed by hand would still be there.

If the base skill is the only one wanted, name it alone:

```bash
npx skills add Samuka007/skills --skill agent-session-batch-export -g -y
```

### What the next retirement owes

Three edits in one commit: remove the directory, name its replacement here, and
carry the same note in the replacement's `README.md`. The mechanical half is
checkable — no shipped file may print an install command naming a skill that
`skills/` cannot install:

```bash
bash test/shipped-install-refs.sh
```

The check reads every file under `skills/`, because that whole tree is what
reaches a partner's machine; it fails on a name with no `skills/<name>/SKILL.md`
behind it, and on a scan that found no install reference at all.
