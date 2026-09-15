# Trajectory pack family — directory design

How the trajectory-export skills are laid out, and why. This is the design
record for the *shape* of the family; the buy-side specification lives in
`PACK-SPEC.md` beside it.

## Who this is for

We buy trajectory data. A partner organisation runs one of these skills on their
own machine and hands back a file; we pay for it and analyse it together with
everything else we collect. Two consequences drive the whole layout:

- The partner runs the skill on **their** machine, so a skill must be
  installable, runnable, and explainable without us present.
- What they export must be **re-checkable by us**. We do not take their word for
  which sessions qualified; we re-run the same pack over the same files and
  compare.

## The three layers

| Layer | Skill | Holds | Changes when |
|---|---|---|---|
| Mechanism | `trajectory-funnel` | The ordered stages, the two session-format adapters, the report shape | The way sessions are read or judged changes |
| Interface + pipeline | `agent-session-batch-export` | Enumeration, the review gate, byte-identical copy, manifest, delivery archive | The user-facing flow changes |
| Packs | `trajectory-packs` (+ one skill per theme) | The numbers: which stages are on, at what thresholds, and which themes are being bought | We change what we are buying |

The split is a rule about *where a change lands*, not a stylistic preference. A
new threshold is a pack edit and touches no code; a new stage is a mechanism
edit and touches no pack. When a change seems to need both, the mechanism is
usually wrong — it has hard-coded a policy.

## Direction packs and theme packs

A **theme pack** is one thing we buy, with its own thresholds and keyword list:
role-play, translation, rewriting, generation, data analysis, multimodal. A
**direction pack** groups several theme packs and carries the defaults they
share. The theme set is the reference bundle's own vocabulary.

Both are files. What differs is what a partner names on the command line, and
that difference is the whole reason the two levels exist: one partner picks
themes one at a time and reviews each selection; another takes the direction as
a standing order and lets it run to completion.

```
direction pack  noncoding-multimodal.json
├── theme  role-play.json        keywords, min turns, tool-ratio ceiling, …
├── theme  translation.json      …
├── theme  rewriting.json        …
├── theme  generation.json       …
├── theme  data-analysis.json    …
└── theme  multimodal.json       (report-only: counted, never a pass/fail)
```

A session may satisfy several themes at once — the counts per theme sum to more
than the session count, exactly as the reference bundle's coverage table does.
Themes are not exclusive buckets.

### Two ways a partner runs it

| Flow | Command | Typical use |
|---|---|---|
| Direction pack, unattended | `--direction noncoding-multimodal --yolo` | The standing agreement: they export, we buy, nobody reviews a list |
| Theme selection, interactive | `--theme role-play --theme translation` then the picker | A partner who wants to see and approve what leaves their machine |

Both produce the same artifact and the same manifest. The difference is which
pack was expanded and whether a human confirmed the selection.

## Two levels of knowledge

A theme has a **number** and a **judgement**. The number is data (thresholds);
the judgement is prose (what makes a good role-play trajectory, what a thin one
looks like).

Those live in different homes on purpose:

- **Numbers** live in the pack JSON under `skills/trajectory-packs/packs/`.
  Exactly one copy. Every consumer reads that file.
- **Judgement** lives in a theme skill's `SKILL.md` — prose for the agent, with
  no numbers restated. It points at the pack for the thresholds instead of
  repeating them.

Restating a threshold in prose is how two sources of truth begin. If a theme
skill needs to say "at least five turns", it says "at least `min_user_turns` as
the pack sets it", and the reader opens the pack.

## What ships to a partner

`npx skills add` copies one skill directory whole, so a skill that needs the
funnel must not assume it is present. The install command therefore names both:

```bash
npx skills add Samuka007/skills \
  --skill trajectory-packs --skill trajectory-funnel \
  --skill agent-session-batch-export -g -y
```

The driver checks for the engine and, when it is missing, stops with that
command rather than failing obscurely. Rejected alternative: copying `funnel.py`
into the pack skill's `scripts/`. It would work in one command, and it would put
two copies of the mechanism in the repository, which is the one thing this
layout exists to prevent.

## Where things live

```
skills/trajectory-packs/           # the direction skill: packs + the driver
  SKILL.md
  packs/directions/noncoding-multimodal.json
  packs/themes/role-play.json      # one file per theme (the numbers)
  packs/themes/translation.json
  packs/themes/…                   # generation, rewriting, data-analysis, multimodal
  scripts/pack-export.sh           # expands a pack, drives funnel + finalize
skills/trajectory-theme-<name>/    # one skill per theme: prose only
  SKILL.md
skills/trajectory-funnel/          # the mechanism
skills/agent-session-batch-export/ # interface + pipeline
docs/trajectory-packs/
  DESIGN.md                        # this file
  PACK-SPEC.md                     # what we buy and how it is checked
SPEC/README.md                     # items, status, acceptance evidence
```

A theme skill with no `scripts/` is deliberate: it is knowledge, and knowledge
does not need code to be usable.

One theme is one file, not one directory inside the driver. A partner selecting
three themes names three things; the driver reads three files. Adding a theme
means adding a file, which is what keeps the driver from growing a branch per
theme.
