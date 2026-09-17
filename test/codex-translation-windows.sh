#!/usr/bin/env bash
# Acceptance run against the Windows-side codex store, for the translation
# theme: 25 sessions in, exactly one out — the one-shot 桃花源记 translation.
#
# Why the engine runs from WSL: this machine's Windows Git Bash has no real
# python3 (only the Microsoft Store alias stub), so the funnel cannot execute
# there. The DATA is the Windows store, which is what the run is about; the
# enumeration below reproduces what `curate-sessions.sh scan` would emit, since
# scan hardcodes $HOME and would read the WSL store instead.
#
# The shipped translation calibration (min_user_msg_chars 5, from
# skills/agent-session-batch-export/themes/translation.json's `override`) is
# what makes the one-shot request survive; at the policy default of 20 the
# length layer kills it.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
F="$REPO/skills/agent-session-batch-export/scripts/funnel.py"
WIN="${WIN_CODEX_STORE:-/mnt/c/Users/Samuka007/.codex/sessions}"
W="${1:-/tmp/acc-codex-win}"
rm -rf "$W"; mkdir -p "$W"

[[ -d "$WIN" ]] || { echo "SKIP: no Windows codex store at $WIN"; exit 0; }

python3 - "$WIN" "$W/candidates.tsv" <<'PY'
import json, pathlib, sys
root, out = pathlib.Path(sys.argv[1]), sys.argv[2]
rows = []
for p in sorted(root.rglob("*.jsonl")):
    first, n = "", 0
    for line in p.open(encoding="utf-8", errors="replace"):
        n += 1
        if first:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        if r.get("type") != "response_item":
            continue
        pl = r.get("payload") or {}
        if pl.get("type") == "message" and pl.get("role") == "user":
            t = "".join(c.get("text", "") for c in (pl.get("content") or []) if isinstance(c, dict))
            if t.strip() and not t.lstrip().startswith("<"):
                first = t.replace("\t", " ").replace("\n", " ")[:120]
    rows.append((p, n, first))
with open(out, "w", encoding="utf-8") as fh:
    fh.write("agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file\n")
    for p, n, first in rows:
        fh.write(f"codex\tC:/Users/Samuka007\t{int(p.stat().st_mtime)}\t{p.stat().st_size}\t{n}\t{first}\t{p}\n")
print(f"enumerated {len(rows)} codex sessions from {root}")
PY

# The coding-signal exclusion list lives at the direction layer now (SPEC item
# 25): a `--theme` run alone carries no word list, so this script reads the
# shipped direction's override and passes it exactly the way
# export-direction.sh does — by file content, never hand-copied literals.
DIRECTION="$REPO/skills/session-export-nocode/direction.json"
EXCL="$(python3 - "$DIRECTION" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(",".join(d.get("override", {}).get("exclude_keywords", [])))
PY
)"
[[ -n "$EXCL" ]] || { echo "FATAL: direction carries no exclude_keywords: $DIRECTION"; exit 1; }

# Case A — the shipped theme, read by the engine itself (`--theme`), with the
# direction's exclusion list alongside and no flag overriding any threshold.
# This is the arm that means something: it asserts what a partner's machine
# actually does (the same composition export-direction.sh performs).
#
# An earlier version of this test hand-copied the thresholds onto the command
# line instead. That made the arm evidence about a set of literals rather than
# about the shipped bundle, and it showed: the funnel printed
# `L7 noncode OFF (this pack sets no exclude_keywords)` because a flag run
# carries no word lists. Asking the shipped files is the only way to test them.
#
# `--no-dedup` is deliberately NOT passed: this arm asserts what a partner's
# machine does, and the shipped theme supplies a dedup threshold, so L9 is part
# of that answer. The flag itself no longer inverts its meaning (SPEC item 18,
# fixed: it clears the threshold, so the layer prints OFF and kills nothing).
echo
echo "== A. the shipped translation theme, as a partner runs it =="
python3 "$F" run "$W/candidates.tsv" "$W/out.tsv" \
  --theme translation --exclude-keywords "$EXCL" > "$W/funnel.txt" 2>&1
sed -n '/^L0/,$p' "$W/funnel.txt"

# Case B — the same theme with one value overridden, which is the layering
# claim: a flag still wins over every data layer, so a theme can be bought
# under different terms for one run without editing any shipped file. The
# reference bundle's own translation entries have 7 and 8 user turns, so a
# floor of 5 reproduces its口径 — and rejects the one-shot request this store
# holds.
echo
echo "== B. same theme, min_user_turns overridden to the reference's 5 =="
python3 "$F" run "$W/candidates.tsv" "$W/out-strict.tsv" \
  --theme translation --exclude-keywords "$EXCL" --min-turns 5 > "$W/funnel-strict.txt" 2>&1
sed -n '/^L0/,$p' "$W/funnel-strict.txt"

echo
echo "== survivors =="
python3 - "$W/out.tsv" "$W/out-strict.tsv" <<'PY'
import csv, json, sys, os
def rows(p):
    return list(csv.DictReader(open(p, encoding="utf-8"), delimiter="\t"))
a = rows(sys.argv[1])
print(f"  A (shipped theme):        {len(a)} survivor(s)")
print(f"  B (min_user_turns -> 5):  {len(rows(sys.argv[2]))} survivor(s)")
for r in a:
    for line in open(r["session_file"], encoding="utf-8", errors="replace"):
        try:
            o = json.loads(line)
        except Exception:
            continue
        pl = o.get("payload") or {}
        if pl.get("type") == "message" and pl.get("role") == "user":
            t = "".join(c.get("text", "") for c in (pl.get("content") or []) if isinstance(c, dict))
            if t.strip() and not t.lstrip().startswith("<"):
                print(f"    -> {os.path.basename(r['session_file'])}  first user message {t.strip()!r}")
                break
PY
