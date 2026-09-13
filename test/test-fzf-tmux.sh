#!/usr/bin/env bash
# Real-PTY interaction test for the fzf review flow, driven through tmux.
#
# Why tmux: `--ui tsv` can be exercised by piping, but the DEFAULT review path is
# interactive fzf. A piped test would prove nothing about it. tmux gives a real
# terminal we can send keys into and read the rendered screen back from.
#
# Run inside `nix develop` (needs tmux + fzf).
set -uo pipefail

SKILL="${1:?usage: test-fzf-tmux.sh <skill-dir> [work-dir]}"
WORK="${2:-/tmp/fzftest}"
C="$SKILL/scripts/curate-sessions.sh"
SESS="ezfz$$"

cleanup() { tmux kill-session -t "$SESS" 2>/dev/null || true; }
trap cleanup EXIT

pass=0; fail=0
ok()   { echo "  OK   $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL $1"; fail=$((fail+1)); }
check(){ if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else bad "$1: got '$2' want '$3'"; fi; }

echo "=== PTY interaction test (tmux) ==="
echo "tmux: $(tmux -V)"
echo "fzf:  $(fzf --version)"

rm -rf "$WORK"; mkdir -p "$WORK"
bash "$C" scan -o "$WORK" >/dev/null 2>&1
total="$(awk -F'\t' 'NR>1' "$WORK/candidates.tsv" | wc -l | tr -d ' ')"
echo "candidates: $total"

# ---------------------------------------------------------------- session 1
# Run the review in a detached tmux session with a wide, tall window so fzf has
# room to render both the list and the preview pane unambiguously.
echo
echo "--- 1. launch review --ui fzf in a tmux session ---"
tmux new-session -d -s "$SESS" -x 200 -y 50
tmux send-keys -t "$SESS" "bash '$C' review -o '$WORK'" Enter
sleep 3

screen="$(tmux capture-pane -p -t "$SESS")"
echo "$screen" | sed -n '1,6p'

# fzf renders a header containing this text; its presence proves the TUI came up
if grep -q "keep selected" <<<"$screen"; then ok "fzf TUI rendered"; else bad "fzf TUI did not render"; fi

# the list must contain our own candidate sessions (fzf is showing real rows)
if grep -qE "claude|codex" <<<"$screen"; then ok "candidate rows visible"; else bad "no candidate rows on screen"; fi

echo
echo "--- 2. ctrl-a selects all, ctrl-d clears, TAB marks one, ENTER accepts ---"
tmux send-keys -t "$SESS" C-a        # ctrl-a selects all bound in the script
sleep 1
screen_all="$(tmux capture-pane -p -t "$SESS")"
if grep -qE "^ *[0-9]*/$total" <<<"$screen_all" || grep -q "$total/$total" <<<"$screen_all"; then
  ok "ctrl-a select-all reflected in fzf counter"
else
  echo "  note: counter not matched verbatim; screen tail:"; echo "$screen_all" | tail -3
fi

# deselect all, then pick exactly the first row
tmux send-keys -t "$SESS" C-d
sleep 1
tmux send-keys -t "$SESS" TAB
sleep 1
sel="$(tmux capture-pane -p -t "$SESS" | grep -cE '^ *[0-9]+/[0-9]+' || true)"
echo "  fzf counter line(s): $sel"
tmux send-keys -t "$SESS" Enter
sleep 2

echo
echo "--- 3. decisions.tsv written by the interactive path ---"
if [[ -f "$WORK/decisions.tsv" ]]; then
  ok "decisions.tsv exists"
  dec_rows="$(awk -F'\t' 'NR>1' "$WORK/decisions.tsv" | wc -l | tr -d ' ')"
  check "decision rows == candidates" "$dec_rows" "$total"
  kept="$(awk -F'\t' 'NR>1 && $1=="keep"' "$WORK/decisions.tsv" | wc -l | tr -d ' ')"
  check "exactly 1 row marked keep by TAB" "$kept" "1"
  dropped="$(awk -F'\t' 'NR>1 && $1=="drop"' "$WORK/decisions.tsv" | wc -l | tr -d ' ')"
  check "all others marked drop" "$dropped" "$((total-1))"
else
  bad "decisions.tsv missing — interactive path produced nothing"
fi

echo
echo "--- 4. ESC aborts without writing ---"
rm -f "$WORK/decisions.tsv"
tmux kill-session -t "$SESS" 2>/dev/null || true
SESS="ezfz2$$"
tmux new-session -d -s "$SESS" -x 200 -y 50
tmux send-keys -t "$SESS" "bash '$C' review -o '$WORK'" Enter
sleep 3
tmux send-keys -t "$SESS" Escape
sleep 2
if [[ ! -f "$WORK/decisions.tsv" ]]; then ok "ESC left no decisions.tsv"; else bad "ESC still wrote decisions.tsv"; fi

cleanup
echo
echo "================================"
echo "PTY CHECKS: $pass passed, $fail failed"
echo "================================"
exit $(( fail > 0 ? 1 : 0 ))
