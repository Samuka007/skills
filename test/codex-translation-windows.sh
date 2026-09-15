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
# The pack's shipped translation thresholds (min_user_msg_chars 5, from
# packs/themes/translation.json) are what make the one-shot request survive; at
# the direction default of 20 it is killed by the length layer.
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

KEYWORDS="翻译,互译,译成,翻译成,中译,英译,日译,translate,translation,localize"

# Case A — what the pack ships. The one-shot request does not qualify: the
# translation theme holds min_user_turns at the pack default of 5, because the
# reference bundle buys translation as multi-turn work (its two entries have 7
# and 8 user turns). A run under the shipped thresholds selects nothing here.
echo
echo "== A. pack thresholds as shipped (min_user_turns 5) =="
python3 "$F" run "$W/candidates.tsv" "$W/out-pack.tsv" \
  --preset report --min-turns 5 --min-user-msg-chars 5 \
  --max-tool-ratio 100 --no-end-turn --no-dedup --max-first-msg-chars 1000000 \
  --topic-keywords "$KEYWORDS" > "$W/funnel-pack.txt" 2>&1
sed -n '/^L0/,$p' "$W/funnel-pack.txt"

# Case B — the override. The mechanism and the policy are separate: a theme
# that buys multi-turn work today can be bought as one-shot work for one run,
# without editing the pack or the code.
echo
echo "== B. overridden for one run (min-user-msg-chars 5, min-turns 1) =="
python3 "$F" run "$W/candidates.tsv" "$W/out.tsv" \
  --preset report --min-turns 1 --min-user-msg-chars 5 \
  --max-tool-ratio 100 --no-end-turn --no-dedup --max-first-msg-chars 1000000 \
  --topic-keywords "$KEYWORDS" > "$W/funnel.txt" 2>&1
sed -n '/^L0/,$p' "$W/funnel.txt"

echo
echo "== survivors =="
python3 - "$W/out-pack.tsv" "$W/out.tsv" <<'PY'
import csv, json, sys, os
def rows(p):
    return list(csv.DictReader(open(p, encoding="utf-8"), delimiter="\t"))
print(f"  A (pack thresholds): {len(rows(sys.argv[1]))} survivor(s)")
b = rows(sys.argv[2])
print(f"  B (overridden):      {len(b)} survivor(s)")
for r in b:
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
