# Session-export family — directory design

How the session-export skills are laid out, and why. This is the design record
for the *shape* of the family; the buy-side specification lives in
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

## The two layers

| Layer | Skill | Holds | Changes when |
|---|---|---|---|
| Base | `agent-session-batch-export` | The funnel: ordered stages, the two format adapters, the report shape. The six theme files: which stages are on and at what thresholds. Enumeration, the review gate, byte-identical copy, manifest, delivery archive | The way sessions are read or judged changes, or a threshold changes |
| Direction bundle | `session-export-<direction>` | One theme list, and the policy for when it may run unattended | We change what we are buying |

The split is still a rule about *where a change lands*: a new threshold is a
theme-file edit and touches no code; a new stage is a funnel edit and touches no
theme. When a change seems to need both, the mechanism is usually wrong — it has
hard-coded a policy. A new purchase direction adds one small skill and changes
no numbers.

### Why this was three layers, and is now two

The mechanism used to live in its own directory, `trajectory-funnel`, described
as "engine code in this repo, not an installable skill". That description was
the defect. Because it had no `SKILL.md` it was invisible to the installer —
measured: `npx skills add Samuka007/skills --skill trajectory-funnel` answers
`No matching skills found for: trajectory-funnel` — while the pack driver's
own missing-engine message told the user to install exactly that. The
instruction could not be followed by anyone, and a user who followed it saw
`Installed 2 skills ✓✓` with the engine silently dropped, then hit the same
error again.

Embedding the engine in the base skill removes the unfollowable instruction
rather than rewording it. The cost is that the base skill now requires
`python3`; that is the honest price of the deterministic selection being the
product, and it is stated in the skill's `compatibility` field.

## Directions and themes

A **theme** is one thing we buy, with its own thresholds and word lists:
role-play, translation, rewriting, generation, data analysis, multimodal. The
theme set is the reference bundle's own vocabulary. Each theme file is
self-contained: it carries every threshold it needs, so nothing has to be read
alongside it to know how it behaves.

A **direction** names a set of themes and nothing else. It carries no threshold,
which is what keeps a second copy of a number out of a direction bundle — the
runner refuses a direction file containing policy keys rather than trusting it.

```
session-export-nocode/direction.json     themes: [ … ], no numbers
└── read from the base skill's themes/
    ├── role-play.json        keywords, exclusions, thresholds, provenance
    ├── translation.json      …
    ├── rewriting.json        …
    ├── generation.json       …
    ├── data-analysis.json    …
    └── multimodal.json       (report-only: counted, never selected)
```

A session may satisfy several themes at once — the counts per theme sum to more
than the session count, exactly as the reference bundle's coverage table does.
Themes are not exclusive buckets.

### Two ways a partner runs it

| Flow | Command | Typical use |
|---|---|---|
| Direction, unattended | `/session-export-nocode … 直接导出` | The standing agreement: they export, we buy, nobody reviews a list |
| Direction, confirmed | `/session-export-nocode …` with no opt-out phrase | The same deterministic selection, with one batch-level yes/no |
| Base skill, interactive | `pick-sessions.sh` and the picker | A partner reviewing their own history row by row |

The first two produce the same artifact and the same selection; only
`batch_confirmed` in the manifest differs. The third is a different product: a
human choosing rows, which is why it keeps the `screen.tsv` step the direction
path does not have.

**Only an explicit phrase skips the confirmation.** `直接导出`, `无需确认`,
`不用确认`, `无须确认` — and nothing else. Brevity, silence, and `帮我导出` all
keep the prompt. The reason is asymmetry: a wrongly-withheld export costs one
re-run, and a wrongly-authorised one has already left the machine.

## Two levels of knowledge

A theme has a **number** and a **judgement**. The number is data (thresholds);
the judgement is prose (what makes a good role-play trajectory, what a thin one
looks like).

Those live in different homes on purpose:

- **Numbers** live in the theme JSON under
  `skills/agent-session-batch-export/themes/`. Exactly one copy. Every consumer
  reads that file, including the runner — which is why the runner contains no
  numeric literal that is a threshold.
- **Judgement** lives in prose — a direction skill's `SKILL.md`, or this file —
  with no numbers restated. It names the theme key instead of repeating a value.

Restating a threshold in prose is how two sources of truth begin. When a
document needs to say "at least five turns", it says "at least `min_user_turns`
as the theme sets it", and the reader opens the theme file.

## What ships to a partner

`npx skills add` copies one skill directory whole, so a skill that needs the
funnel must not assume it is present. The install command therefore names both:

```bash
npx skills add Samuka007/skills \
  --skill session-export-nocode --skill agent-session-batch-export -g -y
```

Both are named because the Agent Skills specification has no dependency field —
a skill cannot declare that installing it should install another. `Select All`
in the installer's picker does the same job. The direction skill checks for the
base skill and, when it is missing, stops with that command rather than failing
obscurely.

Rejected alternative: copying `funnel.py` and the theme files into each
direction bundle so one `--skill` suffices. It would put N copies of the
mechanism and the thresholds in the repository, and the second direction we add
would immediately start drifting from the first.

**Uninstalling is not symmetric, and this bit us.** The installer copies; it
never removes. A machine that installed the retired `trajectory-packs` still has
it after the directory left the repository, and its driver still prints an
install command naming skills that no longer exist. Fail-closed, but
unfollowable. Anything that replaces a published skill has to say so in the
release notes, because the old copy will still be sitting on partner machines.

## Where things live

```
skills/agent-session-batch-export/   # the base skill: mechanism + themes + pipeline
  SKILL.md
  themes/translation.json            # one file per theme; every threshold, self-contained
  themes/…                           # rewriting, generation, role-play, data-analysis, multimodal
  scripts/funnel.py                  # the ordered stages and the two format adapters
  scripts/export-direction.sh        # runs a direction: scan -> funnel -> finalize -> delivery
  scripts/curate-sessions.sh         # scan/review/finalize/validate/delivery
  scripts/pick-sessions.sh           # the interactive entry point
skills/session-export-nocode/        # one direction bundle
  SKILL.md
  direction.json                     # a theme list; no numbers
  scripts/session-export-nocode.sh   # phrase gate, then the base runner
docs/session-export/
  DESIGN.md                          # this file
  PACK-SPEC.md                       # what we buy and how it is checked
docs/agent-session-batch-export/
  FUNNEL.md                          # the engine's own notes
  INTERNALS.md                       # why the scripts are written the way they are
SPEC/README.md                       # items, status, acceptance evidence
```

One theme is one file. Adding a theme means adding a file, which is what keeps
the runner from growing a branch per theme; adding a purchase direction means
adding one small skill, which is what keeps the numbers in one place.
