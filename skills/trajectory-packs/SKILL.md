---
name: trajectory-packs
description: Export trajectory sessions against a buy-side pack — a named set of themes (role-play, translation, rewriting, generation, data analysis, multimodal) with fixed thresholds — for a partner handing data to another organisation. Use when someone asks to export sessions "for the pack", "for the buyer", by theme, or when a standing direction pack should run unattended. Not for reviewing your own history for personal use — that is agent-session-batch-export.
---

# Export sessions against a pack

A pack is a named thing we buy. You run it on your own machine, it selects
sessions from your own history, you look at what it picked (or explicitly skip
looking), and it hands you one archive to send back.

## What you need

Three skills, installed in one command:

```bash
npx skills add Samuka007/skills \
  --skill trajectory-packs --skill trajectory-funnel \
  --skill agent-session-batch-export -g -y
```

`trajectory-packs` holds the packs and the driver; `trajectory-funnel` is the
screening mechanism; `agent-session-batch-export` is the pipeline that
enumerates sessions and copies them verbatim. If the engine is missing, the
driver stops and prints that command rather than failing obscurely.

## Two ways to run it

**A direction pack, unattended.** The standing agreement: you have the pack, you
run it, you send what it produces.

```bash
bash scripts/pack-export.sh --direction noncoding-multimodal --yolo
```

**Themes you pick, reviewed.** You want to see and approve what leaves your
machine:

```bash
bash scripts/pack-export.sh --theme role-play --theme translation
```

Both produce the same artifact and the same manifest. The difference is which
pack was expanded and whether you confirmed the selection.

## What it will tell you before it exports

The count of qualifying sessions, per theme. If a theme has nothing, it says so
and exports anyway — a zero is a true answer, not a failure. There is no minimum
you have to reach.

## What is never done for you

- **Nothing is rewritten.** Every session in the archive is a byte-identical
  copy of the file on your disk. That is what makes the batch checkable at the
  other end, and it is why there is no redaction option.
- **Credentials stop the run.** Sessions whose text matches a credential pattern
  are not exported. Unattended, the run reports how many it found and stops;
  exporting them requires `--allow-credentials`, and the manifest records that
  you passed it. This exists because the sessions are your machine's history and
  may contain your own keys.
- **The selection is not final until you confirm it** — unless you passed
  `--yolo`, which says you opted out. The manifest records which happened.

## Where the numbers come from

Thresholds are not described here. Each theme's gate, its keyword list, and the
reasoning behind every value live in
`packs/themes/<theme>.json` and are written up in the repository under
`docs/trajectory-packs/PACK-SPEC.md`. Read the pack file for the numbers; it is
the only copy.

## When a theme looks wrong

If a theme selects nothing from a history that clearly contains that kind of
work, the pack's keyword list or its threshold is the likely cause, and that is
worth reporting back rather than working around — the pack is ours to fix, and a
silent local workaround makes the next batch incomparable.
