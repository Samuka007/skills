#!/usr/bin/env bash
# Non-interactive acceptance test for the curate-sessions skill.
# Usage: test/accept.sh <skill-dir> <work-dir>
# Portable: Linux, macOS, Windows Git Bash.
set -uo pipefail
SKILL="$1"; WORK="$2"
C="$SKILL/scripts/curate-sessions.sh"

fail=0
step() { printf '\n--- %s ---\n' "$1"; }
chk()  { if [[ "$2" == "$3" ]]; then echo "  OK   $1 ($2)"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }
pos()  { if [[ "$2" -gt 0 ]]; then echo "  OK   $1 ($2)"; else echo "  FAIL $1: expected >0, got $2"; fail=1; fi; }

echo "jq:   $(jq --version)"
echo "rg:   $(rg --version | sed -n 1p)"
echo "bash: $BASH_VERSION ${MSYSTEM:-}"
rm -rf "$WORK"; mkdir -p "$WORK"

step "scan"
out="$(bash "$C" scan -o "$WORK" 2>&1)"; echo "$out" | sed -n 1p
total="${out##*candidates: }"; total="${total%% *}"
pos "candidates" "${total:-0}"

step "filters"
ml="$(bash "$C" scan -o "$WORK/ml" --min-lines 20 2>&1 | sed -n 's/^candidates: \([0-9]*\).*/\1/p')"
pos "min-lines" "${ml:-0}"
tp="$(bash "$C" scan -o "$WORK/tp" --topic 'zzz-no-such-topic-xyz' 2>&1 | sed -n 's/^candidates: \([0-9]*\).*/\1/p')"
chk "absent topic -> 0" "${tp:-x}" "0"

step "review --ui tsv"
bash "$C" review --ui tsv -o "$WORK" >/dev/null 2>&1
chk "rows" "$(awk -F'\t' 'NR>1' "$WORK/decisions.tsv" | wc -l | tr -d ' ')" "${total:-0}"
chk "cols" "$(awk -F'\t' 'NR==1{print NF}' "$WORK/decisions.tsv")" "10"

step "validate"
bash "$C" validate -o "$WORK" --from "$WORK/decisions.tsv" 2>&1 | sed -n '1,3p'

step "mark 3 keep"
awk -F'\t' 'BEGIN{OFS="\t"} NR>1 { if (++c<=3) {$1="keep"; $2="acceptance"} else {$1="drop"} } {print}' \
  "$WORK/decisions.tsv" > "$WORK/d2" && mv "$WORK/d2" "$WORK/decisions.tsv"

step "finalize"
bash "$C" finalize -o "$WORK" 2>&1 | sed -n 1p
chk "manifest entries" "$(jq 'length' "$WORK/manifest.json")" "3"

step "byte identity"
jq -r '.[] | "\(.source)\t\(.kept_as)"' "$WORK/manifest.json" > "$WORK/pairs.tsv"
bad=0
while IFS=$'\t' read -r s d; do d="${d%$'\r'}"; cmp -s "$s" "$d" || { bad=$((bad+1)); echo "  MISMATCH $s"; }; done < "$WORK/pairs.tsv"
chk "mismatches" "$bad" "0"

step "absolute paths"
abs=1; while IFS= read -r p; do p="${p%$'\r'}"; case "$p" in /*) ;; *) abs=0;; esac; done < <(jq -r '.[].kept_as' "$WORK/manifest.json")
chk "kept_as absolute" "$abs" "1"

step "sha256"
bad=0
if command -v sha256sum >/dev/null; then SH="sha256sum"; else SH="shasum -a 256"; fi
while IFS=$'\t' read -r want path; do path="${path%$'\r'}"
  [[ "$want" == "$("$SH" "$path" | cut -d' ' -f1)" ]] || { bad=$((bad+1)); echo "  SHA MISMATCH $path"; }
done < <(jq -r '.[] | "\(.sha256)\t\(.kept_as)"' "$WORK/manifest.json")
chk "sha mismatches" "$bad" "0"

printf '\n=====================================\n'
if [[ $fail -eq 0 ]]; then echo "RESULT: ALL CHECKS PASSED"; else echo "RESULT: FAILURES PRESENT"; fi
echo "====================================="
exit $fail
