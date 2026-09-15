#!/usr/bin/env bash
# E2E regression for the funnel --in-place integration contract (issue #1).
# Chain: scan → funnel run --in-place → pick-sessions.sh --review-only in a
# real tmux (fzf) → ENTER → assert kept + verified byte-identical.
# Usage: test/funnel-e2e.sh   (runs under nix develop for tmux; skips if absent)
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
FUNNEL="$REPO/skills/agent-session-batch-export/scripts/funnel.py"
C="$REPO/skills/agent-session-batch-export/scripts/curate-sessions.sh"
PICK="$REPO/skills/agent-session-batch-export/scripts/pick-sessions.sh"
WORK="${1:-/tmp/funnel-e2e}"
fail=0

command -v tmux >/dev/null || { echo "SKIP: tmux not available"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 not available"; exit 0; }

echo "== scan =="
rm -rf "$WORK"; mkdir -p "$WORK"
bash "$C" scan -o "$WORK" --agent both --min-lines 3 >/dev/null 2>&1
[[ -s "$WORK/candidates.tsv" ]] || { echo "FAIL: scan produced nothing"; exit 1; }
total=$(awk -F'\t' 'NR>1' "$WORK/candidates.tsv" | wc -l | tr -d ' ')
echo "  candidates: $total"

echo "== funnel --in-place =="
python3 "$FUNNEL" run "$WORK/candidates.tsv" unused --in-place \
  --preset report --min-turns 1 --max-tool-ratio 1.0 --no-end-turn \
  --topic-keywords "" --no-dedup | sed -n '2,3p'
[[ -f "$WORK/candidates.full.tsv" ]] || { echo "FAIL: full archive missing"; fail=1; }
surv=$(awk -F'\t' 'NR>1' "$WORK/candidates.tsv" | wc -l | tr -d ' ')
hdr=$(head -1 "$WORK/screen.tsv" | awk -F'\t' '{print $NF}')
[[ "$hdr" == "reason" ]] || { echo "FAIL: screen.tsv header missing suggested/reason (last=$hdr)"; fail=1; }
echo "  survivors: $surv (full archived, screen scaffold rebuilt)"

echo "== pick in tmux (real fzf) =="
SESS=fe$$
tmux kill-session -t "$SESS" 2>/dev/null || true
tmux new-session -d -s "$SESS" -x 200 -y 50
tmux send-keys -t "$SESS" "bash '$PICK' -o '$WORK' -y --review-only" Enter
ok=0
for _ in $(seq 1 40); do
  sleep 0.5
  tmux capture-pane -p -t "$SESS" | grep -q "ENTER confirm" && { ok=1; break; }
done
if [[ $ok -ne 1 ]]; then echo "FAIL: picker never rendered"; tmux kill-session -t "$SESS"; exit 1; fi
info="$(tmux capture-pane -p -t "$SESS" | grep -oE "\[[0-9]+ candidates; [0-9]+ pre-selected\]" | sed -n 1p)"
echo "  $info"
expected="[$surv candidates; 0 pre-selected]"
# before the fill, suggested is empty: survivor count correct, nothing preselected
[[ "$info" == "$expected" ]] || { echo "FAIL: got $info want $expected"; fail=1; }

# fill suggested=keep for all (funnel survivors are the recommendation), then
# restart picker so preselection picks them up, ENTER to confirm
python3 - "$WORK" <<'PY'
import sys, pathlib
w = pathlib.Path(sys.argv[1])
lines = (w / "screen.tsv").read_text().splitlines()
out = [lines[0]]
for ln in lines[1:]:
    parts = ln.split("\t")
    parts += [""] * (9 - len(parts))
    parts[7], parts[8] = "keep", "funnel e2e"
    out.append("\t".join(parts[:9]))
(w / "screen.tsv").write_text("\n".join(out) + "\n")
PY
tmux send-keys -t "$SESS" Escape; sleep 1
tmux send-keys -t "$SESS" "bash '$PICK' -o '$WORK' -y --review-only" Enter
for _ in $(seq 1 40); do
  sleep 0.5
  tmux capture-pane -p -t "$SESS" | grep -q "ENTER confirm" && break
done
info2="$(tmux capture-pane -p -t "$SESS" | grep -oE "\[[0-9]+ candidates; [0-9]+ pre-selected\]" | sed -n 1p)"
echo "  $info2 (after fill)"
expected2="[$surv candidates; $surv pre-selected]"
[[ "$info2" == "$expected2" ]] || { echo "FAIL: got $info2 want $expected2"; fail=1; }
tmux send-keys -t "$SESS" Enter
for _ in $(seq 1 40); do
  sleep 0.5
  tmux capture-pane -p -t "$SESS" | grep -q "verified:" && break
done
fin="$(tmux capture-pane -p -t "$SESS")"
tmux kill-session -t "$SESS" 2>/dev/null

grep -q "verified: .* byte-identical" <<<"$fin" || { echo "FAIL: no verified line"; fail=1; }
grep -qE "kept [0-9]+ of $surv" <<<"$fin" || { echo "FAIL: kept line wrong"; fail=1; }
# the printed verify RECIPE contains the literal "MISMATCH $s"; a real
# mismatch is a line starting with it at column 0
grep -q "^MISMATCH" <<<"$fin" && { echo "FAIL: mismatch present"; fail=1; }
echo "  $(grep -oE 'verified: [0-9]+/[0-9]+ copies byte-identical.*' <<<"$fin" | sed -n 1p)"

printf '\n=====================\n'
if [[ $fail -eq 0 ]]; then echo "FUNNEL E2E: ALL CHECKS PASSED"; else echo "FUNNEL E2E: FAILURES PRESENT"; fi
printf '=====================\n'
exit $fail
