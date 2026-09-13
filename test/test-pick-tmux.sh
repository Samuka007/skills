#!/usr/bin/env bash
# End-to-end test of the one-command picker (pick-sessions.sh) under a real PTY.
#
# Proves the WHOLE user journey, not just that a window opened:
#   scan -> fzf pick (TAB/ENTER through a real terminal) -> finalize -> verify
#
# The one command serves two documented journeys, and both are driven here:
#
#   1. UNScreened — `pick-sessions.sh -o DIR --agent codex` scans, then picks.
#      Nothing arrives pre-selected: a fresh scan's screen.tsv scaffold has
#      empty suggestion columns, and pre-filling them is deliberately rejected
#      (SPEC decisions: "the funnel does not pre-fill `suggested`" — the column
#      records a judgement made by reading the session). "Everything" is
#      therefore ctrl-a select-all, then TAB unmarks the row under the cursor.
#   2. SCREENED — `--review-only` over an OUTDIR the agent screened. This is the
#      hand-off SKILL.md prescribes, and the exact shape the picker's own
#      spawn uses (spawn_terminal relaunches with --review-only, so the
#      screening is not overwritten by a second scan): the keeps arrive
#      PRE-SELECTED and the preview names the suggestion.
#
# Both journeys begin at the output-directory confirmation (SKILL.md
# § Output directory): `-o DIR` only PROPOSES DIR, a human accepts with Enter.
# The suite answers that prompt for real and asserts the prompt rendered.
# It used to launch the picker and keep typing without ever answering, so every
# assertion ran against a pane still sitting on the prompt — see
# docs/agent-session-batch-export/INTERNALS.md, picker trap 49.
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

dump() { tmux capture-pane -p -t "$SESS"; }

# fzf's info line "N/M (S)": M matched of N total with S selected. The (S) is
# the selected count (INTERNALS trap 17), and pinning the whole line avoids
# matching a stray parenthesised number elsewhere on the pane.
sel() { dump | grep -oE '[0-9]+/[0-9]+ \([0-9]+\)' | sed -n 1p; }

# launch_picker [EXTRA_FLAGS] — start the picker in a fresh tmux session
# (--in-terminal so the script does not try to spawn a terminal of its own; we
# are already giving it a real PTY via tmux), accept the proposed output
# directory with Enter, and wait until fzf's header is up.
#
# The wait for the prompt TEXT before typing is required, not tidiness:
# send-keys that lands while an earlier stage is still running is swallowed
# (INTERNALS trap 31), and the prompt appears only after the dependency checks.
# The confirmation pane is saved before the Enter, because fzf then takes over
# the alternate screen and the prompt is no longer readable from the pane.
PICK_CMD="bash '$PICK' -o '$WORK'"
launch_picker() { # $1 = extra flags ('' for none)
  tmux kill-session -t "$SESS" 2>/dev/null || true
  tmux new-session -d -s "$SESS" -x 200 -y 50
  tmux send-keys -t "$SESS" "$PICK_CMD ${1:-} --in-terminal" Enter
  for _ in $(seq 1 60); do sleep 0.5; dump | grep -q "quit >" && break; done
  dump > "$WORK/.launch-pane"
  tmux send-keys -t "$SESS" Enter          # accept the proposed directory
  for _ in $(seq 1 60); do sleep 0.5; dump | grep -q "ENTER confirm" && break; done
  sleep 0.5                                # let the preview pane render
}

echo "=== one-command picker end-to-end (tmux PTY) ==="
rm -rf "$WORK"; mkdir -p "$WORK"

echo
echo "--- 1. launch: -o is proposed, Enter accepts, the scan runs, fzf opens ---"
launch_picker "--agent codex"
if grep -q "output directory" "$WORK/.launch-pane" && grep -qF "$WORK" "$WORK/.launch-pane"; then
  ok "output-directory prompt proposed the -o value"
else
  bad "output-directory prompt missing, or did not show $WORK"
fi

screen="$(dump)"
echo "$screen" | sed -n '1,4p'

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

# The scan ran INSIDE the command — that is journey 1's whole point, and the
# candidate count the picker is showing comes from that scan.
total="$(awk -F'\t' 'NR>1' "$WORK/candidates.tsv" | wc -l | tr -d ' ')"
echo "  candidates: $total"
if [[ "$total" -ge 3 ]]; then
  ok "in-command scan found candidates ($total)"
else
  bad "in-command scan found $total candidates — too few to assert a pick on"
fi
if grep -qF "[$total candidates; 0 pre-selected]" <<<"$screen"; then
  ok "unscreened run pre-selects nothing"
else
  bad "header does not say [$total candidates; 0 pre-selected]"
fi

echo
echo "--- 2. ctrl-a takes all, TAB removes one (a pure mark), ENTER finalizes ---"
t0="$(sel)"
tmux send-keys -t "$SESS" C-a; sleep 1
t1="$(sel)"
tmux send-keys -t "$SESS" Tab; sleep 1
t2="$(sel)"
echo "  fzf counter: start $t0 -> ctrl-a $t1 -> TAB $t2"
if [[ "$t0" == "$total/$total (0)" && "$t1" == "$total/$total ($total)" && "$t2" == "$total/$total ($((total-1)))" ]]; then
  ok "ctrl-a selected all, TAB removed exactly 1"
else
  bad "counter went $t0 -> $t1 -> $t2, want (0) -> ($total) -> ($((total-1)))"
fi
tmux send-keys -t "$SESS" Enter
for _ in $(seq 1 60); do sleep 0.5; dump | grep -q "verified:" && break; done
fin="$(dump)"

echo
echo "--- 3. decisions + finalize + verification, all from one command ---"
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
echo "--- 4. the screened hand-off: suggestion shown, keeps pre-selected ---"
# Stage 2 exactly as SKILL.md prescribes: fill scan's scaffold in place — the
# first three rows keep with a reason, the rest drop — then re-pick the SAME
# OUTDIR with --review-only, which is what the spawned window runs.
awk -F'\t' 'BEGIN{OFS="\t"}
  NR==1 { print; next }
  { if (++c <= 3) { $8="keep"; $9="real human task" }
    else          { $8="drop"; $9="probe or meta session" }
    print }' "$WORK/screen.tsv" > "$WORK/.screen.new" && mv "$WORK/.screen.new" "$WORK/screen.tsv"

rm -f "$WORK/decisions.tsv" "$WORK/manifest.json"
launch_picker "--review-only"
s2="$(dump)"
if grep -q "agent suggests" <<<"$s2"; then
  ok "suggested/reason shown in preview"
else
  bad "suggestion missing"
fi
if grep -qF "[$total candidates; 3 pre-selected]" <<<"$s2"; then
  ok "the screening's keeps arrive pre-selected"
else
  bad "header does not say [$total candidates; 3 pre-selected]"
fi
s2sel="$(sel)"
if [[ "$s2sel" == "$total/$total (3)" ]]; then
  ok "fzf counter agrees: 3 selected"
else
  bad "fzf counter $s2sel, want $total/$total (3)"
fi

echo
echo "--- 5. ESC aborts without writing ---"
tmux send-keys -t "$SESS" Escape
sleep 2
ab="$(dump)"
if [[ ! -f "$WORK/decisions.tsv" ]]; then
  ok "ESC left no decisions.tsv"
else
  bad "ESC still wrote decisions.tsv"
fi
if grep -q "aborted — nothing written" <<<"$ab"; then
  ok "abort reported on the pane"
else
  bad "no abort message on the pane"
fi

cleanup
echo
echo "================================"
echo "PICKER E2E: $pass passed, $fail failed"
echo "================================"
exit $(( fail > 0 ? 1 : 0 ))
