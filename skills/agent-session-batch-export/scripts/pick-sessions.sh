#!/usr/bin/env bash
# One-command entry point for curating agent sessions.
#
# Wraps the four stages (scan -> screen -> review -> finalize) so the user runs
# ONE command and lands in fzf. If the process has no terminal, it re-launches
# itself in one (Windows Terminal on WSL, a GUI terminal on Linux desktops,
# tmux as the last resort) instead of dying on a TUI that cannot render.
#
# Usage:
#   bash pick-sessions.sh                      # scan everything, pick, finalize
#   bash pick-sessions.sh -w cits4012 -n 20    # pre-filter the candidate set
#   bash pick-sessions.sh -o ~/traj/run1       # choose the output directory
#   bash pick-sessions.sh -o DIR --review-only # re-pick an existing scan
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ENGINE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/curate-sessions.sh"

AGENT=both; WORKSPACE=""; TOPIC=""; SINCE=""; MIN_LINES=0
OUTDIR="./session-curation"
REVIEW_ONLY=0
IN_TERMINAL=0
NO_FINALIZE=0

usage() {
  cat <<'USAGE'
Usage: pick-sessions.sh [scan filters] [options]

Scan filters (passed through to `scan`):
  -a, --agent claude|codex|both   (default both)
  -w, --workspace SUBSTR          substring of the session's real cwd
  -t, --topic REGEX               regex over extracted prose
      --since YYYY-MM-DD
  -n, --min-lines N               drop stub sessions

Options:
  -o, --out DIR        output directory (default ./session-curation)
      --review-only    skip the scan; re-pick an existing OUTDIR
      --no-finalize    pick only; do not materialize the kept corpus
      --in-terminal    internal: already running inside the spawned window
  -h, --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--agent)      AGENT="$2"; shift 2 ;;
    -w|--workspace)  WORKSPACE="$2"; shift 2 ;;
    -t|--topic)      TOPIC="$2"; shift 2 ;;
    --since)         SINCE="$2"; shift 2 ;;
    -n|--min-lines)  MIN_LINES="$2"; shift 2 ;;
    -o|--out)        OUTDIR="$2"; shift 2 ;;
    --review-only)   REVIEW_ONLY=1; shift ;;
    --no-finalize)   NO_FINALIZE=1; shift ;;
    --in-terminal)   IN_TERMINAL=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -f "$ENGINE" ]] || { echo "engine not found next to this script: $ENGINE" >&2; exit 1; }
for dep in jq rg; do command -v "$dep" >/dev/null || { echo "$dep is required" >&2; exit 1; }; done

OUTDIR_ABS="$(mkdir -p "$OUTDIR" && cd "$OUTDIR" && pwd)"
CAND="$OUTDIR_ABS/candidates.tsv"

# ---------------------------------------------------------------- stage 1: scan
if [[ $REVIEW_ONLY -eq 0 ]]; then
  echo "== scanning ($AGENT) =="
  bash "$ENGINE" scan -o "$OUTDIR_ABS" \
    --agent "$AGENT" \
    ${WORKSPACE:+--workspace "$WORKSPACE"} \
    ${TOPIC:+--topic "$TOPIC"} \
    ${SINCE:+--since "$SINCE"} \
    --min-lines "$MIN_LINES" || exit 1
else
  [[ -f "$CAND" ]] || { echo "no $CAND — run without --review-only first" >&2; exit 1; }
fi

total="$(awk -F'\t' 'NR>1' "$CAND" | wc -l | tr -d ' ')"
if [[ "$total" -eq 0 ]]; then
  echo "no candidates matched — nothing to pick." >&2
  exit 0
fi

# ------------------------------------------------- terminal availability check
have_tty() { [[ -t 0 && -t 1 ]]; }

# Spawn a terminal that runs this script again with --in-terminal.
spawn_terminal() {
  local cmd="$SELF -o '$OUTDIR_ABS' --review-only --in-terminal"
  [[ $NO_FINALIZE -eq 1 ]] && cmd="$cmd --no-finalize"

  # WSL -> Windows Terminal (preferred), then cmd.exe. Both need wsl.exe, since
  # fzf here is a Linux binary that needs a Linux tty.
  if [[ -n "${WSL_DISTRO_NAME:-}" ]] && command -v wt.exe >/dev/null 2>&1; then
    echo "opening Windows Terminal…"
    wt.exe -- wsl.exe -d "$WSL_DISTRO_NAME" --cd "$OUTDIR_ABS" -- \
      bash -lc "bash $cmd" >/dev/null 2>&1 && return 0
  fi
  if [[ -n "${WSL_INTEROP:-}" ]] && command -v cmd.exe >/dev/null 2>&1; then
    echo "opening a console window…"
    cmd.exe /c start "" wsl.exe -d "${WSL_DISTRO_NAME:-}" -- bash -lc "bash $cmd" >/dev/null 2>&1 && return 0
  fi

  # Native Linux desktop terminals.
  local t
  for t in x-terminal-emulator alacritty kitty wezterm foot gnome-terminal konsole xterm; do
    command -v "$t" >/dev/null 2>&1 || continue
    echo "opening $t…"
    case "$t" in
      gnome-terminal|konsole) "$t" -- bash -lc "bash $cmd" >/dev/null 2>&1 ;;
      *)                      "$t" -e bash -lc "bash $cmd" >/dev/null 2>&1 ;;
    esac && return 0
  done

  # Last resort: tmux gives us a real tty on any host that has it.
  if command -v tmux >/dev/null 2>&1; then
    echo "no GUI terminal found — using tmux (attach with: tmux attach -t curate)"
    tmux kill-session -t curate 2>/dev/null || true
    tmux new-session -d -s curate -x 200 -y 50 bash -lc "bash $cmd" && {
      if [[ -n "${TMUX:-}" ]]; then tmux switch-client -t curate
      else exec tmux attach -t curate; fi
      return 0
    }
  fi
  return 1
}

if ! have_tty; then
  if [[ $IN_TERMINAL -eq 1 ]]; then
    echo "still no terminal — falling back to the TSV workflow" >&2
  elif spawn_terminal; then
    echo
    # spawn_terminal returning 0 means a window was launched, not that the user
    # finished picking. Poll briefly so the caller can tell "the picker ran" from
    # "the window never came up", instead of reporting success blindly.
    launched=0
    for _ in $(seq 1 20); do
      sleep 0.5
      if pgrep -f "curate-sessions.sh review .*$OUTDIR_ABS|pick-sessions.sh .*--in-terminal" >/dev/null 2>&1; then
        launched=1; break
      fi
    done
    if [[ $launched -eq 1 ]]; then
      echo "picker is running in the new window — confirm there with ENTER."
      echo "corpus will land in: $OUTDIR_ABS/keep"
      exit 0
    fi
    echo "a launcher was invoked but no picker appeared; use the TSV workflow:" >&2
    echo "  vi $OUTDIR_ABS/decisions.tsv   # then: bash $ENGINE finalize -o $OUTDIR_ABS" >&2
    exit 1
  else
    cat >&2 <<EOF

No terminal available and none could be opened.
Use the hand-edit workflow instead:

  vi $OUTDIR_ABS/decisions.tsv      # set column 1 to keep|drop
  bash $ENGINE finalize -o $OUTDIR_ABS
EOF
    exit 1
  fi
fi

# -------------------------------------------------------------- stage 2+3: pick
# If the agent (or a previous run) left screen.tsv with suggested/reason, fold
# those into the fzf rows so the preview can show the recommendation.
SCREEN="$OUTDIR_ABS/screen.tsv"
PREVIEW="$OUTDIR_ABS/.preview.sh"
cat > "$PREVIEW" <<'PEOF'
#!/usr/bin/env bash
# Receives the WHOLE row (`{}`), never `{n}`: with --with-nth in play, `{n}`
# indexes the transformed display fields, not the original ones — verified by
# experiment (with-nth=3,1 with preview {1} yielded the old third column).
# Row layout is the fixed 8-column form built in pick-sessions.sh:
#   1 agent · 2 cwd · 3 size · 4 n_lines · 5 first_prompt
#   6 session_file · 7 suggested · 8 reason
line="$1"
IFS=$'\t' read -r agent cwd size n_lines fp f sug why <<<"$line"
printf '\033[1m%s\033[0m  \033[2m%s\033[0m\n' "$agent" "$f"
printf 'size: %s bytes   events: %s\n' "$size" "$n_lines"
[[ -n "$sug" ]] && printf 'agent suggests: \033[33m%s\033[0m — %s\n' "$sug" "$why"
printf '\n\033[2m--- opening prose ---\033[0m\n'
case "$agent" in
  claude) jq -r 'select(.type=="user" or .type=="assistant") | .message.content
                 | if type=="array" then map(select(.type=="text")|.text)|join("\n")
                   else (if type=="string" then . else "" end) end' "$f" 2>/dev/null ;;
  codex)  jq -r 'select(.type=="response_item" and .payload.type=="message")
                 | .payload.content | map(.text//empty) | join("\n")' "$f" 2>/dev/null ;;
esac | awk '{ sub(/^[ \t\r]+/,"") }
            $0 ~ /^</ { next } $0 ~ /<environment_context>/ { next }
            $0 ~ /<user_instructions>/ { next } $0 ~ /<permissions/ { next }
            $0 ~ /^# AGENTS\.md/ { next } $0 ~ /^- [a-z].*: .*\(file:/ { next }
            length($0) > 2 { print }' | sed -n '1,80p'
PEOF
chmod +x "$PREVIEW"

# Build the fzf row set: candidates columns + suggested + reason.
if [[ -f "$SCREEN" ]]; then
  # Both sides must exclude their header or paste() misaligns by one row.
  paste <(awk -F'\t' 'NR>1' "$CAND") \
        <(awk -F'\t' 'NR>1{print $3"\t"$2}' "$SCREEN") > "$OUTDIR_ABS/.rows.tsv"
else
  awk -F'\t' 'BEGIN{OFS="\t"} NR>1{print $0,"",""}' "$CAND" > "$OUTDIR_ABS/.rows.tsv"
fi

# fzf cannot pre-select by predicate, and pre-selecting EVERYTHING (the earlier
# behaviour) silently re-enabled rows the screening had rejected — the user saw
# "all ticked" and reasonably read it as the recommendation.
#
# What works: leave everything UNSELECTED and physically order the suggested
# keeps first, so the agent's picks are what ctrl-a sweeps up immediately.
#
# The row is purpose-built for display rather than reusing candidates.tsv with
# --with-nth: --preview {n} indexes the TRANSFORMED fields once --with-nth is in
# play (verified by experiment), which is exactly the bug that made the preview
# render empty. One fixed layout, no field mapping:
#   1 agent · 2 cwd · 3 size · 4 events · 5 first_prompt
#   6 session_file · 7 suggested · 8 reason
awk -F'\t' 'BEGIN{OFS="\t"}
  { k = ($8 == "keep") ? 0 : 1
    print k, $1, $2, $4, $5, $6, $7, $8, $9 }
' "$OUTDIR_ABS/.rows.tsv" | sort -t$'\t' -k1,1n -s -o "$OUTDIR_ABS/.rows2.tsv"
# strip the sort key, keeping the now-correct physical order
cut -f2- "$OUTDIR_ABS/.rows2.tsv" > "$OUTDIR_ABS/.rows3.tsv"
mv "$OUTDIR_ABS/.rows3.tsv" "$OUTDIR_ABS/.rows2.tsv"

n_keep_sug="$(awk -F'\t' '$7=="keep"' "$OUTDIR_ABS/.rows2.tsv" | wc -l | tr -d ' ')"
n_drop_sug="$(awk -F'\t' '$7=="drop"' "$OUTDIR_ABS/.rows2.tsv" | wc -l | tr -d ' ')"

# Actually pre-select the screening's picks.
#
# Two fzf facts, both established by experiment on this box:
#   * `start:` fires BEFORE the input is loaded, so `start:select-all` selects
#     nothing. `load:` fires after loading, so it works. (`start:` only works if
#     you also pass --sync.)
#   * selection actions operate on the matched set, never on a row id, so
#     selecting "these N rows" means positioning and toggling N times. Because
#     the keeps were sorted to the top of the file, that is simply the first N.
if [[ "$n_keep_sug" -gt 0 ]]; then
  sel_seq="pos(1)"
  i=1
  while [[ $i -le $n_keep_sug ]]; do
    if [[ $i -lt $n_keep_sug ]]; then sel_seq="$sel_seq+toggle+down"
    else                          sel_seq="$sel_seq+toggle+first"; fi
    i=$((i + 1))
  done
else
  sel_seq=""
fi

echo
echo "== pick ================================================================"
if [[ "$n_keep_sug" -gt 0 ]]; then
  echo "   $n_keep_sug rows are PRE-SELECTED at the top — the screening's picks."
  echo "   Press SPACE on any of them to drop it, or SPACE a lower row to add it."
  echo "   ($n_drop_sug rejected rows follow below, unselected.)"
else
  echo "   no screening ran; nothing is pre-selected. All $total are listed."
fi
cat <<'KEYS'
   SPACE  mark / unmark the highlighted row      TAB  same, then move down
   ENTER  confirm  (marked rows are kept)        ESC  abort
   ctrl-a all   ctrl-d none      ctrl-o hide/show preview
   shift-↑/↓ scroll preview   PgUp/PgDn by page   alt-↑/↓ top/bottom
   (the preview cannot take focus — fzf has no such concept — so it is
    scrolled by keys, never by tabbing into it)
========================================================================
KEYS
echo

# SPACE always marks; there is no search mode to leave.
#
# A `/`-to-search mode was tried and removed. Making search modal forces a
# choice: while search is on, SPACE must type a space, so it cannot also mark.
# That escape hatch (a key to leave search, plus having to remember which mode
# you are in) turned out to be worse than the problem it solved. Marking is the
# primary action here and it now always behaves the same way.
#
# Consequence, stated plainly: typing goes straight into the query and filters
# immediately, so a query cannot contain a space. Everything before the first
# space still works normally.
#
# SPACE toggles: TAB is the fzf default but space is what a checklist UI trains
# people to press. TAB is bound too (plus a nudge down), since some reach for it.
#
# No --with-nth: it transforms the fields AND the fields fzf writes back on
# selection, which silently mangled the session paths (only rows whose shifted
# column happened to be a valid path survived). Showing the whole row with
# --no-sort keeps display order == file order and makes the returned row
# identical to the input row, so column maths can never drift.
#
# --layout=reverse so item 1 renders at the TOP: with fzf's default layout the
# first row is drawn at the bottom, which made the sorted keeps look like they
# had not sorted at all.
#
# The preview is NOT a focusable pane — fzf has no notion of focusing it, so
# TAB cannot switch panes. Scrolling it is key-driven; shift-↑/↓ is fzf's
# built-in binding, the rest are added here.
set -o pipefail
chosen="$(fzf --multi --ansi --delimiter='\t' \
    --layout=reverse \
    --nth=5,2 \
    --no-sort \
    --preview "$PREVIEW {}" \
    --preview-window=right:60%:wrap \
    --header="SPACE mark · ENTER confirm · ESC abort · shift-↑/↓ preview
[$total candidates; $n_keep_sug pre-selected]  columns: agent · cwd · size · events · first-prompt · file · suggested · reason" \
    --bind "load:$sel_seq" \
    --bind 'space:toggle' \
    --bind 'tab:toggle+down' \
    --bind 'ctrl-a:select-all' --bind 'ctrl-d:deselect-all' \
    --bind 'ctrl-o:toggle-preview' \
    --bind 'pgdn:preview-page-down' --bind 'pgup:preview-page-up' \
    --bind 'alt-up:preview-top' --bind 'alt-down:preview-bottom' \
    < "$OUTDIR_ABS/.rows2.tsv")" || {
  echo "aborted — nothing written" >&2; exit 1; }

printf '%s\n' "$chosen" > "$OUTDIR_ABS/.chosen.tsv"
# .rows2.tsv layout (8 cols, built above):
#   1 agent · 2 cwd · 3 size · 4 n_lines · 5 first_prompt
#   6 session_file · 7 suggested · 8 reason
awk -F'\t' 'NF{print $6}' "$OUTDIR_ABS/.chosen.tsv" | sort -u > "$OUTDIR_ABS/.keep.txt"
kept="$(wc -l < "$OUTDIR_ABS/.keep.txt" | tr -d ' ')"

# decisions.tsv carries every candidate; the picked ones become keep.
# Read rows2 (the same file fzf was given) so the column order can never drift
# from what was selected — reading .rows.tsv here was the bug: that file is
# candidates(7) + suggested + reason, whose column 7 is the path, not column 8.
{
  printf 'decision\treason\tsuggested\tagent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file\n'
  # Re-split on \x1f, NOT tabs. bash `read` treats tab as collapsible IFS
  # whitespace, so a row whose first_prompt is EMPTY loses that field and every
  # later column shifts left — $f then held the reason, not the path, and
  # `grep -qxF` never matched, silently dropping 2 of 15 rows from the manifest.
  # Same trap as curate-sessions.sh; this reader had reintroduced it.
  sep="$(printf '\037')"
  while IFS="$sep" read -r _a _c _s _e _fp _f _su _wh; do
    [[ -z "$_f" ]] && continue
    [[ -f "$_f" ]] || continue
    if grep -qxF "$_f" "$OUTDIR_ABS/.keep.txt"; then d=keep; else d=drop; fi
    # mtime comes from candidates.tsv (not carried in the display row)
    mtime="$(awk -F'\t' -v p="$_f" '$7 == p { print $3; exit }' "$CAND")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$d" "$_wh" "$_su" "$_a" "$_c" "$mtime" "$_s" "$_e" "$_fp" "$_f"
  done < <(awk -F'\t' -v sep="$sep" 'BEGIN{OFS=sep} { $1=$1; print }' "$OUTDIR_ABS/.rows2.tsv")
} > "$OUTDIR_ABS/decisions.tsv"

echo
echo "== kept $kept of $total =="

# ------------------------------------------------------------ stage 4: finalize
if [[ $NO_FINALIZE -eq 1 ]]; then
  echo "decisions: $OUTDIR_ABS/decisions.tsv"
  exit 0
fi

bash "$ENGINE" finalize -o "$OUTDIR_ABS"

# Prove the copies before handing them on, in the same run.
bad=0; n=0
# jq -r emits CRLF on Windows, so BOTH fields need the CR stripped — a trailing
# CR on either path makes cmp exit 2 ("No such file"), which is indistinguishable
# from a corrupt copy. The pair list goes through a file, never a process
# substitution, because the latter blocks forever if the job is backgrounded.
jq -r '.[] | "\(.source)\t\(.kept_as)"' "$OUTDIR_ABS/manifest.json" > "$OUTDIR_ABS/.pairs.tsv"
while IFS=$'\t' read -r s d; do
  s="${s%$'\r'}"; d="${d%$'\r'}"; n=$((n+1))
  cmp -s "$s" "$d" || { bad=$((bad+1)); echo "MISMATCH: $s" >&2; }
done < "$OUTDIR_ABS/.pairs.tsv"
echo
if [[ $bad -eq 0 ]]; then
  echo "verified: $n/$n copies byte-identical to their originals"
else
  echo "WARNING: $bad of $n copies differ — do not use this corpus" >&2
  exit 1
fi
echo "corpus:  $OUTDIR_ABS/keep"
echo "manifest: $OUTDIR_ABS/manifest.json"
