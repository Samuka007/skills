#!/usr/bin/env bash
# CRLF self-check, same design as curate-sessions.sh: every physical line ends
# in a comment so a CRLF-smudged install loses its CR into the comment instead
# of appending it to a word; exit 3 (distinct from usage errors, exit 2).
__crlf_hit=0                                                                                                            # CRLF-GUARD
if [[ -f "${BASH_SOURCE[0]}" && -r "${BASH_SOURCE[0]}" ]]; then                                                         # CRLF-GUARD
  while IFS= read -r __crlf_line || [[ -n "$__crlf_line" ]]; do                                                         # CRLF-GUARD
    if [[ "$__crlf_line" == *$'\r'* ]]; then __crlf_hit=1; break; fi                                                    # CRLF-GUARD
  done < "${BASH_SOURCE[0]}"                                                                                           # CRLF-GUARD
fi                                                                                                                     # CRLF-GUARD
if [[ "$__crlf_hit" -eq 1 ]]; then                                                                                     # CRLF-GUARD
  printf '%s\n' 'this script was installed with CRLF (Windows) line endings and cannot run under bash.' >&2            # CRLF-GUARD
  printf '%s\n' "fix either way:" >&2                                                                                  # CRLF-GUARD
  printf '%s\n' "  dos2unix \"${BASH_SOURCE[0]}\"" >&2                                                                 # CRLF-GUARD
  printf '%s\n' '  reinstall:  npx --yes skills@latest add Samuka007/skills --skill agent-session-batch-export -g -y' >&2  # CRLF-GUARD
  exit 3                                                                                                               # CRLF-GUARD
fi                                                                                                                     # CRLF-GUARD
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
OUTDIR=""
REVIEW_ONLY=0
IN_TERMINAL=0
NO_FINALIZE=0
YES=0
ASK_OUT=1
STAY=0
TEST_SPAWN=""

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
  -o, --out DIR        output directory. Default: ./curated-<agent>-<date>
                       (confirmed interactively; -y to skip the prompt)
  -y, --yes            do not prompt for the output directory
      --review-only    skip the scan; re-pick an existing OUTDIR
      --no-finalize    pick only; do not materialize the kept corpus
      --in-terminal    internal: already running inside the spawned window
      --stay           internal: pause at the end so the window stays readable
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
    -y|--yes)        YES=1; shift ;;
    --review-only)   REVIEW_ONLY=1; shift ;;
    --no-finalize)   NO_FINALIZE=1; shift ;;
    --in-terminal)   IN_TERMINAL=1; shift ;;
    --stay)          STAY=1; shift ;;
    --test-spawn)    TEST_SPAWN="$2"; shift 2 ;;   # undocumented: agent test harness
    -h|--help)       usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -f "$ENGINE" ]] || { echo "engine not found next to this script: $ENGINE" >&2; exit 1; }
for dep in jq rg awk sort cut tr wc cmp; do
  command -v "$dep" >/dev/null || { echo "$dep is required" >&2; exit 1; }
done
# fzf is NOT a hard dependency: the staged pipeline needs none of it. A
# missing fzf must fail LATE (after the tty check, at the picker itself) so a
# headless caller still gets the staged fallback instead of a dead end —
# SKILL.md advertises fzf as optional.

# --stay holds the window open, and it has to apply to EVERY exit path (accept,
# abort via ESC, a validation failure, a crash). A per-path `read` would have to
# be repeated at every `exit` and would be forgotten at exactly the moment it is
# wanted. One EXIT trap covers them all.
if [[ "${STAY:-0}" -eq 1 ]]; then
  trap 'echo; printf "press Enter to close this window… "; read -r _ 2>/dev/null || true' EXIT
fi

# ------------------------------------------------------------ output directory
# A dated, agent-tagged default, then confirmed interactively. Curating is
# something you do repeatedly for different topics, so a fixed
# ./session-curation silently mixes runs together — the previous run's files
# stay behind and the corpus stops describing one selection. A dated default
# makes each run its own directory without the user having to invent a name.
if [[ -z "$OUTDIR" ]]; then
  OUTDIR="./curated-${AGENT}-$(date +%Y%m%d-%H%M)"
fi

# Confirm the destination before anything is written. Skipped with -y, and
# skipped entirely when there is no tty (a scripted/headless invocation must not
# block on a prompt nobody can answer).
# Does this bash support `read -e` (readline editing + Tab path completion)?
# Probe ONCE, at startup, instead of trying it per prompt: at EOF `read` returns
# non-zero *after* consuming the line, so a per-call `read -e … || read -r …`
# fallback runs a SECOND read and eats the next input. That is exactly what
# happened — 'e' consumed the answer and the follow-up read swallowed the path.
# Probe with non-empty input: an empty string yields EOF, which returns non-zero
# for the wrong reason and would report a false negative.
READLINE="-e"
if ! ( read -e -r _ <<< "probe" ) 2>/dev/null; then READLINE=""; fi

# $READLINE is unquoted on purpose: it is either "-e" or empty, never user input.
# shellcheck disable=SC2086
prompt_read() { # $1 = variable name
  local __v="$1"
  local __line
  if [[ -n "$READLINE" ]]; then read -e -r __line; else read -r __line || __line=""; fi
  printf -v "$__v" '%s' "$__line"
}

prompt_outdir() {
  local answer edited
  printf '\n== output directory ==\n   %s\n' "$OUTDIR"
  printf '   [Enter] accept   [e] edit   [q] quit > '
  prompt_read answer
  case "$answer" in
    "" ) ;;
    e|E) printf '   path (Tab completes): '
         prompt_read edited
         [[ -n "$edited" ]] && OUTDIR="$edited" ;;
    q|Q) echo "aborted — nothing written."; exit 0 ;;
    * )  OUTDIR="$answer" ;;   # typing a path directly also works
  esac
  printf '   -> %s\n\n' "$OUTDIR"
}

if [[ $ASK_OUT -eq 1 && $YES -eq 0 && -t 0 && -t 1 ]]; then
  prompt_outdir
elif [[ $YES -eq 1 || ! -t 0 ]]; then
  echo "output directory: $OUTDIR"
fi

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
  # --stay keeps the spawned window alive after the run so the result path is
  # actually readable. Windows Terminal defaults to closeOnExit=graceful, i.e.
  # the window disappears the moment the command returns — the user never sees
  # where the corpus landed, let alone gets to answer any prompt.
  # %q: the skills-CLI install path usually contains spaces
  # (/c/Users/<First Last>/...), and an unquoted $SELF made the child try to
  # execute the first word of the path. Also defends OUTDIR_ABS (a single
  # quote in it broke the same construct). printf %q yields a reusable word.
  local cmd
  printf -v cmd '%q -o %q --review-only --in-terminal --stay' "$SELF" "$OUTDIR_ABS"
  [[ $NO_FINALIZE -eq 1 ]] && cmd="$cmd --no-finalize"

  # ── Native Windows (Git Bash / MSYS) ──────────────────────────────────────
  # Detected by MSYSTEM, NOT by wt.exe's presence: wt.exe is on PATH inside WSL
  # too. Here the shell to relaunch is Git Bash itself — invoking wsl.exe would
  # be wrong, and on a machine with no WSL it would simply fail. Every other
  # branch below is unreachable here (no WSL_DISTRO_NAME, no X terminals, no
  # tmux under MSYS), so without this the whole auto-spawn silently failed and
  # told the user to hand-edit the TSV instead.
  if [[ -n "${MSYSTEM:-}" ]] && command -v wt.exe >/dev/null 2>&1; then
    echo "opening Windows Terminal (Git Bash)…"
    # MSYS rewrites POSIX-looking ARGUMENTS before a native program sees them,
    # corrupting wt.exe's own flags: `-d C:\Users\...` arrived mangled and wt ran
    # nothing at all (exit 0, no window). Verified: with MSYS_NO_PATHCONV=1 the
    # identical invocation works. Same class as trap 7; this call site lacked it.
    #
    # bash.exe must be given as a WINDOWS ABSOLUTE PATH. A bare `bash.exe` is
    # not resolvable by wt.exe, because Git's bin directory is on the MSYS PATH
    # but NOT on the Windows one — so the window opened and the command never
    # ran. (The WSL branch below gets away with `wsl.exe` purely because that
    # lives in system32, which is on the Windows PATH.) Only -d needs the
    # path-conversion guard; inside the -lc string $SELF stays a /c/... path,
    # which the child MSYS bash opens happily.
    local wbash; wbash="$(cygpath -w "$BASH" 2>/dev/null || cygpath -w /usr/bin/bash 2>/dev/null || printf 'bash.exe')"
    # Convert first, then run wt with NO MSYS_* in the environment. Two reasons:
    #  1. `MSYS_NO_PATHCONV=1 cmd` exports the variable for the WHOLE subtree, so
    #     the spawned bash — and every jq it runs — inherited it. jq.exe is a
    #     native binary and with conversion disabled it could not open the
    #     `/c/...` paths MSYS bash hands it ("Could not open file ... No such
    #     file"), which blanked the preview pane. This is exactly the trap
    #     documented in curate-sessions.sh, where the exemption is confined to
    #     the data argument only; applying it to the process broke the operand.
    #  2. Passing already-converted paths means there is nothing left to rewrite,
    #     so the guard is unnecessary here in the first place.
    wt.exe -d "$(cygpath -w "$OUTDIR_ABS" 2>/dev/null || printf '%s' "$OUTDIR_ABS")" \
      "$wbash" -lc "bash $cmd" >/dev/null 2>&1 && return 0
  fi

  # ── WSL ───────────────────────────────────────────────────────────────────
  # WSL -> Windows Terminal (preferred), then cmd.exe. Both need wsl.exe, since
  # fzf here is a Linux binary that needs a Linux tty.
  if [[ -n "${WSL_DISTRO_NAME:-}" ]] && command -v wt.exe >/dev/null 2>&1; then
    echo "opening Windows Terminal…"
    # No --cd OUTDIR: wsl.exe refuses to start the shell when the directory
    # is gone (deleted between spawn request and child start — the child runs
    # later, on its own schedule). Every path inside is absolute, so cwd is
    # irrelevant; defaulting to HOME keeps the child alive instead of dying
    # at chdir.
    wt.exe -- wsl.exe -d "$WSL_DISTRO_NAME" -- \
      bash -lc "bash $cmd" >/dev/null 2>&1 && return 0
  fi
  if [[ -n "${WSL_INTEROP:-}" ]] && command -v cmd.exe >/dev/null 2>&1; then
    echo "opening a console window…"
    cmd.exe /c start "" wsl.exe -d "${WSL_DISTRO_NAME:-}" -- bash -lc "bash $cmd" >/dev/null 2>&1 && return 0
  fi

  return 1
}

# TEST-ONLY spawn (not documented in SKILL.md, never auto-triggered): a
# monitored multiplexer for the agent that is ITERATING on this skill, chosen
# per platform — tmux where it exists (Linux/WSL), zellij where tmux does not
# (native Windows, scoop zellij; dump-screen reads the pane back). Creates a
# detached session running the picker so the agent can drive the TUI
# programmatically (send-keys / write-chars, then capture-pane / dump-screen).
# Idempotent: a stale session of the same name is killed first; the cleanup
# command is printed so the caller can reclaim it. A headless caller canNOT
# attach, so this never execs/attaches — it prints and returns.
test_spawn() { # $1 = tmux|zellij
  local tool="$1" cmd
  printf -v cmd '%q -o %q --review-only --in-terminal --stay' "$SELF" "$OUTDIR_ABS"
  [[ $NO_FINALIZE -eq 1 ]] && cmd="$cmd --no-finalize"
  local sess="curate-test"
  if [[ "$tool" == tmux ]]; then
    command -v tmux >/dev/null 2>&1 || { echo "tmux not found" >&2; return 1; }
    tmux kill-session -t "$sess" 2>/dev/null || true
    tmux new-session -d -s "$sess" -x 200 -y 50 bash -lc "bash $cmd" || return 1
    echo "test session created: tmux session '$sess'"
    echo "attach:    tmux attach -t $sess"
    echo "drive:     tmux send-keys -t $sess '<keys>'"
    echo "read back: tmux capture-pane -p -t $sess"
    echo "cleanup:   tmux kill-session -t $sess"
  else
    if [[ -z "${MSYSTEM:-}" ]]; then
      echo "zellij is the WINDOWS-side test multiplexer (no tmux there); use --test-spawn tmux on Linux/WSL" >&2
      return 1
    fi
    command -v zellij >/dev/null 2>&1 || { echo "zellij not found (scoop install zellij)" >&2; return 1; }
    zellij delete-session "$sess" --force 2>/dev/null || true
    # Two steps, both verified against zellij 0.45: an invocation with a bare
    # command after `--` is REJECTED as a subcommand, so first boot the empty
    # session, then `run -- <cmd>` places the picker in its first pane.
    zellij --session "$sess" >/dev/null 2>&1 </dev/null || return 1
    sleep 1
    zellij --session "$sess" run -- bash -lc "bash $cmd" >/dev/null 2>&1 </dev/null || return 1
    echo "test session created: zellij session '$sess'"
    echo "attach:    zellij attach $sess"
    echo "drive:     zellij --session $sess action write-chars '<text>' ; zellij --session $sess action send-keys Enter"
    echo "read back: zellij --session $sess action dump-screen"
    echo "cleanup:   zellij delete-session $sess --force"
  fi
  return 0
}

staged_fallback() {
  cat >&2 <<EOF

No usable terminal here (headless run). Two ways to finish:

Interactive (the USER opens their own terminal):

  bash $ENGINE package -o $OUTDIR_ABS
  -> writes $OUTDIR_ABS/open-review.sh; the user runs: bash open-review.sh
     in any terminal and gets the fzf picker, then finalize+verify in one go

Non-interactive (no terminal available to the user either):

  1. screen: read $OUTDIR_ABS/candidates.tsv and add 'suggested'
     (keep|drop) + 'reason' columns (edit in place, or write
     $OUTDIR_ABS/screen.tsv with a header naming those columns)
  2. bash $ENGINE review --ui tsv -o $OUTDIR_ABS
     -> writes $OUTDIR_ABS/decisions.tsv
  3. edit the decision column to keep|drop
  4. bash $ENGINE finalize -o $OUTDIR_ABS
     -> materializes OUT/keep/ + manifest.json and verifies every copy
EOF
}

if ! have_tty; then
  # TEST-ONLY path first: an explicit --test-spawn tmux|zellij creates a
  # drivable session instead of the product's normal spawn attempts. Not part
  # of the product's interaction surface; kept out of SKILL.md on purpose.
  if [[ -n "$TEST_SPAWN" ]]; then
    case "$TEST_SPAWN" in
      tmux|zellij) test_spawn "$TEST_SPAWN" || exit 1 ;;
      *) echo "--test-spawn wants tmux or zellij, got '$TEST_SPAWN'" >&2; exit 2 ;;
    esac
    exit 0
  fi
  if [[ $IN_TERMINAL -eq 1 ]]; then
    # We were spawned into a terminal but stdout is not a tty — e.g. someone
    # redirected it to a log. fzf opens /dev/tty on its own, so the picker still
    # works; do not claim we are falling back when we are not.
    echo "note: stdout is not a tty; fzf will use /dev/tty directly" >&2
  elif spawn_terminal; then
    # wt.exe (and friends) exit 0 when the spawn is DELEGATED, not when a
    # visible window is running — on a disconnected desktop "success" can mean
    # a dead child. Report the spawn as requested, never as verified, and
    # always hand the caller the staged escape hatch.
    echo
    echo "picker requested in a new window (the spawn itself is not verifiable from here)."
    echo "If no window appeared, finish with the staged pipeline below instead."
    echo "corpus will land in: $OUTDIR_ABS/keep"
    staged_fallback
    exit 0
  else
    # On pure Linux there is no terminal this product can launch: interaction
    # is the caller's own terminal (user runs the `package`d launcher or
    # review --ui fzf), or the staged pipeline. Say so plainly instead of
    # silently trying desktop terminals no headless agent can see.
    if [[ -n "${WSL_DISTRO_NAME:-}" || -n "${MSYSTEM:-}" ]]; then
      echo "no Windows-side terminal could be opened from this environment." >&2
    fi
    staged_fallback
    exit 1
  fi
fi

# fzf missing at runtime must not waste a spawn: the window would open, scan,
# then die at the fzf call. (The dep check above already gates this for the
# common case; this guards an interactive caller whose PATH changed.)
if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf not found — the interactive picker cannot run." >&2
  staged_fallback
  exit 1
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
# Split on \x1f, NOT tab. `read` treats tab as collapsible IFS *whitespace*, so
# a row whose 5th field (first_prompt) is EMPTY loses that field and every later
# column shifts left — $f then held the empty reason instead of the session path
# and jq read a nonexistent file, which is why the preview pane went blank for
# every session with no first prompt. Same trap already documented for
# decisions.tsv; this reader had reintroduced it.
sep="$(printf '\037')"
line="${line//$'\t'/$sep}"
IFS="$sep" read -r agent cwd size n_lines fp f sug why <<<"$line"
printf '\033[1m%s\033[0m  \033[2m%s\033[0m\n' "$agent" "$f"
printf 'size: %s bytes   events: %s\n' "$size" "$n_lines"
[[ -n "$sug" ]] && printf 'agent suggests: \033[33m%s\033[0m — %s\n' "$sug" "$why"
printf '\n\033[2m--- opening prose ---\033[0m\n'
# Only real conversation belongs here. Codex marks every injected block as a
# `message` too, so filtering on payload.type alone drags in the three
# `developer` blocks (app-context, team preamble, multi-agent mode) — hundreds
# of lines of boilerplate that buried the actual first exchange past the cutoff
# and made the pane look empty. Filter on ROLE, and label it, so a reader can
# tell who said what.
case "$agent" in
  claude) jq -r 'select(.type=="user" or .type=="assistant") | .message.content
                 | if type=="array" then map(select(.type=="text")|.text)|join("\n")
                   else (if type=="string" then . else "" end) end' "$f" 2>/dev/null ;;
  codex)  jq -r 'select(.type=="response_item" and .payload.type=="message"
                   and (.payload.role=="user" or .payload.role=="assistant"))
                 | [.payload.role, (.payload.content | map(.text//empty) | join("\n"))]
                 | @tsv' "$f" 2>/dev/null | while IFS=$'\t' read -r role body; do
            # @tsv escapes newlines/tabs inside a field as literal \\n / \\t, so
            # multi-line messages would print a trailing "\\n" instead of
            # breaking the line. jq -r already unescapes nothing here — undo the
            # TSV escaping by hand before rendering.
            body="${body//\\n/$'\n'}"
            body="${body//\\t/$'\t'}"
            body="${body//\\r/}"
            body="${body//\\\\/\\}"
            # Drop the injected blocks BEFORE printing the [role] header, so a
            # user turn that is nothing but <environment_context> does not leave
            # a dangling empty label.
            body="$(printf '%s' "$body" | awk '{ sub(/^[ \t\r]+/,"") }
              $0 ~ /^</ { next } $0 ~ /<environment_context>/ { next }
              $0 ~ /<user_instructions>/ { next } $0 ~ /<permissions/ { next }
              $0 ~ /^# AGENTS\.md/ { next } $0 ~ /^- [a-z].*: .*\(file:/ { next }
              length($0) > 2 { print }')"
            [[ -z "$body" ]] && continue
            printf '\n\033[36m[%s]\033[0m\n%s\n' "$role" "$body"
          done ;;
esac | awk '{ sub(/^[ \t\r]+/,"") }
            $0 ~ /^</ { next } $0 ~ /<environment_context>/ { next }
            $0 ~ /<user_instructions>/ { next } $0 ~ /<permissions/ { next }
            $0 ~ /^# AGENTS\.md/ { next } $0 ~ /^- [a-z].*: .*\(file:/ { next }
            length($0) > 2 { print }' | sed -n '1,80p'
PEOF
chmod +x "$PREVIEW"

# Build the fzf row set: candidates columns + suggested + reason.
#
# screen.tsv is "candidates.tsv plus two columns", but the header shape varies in
# practice: a maintainer's test writes `decision reason suggested …` (10 cols) and
# a hand-written screening `session_file suggested reason` (3 cols). Reading by
# POSITION therefore reads the wrong field for at least one of them — that is
# what swapped suggested/reason, zeroed the pre-selection count, and made the
# preview print the reason as the suggestion.
#
# So: resolve the two columns by HEADER NAME, and join on `session_file` rather
# than by line order — `paste` would attach a suggestion to whichever candidate
# happened to sit at the same line, silently mislabelling the whole set if the
# screening were sorted differently.
if [[ -f "$SCREEN" ]]; then
  # Header-name resolution on BOTH sides (the candidates side used to take
  # $NF, a positional read that silently keys the join wrong if the candidate
  # shape ever grows a trailing column). CRLF strip on every input line: a
  # screen.tsv saved CRLF by a Windows-side screening rode its CR onto the
  # session_file value, the /\.jsonl$/ key regex never matched, and the whole
  # screening came through as empty suggestions.
  awk -F'\t' 'BEGIN{OFS="\t"}
    NR==FNR {
      { sub(/\r$/, "") }
      if (FNR==1) { for (i=1;i<=NF;i++) { if ($i=="suggested") si=i; if ($i=="reason") ri=i; if ($i=="session_file") fi=i }
                    if (!si) { print "screen.tsv has no `suggested` column" > "/dev/stderr"; exit 2 }
                    next }
      # reason is free text: a tab in it shifts every later column downstream
      # (a kept session then silently vanished at finalize). Same sanitizing
      # the finalize reader applies on its side.
      sug_txt = si ? $(si) : ""; why_txt = ri ? $(ri) : ""
      gsub(/[\t\r\n]/, " ", sug_txt); gsub(/[\t\r\n]/, " ", why_txt)
      k = fi ? $fi : ""
      sug[k]=sug_txt; why[k]=why_txt
      next
    }
    { sub(/\r$/, "") }
    FNR==1 { fi=0; for (i=1;i<=NF;i++) if ($i=="session_file") fi=i; next }
    # Rebuild the fields explicitly rather than printing $0 with two appends:
    # $0 is the raw line and appending to it re-joins with OFS, which does not
    # reproduce a row whose fields were split on tabs.
    { f = fi ? $fi : $NF
      for (i=1;i<=NF;i++) printf "%s\t", $i
      printf "%s\t%s\n", (f in sug ? sug[f] : ""), (f in why ? why[f] : "") }
  ' "$SCREEN" "$CAND" > "$OUTDIR_ABS/.rows.tsv"
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
  # TAB, not SPACE: SPACE is deliberately left unbound so it can be typed into
  # the query (see the key-binding notes below). Advertising SPACE here sent
  # users to a key that does nothing.
  echo "   TAB any of them to drop it, or TAB a lower row to add it."
  echo "   ($n_drop_sug rejected rows follow below, unselected.)"
else
  echo "   no screening ran; nothing is pre-selected. All $total are listed."
fi
cat <<'KEYS'
   TAB    mark / unmark the highlighted row (stays put)
   ENTER  confirm  (marked rows are kept)        ESC  abort
   ctrl-a all   ctrl-d none      ctrl-o hide/show preview
   shift-↑/↓ scroll preview   PgUp/PgDn by page   alt-↑/↓ top/bottom
   (the preview cannot take focus — fzf has no such concept — so it is
    scrolled by keys, never by tabbing into it)
========================================================================
KEYS
echo

# TAB marks and stays on the row; SPACE is deliberately NOT bound.
#
# Binding SPACE to `toggle` cost the ability to type a space in the query, and
# a modal `/`-search (tried, then removed) only traded that for a worse problem:
# a mode to track plus a key to escape it. Leaving SPACE unbound solves it in
# one move — it is an ordinary character, so queries may contain spaces, and the
# marking key is TAB, which has no character to steal.
#
# TAB keeps fzf's default `toggle` with the default "move down" removed, so it
# is a pure mark/unmark like a checkbox and does not scroll away from the row
# just marked.
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
    --preview "'$PREVIEW' {}" \
    --preview-window=right:60%:wrap \
    --header="TAB mark · ENTER confirm · ESC abort · shift-↑/↓ preview
[$total candidates; $n_keep_sug pre-selected]  columns: agent · cwd · size · events · first-prompt · file · suggested · reason" \
    --bind "load:$sel_seq" \
    --bind 'tab:toggle' \
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
