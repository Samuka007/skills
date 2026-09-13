#!/usr/bin/env bash
# finalize must describe the CURRENT decisions exactly: a second run with fewer
# keeps must not leave the first run's files behind.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
C="$REPO/skills/agent-session-batch-export/scripts/curate-sessions.sh"
W=/tmp/vc; rm -rf "$W"; mkdir -p "$W"
bash "$C" scan -o "$W" --agent codex >/dev/null 2>&1
bash "$C" review --ui tsv -o "$W" >/dev/null 2>&1

# run 1: keep everything
awk -F'\t' 'BEGIN{OFS="\t"} NR>1{$1="keep"} {print}' "$W/decisions.tsv" > "$W/d1" && mv "$W/d1" "$W/decisions.tsv"
bash "$C" finalize -o "$W" >/dev/null 2>&1
r1_files=$(find "$W/keep" -maxdepth 1 -type f | wc -l | tr -d ' ')
r1_man=$(jq 'length' "$W/manifest.json")
echo "run 1: keep/=$r1_files manifest=$r1_man"

# run 2: keep only the first two
awk -F'\t' 'BEGIN{OFS="\t"} NR>1{ $1 = (++c<=2) ? "keep" : "drop" } {print}' "$W/decisions.tsv" > "$W/d2" && mv "$W/d2" "$W/decisions.tsv"
bash "$C" finalize -o "$W" > "$W/run2.log" 2>&1
r2_files=$(find "$W/keep" -maxdepth 1 -type f | wc -l | tr -d ' ')
r2_man=$(jq 'length' "$W/manifest.json")
echo "run 2: keep/=$r2_files manifest=$r2_man"
echo "  log: $(grep -i clearing "$W/run2.log" || echo '(no clearing message)')"

if [[ "$r2_files" == "$r2_man" && "$r2_man" == "2" ]]; then
  echo "OK  corpus matches the manifest exactly ($r2_files files)"
else
  echo "FAIL corpus ($r2_files) != manifest ($r2_man)"
fi
