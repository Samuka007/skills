#!/usr/bin/env bash
# End-to-end test of the one-command picker (pick-sessions.sh) under a real PTY.
#
# Proves the WHOLE user journey, not just that a window opened:
#   scan -> fzf pick (TAB/ENTER through a real terminal) -> finalize -> verify
#
# Run inside `nix develop` (needs tmux + fzf + jq + rg).
set -uo pipefail

REPO="${1:?usage: test-pick-tmux.sh <repo-root>}"
PICK="$REPO/skills/agent-session-batch-export/scripts/pick-sessions.sh"
WORK="${2:-/tmp/picktest}"
SESS="ezpick$$"

cleanup() { tmux kill-session -t "$SESS" 2>/dev/null || true; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "  OK   $1"; pass=$((pass+1)); return 0; }
bad() { echo "  FAIL $1"; fail=$((fail+1)); return 0; }

echo "=== one-command picker end-to-end (tmux PTY) ==="
rm -rf "$WORK"; mkdir -p "$WORK"

# --in-terminal so the script does not try to spawn a terminal of its own;
# we are already giving it a real PTY via tmux.
tmux new-session -d -s "$SESS" -x 200 -y 50
tmux send-keys -t "$SESS" "bash '$PICK' -o '$WORK' --agent codex --in-terminal" Enter

# wait for fzf to be up
for _ in $(seq 1 40); do
  sleep 0.5
  tmux capture-pane -p -t "$SESS" 2>/dev/null | grep -q "ENTER confirm" && break
done
screen="$(tmux capture-pane -p -t "$SESS")"

echo
echo "--- 1. fzf opened with the new header + preview ---"
if grep -q "ENTER confirm" <<<"$screen"; then
  ok "custom header rendered"
else
  bad "header missing"
fi
if grep -q -- "--- opening prose ---" <<<"$screen"; then
  ok "prose preview rendered"
else
  bad "preview missing"
fi
if grep -q "agent suggests" <<<"$screen"; then
  ok "suggested/reason shown in preview"
else
  bad "suggestion missing"
fi

echo
echo "--- 2. default select-all, then TAB removes one ---"
total="$(awk -F'\t' 'NR>1' "$WORK/candidates.tsv" | wc -l | tr -d ' ')"
echo "  candidates: $total"
# start:select-all means everything begins selected; deselect the first row
tmux send-keys -t "$SESS" TAB
sleep 1
tmux send-keys -t "$SESS" Enter
sleep 3

echo
echo "--- 3. decisions + finalize + verification, all from one command ---"
for _ in $(seq 1 40); do
  sleep 0.5
  grep -q "verified:" <<<"$(tmux capture-pane -p -t "$SESS")" && break
done
fin="$(tmux capture-pane -p -t "$SESS")"

if [[ -f "$WORK/decisions.tsv" ]]; then
  rows="$(awk -F'\t' 'NR>1' "$WORK/decisions.tsv" | wc -l | tr -d ' ')"
  if [[ "$rows" == "$total" ]]; then
    ok "decisions cover all candidates ($rows)"
  else
    bad "decisions rows $rows != $total"
  fi
  kept="$(awk -F'\t' 'NR>1 && $1=="keep"' "$WORK/decisions.tsv" | wc -l | tr -d ' ')"
  if [[ "$kept" == "$((total-1))" ]]; then
    ok "TAB removed exactly 1 ($kept kept)"
  else
    bad "kept $kept, want $((total-1))"
  fi
else
  bad "no decisions.tsv"
fi

if grep -q "kept .* of $total"   <<<"$fin"; then
  ok "kept-count summary printed"
else
  bad "no kept summary"
fi
if grep -qE "verified: [0-9]+/[0-9]+ copies byte-identical" <<<"$fin"; then
  ok "byte-identity verified in the same run"
else
  bad "verification line missing"
fi
if [[ -f "$WORK/manifest.json" ]]; then
  ok "manifest.json written"
else
  bad "manifest missing"
fi

echo
echo "--- 4. ESC aborts without writing ---"
rm -f "$WORK/decisions.tsv" "$WORK/manifest.json"
tmux send-keys -t "$SESS" "bash '$PICK' -o '$WORK' --review-only --in-terminal" Enter
for _ in $(seq 1 40); do sleep 0.5; tmux capture-pane -p -t "$SESS" | grep -q "ENTER confirm" && break; done
tmux send-keys -t "$SESS" Escape
sleep 2
if [[ ! -f "$WORK/decisions.tsv" ]]; then
  ok "ESC wrote nothing"
else
  bad "ESC still wrote decisions"
fi

cleanup
echo
echo "================================"
echo "PICKER E2E: $pass passed, $fail failed"
echo "================================"
exit $(( fail > 0 ? 1 : 0 ))
