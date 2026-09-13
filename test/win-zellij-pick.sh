#!/usr/bin/env bash
# Windows interactive-picker regression (issue #7): drive the REAL picker on
# Windows through zellij, and assert on what the pane renders — not on a log
# file, a scan, or --yolo (which by design never opens the picker, so it says
# nothing about the fzf pane, its key handling, its pre-selection display or
# the terminal spawn).
#
# Usage (from the Windows Git Bash):
#   bash test/win-zellij-pick.sh
#   SKILL=C:/path/to/agent-session-batch-export bash test/win-zellij-pick.sh
#
# SKILL defaults to the copy installed by `npx skills add` into
# `$HOME/.agents/skills/…`: that is what a Windows user runs, and the shipped
# artifact is the thing under test.
#
# Why the driving looks the way it does (each fact verified with a pane dump;
# see docs/agent-session-batch-export/INTERNALS.md § "Driving the TUI from a
# script"):
#   * `dump-screen` reads the screen the CLIENT rendered. A session created
#     without a client (`attach --create-background`, or `zellij --session N`
#     from a headless caller, which quits the session on stdin EOF) returns a
#     BLANK screen even while its pane process runs fine and writes files. So
#     the session is created THROUGH a Windows Terminal window, which stays
#     attached as its client.
#   * That window must be WIDE. fzf draws its header in the list column (40% of
#     the pane), so a default 66-column window renders the header as
#     `[3 candidates; 1 pr··` — asserting on a truncated substring would pass
#     for the wrong reason. With `--maximized` (280 columns here) the full
#     line renders and is asserted verbatim.
#   * The picker is the session's FIRST pane command, so nothing races a
#     shell's startup files, and keys go through `action send-keys`.
#
# The window is transient (the run takes ~20s) and is reclaimed with the
# session: `zellij delete-session` ends the client, which closes the window.
set -uo pipefail

SKILL="${SKILL:-$HOME/.agents/skills/agent-session-batch-export}"
PICK="$SKILL/scripts/pick-sessions.sh"
WORK="${WORK:-$HOME/tmp-zellij-pick}"   # fixtures + dumps (removed on exit)
RUN="$WORK/run"                         # the picker's -o OUTDIR
SESS="win-zellij-pick"

fail=0
step() { printf '\n== %s ==\n' "$1"; }
check() { # $1 label, $2 got, $3 want
  if [[ "$2" == "$3" ]]; then printf '  OK   %s: %s\n' "$1" "$2"
  else printf "  FAIL %s: got '%s' want '%s'\n" "$1" "$2" "$3"; fail=1; fi
}
show_dump() { # $1 dump file, $2 label — trailing blanks stripped for reading only
  printf -- '--- %s ---\n' "$2"
  sed 's/[[:space:]]\{1,\}$//' "$1"
  printf -- '--- end: %s ---\n' "$2"
}
dump() { zellij --session "$SESS" action dump-screen > "$1" 2>&1; }
cleanup() {
  zellij delete-session "$SESS" --force >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- preflight
[[ -n "${MSYSTEM:-}" ]] || { echo "SKIP: Windows-only regression — run it under the Git Bash"; exit 0; }
for dep in zellij wt.exe fzf jq cmp; do
  command -v "$dep" >/dev/null 2>&1 || { echo "SKIP: $dep not available"; exit 0; }
done
[[ -f "$PICK" ]] || { echo "FAIL: picker not found: $PICK (set SKILL=<skill dir>)" >&2; exit 1; }
case "$WORK" in
  "$HOME"/tmp-*) ;;
  *) echo "FAIL: WORK must be under \$HOME/tmp-* (this script rm -rf's it), got: $WORK" >&2; exit 2 ;;
esac

echo "bash:   $BASH_VERSION  (MSYSTEM=$MSYSTEM)"
echo "zellij: $(zellij --version 2>&1)"
echo "fzf:    $(fzf --version 2>&1)"
echo "skill:  $SKILL"

# --------------------------------------------------------------- fixtures
# Synthetic throughout: three tiny sessions, one of which screen.tsv marks
# suggested=keep. The numbers the picker must print follow from these files:
# 3 candidates, 1 pre-selected — and the kept corpus must be exactly the
# pre-selected row plus the row TAB toggles below.
step "fixtures under $WORK"
rm -rf "$WORK"; mkdir -p "$WORK" "$RUN"
printf '%s\n' \
  '{"type":"user","message":{"content":"fixture alpha question"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"fixture alpha answer"}]}}' \
  > "$WORK/cand-a.jsonl"
printf '%s\n' \
  '{"type":"user","message":{"content":"fixture beta question"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"fixture beta answer"}]}}' \
  > "$WORK/cand-b.jsonl"
printf '%s\n' \
  '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fixture gamma question"}]}}' \
  > "$WORK/cand-c.jsonl"
{
  printf 'agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file\n'
  printf 'claude\t/home/u/proj-a\t2026-09-01T10:00:00Z\t123\t12\tfixture alpha question\t%s/cand-a.jsonl\n' "$WORK"
  printf 'claude\t/home/u/proj-b\t2026-09-02T11:00:00Z\t234\t20\tfixture beta question\t%s/cand-b.jsonl\n' "$WORK"
  printf 'codex\t/home/u/proj-c\t2026-09-03T12:00:00Z\t345\t30\tfixture gamma question\t%s/cand-c.jsonl\n' "$WORK"
} > "$WORK/candidates.tsv"
{
  printf 'agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file\tsuggested\treason\n'
  printf 'claude\t/home/u/proj-a\t2026-09-01T10:00:00Z\t123\t12\tfixture alpha question\t%s/cand-a.jsonl\tkeep\tfixture says keep\n' "$WORK"
  printf 'claude\t/home/u/proj-b\t2026-09-02T11:00:00Z\t234\t20\tfixture beta question\t%s/cand-b.jsonl\t\t\n' "$WORK"
  printf 'codex\t/home/u/proj-c\t2026-09-03T12:00:00Z\t345\t30\tfixture gamma question\t%s/cand-c.jsonl\t\t\n' "$WORK"
} > "$WORK/screen.tsv"
cp "$WORK/candidates.tsv" "$WORK/screen.tsv" "$RUN/"
echo "  candidates.tsv: $(awk 'END{print NR-1}' "$WORK/candidates.tsv") rows, screen.tsv marks 1 suggested=keep"

# ------------------------------------------------------------------- boot
step "boot: zellij session '$SESS' hosted by a maximized Windows Terminal window"
zellij delete-session "$SESS" --force >/dev/null 2>&1 || true
pane_cmd="$(printf '%q -o %q -y --review-only --in-terminal --stay' "$PICK" "$RUN")"
# -y: the destination is the fixture directory this script just created; the
# confirmation prompt it skips has its own test (test/outdir-tmux.sh).
wt.exe --maximized -d "$(cygpath -w "$WORK")" "$(cygpath -w "$BASH")" \
  -lc "zellij attach --create $SESS -- bash -lc $(printf '%q' "bash $pane_cmd")" >/dev/null 2>&1 \
  || { echo "  FAIL wt.exe could not launch the session host"; exit 1; }
up=0
for i in $(seq 1 20); do
  sleep 1
  [[ "$(zellij list-sessions 2>&1)" == *"$SESS"* ]] && { up=1; break; }
done
check "session up (after ${i}s)" "$up" "1"
[[ $up -eq 1 ]] || exit 1

step "wait for the picker to render"
D1="$WORK/dump-1-fzf.txt"; : > "$D1"
for i in $(seq 1 60); do
  sleep 1
  dump "$D1"
  [[ "$(<"$D1")" == *"ENTER confirm"* ]] && break
done
show_dump "$D1" "pane with the picker's fzf up (${i}s after boot)"

# --------------------------------------------------- assert the rendering
step "assert the picker's own rendering"
hdr="$(grep -o '\[[0-9][0-9]* candidates; [0-9][0-9]* pre-selected\]' "$D1" | sed -n 1p)"
check "header numbers (3 candidates, 1 pre-selected)" "$hdr" "[3 candidates; 1 pre-selected]"
check "confirm hint rendered in full" \
  "$(grep -c 'TAB mark · ENTER confirm · ESC abort · shift-↑/↓ preview' "$D1")" "1"
check "fzf shows the pre-selection" \
  "$(grep -o '[0-9][0-9]*/[0-9][0-9]* ([0-9][0-9]*)' "$D1" | sed -n 1p)" "3/3 (1)"

# ------------------------------------------------------------------ drive
step "drive: Down, then TAB (toggle the highlighted row)"
zellij --session "$SESS" action send-keys "Down" >/dev/null 2>&1
sleep 1
zellij --session "$SESS" action send-keys "Tab" >/dev/null 2>&1
D2="$WORK/dump-2-after-tab.txt"; : > "$D2"
for i in $(seq 1 20); do
  sleep 1
  dump "$D2"
  [[ "$(<"$D2")" == *"3/3 (2)"* ]] && break
done
show_dump "$D2" "pane after Down+TAB"
check "TAB toggled the highlighted row (selected 1 -> 2)" \
  "$(grep -o '[0-9][0-9]*/[0-9][0-9]* ([0-9][0-9]*)' "$D2" | sed -n 1p)" "3/3 (2)"

step "press ENTER and wait for finalize"
zellij --session "$SESS" action send-keys "Enter" >/dev/null 2>&1
D3="$WORK/dump-3-after-enter.txt"; : > "$D3"
fin=0
for i in $(seq 1 60); do
  sleep 1
  dump "$D3"
  [[ "$(<"$D3")" == *"verified:"* ]] && { fin=1; break; }
done
check "finalize finished (after ${i}s)" "$fin" "1"
show_dump "$D3" "pane after ENTER"
check "kept line" "$(grep -o '== kept 2 of 3 ==' "$D3" | sed -n 1p)" "== kept 2 of 3 =="
check "verify line" \
  "$(grep -o 'verified: 2/2 copies byte-identical to their originals' "$D3" | sed -n 1p)" \
  "verified: 2/2 copies byte-identical to their originals"

# --------------------------------------------------- corpus on the filesystem
step "corpus on the Windows filesystem"
check "keep/ file count" "$(find "$RUN/keep" -type f | wc -l | tr -d ' ')" "2"
# Which rows got in: the pre-selected one (cand-a) and the TAB'd one (cand-b).
check "kept sources" \
  "$(jq -r '.[].source' "$RUN/manifest.json" | sed 's#.*/##' | sort | paste -sd' ' -)" \
  "cand-a.jsonl cand-b.jsonl"
bad=0; n=0
jq -r '.[] | "\(.source)\t\(.kept_as)"' "$RUN/manifest.json" > "$RUN/.pairs.tsv"
while IFS=$'\t' read -r s d; do
  s="${s%$'\r'}"; d="${d%$'\r'}"; n=$((n+1))
  cmp -s "$s" "$d" || { bad=$((bad+1)); echo "  MISMATCH $s"; }
done < "$RUN/.pairs.tsv"
check "pairs compared" "$n" "2"
check "copies byte-identical to their sources" "$bad" "0"

# ----------------------------------------------------------------- cleanup
step "cleanup (session, window, fixtures)"
cleanup
sessions="$(zellij list-sessions 2>&1)"
check "zellij session reclaimed" \
  "$([[ "$sessions" == *"$SESS"* ]] && echo present || echo gone)" "gone"
check "fixtures removed" "$([[ -e "$WORK" ]] && echo present || echo gone)" "gone"

printf '\n===============================================\n'
if [[ $fail -eq 0 ]]; then echo "WINDOWS ZELLIJ PICK: ALL CHECKS PASSED"
else echo "WINDOWS ZELLIJ PICK: FAILURES PRESENT"; fi
printf '===============================================\n'
exit $fail
