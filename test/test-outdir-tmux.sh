#!/usr/bin/env bash
# Verify the output-directory flow:
#   A) a dated default is proposed
#   B) Enter accepts it
#   C) 'e' then a path uses the edited path  (and Tab completion is available)
#   D) 'q' aborts without writing
#   E) --stay holds the terminal open at the end
# Run under tmux so there is a real tty for the prompt.
set -uo pipefail
pass=0; fail=0
ok(){ echo "  OK   $1"; pass=$((pass+1)); return 0; }
no(){ echo "  FAIL $1"; fail=$((fail+1)); return 0; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PICK="$REPO/skills/agent-session-batch-export/scripts/pick-sessions.sh"
S=od$$
cleanup(){ tmux kill-session -t "$S" 2>/dev/null || true; }
trap cleanup EXIT
dump(){ tmux capture-pane -p -t "$S"; }

base=/tmp/odtest
rm -rf "$base"; mkdir -p "$base/work"
cd "$base/work" || exit 1

# Wait for the PROMPT to appear rather than sleeping a fixed time: the scan
# runs first and takes seconds, so a fixed sleep races it and keystrokes sent
# too early get swallowed by the scan output. (This race produced a false
# "the e branch is broken" verdict during development.)
start(){ tmux kill-session -t "$S" 2>/dev/null || true
  tmux new-session -d -s "$S" -x 170 -y 40
  tmux send-keys -t "$S" "$1" Enter
  for _ in $(seq 1 60); do sleep 0.5; dump | grep -q "quit >" && break; done
  sleep 0.3; }

echo "════ A+B. default is dated, Enter accepts ════"
start "bash '$PICK' --agent codex"
dump | grep -A2 "output directory" | sed -n '1,4p'
tmux send-keys -t "$S" Enter; sleep 1
echo "  after Enter:"
dump | grep -E "^\s+->|scanning|candidates:" | sed -n '1,4p'
tmux send-keys -t "$S" Escape; sleep 0.8   # abort the fzf picker
tmux kill-session -t "$S" 2>/dev/null || true
d="$(find "$base/work" -maxdepth 1 -type d -name 'curated-*' 2>/dev/null | sed -n 1p)"
if [[ -n "$d" ]]; then ok "dated default created: $(basename "$d")"; else no "no dated default dir"; fi

echo
echo "════ C. 'e' then an edited path ════"
start "bash '$PICK' --agent codex"
tmux send-keys -t "$S" "e"; sleep 0.8
tmux send-keys -t "$S" Enter; sleep 0.5
printf '  prompt after e: %s\n' "$(dump | grep -E 'path \(Tab' | sed -n 1p)"
tmux send-keys -t "$S" "$base/custom-dir"; sleep 0.5
tmux send-keys -t "$S" Enter; sleep 1.5
printf '  resolved: %s\n' "$(dump | grep -E '^\s+->' | sed -n 1p)"
tmux send-keys -t "$S" Escape; sleep 0.8
tmux kill-session -t "$S" 2>/dev/null || true
if [[ -d "$base/custom-dir" ]]; then ok "edited path used"; else no "edited path ignored"; fi

echo
echo "════ D. 'q' aborts without writing ════"
start "bash '$PICK' --agent codex"
tmux send-keys -t "$S" "q"; sleep 1
dump | grep -iE "aborted" | sed -n 1p
n="$(find "$base/work" -maxdepth 1 -type d -name 'curated-*' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$n" == "1" ]]; then ok "q quit without creating a new dir"; else no "q created something ($n dirs)"; fi
tmux kill-session -t "$S" 2>/dev/null || true

echo
echo "════ E. --stay holds the window ════"
start "bash '$PICK' --agent codex --stay"
tmux send-keys -t "$S" Enter; sleep 1
tmux send-keys -t "$S" Escape; sleep 1.5
if dump | grep -q "press Enter to close"; then
  ok "--stay held the window open"
else
  no "--stay did not hold the window"
fi
cleanup

echo
echo "================================"
echo "OUTDIR FLOW: $pass passed, $fail failed"
echo "================================"
exit $(( fail > 0 ? 1 : 0 ))
