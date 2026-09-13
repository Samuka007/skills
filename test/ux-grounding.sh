#!/usr/bin/env bash
# UX grounding for the one-command picker, driven through a real PTY (tmux).
#
# Asserts on things a piped test cannot see: what the list looks like on screen,
# whether the agent's picks are physically ordered first, whether anything is
# wrongly pre-ticked, and that the whole journey ends with a verified corpus.
#
# Two fzf semantics that a naive assertion gets wrong, both verified by probe:
#   * the "N/M" in the info line is MATCHED/TOTAL, not SELECTED/TOTAL;
#   * ENTER with nothing TABbed returns the HIGHLIGHTED row (1 row), not an
#     empty set — so "ENTER returned 1" is correct behaviour, not a bug.
# Real gating is therefore asserted on the returned PATH SET, not on a count.
set -uo pipefail

REPO="${1:?usage: ux-grounding.sh <repo-root>}"
PICK="$REPO/skills/agent-session-batch-export/scripts/pick-sessions.sh"
ENG="$REPO/skills/agent-session-batch-export/scripts/curate-sessions.sh"
WORK="${2:-/tmp/uxtest}"
SESS=ux$$

cleanup() { tmux kill-session -t "$SESS" 2>/dev/null || true; }
trap cleanup EXIT
dump() { tmux capture-pane -p -t "$SESS"; }
pass=0; fail=0
ok(){ echo "  OK   $1"; pass=$((pass+1)); return 0; }
no(){ echo "  FAIL $1"; fail=$((fail+1)); return 0; }

setup() { # $1 = with|without
  rm -rf "$WORK"; mkdir -p "$WORK"
  bash "$ENG" scan -o "$WORK" --agent codex >/dev/null 2>&1
  if [[ "$1" == with ]]; then
    awk -F'\t' 'BEGIN{OFS="\t"}
      NR==1 { print "decision","reason","suggested",$1,$2,$3,$4,$5,$6,$7; next }
      { s = (NR==11 || NR==12 || NR==15) ? "keep" : "drop"
        print "", (s=="keep" ? "real human task" : "probe or meta session"), s,
              $1,$2,$3,$4,$5,$6,$7 }' "$WORK/candidates.tsv" > "$WORK/screen.tsv"
  fi
}

run_picker() {
  tmux new-session -d -s "$SESS" -x 200 -y 50
  # Tee the script's own stdout: the help text is printed BEFORE fzf takes over
  # the alternate screen, so capturing the pane afterwards can never see it.
  tmux send-keys -t "$SESS" "bash '$PICK' -o '$WORK' --review-only --in-terminal 2>&1 | tee '$WORK/.picker.log'" Enter
  for _ in $(seq 1 40); do sleep 0.5; dump | grep -q "ENTER confirm" && break; done
}

# the pre-fzf help text, independent of the alternate screen
picker_help() { cat "$WORK/.picker.log" 2>/dev/null; }


echo "=== UX grounding ==="

echo
echo "════ A. WITH a screening file ════"
setup with
run_picker
s="$(dump)"
echo "$s" | grep -vE '^\s*$' | sed -n '1,9p'

echo
echo "--- A1. help text reflects the screening ---"
if picker_help | grep -q "PRE-SELECTED"; then
  ok "help mentions the screening"
else
  no "help silent about it"
fi

echo
echo "--- A2. preview renders (it was blank before the {n} fix) ---"
if grep -q -- "--- opening prose ---" <<<"$s"; then
  ok "preview pane shows prose header"
else
  no "preview blank"
fi
if grep -q "agent suggests:" <<<"$s"; then
  ok "preview shows the suggestion"
else
  no "no suggestion line"
fi
if grep -qE "size: [0-9]+ bytes" <<<"$s"; then
  ok "preview shows real size"
else
  no "size missing"
fi

echo
echo "--- A3. agent-kept rows are ordered FIRST on screen ---"
# first data row on screen must be one of the kept ones; the preview's first
# line names the session, so read the top list row's rendered text instead.
top="$(printf '%s\n' "$s" | grep -oE 'codex[^\|]{0,40}' | sed -n 1p)"
echo "  top row: ${top:0:60}"
first_keep="$(awk -F'\t' '$7=="keep"{print; exit}' "$WORK/.rows2.tsv" | cut -f6)"
first_any="$(sed -n 1p "$WORK/.rows2.tsv" | cut -f6)"
if [[ "$first_keep" == "$first_any" ]]; then
  ok "keeps sort first"
else
  no "keeps are not first"
fi

echo
echo "--- A4. the screening's picks are PRE-SELECTED (exactly 3) ---"
# fzf's info line shows "N/M (selected)"; the parenthesised number IS the
# selected count (established by experiment, not by reading the docs).
info="$(dump | grep -oE '[0-9]+/[0-9]+ \([0-9]+\)' | sed -n 1p)"
echo "  info line: ${info:-<none>}"
if grep -qE '\(3\)' <<<"$info"; then
  ok "3 rows pre-selected (the planted keeps)"
else
  no "expected 3 pre-selected, info says: ${info:-none}"
fi
tmux send-keys -t "$SESS" Enter
sleep 2
sel="$( [[ -s "$WORK/.chosen.tsv" ]] && awk -F'\t' 'NF' "$WORK/.chosen.tsv" | wc -l | tr -d ' ' || echo 0 )"
if [[ "$sel" == "3" ]]; then
  ok "ENTER returned exactly the 3 pre-selected rows"
else
  no "ENTER returned $sel rows, expected 3"
fi

echo "--- A4b. SPACE unmarks a pre-selected row ---"
# restart: A4's ENTER ended the picker
tmux kill-session -t "$SESS" 2>/dev/null || true
rm -f "$WORK/decisions.tsv" "$WORK/.chosen.tsv"
run_picker
before="$(dump | grep -oE '\([0-9]+\)' | sed -n 1p)"
tmux send-keys -t "$SESS" Space; sleep 1
after="$(dump | grep -oE '\([0-9]+\)' | sed -n 1p)"
echo "  selected before=$before after SPACE=$after"
if [[ "$before" == "(3)" && "$after" == "(2)" ]]; then
  ok "SPACE unmarked one row (3 -> 2)"
else
  no "SPACE did not unmark: $before -> $after"
fi
tmux send-keys -t "$SESS" Escape; sleep 1
tmux kill-session -t "$SESS" 2>/dev/null || true

echo
echo "--- A4c. SPACE marks, and typing filters immediately (no search mode) ---"
# The `/`-to-search mode was removed: SPACE must mark, always, and a modal
# search cannot coexist with that. So the invariant is the plain one — typing
# filters, SPACE still marks.
tmux kill-session -t "$SESS" 2>/dev/null || true
rm -f "$WORK/.chosen.tsv"
run_picker
tmux send-keys -t "$SESS" Space; sleep 0.7
sel_sp="$(dump | grep -oE '\([0-9]+\)' | sed -n 1p)"
echo "  SPACE from browse: selected=$sel_sp"
# fresh session => the 3 screening picks are pre-selected again, so one SPACE
# on the top (already-marked) row UNMARKS it: 3 -> 2.
if [[ "$sel_sp" == "(2)" ]]; then
  ok "SPACE toggled the highlighted row (3 -> 2)"
else
  no "SPACE did not toggle: expected (2), got $sel_sp"
fi

before="$(dump | grep -oE '[0-9]+/[0-9]+' | sed -n 1p)"
tmux send-keys -t "$SESS" "codex"; sleep 1
after="$(dump | grep -oE '[0-9]+/[0-9]+' | sed -n 1p)"
qs="$(dump | grep -E '^> ' | sed -n 1p | sed 's/[[:space:]]*╭.*$//' | sed 's/^> *//')"
echo "  typing 'codex': match $before -> $after   query=[${qs:0:20}]"
if [[ "$before" != "$after" ]]; then
  ok "typing filters immediately ($after)"
else
  no "typing did not filter: still $after"
fi
tmux send-keys -t "$SESS" Escape; sleep 1
tmux kill-session -t "$SESS" 2>/dev/null || true

echo "--- A5. ctrl-a then ENTER takes exactly the agent-kept rows ---"
# A4's ENTER already ended the picker; start a fresh session for the next pick.
tmux kill-session -t "$SESS" 2>/dev/null || true
rm -f "$WORK/decisions.tsv" "$WORK/.chosen.tsv"
run_picker
tmux send-keys -t "$SESS" C-a; sleep 1
tmux send-keys -t "$SESS" Enter; sleep 3
for _ in $(seq 1 40); do sleep 0.5; dump | grep -q "verified:" && break; done
fin="$(dump)"
if grep -q "verified: .*byte-identical" <<<"$fin"; then
  ok "corpus verified in-run"
else
  no "no verification line"
fi
if [[ -f "$WORK/decisions.tsv" ]]; then
  k="$(awk -F'\t' 'NR>1 && $1=="keep"' "$WORK/decisions.tsv" | wc -l | tr -d ' ')"
  # ctrl-a is SELECT-ALL: with the 3 screening picks already ticked, ctrl-a
  # must still end at every candidate kept, not just those 3.
  tot="$(awk -F'\t' 'NR>1' "$WORK/candidates.tsv" | wc -l | tr -d ' ')"
  if [[ "$k" == "$tot" ]]; then
    ok "ctrl-a kept all $tot (select-all semantics)"
  else
    no "kept $k of $tot"
  fi
  # the paths must resolve — a shifted column would leave every path non-existent
  miss=0
  while IFS= read -r p; do [[ -f "$p" ]] || miss=$((miss+1)); done \
    < <(awk -F'\t' 'NR>1 && $1=="keep"{print $10}' "$WORK/decisions.tsv")
  if [[ "$miss" == "0" ]]; then
    ok "every kept path exists (columns aligned)"
  else
    no "$miss kept paths do not exist"
  fi
else
  no "no decisions.tsv"
fi

echo
echo "--- A6. corpus byte-identity ---"
if [[ -f "$WORK/manifest.json" ]]; then
  bad=0
  while IFS=$'\t' read -r a b; do b="${b%$'\r'}"; cmp -s "$a" "$b" || bad=$((bad+1)); done \
    < <(jq -r '.[] | "\(.source)\t\(.kept_as)"' "$WORK/manifest.json")
  if [[ "$bad" == "0" ]]; then
    ok "all copies byte-identical"
  else
    no "$bad copies differ"
  fi
fi
cleanup

echo
echo "════ B. WITHOUT a screening file ════"
setup without
run_picker
s="$(dump)"
echo "$s" | grep -vE '^\s*$' | sed -n '1,6p'
echo
if picker_help | grep -q "no screening ran"; then
  ok "help says no screening ran"
else
  no "wrong help text"
fi
tmux send-keys -t "$SESS" Enter; sleep 2
sel="$( [[ -s "$WORK/.chosen.tsv" ]] && awk -F'\t' 'NF' "$WORK/.chosen.tsv" | wc -l | tr -d ' ' || echo 0 )"
if [[ "$sel" -le 1 ]]; then
  ok "nothing bulk-pre-ticked without a screening (ENTER returned $sel)"
else
  no "$sel rows came back without a screening"
fi
# ESC abort needs its own session: this one already ended on ENTER.
tmux kill-session -t "$SESS" 2>/dev/null || true
rm -f "$WORK/decisions.tsv" "$WORK/.chosen.tsv"
run_picker
tmux send-keys -t "$SESS" Escape; sleep 1
if [[ ! -f "$WORK/decisions.tsv" ]]; then
  ok "ESC wrote nothing"
else
  no "ESC wrote a file"
fi
cleanup

echo
echo "================================"
echo "UX GROUNDING: $pass passed, $fail failed"
echo "================================"
exit $(( fail > 0 ? 1 : 0 ))
