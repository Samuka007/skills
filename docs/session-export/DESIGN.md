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
| Base | `agent-session-batch-export` | The funnel: ordered stages, the two format adapters, the report shape. The global policy (`scripts/policy.json`): the shared quality standard. The theme files: a word list, a label, and an optional override each. Enumeration, the review gate, byte-identical copy, manifest, delivery archive | The way sessions are read or judged changes, or the policy or a theme override changes |
| Direction bundle | `session-export-<direction>` | A theme list, the overrides that define the purchase, and the invocation policy for when it may run unattended | We change what we are buying |

The split is still a rule about *where a change lands*: a new threshold is a
policy or theme-override edit and touches no code; a new stage is a funnel edit
and touches no policy file. When a change seems to need both, the mechanism is
usually wrong — it has hard-coded a policy. A new purchase direction adds one
small skill and changes no numbers.

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

The nocode direction buys four themes: role-play, 写作 (`writing`), 策划
(`planning`), and 报告分析 (`report-analysis`). `writing` is the merged
writing spectrum (the former generation and rewriting word lists); `planning`
is new; `report-analysis` refocuses the former data-analysis word list toward
reports. Theme ids stay ASCII; the zh labels carry the purchase names. The
base skill additionally ships ad-hoc topics outside this direction —
`translation`, `rewriting`, `multimodal` — plus `coding`, which reads the
coding-signal word list as a positive topic. A theme file carries what makes
the topic identifiable — its word list, its label, its provenance — and, where
the theme must deviate from the shared standard, an `override` naming the
policy keys it moves and why.

A **direction** names a set of themes and, where the purchase constrains
something, an `override` of its own — the noncode direction's `exclude_keywords`
word list is what defines "non-code". Override keys are deltas against the
policy, and the runner refuses a direction file carrying policy keys at the
top level rather than trusting it. One deliberate number has entered the
layer since (decision of 2026-09-21): the nocode direction's packaging bar
`min_user_turns` — the purchase's own quality bar, aligned with the reference
bundle's turn profile, because a floor of 0 would deliver one-shot stubs the
customer's demo never contained.

```
session-export-nocode/direction.json     four themes + root override (exclusion list + the packaging turn bar)
├── reads the base skill's scripts/policy.json   the shared quality standard
└── and the base skill's themes/
    ├── role-play.json        in the direction
    ├── writing.json          in the direction (写作)
    ├── planning.json         in the direction (策划)
    ├── report-analysis.json  in the direction (报告分析)
    ├── translation.json      shipped, ad-hoc only
    ├── rewriting.json        shipped, ad-hoc only
    ├── multimodal.json       shipped, ad-hoc only (no keywords: L6 OFF)
    └── coding.json           shipped, ad-hoc only (coding signals as a positive topic)
```

A session may satisfy several themes at once — the counts per theme sum to more
than the session count, exactly as the reference bundle's coverage table does.
Themes are not exclusive buckets.

### Two ways a partner runs it

| Flow | Command | Typical use |
|---|---|---|
| Direction, unattended (default) | `/session-export-nocode …` | The standing agreement: they export, we buy, nobody reviews a list |
| Direction, confirmed | `/session-export-nocode … --confirm` | The same deterministic selection, with one batch-level yes/no |
| Base skill, interactive | `pick-sessions.sh` and the picker | A partner reviewing their own history row by row |

The first two produce the same artifact and the same selection; only
`batch_confirmed` in the manifest differs. The third is a different product: a
human choosing rows, which is why it keeps the `screen.tsv` step the direction
path does not have.

**The direction path is unattended by default** (item 31): the selection is
deterministic — policy and theme word lists decide, no model judges — the
skill uploads nothing, and credential-bearing rows are excluded and disclosed
rather than shipped. A caller who wants a checkpoint passes `--confirm`; the
launcher never withholds the export for the lack of a magic phrase. The old
phrase gate was a weak control anyway — the agent composes the request
string, so it could always write the phrase itself — while a wrongly-skipped
confirmation cost a support round-trip.

## Two levels of knowledge

A policy key has a **number** and a **judgement**. The number is data (the
threshold); the judgement is prose (what makes a good role-play trajectory,
what a thin one looks like, why this theme moves this key).

Those live in different homes on purpose:

- **Numbers** live in the base skill's `scripts/policy.json`. Exactly one copy.
  Every consumer reads that file, including the runner — which is why the
  runner contains no numeric literal that is a threshold. A theme or direction
  `override` names a key and its replacement; it does not restate the policy.
- **Judgement** lives in prose — a direction skill's `SKILL.md`, or this file —
  with no numbers restated. It names the theme key instead of repeating a value.

Restating a threshold in prose is how two sources of truth begin. When a
document needs to say "at least five turns", it says "at least `min_user_turns`
as the policy sets it", and the reader opens the policy file.

## Collection and labeling: the two-stage split

This family is the upstream half of a longer pipeline, and the two halves make
opposite promises.

**Upstream (this family) is the collector.** Zero model tokens, fully
deterministic, recall first. The only kills are unambiguous junk — structurally
dead rows and exact duplicates; every other signal is an annotation column,
never a silent drop. It does not own precision. It owns making precision
cheap: every candidate row ships with a **row card**, a self-contained preview
(the first prompt, turn and tool counts, health and verification flags,
matched themes) that a buyer's own model can judge in a few hundred tokens.
Per-row purchasing means the buyer pays per row, so the collector's job is to
move the precision judgment onto the cheapest possible surface — the row card
— and to lose nothing that a row card could still sell.

**Downstream (the labeler) is the precision layer.** Raw JSONL becomes ATIF
labeling-view rows (structure facts are computed at conversion, and every
truncation or fold is recorded as a trajectory-health blocker, never applied
silently); one labeler call runs per row with the rubric injected; a code
validator enforces the consistency rules before a label is accepted; labels
are materialized with the model, prompt hash and token count. Labels are
written once and read many — the LLM never sits on the selection's critical
path. Pool derivation is a separate, versioned policy, exactly as the policy
file is separate from the funnel here. **The labeler lives outside this
repository**: this family's contract ends at the row card and the byte-
identical raw JSONL — everything the ATIF conversion consumes is already in
the shipped files, and the conversion itself is the downstream project's
ingestion adapter (the funnel's format adapters are its reference
implementation).

The external Flywheel row-label standard (v1.2.4) states the same layering
from the other side — controlled label vocabularies are explicitly "not a
filtering policy", and pools are derived downstream — which is why the
vocabulary can be adopted as our annotation columns without adopting its
per-row LLM call.

Collection versus delivery is a policy choice, not a mechanism change: the
same stages annotate loosely for collection and kill tightly for delivery,
and the cut lives in the policy and direction layers.

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

Rejected alternative: copying `funnel.py`, the policy, and the theme files into
each direction bundle so one `--skill` suffices. It would put N copies of the
mechanism and the numbers in the repository, and the second direction we add
would immediately start drifting from the first.

**Uninstalling is not symmetric, and this bit us.** The installer copies; it
never removes. A machine that installed the retired `trajectory-packs` still has
it after the directory left the repository, and its driver still prints an
install command naming skills that no longer exist. Fail-closed, but
unfollowable. Anything that replaces a published skill has to say so in the
release notes, because the old copy will still be sitting on partner machines.

## Where things live

```
skills/agent-session-batch-export/   # the base skill: mechanism + policy + themes + pipeline
  SKILL.md
  scripts/policy.json                # the shared quality standard; the only required configuration
  themes/translation.json            # one file per theme: word list, label, optional override
  themes/…                           # rewriting, generation, role-play, data-analysis, multimodal, coding
  scripts/funnel.py                  # the ordered stages and the two format adapters
  scripts/export-direction.sh        # runs a direction: scan -> funnel -> finalize -> delivery
  scripts/curate-sessions.sh         # scan/review/finalize/validate/delivery
  scripts/pick-sessions.sh           # the interactive entry point
skills/session-export-nocode/        # one direction bundle
  SKILL.md
  direction.json                     # theme names + purchase overrides; no numbers
  scripts/session-export-nocode.sh   # unattended by default; --confirm restores the checkpoint
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
