#!/usr/bin/env bash
# Regression for `validate` (SPEC item 19). Three defects lived in one command,
# and each one hid the others: whichever spelling a caller picked first, that
# spelling's failure answered, so the next defect was never reached.
#
#   * the positional spelling the help invites (`validate DIR/decisions.tsv`)
#     died as `unknown option: …`, rc=2, before validate ran a single line;
#   * `validate -o DIR` resolved only candidates.tsv, so a directory holding
#     just the review output — the file the command's own help says it checks —
#     answered `no such file: …/candidates.tsv`, rc=1;
#   * the shape check hardcoded `want = ($1 == "decision") ? 10 : 7`, so a
#     decisions file whose verdict columns are not first was reported
#     MALFORMED while being perfectly well-formed.
#
# Fixtures, not the real stores: this has to give the same answer on any
# machine, and a test that reads ~/.codex says nothing repeatable about the
# command. Every assertion here fails on the pre-fix code (checked one by one
# against the recorded reproduction), and the two that must NOT change —
# candidates.tsv unchanged, a ragged row still named — are pinned as well,
# because a fix that adds tolerance to the shape check can eat the check.
set -uo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
C="$REPO/skills/agent-session-batch-export/scripts/curate-sessions.sh"
W="${1:-/tmp/validate-e2e}"

pass=0; fail=0
chk() { # label want got
  if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else printf '  FAIL %s\n         want %q\n         got  %q\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}
has() { # label haystack needle
  if [[ "$2" == *"$3"* ]]; then printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else printf '  FAIL %s\n         %q not in output\n' "$1" "$3"; fail=$((fail + 1)); fi
}
lacks() {
  if [[ "$2" != *"$3"* ]]; then printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else printf '  FAIL %s\n         %q unexpectedly present\n' "$1" "$3"; fail=$((fail + 1)); fi
}

rm -rf "$W"; mkdir -p "$W"
H="$W/home"
S="$H/.codex/sessions/2026/09/15"
mkdir -p "$S"

# A codex session needs a session_meta line: scan reads cwd from it and skips
# any file where cwd is empty. Prose here is ASCII on purpose — validate never
# reads it, and a fixture that needs an encoder to be written is a fixture that
# fails for a reason unrelated to the command.
meta='{"type":"session_meta","payload":{"cwd":"/home/demo/notes","model_provider":"OpenAI"}}'
mkcodex() { # name  text
  { printf '%s\n' "$meta"
    printf '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"%s"}]}}\n' "$2"
    printf '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"ok"}]}}\n'
  } > "$S/rollout-$1.jsonl"
}
mkcodex one   'translate this paragraph'
mkcodex two   'summarise the changelog'
mkcodex three 'rename the variable'

v() { # args…  -> $VOUT, $VRC
  VOUT="$(HOME="$H" bash "$C" validate "$@" 2>&1)"; VRC=$?
}

HOME="$H" bash "$C" scan -o "$W/out" >/dev/null 2>&1
HOME="$H" bash "$C" review --ui tsv -o "$W/out" >/dev/null 2>&1
# Three verdicts, one of each kind: keep, drop, and a row nobody decided yet.
# A tally that only prints the decided rows cannot be told from a tally that
# counted nothing, which is what the blank bucket is for.
awk -F'\t' 'BEGIN{OFS="\t"}
  NR == 1 { print; next }
  { if (++c == 1) { $1 = "keep"; $2 = "accepted" }
    else if (c == 2) { $1 = "drop"; $2 = "not relevant" }
    print }' "$W/out/decisions.tsv" > "$W/out/d" && mv "$W/out/d" "$W/out/decisions.tsv"
chk "the fixture produced three decisions rows" "3" \
  "$(awk -F'\t' 'NR>1' "$W/out/decisions.tsv" | wc -l | tr -d ' ')"

echo
echo "== the positional spelling works (it used to die as 'unknown option') =="
v "$W/out/decisions.tsv"
chk "exit code" "0" "$VRC"
has "it names the file it checked" "$VOUT" "== $W/out/decisions.tsv =="
has "the decisions shape passes" "$VOUT" "shape ok (10 cols)"
lacks "and is not called malformed" "$VOUT" "MALFORMED"

echo
echo "== the decision tally survives all three buckets =="
has "keeps" "$VOUT" "decision=keep: 1"
has "drops" "$VOUT" "decision=drop: 1"
# Silence here is the defect: a fresh decisions.tsv printed no tally at all,
# which reads the same as a tally that never ran.
has "and the undecided row is named" "$VOUT" "decision=(blank): 1"

echo
echo "== -o DIR reaches decisions.tsv when it is the only file there =="
mkdir -p "$W/onlydec"; cp "$W/out/decisions.tsv" "$W/onlydec/decisions.tsv"
v -o "$W/onlydec"
chk "exit code" "0" "$VRC"
has "it validated the decisions file" "$VOUT" "== $W/onlydec/decisions.tsv =="
has "with the decisions shape" "$VOUT" "shape ok (10 cols)"

echo
echo "== candidates.tsv keeps its old behaviour (7 cols, no tally row) =="
mkdir -p "$W/candonly"; cp "$W/out/candidates.tsv" "$W/candonly/candidates.tsv"
v -o "$W/candonly"
chk "exit code" "0" "$VRC"
has "the candidates shape" "$VOUT" "shape ok (7 cols)"
lacks "and no decision tally for a file without that column" "$VOUT" "decision="

echo
echo "== an explicit path wins over the -o default =="
v -o "$W/candonly" "$W/out/decisions.tsv"
has "the positional file was the one checked" "$VOUT" "== $W/out/decisions.tsv =="
v -o "$W/candonly" --from "$W/out/decisions.tsv"
has "--from is the same slot" "$VOUT" "== $W/out/decisions.tsv =="

echo
echo "== a decisions file whose verdict columns are not first is not an error =="
# The registered false alarm: 9 columns, `agent` first, decision appended.
awk -F'\t' 'BEGIN{OFS="\t"}
  NR == 1 { print $1, $2, $3, $4, $5, $6, $7, "decision", "reason"; next }
  { print $1, $2, $3, $4, $5, $6, $7, "keep", "appended" }' \
  "$W/out/candidates.tsv" > "$W/legacy.tsv"
v "$W/legacy.tsv"
chk "exit code" "0" "$VRC"
has "its own width is the expected one" "$VOUT" "shape ok (9 cols)"
lacks "no false MALFORMED" "$VOUT" "MALFORMED"
has "and its tally still reads the column by name" "$VOUT" "decision=keep: 3"

echo
echo "== the check that has to survive: a tab inside a field is still named =="
awk -F'\t' 'BEGIN{OFS="\t"} NR == 2 { $2 = "has\ttab inside" } { print }' \
  "$W/out/decisions.tsv" > "$W/ragged.tsv"
v "$W/ragged.tsv"
has "the ragged row is counted against the header" "$VOUT" "MALFORMED rows (expected 10 cols): 1"

echo
echo "== failure modes are still failures =="
v -o "$W/nothing-here"
chk "no TSV at all is an error, not an empty pass" "1" "$VRC"
v "$W/does-not-exist.tsv"
chk "an explicit path that is not there is an error" "1" "$VRC"
# A shape check that answers "shape ok" for a file with no rows is worse than
# no check: it says the file was read.
: > "$W/zero.tsv"
v "$W/zero.tsv"
has "an empty file says so" "$VOUT" "empty file"

echo
echo "== only validate takes a positional =="
POSOUT="$(HOME="$H" bash "$C" scan "$W/nowhere" 2>&1)"; POSRC=$?
chk "another command still rejects one" "2" "$POSRC"
has "with the old wording" "$POSOUT" "unknown option"
v a.tsv b.tsv
chk "two positionals are refused" "2" "$VRC"

echo
printf 'VALIDATE E2E: %s (%d passed' \
  "$([[ "$fail" -eq 0 ]] && echo "ALL CHECKS PASSED" || echo "$fail FAILED")" "$pass"
[[ "$fail" -gt 0 ]] && printf ', %d failed' "$fail"
printf ')\n'
[[ "$fail" -eq 0 ]] || exit 1
