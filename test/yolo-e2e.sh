#!/usr/bin/env bash
# E2E regression for yolo mode (issue #2): an explicit opt-out of review must
# run end to end with no human in the loop — no picker, no terminal spawn, no
# TTY — and must leave a provenance record that says so. The gated path must
# come out of the same scripts unchanged.
#
# Fixtures are synthetic: fabricated candidates.tsv rows pointing at tiny
# .jsonl files created under $WORK. The user's real sessions are never read,
# never written, never needed.
#
# Usage: test/yolo-e2e.sh [work-dir]      (default /tmp/yolo-e2e)
# Dependencies: bash, jq, awk, cmp. NOT tmux, NOT python3, NOT fzf — a yolo run
# reaching one of those is a failure, so their absence is part of what the test
# asserts instead of a precondition it skips on.
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
C="$REPO/skills/agent-session-batch-export/scripts/curate-sessions.sh"
PICK="$REPO/skills/agent-session-batch-export/scripts/pick-sessions.sh"
WORK="${1:-/tmp/yolo-e2e}"

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
no()   { fail=$((fail + 1)); echo "  FAIL $1"; }
chk()  { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else no "$1: got '$2' want '$3'"; fi; }
has()  { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1: missing '$3'"; fi; }
hasnt(){ if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1: unexpected '$3'"; fi; }

# ---------------------------------------------------------------- fixtures
# mkfix DIR MODE — five fabricated candidates under DIR/src plus a screen.tsv:
#   "keeps N"  the first N rows say suggested=keep, the rest say drop
#   "scaffold" what a fresh scan writes: the suggested/reason columns exist,
#              every row has them empty (nothing was screened yet)
#   "none"     no screen.tsv at all
mkfix() { # $1 = dir, $2 = mode
  local dir="$1" mode="$2" i sug cwd
  rm -rf "$dir"; mkdir -p "$dir/src"
  printf 'agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file\n' > "$dir/candidates.tsv"
  for i in 1 2 3 4 5; do
    cwd="/home/demo/ws-$i"
    printf '{"type":"user","message":{"role":"user","content":"synthetic session %s"}}\n' "$i" > "$dir/src/s$i.jsonl"
    printf 'claude_code\t%s\t2026-01-0%sT00:00:00Z\t%s\t1\tsynthetic session %s\t%s/src/s%s.jsonl\n' \
      "$cwd" "$i" "$(wc -c < "$dir/src/s$i.jsonl" | tr -d ' ')" "$i" "$dir" "$i" >> "$dir/candidates.tsv"
  done
  [[ "$mode" == "none" ]] && return 0
  printf 'agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file\tsuggested\treason\n' > "$dir/screen.tsv"
  for i in 1 2 3 4 5; do
    case "$mode" in
      scaffold) sug="" ;;
      "keeps "*) if [[ "$i" -le "${mode#keeps }" ]]; then sug="keep"; else sug="drop"; fi ;;
      *) sug="" ;;
    esac
    printf 'claude_code\t/home/demo/ws-%s\t2026-01-0%sT00:00:00Z\t%s\t1\tsynthetic session %s\t%s/src/s%s.jsonl\t%s\t%s\n' \
      "$i" "$i" "$(wc -c < "$dir/src/s$i.jsonl" | tr -d ' ')" "$i" "$dir" "$i" \
      "$sug" "${sug:+screen says $sug}" >> "$dir/screen.tsv"
  done
}

# mkdecisions DIR N — the engine's decisions.tsv (10 columns, decision first)
# marking the first N candidates keep. This is the gated path's input.
mkdecisions() { # $1 = dir, $2 = keep count
  awk -F'\t' -v n="$2" 'BEGIN{OFS="\t"; c=0}
    NR==1 { print "decision","reason","suggested","agent","cwd","mtime","size_bytes","n_lines","first_prompt","session_file"; next }
    { c++
      print (c <= n ? "keep" : "drop"), "gated run", "", $1, $2, $3, $4, $5, $6, $7 }
  ' "$1/candidates.tsv" > "$1/decisions.tsv"
}

# ------------------------------------------------------------- assertions
nkeep() { # $1 = out dir -> files actually materialized in keep/
  [[ -d "$1/keep" ]] || { echo 0; return; }
  find "$1/keep" -maxdepth 1 -type f | wc -l | tr -d ' '
}
sources() { # $1 = out dir -> space-separated source basenames in manifest order
  jq -r '.[].source | sub(".*/";"")' "$1/manifest.json" 2>/dev/null | sort | tr '\n' ' '
}
stamp_bad() { # $1 = out dir -> entries NOT carrying the full yolo stamp
  jq '[.[] | select(.mode != "yolo" or .reviewed != false or .approved_by != "user-opt-out")] | length' \
    "$1/manifest.json" 2>/dev/null
}
keyset_bad() { # $1 = out dir -> entries carrying any provenance key
  jq '[.[] | select(has("mode") or has("reviewed") or has("approved_by"))] | length' \
    "$1/manifest.json" 2>/dev/null
}
cmp_bad() { # $1 = out dir -> copies that are not byte-identical to their source
  local bad=0 s d
  # Pairs go through a file, not a process substitution: the latter can block
  # forever in a backgrounded caller.
  jq -r '.[] | "\(.source)\t\(.kept_as)"' "$1/manifest.json" > "$1/.pairs.tsv" 2>/dev/null || return 1
  while IFS=$'\t' read -r s d; do
    s="${s%$'\r'}"; d="${d%$'\r'}"
    cmp -s "$s" "$d" || bad=$((bad + 1))
  done < "$1/.pairs.tsv"
  echo "$bad"
}

# The picker and the terminal spawn are the two things yolo must never reach.
# Shims that shout when executed turn "we did not call fzf" from a claim about
# the source into an observation about the run.
mkdir -p "$WORK/bin"
for tool in fzf tmux; do
  printf '#!/usr/bin/env bash\necho "PICKER-REACHED: %s" >&2\nexit 1\n' "$tool" > "$WORK/bin/$tool"
  chmod +x "$WORK/bin/$tool"
done
PATH="$WORK/bin:$PATH"; export PATH

echo "yolo e2e — work dir: $WORK"
echo "scripts: $(basename "$C"), $(basename "$PICK")"

# ------------------------------------------------- A: screened, 2 of 5 keep
echo
echo "== A: screen.tsv with 2 of 5 suggested=keep =="
A="$WORK/a"; mkfix "$A" "keeps 2"
aout="$(bash "$PICK" -o "$A" -y --review-only --yolo < /dev/null 2>&1)"; arc=$?
chk "exit status" "$arc" "0"
has  "names the rule it applied" "$aout" "yolo rule: suggested=keep rows from screen.tsv — keeping 2 of 5"
has  "says there was no picker"  "$aout" "no picker"
hasnt "never reached the picker" "$aout" "PICKER-REACHED"
hasnt "no picker key hints"      "$aout" "ENTER confirm"
chk "kept exactly 2"             "$(nkeep "$A")" "2"
chk "kept the two keep rows"     "$(sources "$A")" "s1.jsonl s2.jsonl "
chk "manifest entries"           "$(jq 'length' "$A/manifest.json")" "2"
chk "every entry stamped yolo"   "$(stamp_bad "$A")" "0"
chk "selection record rows"      "$(awk -F'\t' 'NR>1' "$A/decisions.tsv" | wc -l | tr -d ' ')" "2"
chk "all decisions are keep"     "$(awk -F'\t' 'NR>1 && $1!="keep"' "$A/decisions.tsv" | wc -l | tr -d ' ')" "0"
has  "byte-identity line printed" "$aout" "verified: 2/2 copies byte-identical to their originals"
chk "copies cmp-clean"           "$(cmp_bad "$A")" "0"

# ------------------------------------------------------------- B: no screen
echo
echo "== B: no screen.tsv (nothing was screened) =="
B="$WORK/b"; mkfix "$B" none
bout="$(bash "$PICK" -o "$B" -y --review-only --yolo < /dev/null 2>&1)"; brc=$?
chk "exit status" "$brc" "0"
has  "names the rule it applied" "$bout" "yolo rule: no screened keep rows (unscreened or all-drop) — keeping ALL 5 candidates"
hasnt "never reached the picker" "$bout" "PICKER-REACHED"
chk "kept all 5"                 "$(nkeep "$B")" "5"
chk "manifest entries"           "$(jq 'length' "$B/manifest.json")" "5"
chk "every entry stamped yolo"   "$(stamp_bad "$B")" "0"
has  "byte-identity line printed" "$bout" "verified: 5/5 copies byte-identical to their originals"
chk "copies cmp-clean"           "$(cmp_bad "$B")" "0"

# ------------------------------------------- C: scan scaffold, no keep rows
echo
echo "== C: screen.tsv scaffold (columns present, nothing suggested) =="
D="$WORK/c"; mkfix "$D" scaffold
cout="$(bash "$PICK" -o "$D" -y --review-only --yolo < /dev/null 2>&1)"; crc=$?
chk "exit status" "$crc" "0"
has  "falls back to all candidates" "$cout" "yolo rule: no screened keep rows (unscreened or all-drop) — keeping ALL 5 candidates"
chk "kept all 5"                    "$(nkeep "$D")" "5"
chk "every entry stamped yolo"      "$(stamp_bad "$D")" "0"
chk "copies cmp-clean"              "$(cmp_bad "$D")" "0"

# ------------------------------------------------- D: gated path unchanged
echo
echo "== D: gated finalize (no --yolo) is unchanged =="
G="$WORK/gated"; mkfix "$G" none; mkdecisions "$G" 2
gout="$(bash "$C" finalize -o "$G" < /dev/null 2>&1)"; grc=$?
chk "exit status"                 "$grc" "0"
chk "kept 2"                      "$(jq 'length' "$G/manifest.json")" "2"
chk "no provenance keys added"    "$(keyset_bad "$G")" "0"
hasnt "no yolo notice"            "$gout" "no human reviewed"
has   "verification recipe still printed" "$gout" "verify every copy is byte-identical:"
chk "copies cmp-clean"            "$(cmp_bad "$G")" "0"

printf '\n=====================\n'
if [[ $fail -eq 0 ]]; then
  printf 'YOLO E2E: ALL CHECKS PASSED (%d checks)\n' "$pass"
else
  printf 'YOLO E2E: FAILURES PRESENT (%d of %d checks failed)\n' "$fail" "$((pass + fail))"
fi
printf '=====================\n'
exit "$fail"
