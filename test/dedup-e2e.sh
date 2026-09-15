#!/usr/bin/env bash
# E2E regression for the L9 dedup layer and its `--no-dedup` switch (SPEC item 18).
#
# The defect this suite exists for: `--no-dedup` set the similarity threshold to
# `0.0` while the stage tests `jaccard >= thr`, and `>= 0.0` holds for every
# pair — including two empty signatures. The flag that promised to disable
# deduplication therefore collapsed every survivor into one. Measured on the
# fixtures below before the fix: 3 pairwise-distinct sessions in, 1 out.
#
# Two statements have to hold at once, and they are what the sections below
# separate:
#   * default (threshold supplied)  dedup RUNS: a twin pair collapses to one;
#   * --no-dedup                    dedup is OFF, and the table says so where
#                                   its kill count would sit — the flag must
#                                   disable the layer, not invert it.
# A third statement guards the fix itself: `--dedup-threshold 0.0` remains a
# REAL threshold (collapse everything), which is the reason the off state is
# `None` and not a zero — a fix that treated 0 as "off" would pass sections
# A-C and fail D.
#
# Fixtures are synthetic .jsonl files under $WORK. The user's real sessions are
# never read, never written, never needed.
#
# Usage: test/dedup-e2e.sh [work-dir]        (default /tmp/dedup-e2e)
# Dependencies: bash, awk, python3. NOT tmux, NOT fzf, NOT jq.
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
F="$REPO/skills/agent-session-batch-export/scripts/funnel.py"
WORK="${1:-/tmp/dedup-e2e}"

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
no()   { fail=$((fail + 1)); echo "  FAIL $1"; }
chk()  { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else no "$1: got '$2' want '$3'"; fi; }
has()  { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1: missing '$3'"; fi; }
hasnt(){ if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1: unexpected '$3'"; fi; }

command -v python3 >/dev/null || { echo "SKIP: python3 not available"; exit 0; }

echo "dedup e2e — work dir: $WORK"
echo "script: $(basename "$F")"

# ---------------------------------------------------------------- fixtures
# Four claude_code sessions, each passing every per-row stage of the `report`
# preset (5 user turns, no tool use, `end_turn` closure, topic keyword in the
# opening prose), so the funnel actually reaches L9. d1/d2/d3 differ in their
# first user message; `twin` repeats d1's verbatim, which is the pair dedup is
# for. The opening prose is deliberately the ONLY thing distinguishing them:
# dedup compares first user messages.
rm -rf "$WORK"; mkdir -p "$WORK/src"
python3 - "$WORK" <<'PY'
import json, os, sys
w = sys.argv[1]
S = os.path.join(w, "src")

def claude(name, first, later):
    lines = [json.dumps({"type": "user", "message": {"role": "user", "content": first}})]
    lines.append(json.dumps({"type": "assistant",
        "message": {"role": "assistant", "content": [{"type": "text", "text": "reply " * 40}]},
        "stop_reason": "end_turn"}))
    for u in later:
        lines.append(json.dumps({"type": "user", "message": {"role": "user", "content": u}}))
        lines.append(json.dumps({"type": "assistant",
            "message": {"role": "assistant", "content": [{"type": "text", "text": "reply " * 40}]},
            "stop_reason": "end_turn"}))
    p = os.path.join(S, name)
    open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    return p

LATER = [f"expand section {i} of that report please" for i in range(4)]
d1 = claude("d1.jsonl", "写一份关于安第斯梯田农业灌溉体系的报告", LATER)
d2 = claude("d2.jsonl", "写一份关于潮汐沼泽修复工程的报告", LATER)
d3 = claude("d3.jsonl", "写一份关于维京长船索具结构的报告", LATER)
twin = claude("twin.jsonl", "写一份关于安第斯梯田农业灌溉体系的报告", LATER)  # same opening as d1

hdr = "agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file"
def cands(name, files):
    with open(os.path.join(w, name), "w", encoding="utf-8") as fh:
        fh.write(hdr + "\n")
        for p in files:
            fh.write(f"claude\t/home/u/proj\t0\t{os.path.getsize(p)}\t9\tfirst\t{p}\n")

cands("candidates3.tsv", [d1, d2, d3])       # pairwise-distinct: nothing to collapse
cands("candidates4.tsv", [d1, d2, d3, twin])  # + one true duplicate of d1
PY

survivors() { awk -F'\t' 'NR>1' "$WORK/$1" | wc -l | tr -d ' '; }
# cell LABEL FIELD -> field 3 (out) / 4 (killed column) / 5 (killed) of the L9 row
cell() {
  awk -v fld="$1" -F'[ \t]+' '$1 == "L9" && $2 == "dedup" { print $fld }' "$WORK/$2"
}
row() { sed -n 's/^\(L9 dedup.*\)$/\1/p' "$WORK/$1"; }

# ------------------------------------------------- A: dedup runs by default
echo
echo "== A: default threshold -- a twin pair collapses =="
python3 "$F" run "$WORK/candidates4.tsv" "$WORK/out.on.tsv" --preset report \
  > "$WORK/run.on" 2>&1
chk "4 in, the duplicate collapsed"        "$(survivors out.on.tsv)" "3"
chk "L9 killed exactly the twin"           "$(cell 5 run.on)" "1"
chk "L9 ran (no OFF in its row)"           "$(cell 4 run.on)" "killed"
has "the kill names its near-duplicate"    "$(row run.on)" "near-duplicate of"

# ------------------------------- B: --no-dedup over distinct sessions keeps N
# The literal acceptance in SPEC item 18: N pairwise-distinct sessions in, N out.
echo
echo "== B: --no-dedup over 3 pairwise-distinct sessions =="
python3 "$F" run "$WORK/candidates3.tsv" "$WORK/out.off.tsv" --no-dedup --preset report \
  > "$WORK/run.off" 2>&1
chk "3 in, 3 out"                          "$(survivors out.off.tsv)" "3"
chk "L9 row reports the same survivors"    "$(cell 3 run.off)" "3"
chk "the kill column reads OFF"            "$(cell 4 run.off)" "OFF"
hasnt "and claims no kill"                 "$(row run.off)" "killed"
# The row must still be THERE: an auditor telling "the layer never ran" from
# "the layer ran and passed everything" has only the table to read, so a
# vanished row would make those two identical.
chk "the off row is still printed, not dropped" "$(grep -c '^L9 dedup' "$WORK/run.off")" "1"
has "the off reason names the key that turns it on" "$(row run.off)" "dedup_threshold"

# ------------------------- C: --no-dedup disables the layer, not just its kills
# The sharp case: with a true twin pair present, "disable dedup" and "invert
# dedup" give visibly different answers (4 survivors vs 1). Pre-fix this run
# kept exactly 1 of 4.
echo
echo "== C: --no-dedup with a twin pair present keeps both =="
python3 "$F" run "$WORK/candidates4.tsv" "$WORK/out.off4.tsv" --no-dedup --preset report \
  > "$WORK/run.off4" 2>&1
chk "4 in, 4 out"                          "$(survivors out.off4.tsv)" "4"
chk "both twins survive"                   "$(grep -c 'twin.jsonl' "$WORK/out.off4.tsv")" "1"
chk "L9 still prints OFF"                  "$(cell 4 run.off4)" "OFF"

# ------------------- D: 0.0 stays a real threshold, which is why off is None
# A fix that reads "threshold 0" as "no dedup" would satisfy A-C and be wrong:
# the value is a similarity floor the caller may legitimately set, and at 0 it
# means "collapse everything into one cluster" -- the behaviour the old flag
# produced by accident.
echo
echo "== D: --dedup-threshold 0.0 still collapses every survivor into one =="
python3 "$F" run "$WORK/candidates4.tsv" "$WORK/out.zero.tsv" --dedup-threshold 0.0 --preset report \
  > "$WORK/run.zero" 2>&1
chk "4 in, 1 out"                          "$(survivors out.zero.tsv)" "1"
chk "L9 ran and killed 3"                  "$(cell 5 run.zero)" "3"

# --------------------------------------------------------------- summary
printf '\n=====================\n'
if [[ $fail -eq 0 ]]; then echo "DEDUP E2E: ALL CHECKS PASSED ($pass)"; else echo "DEDUP E2E: FAILURES PRESENT ($fail)"; fi
printf '=====================\n'
exit $((fail > 0))
