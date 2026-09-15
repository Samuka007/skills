#!/usr/bin/env bash
# CRLF self-check. An install smudged to CRLF (Windows autocrlf at clone time)
# dies below with "$'\r': command not found"; this turns that into an explicit,
# fixable message instead. Every physical line of the guard ends in a comment
# on purpose: under CRLF the trailing CR is swallowed by the comment instead of
# silently appending to the preceding word (a quoted word would grow a CR).
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
# Trajectory curation workbench for coding-agent session JSONL.
#
# Goal: let a human build a curated set of RAW .jsonl trajectory material
# (claude_code / codex) for downstream agentic analysis — with an agent in the
# loop for topic screening and a cheap human keep/drop pass — WITHOUT ever
# converting the transcripts to markdown.
#
# Pipeline:
#   scan      enumerate candidates -> OUT/candidates.tsv
#             (agent cwd mtime size n_lines first_prompt session_file)
#   screen    (done BY THE AGENT, out of band: add `suggested` + `reason`
#              columns to candidates.tsv after reading the prose. This script
#              only validates the shape.)
#   review    human keep/drop -> OUT/decisions.tsv
#             --ui fzf   interactive multi-select with prose preview
#             --ui tsv   just (re)emit decisions.tsv for hand-editing
#   finalize  materialize -> OUT/keep/*.jsonl (verbatim) + OUT/manifest.json
#
# The raw bytes are never transformed. finalize copies them byte-for-byte and
# records sha256 so the curated set is provably the original trajectory.
set -uo pipefail

CMD="${1:-}"; shift || true
OUTDIR="./session-curation"
AGENT=both
WORKSPACE=""
TOPIC=""
SINCE=""
MIN_LINES=0
UI=fzf
HARDLINK=0
FROM=""
# validate's positional argument: the TSV to check, `validate DIR/decisions.tsv`.
# Same slot as --from, which is how finalize has always named its decisions
# file; --from wins if both are given.
SRC_ARG=""
# delivery's archive override. `-o` is the working directory on every command;
# `delivery` takes the contract's `--out FILE` as the path of the ARTIFACT it
# produces (issue #10), so the two spellings are split in the parse loop.
ARCHIVE_OUT=""
# yolo: the USER explicitly opted out of reviewing the selection ("直接导出，
# 不用我看", "just export it"). It changes the manifest's provenance record —
# NEVER the integrity checks: sha256 + cmp run identically either way.
YOLO=0

# Scratch dir for scan and review. It was created only inside the scan block,
# so `review` (whose default UI is fzf) died at its first $TMP reference with
# "TMP: unbound variable" under set -u — on every platform. One definition
# here covers every command; the EXIT trap cleans up on every exit path.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

usage() {
  cat <<'USAGE'
Usage: curate-sessions.sh <command> [options]

Commands
  scan        enumerate candidate sessions -> OUT/candidates.tsv
  review      human keep/drop pass        -> OUT/decisions.tsv
  finalize    materialize kept raw JSONL  -> OUT/keep/ + OUT/manifest.json
  package     write OUT/open-review.sh: a one-click launcher the USER runs in
              their own terminal after the agent finished scan+screen. It opens
              the fzf review and finalizes with verification when accepted.
  delivery    package OUT/keep/ + OUT/manifest.json into ONE archive for
              handing to the buyer: verifies every recorded sha256 first, then
              writes OUT/<name>-<date>.zip|tar.gz with the corpus at its root
              and reads the archive back to confirm the members.
  validate    sanity-check a candidates/decisions TSV: every row as wide as the
              header, plus a tally of the decision column. The TSV may be given
              positionally (validate DIR/decisions.tsv) or with --from FILE;
              the default is OUT/candidates.tsv, or OUT/decisions.tsv when that
              is the only one of the two present.

Shared options
  -a, --agent NAME      claude | codex | both           (scan)
  -w, --workspace STR   substring of the session's real cwd
  -t, --topic REGEX     regex over extracted PROSE (skips base64/tool noise)
      --since DATE      only files modified on/after YYYY-MM-DD
      --min-lines N     skip tiny stub sessions (default 0)
  -o, --out DIR         working directory               (default: ./session-curation)

review options
      --ui fzf|tsv      fzf multi-select w/ prose preview, or emit a TSV to
                        hand-edit (default: fzf, falls back to tsv if no fzf)
      --resume          preserve `decision` values already present in
                        OUT/decisions.tsv instead of starting clean

finalize options
      --from FILE       decisions TSV to use (default OUT/decisions.tsv)
      --yolo            record mode=yolo / reviewed=false in the manifest:
                        ONLY for runs the user explicitly opted out of review
      --hardlink        hardlink instead of copy (read-only analysis only:
                        a downstream writer would corrupt the original)

delivery options
      --out FILE        write the archive to FILE instead of the default
                        OUT/<outdir-basename>-<date>.zip|tar.gz
  -h, --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--agent)     AGENT="$2"; shift 2 ;;
    -w|--workspace) WORKSPACE="$2"; shift 2 ;;
    -t|--topic)     TOPIC="$2"; shift 2 ;;
    --since)        SINCE="$2"; shift 2 ;;
    --min-lines)    MIN_LINES="$2"; shift 2 ;;
    -o)             OUTDIR="$2"; shift 2 ;;
    # `--out` is command-scoped. On scan/review/finalize/validate/package it is
    # the documented synonym of `-o` (the working directory) and stays that way.
    # `delivery` takes the buy-side contract's `--out FILE`, the name of the
    # ARTIFACT it produces, so the two cannot be the same variable there.
    --out)          if [[ "$CMD" == delivery ]]; then ARCHIVE_OUT="$2"; else OUTDIR="$2"; fi; shift 2 ;;
    --ui)           UI="$2"; shift 2 ;;
    --resume)       RESUME=1; shift ;;
    --from)         FROM="$2"; shift 2 ;;
    --hardlink)     HARDLINK=1; shift ;;
    --yolo)         YOLO=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             echo "unknown option: $1" >&2; exit 2 ;;
    # A bare positional. Only validate consumes one — the help calls it
    # "sanity-check a candidates/decisions TSV" and the natural spelling is
    # `validate DIR/decisions.tsv`, which used to die as "unknown option: …",
    # rc=2, on the one file the command exists to check. Every other command
    # keeps rejecting a positional: none of them has a slot for one.
    *)  if [[ "$CMD" != validate ]]; then
          echo "unknown option: $1" >&2; exit 2
        fi
        [[ -z "$SRC_ARG" ]] || { echo "unexpected extra argument: $1" >&2; exit 2; }
        SRC_ARG="$1"; shift ;;
  esac
done

for dep in jq rg find awk sed grep sort cut tr wc mktemp; do
  command -v "$dep" >/dev/null || { echo "$dep is required" >&2; exit 1; }
done

# MSYS2/Git Bash rewrites POSIX-looking command-line ARGUMENTS before handing
# them to a native binary. That corrupts DATA: a workspace of `/proj/beta`
# reached jq as `C:/Program Files/Git/proj/beta`. Disabling it for the whole
# script is wrong in the other direction — jq.exe is a native binary and then
# cannot open the `/c/...` file paths MSYS bash passes it, which silently
# yielded zero candidates. So the exemption applies ONLY to the argument that
# carries data, never to the file operand. On GNU/BSD these are plain `jq`.
if [[ -n "${MSYSTEM:-}" ]]; then
  jqd() { MSYS_NO_PATHCONV=1 jq "$@"; }
else
  jqd() { jq "$@"; }
fi

# ------------------------------------------------------------ portability layer
# This script targets GNU/Linux, macOS (BSD userland) and Windows Git Bash
# (MSYS) alike, so no assumption may bind it to one machine's toolchain.
#
# `jq` may be jaq, a jq reimplementation that does NOT implement jq's
# argument-less `first` as `.[0]` (it yields every element). No `first` here.

# stat(1) is a file-reporting tool on GNU/BSD and a FILE-INFO tool on MSYS, so
# probe behaviour instead of guessing from uname. Collect results in one awk
# pass and inverse-match, because a filename may contain the literal "GNU".
_stat_probe() {
  _sp_f="$1"
  {
    stat -f '%z %m' "$_sp_f" 2>/dev/null || :
    stat -c '%s %Y' "$_sp_f" 2>/dev/null || :
  } | awk '/^[0-9]+ [0-9]+$/ { print; exit }'
  rm -f "$_sp_f"
}

# Sets $STAT_OPT + $STAT_FMT, used as:  stat $STAT_OPT "$STAT_FMT" <file>
# They are two variables because the format must stay ONE argv entry: expanding
# "-c %s %Y" unquoted splits it, and GNU stat then reads %Y as a filename.
if [[ -z "${STAT_FMT:-}" ]]; then
  _sp="$(mktemp)"; printf '1' > "$_sp"
  case "$(_stat_probe "$_sp")" in
    "1 "* | "") STAT_OPT="-c"; STAT_FMT="%s %Y" ;;   # GNU, Git Bash, or unprobeable
    *)          STAT_OPT="-f"; STAT_FMT="%z %m" ;;   # BSD / macOS
  esac
fi

# fields: <bytes> <mtime-epoch>, for a path that exists
stat_pair() { # $1=file
  local out
  # Both variables are quoted: $STAT_OPT (-c/-f) and $STAT_FMT are each a single
  # argument. Quoting $STAT_FMT matters because it contains a space.
  out="$(stat "$STAT_OPT" "$STAT_FMT" "$1" 2>/dev/null)" || { printf '0 0'; return; }
  case "$out" in
    *$'\n'*) out="$(printf '%s' "$out" | awk 'NR==1{print; exit}')" ;;
  esac
  # Deliberate word split: $out is "<bytes> <mtime>" and must become two params.
  # shellcheck disable=SC2086
  set -- $out
  printf '%s %s' "${1:-0}" "${2:-0}"
}

stat_size() { # $1=file
  # Deliberate word split: stat_pair prints "<bytes> <mtime>".
  # shellcheck disable=SC2046
  set -- $(stat_pair "$1")
  printf '%s' "$1"
}

# sha256 of a file as a bare hex digest, or "unavailable-no-sha256-tool" when
# the platform ships neither sha256sum (GNU, Git Bash) nor shasum (macOS).
# Probed once and cached so the per-file cost is the hash itself, not a
# `command -v` per file. Both callers (finalize, delivery) go through here:
# two copies of the probe would be two places for the probe to drift.
sha256_of() { # $1=file
  if [[ -z "${SHA_CMD:-}" ]]; then
    if command -v sha256sum >/dev/null; then SHA_CMD="sha256sum"
    elif command -v shasum  >/dev/null; then SHA_CMD="shasum -a 256"
    else SHA_CMD=""; fi
  fi
  [[ -n "$SHA_CMD" ]] || { printf 'unavailable-no-sha256-tool'; return 0; }
  # Deliberate word split: SHA_CMD is "shasum -a 256" on macOS and must expand
  # into two argv entries.
  # shellcheck disable=SC2086
  $SHA_CMD "$1" 2>/dev/null | cut -d' ' -f1
}

# sed -i and awk regex escapes differ between GNU and BSD; keep one wrapper so
# both spellings live in a single place.
sed_inplace() { # $1=expression $2=file
  sed -i "$1" "$2" 2>/dev/null || sed -i '' "$1" "$2"
}

# ---------------------------------------------------------------- text plumbing
# prose extraction, per agent. Used for topic filtering and previews.
prose() { # $1=agent $2=file
  case "$1" in
    claude)
      jq -r 'select(.type == "user" or .type == "assistant")
             | .message.content
             | if type == "array"
               then map(select(.type == "text") | .text) | join("\n")
               else (if type == "string" then . else "" end)
               end' "$2" 2>/dev/null ;;
    codex)
      jq -r 'select(.type == "response_item" and .payload.type == "message")
             | .payload.content | map(.text // empty) | join("\n")' "$2" 2>/dev/null ;;
  esac
}

# first real user prompt (skips tool_results / system scaffolding), flattened
# to one line so it cannot break the TSV.
first_prompt() { # $1=agent $2=file
  case "$1" in
    claude)
      jq -r 'select(.type == "user" and (.message.content | type == "string"))
             | .message.content' "$2" 2>/dev/null ;;
    codex)
      jq -r 'select(.type == "response_item" and .payload.type == "message"
                    and .payload.role == "user")
             | .payload.content | map(.text // empty) | join(" ")' "$2" 2>/dev/null ;;
  esac | awk '
    # scaffolding filter lives here, not in jq: jaq (the jq on this box) lacks
    # starts()/test()/several builtins, and awk is dialect-free. Leading space
    # must be trimmed first — codex joins content parts with " ", so the
    # scaffolding marker is frequently not at column 0.
    { sub(/^[ \t\r]+/, "") }
    $0 ~ /^</                                              { next }
    $0 ~ /^# (AGENTS\.md|Agent skills|user_instructions)/  { next }
    $0 ~ /<environment_context>/                           { next }
    $0 ~ /<user_instructions>/                             { next }
    $0 ~ /<permissions/                                    { next }
    length($0) > 3 { print; exit }' \
       | tr '\t\r\n' '   ' | sed 's/  */ /g' | cut -c1-180
}

cwd_of() { # $1=agent $2=file
  case "$1" in
    claude) jq -r 'select(.cwd != null) | .cwd' "$2" 2>/dev/null \
              | awk 'NR == 1 { print; exit }' ;;
    codex)  jq -r 'select(.type == "session_meta") | .payload.cwd' "$2" 2>/dev/null \
              | awk 'NR == 1 { print; exit }' ;;
  esac
}

# ------------------------------------------------------------------- commands
cmd="${CMD:-}"
case "$cmd" in
  scan|review|finalize|validate|package|delivery) ;;
  ""|-h|--help) usage; exit 0 ;;
  *) echo "unknown command: $cmd" >&2; usage; exit 2 ;;
esac

CAND="$OUTDIR/candidates.tsv"
DEC="$OUTDIR/decisions.tsv"
mkdir -p "$OUTDIR"

# ============================================================== scan
if [[ "$cmd" == scan ]]; then
  # NUL-delimited find output piped into the loop. `read -d ''` needs bash 4+;
  # the `$'\0'` spelling below is what bash 3.2 (macOS) accepts, so one form
  # works on every bash the three target platforms ship.
  emit_sessions() { # $1=agent $2=root
    [[ -d "$2" ]] || return 0
    find "$2" -name '*.jsonl' -type f -print0 2>/dev/null \
      | while IFS= read -r -d $'\0' f; do
          cwd="$(cwd_of "$1" "$f")"; [[ -z "$cwd" ]] && continue
          # Windows sessions record `C:\Users\x\proj`; POSIX ones `/home/x/proj`.
          # Normalise separators on the DERIVED workspace field so `--workspace`
          # means the same thing on every platform (a filter for "proj" works on
          # both). The trajectory itself is copied byte-identical and untouched.
          cwd="${cwd//\\//}"
          # stat_pair already returns "<bytes> <mtime>" — keep BOTH. The main
          # loop below needs size again, and a second stat per file is another
          # fork per candidate: on MSYS every fork is a simulated fork
          # (CreateProcess + cygheap copy), and high fork density inside a
          # spawned-terminal subtree is what trips "cygheap read copy failed"
          # transiently. One stat per file, total.
          # Deliberate split: stat_pair prints "<bytes> <mtime>".
          # shellcheck disable=SC2207
          __st=($(stat_pair "$f"))
          # Column order here is agent <TAB> cwd <TAB> mtime <TAB> size <TAB>
          # file; the awk filter below and the main loop both know it.
          printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$cwd" "${__st[1]}" "${__st[0]}" "$f"
        done
  }

  # NB: both branches must feed the SAME redirect. With the redirect hanging off
  # only the codex `fi`, the claude half leaked to stdout and the candidate file
  # silently held codex only.
  {
    [[ "$AGENT" == claude || "$AGENT" == both ]] \
      && emit_sessions claude "$HOME/.claude/projects"
    [[ "$AGENT" == codex || "$AGENT" == both ]] \
      && emit_sessions codex "$HOME/.codex/sessions"
  } > "$TMP/all.tsv"

  # A `subshell`-less pipeline still exits 0 on an absent root; the empty-result
  # case is reported below rather than silently producing an empty candidate set.

  # workspace + date + size filters are metadata-only, so they run before the
  # expensive prose read.
  since_e=0
  if [[ -n "$SINCE" ]]; then
    # busybox date has -D; GNU has -d; BSD has -j -f. Probe in bash rather than
    # inside awk, where the fallbacks cannot be sequenced cleanly.
    since_e="$(date -d "$SINCE" +%s 2>/dev/null || date -j -f %Y-%m-%d "$SINCE" +%s 2>/dev/null || echo 0)"
    [[ "$since_e" =~ ^[0-9]+$ ]] || since_e=0
  fi

  awk -F'\t' -v w="$WORKSPACE" -v since_e="$since_e" '
    NF >= 5 {
      if (w != "" && index($2, w) == 0) next
      if (since_e + 0 > 0 && ($3 + 0) < since_e + 0) next
      print
    }' "$TMP/all.tsv" > "$TMP/f1.tsv"

  header=$'agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file'
  printf '%s\n' "$header" > "$CAND"

  n=0
  # size arrives from emit_sessions (single stat per file above) — do not
  # stat again here, that was one more fork per candidate on every platform.
  while IFS=$'\t' read -r agent cwd mtime size f; do
    lines=$(wc -l < "$f" 2>/dev/null || echo 0)
    (( lines < MIN_LINES )) && continue
    if [[ -n "$TOPIC" ]]; then
      prose "$agent" "$f" > "$TMP/prose"
      rg -qi -- "$TOPIC" "$TMP/prose" 2>/dev/null || continue
    fi
    fp="$(first_prompt "$agent" "$f")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$agent" "$cwd" "$mtime" "$size" "$lines" "$fp" "$f" >> "$CAND"
    n=$((n + 1))
  done < "$TMP/f1.tsv"

  echo "candidates: $n  (workspace='${WORKSPACE:-*}' topic='${TOPIC:-*}' since='${SINCE:-*}' min_lines=$MIN_LINES)"
  echo "wrote: $CAND"

  # Deterministic screening scaffold, not a free-form contract: the agent's
  # stage 2 is "fill these two columns in THIS file", the same way a human
  # would. Before this, the screening file's NAME was never specified
  # anywhere — one run invented candidates.screen.tsv, the next run inherited
  # the invented name from the previous run's artifacts, review could not
  # find it, and the agent fell back to rewriting decisions.tsv from scratch.
  # One canonical file, generated here: candidates columns + two empty ones.
  SCREEN="$OUTDIR/screen.tsv"
  awk -F'\t' 'BEGIN{OFS="\t"}
    NR == 1 { print $0, "suggested", "reason"; next }
    { print $0, "", "" }
  ' "$CAND" > "$SCREEN"
  echo "screen scaffold: $SCREEN  (fill the last two columns: suggested=keep|drop, reason=one line)"
  echo
  echo "next: agent fills 'suggested' (keep|drop) + 'reason' in $SCREEN,"
  echo "      then run: $0 review --ui tsv -o $OUTDIR"
  exit 0
fi

# ============================================================== package
if [[ "$cmd" == package ]]; then
  [[ -f "$CAND" ]] || { echo "no $CAND — run the scan command first" >&2; exit 1; }
  OUTDIR_ABS="$(cd "$OUTDIR" && pwd)"
  # The launcher is a BUNDLE member: it lives next to the TSVs in OUTDIR and
  # resolves the engine relative to ITS OWN location at package time (the
  # engine path is fixed for the install that wrote it). Hardcoding the
  # absolute engine path is the simple, robust choice — the launcher is
  # consumed on the machine that produced it, alongside this very OUTDIR.
  ENGINE_ABS="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  launcher="$OUTDIR_ABS/open-review.sh"
  # Quoted heredoc: every path is expanded NOW, not at launcher runtime.
  cat > "$launcher" <<LEOF
#!/usr/bin/env bash
# One-click review launcher, generated by \`curate-sessions.sh package\`.
# Run it in YOUR OWN terminal: bash open-review.sh
# It opens the fzf picker over the screened candidates and, when you confirm,
# finalizes the corpus and verifies every copy — one interaction, done.
set -uo pipefail
ENGINE="$ENGINE_ABS"
OUTDIR="$OUTDIR_ABS"
if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf is required for the interactive review. Install it, or run the" >&2
  echo "non-interactive path instead:" >&2
  echo "  bash \$ENGINE review --ui tsv -o \$OUTDIR" >&2
  exit 1
fi
bash "\$ENGINE" review --ui fzf -o "\$OUTDIR" || exit 1
bash "\$ENGINE" finalize -o "\$OUTDIR" || exit 1
echo
echo "corpus: \$OUTDIR/keep"
echo "manifest: \$OUTDIR/manifest.json"
LEOF
  chmod +x "$launcher"
  echo "launcher written: $launcher"
  echo "hand this to the user: open a terminal in $OUTDIR_ABS and run"
  echo "  bash open-review.sh"
  exit 0
fi

# ============================================================== validate
if [[ "$cmd" == validate ]]; then
  # Which TSV: an explicit path wins — the positional argument or --from FILE,
  # which name the same slot. Without one, the default is candidates.tsv,
  # falling back to decisions.tsv when that is the only one of the two present:
  # a decisions-only directory is a normal state (the review step's output is
  # what matters by then), and `-o DIR` has to be able to check it. Resolving
  # only $CAND here made `validate -o DIR` unreachable for exactly the file the
  # command's own help says it validates.
  src="${FROM:-${SRC_ARG:-}}"
  if [[ -z "$src" ]]; then
    if   [[ -f "$CAND" ]]; then src="$CAND"
    elif [[ -f "$DEC"  ]]; then src="$DEC"
    else echo "no such file: $CAND (or $DEC)" >&2; exit 1
    fi
  fi
  [[ -f "$src" ]] || { echo "no such file: $src" >&2; exit 1; }
  echo "== $src =="
  # The expected width is the file's OWN header: candidates.tsv is 7 columns,
  # decisions.tsv is 10 (the verdict columns first), a screen.tsv is 9. A
  # hardcoded 10-vs-7 branch keyed on $1 false-alarms on any decisions file
  # whose verdict columns are not first — which is the file this command is
  # documented to check. What has to hold is that every row is as wide as the
  # header, because that is what a tab inside a free-text field breaks.
  awk -F'\t' '
    NR == 1 {
      print "columns(" NF "): " $0
      want = NF
      print "expected cols: " want
      next
    }
    NF != want { bad++ }
    END { if (NR == 0)  print "empty file — nothing to check"
          else if (bad) print "MALFORMED rows (expected " want " cols): " bad
          else          print "shape ok (" want " cols)" }' "$src"
  # decision tally. A file with no decision column (candidates, screen) has
  # none to print. The blank count is printed too: a fresh decisions.tsv then
  # says how many rows are still undecided instead of printing nothing at all,
  # which is indistinguishable from a tally that never ran. `for (k in c)` has
  # no order, so the report goes through sort to be deterministic.
  awk -F'\t' '
    NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
    { if (!("decision" in h)) next
      d = $h["decision"]
      if (d == "") blank++
      else c[d]++ }
    END { if (!("decision" in h)) exit
          printf "decision=%s: %d\n", "(blank)", blank
          for (k in c) printf "decision=%s: %d\n", k, c[k] }' "$src" | sort
  exit 0
fi

# ============================================================== review
if [[ "$cmd" == review ]]; then
  [[ -f "$CAND" ]] || { echo "no $CAND — run the scan command first" >&2; exit 1; }
  command -v fzf >/dev/null && [[ "$UI" == fzf ]] || UI=tsv

  # carry over decisions from a previous pass
  prev=""
  if [[ -n "${RESUME:-}" && -f "$DEC" ]]; then
    cp "$DEC" "$TMP/prev.tsv" 2>/dev/null || true
    prev="$TMP/prev.tsv"
  fi

  if [[ "$UI" == fzf ]]; then
    # preview: metadata + the opening of the actual prose, so the human judges
    # the real content rather than the one-line summary.
    cat > "$TMP/preview.sh" <<'PEOF'
#!/usr/bin/env bash
line="$1"
file="$(printf '%s' "$line" | awk -F'\t' '{print $7}')"
agent="$(printf '%s' "$line" | awk -F'\t' '{print $1}')"
echo "== $agent =="
echo "cwd:   $(printf '%s' "$line" | awk -F'\t' '{print $2}')"
echo "file:  $file"
echo "size:  $(printf '%s' "$line" | awk -F'\t' '{print $4}') bytes, $(printf '%s' "$line" | awk -F'\t' '{print $5}') events"
echo
echo "--- opening prose ---"
case "$agent" in
  claude) jq -r 'select(.type=="user" or .type=="assistant") | .message.content
                 | if type=="array" then map(select(.type=="text")|.text)|join("\n")
                   else (if type=="string" then . else "" end) end' "$file" 2>/dev/null ;;
  codex)  jq -r 'select(.type=="response_item" and .payload.type=="message")
                 | .payload.content | map(.text//empty) | join("\n")' "$file" 2>/dev/null ;;
esac | sed -n '1,120p'
PEOF
    chmod +x "$TMP/preview.sh"

    echo "fzf: TAB=select, ENTER=confirm selection as KEEP, ESC=abort"
    selected="$(tail -n +2 "$CAND" | fzf --multi --ansi --delimiter='\t' \
      --with-nth=1,2,5,6 \
      --preview "$TMP/preview.sh {}" \
      --preview-window=right:60%:wrap \
      --header='TAB=select · ENTER=keep selected · ESC=abort' \
      --bind 'ctrl-a:select-all' --bind 'ctrl-d:deselect-all' \
      )" || { echo "aborted — no decisions written" >&2; exit 1; }

    printf '%s\n' "$selected" > "$TMP/picked.tsv"
    awk -F'\t' '{print $7}' "$TMP/picked.tsv" | sort -u > "$TMP/keep_paths.txt"

    # emit decisions for every candidate row
    { printf 'decision\treason\tsuggested\tagent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file\n'
      awk -F'\t' -v kp="$TMP/keep_paths.txt" '
        NR == FNR { keep[$0] = 1; next }
        FNR == 1 { next }
        { d = ($7 in keep) ? "keep" : "drop"; print d "\t\t\t" $0 }
      ' "$TMP/keep_paths.txt" "$CAND"
    } > "$DEC"
  else
    # tsv mode: decisions.tsv IS the filled screen.tsv (columns re-ordered,
    # decision defaults to the agent's suggested). No join heuristics: the
    # agent edited the file scan generated, so the shape is known — the last
    # two columns are suggested/reason, and the row set is the candidate set.
    # --resume keeps a previous decisions.tsv verbatim instead.
    if [[ -n "$prev" ]]; then
      { printf 'decision\treason\tsuggested\tagent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file\n'
        cat "$prev"
      } > "$DEC"
    elif [[ -f "$OUTDIR/screen.tsv" ]]; then
      awk -F'\t' 'BEGIN{OFS="\t"}
        {
          sub(/\r$/, "")
        }
        NF > 9 {
          # a tab inside reason shifts the path right; the row is unfixable
          # without guessing — name it and fail (same policy as finalize)
          print "  ! screen.tsv row " FNR " has " NF " columns (want 9) — tab or newline inside a field?" > "/dev/stderr"
          bad = 1; next
        }
        NF == 9 {
          if (FNR == 1) { print "decision", "reason", "suggested", $1, $2, $3, $4, $5, $6, $7; next }
          # scaffold layout: $1..$7 = candidates columns, $8 = suggested,
          # $9 = reason. decisions.tsv wants decision(reason) suggested + all 7.
          d = ($8 == "keep" || $8 == "drop") ? $8 : ""
          print d, $9, $8, $1, $2, $3, $4, $5, $6, $7
          next
        }
        END { exit bad ? 1 : 0 }' "$OUTDIR/screen.tsv" > "$DEC" \
      || { echo "screen.tsv malformed — fix the rows named above" >&2; exit 1; }
      unfilled="$(awk -F'\t' 'NR>1 && $1=="" {c++} END{print c+0}' "$DEC")"
      if [[ "$unfilled" -gt 0 ]]; then
        echo "note: $unfilled row(s) have no suggested value — they arrive with an empty decision"
      fi
    else
      { printf 'decision\treason\tsuggested\tagent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file\n'
        awk -F'\t' 'FNR == 1 { next } { print "\t\t\t" $0 }' "$CAND"
      } > "$DEC"
    fi
    # sanity: reject a scaffold the agent edited into a wrong shape
    awk -F'\t' 'NR==1{want=NF; next} NF!=want{bad++; print "  ! row " FNR " has " NF " columns (want " want ")"} END{if(bad) exit 1}' "$DEC" \
      || { echo "decisions.tsv malformed — fix the rows named above" >&2; exit 1; }
    echo "wrote $DEC"
    echo "edit the decision column to keep|drop (reason is free text), then run:"
    echo "  $0 finalize -o $OUTDIR"
    # The agent-delegated path's hand-off gate: an agent reading this output
    # must present the keep/drop list to the USER before running finalize.
    # finalize itself stays silent — on the interactive path the fzf ENTER
    # was the approval, and a warning there would contradict it.
    echo
    echo "hand-off gate: the keep/drop decision belongs to the user. Show them"
    echo "this list (or offer the interactive picker / open-review.sh) and get"
    echo "their approval BEFORE running finalize. finalize without approval is"
    echo "not a completed task."
    exit 0
  fi
fi

# ============================================================== finalize
if [[ "$cmd" == finalize ]]; then
  src="${FROM:-$DEC}"
  [[ -f "$src" ]] || { echo "no decisions file: $src" >&2; exit 1; }

  header="$(awk -F'\t' 'NR==1{print NF; exit}' "$src")"
  [[ "$header" != "10" ]] && { echo "expected 10 columns in $src, got $header" >&2; exit 1; }

  KEEP="$OUTDIR/keep"; mkdir -p "$KEEP"
  # Record ABSOLUTE paths in the manifest. With a relative OUTDIR every
  # `kept_as` was relative too, so a verifier running from another directory
  # (or the `cmp` recipe the script itself prints) failed with "No such file"
  # and exit 2 — indistinguishable from a corrupt copy.
  OUTDIR_ABS="$(cd "$OUTDIR" && pwd)"
  KEEP_ABS="$OUTDIR_ABS/keep"

  # Clear previous output before materializing. Copying is additive, so a second
  # run over a different selection used to leave the earlier corpus in place —
  # `keep/` showed 12 files while the manifest listed 3, which reads as a bug and
  # could silently hand downstream analysis extra sessions the user had dropped.
  # The corpus is derived state: it must describe the current decisions exactly.
  if [[ -d "$KEEP_ABS" ]]; then
    n_old="$(find "$KEEP_ABS" -maxdepth 1 -type f | wc -l | tr -d ' ')"
    [[ "$n_old" -gt 0 ]] && echo "clearing $n_old file(s) from a previous run"
    find "$KEEP_ABS" -maxdepth 1 -type f -delete
  fi

  kept=0
  rowsfile="$(mktemp)"
  # strip CR: a human may edit the TSV in an editor that saves CRLF.
  # Re-split on \x1f (unit separator), NOT on tabs. bash `read` treats
  # space/tab/newline as collapsible IFS whitespace, so a row whose `reason`
  # and `suggested` are empty loses both fields and every later column shifts
  # left by two — which silently yielded "kept 0" here. \x1f is not IFS
  # whitespace, so empty fields survive. The TSV stays tab-delimited because
  # that is what humans edit; this is the machine-side re-split.
  sep="$(printf '\037')"
  # Sanitize HERE, in the awk pass that fixes positions: a tab inside `reason`
  # makes the row NF>10. The overflow column IS the session path, so there is
  # no way to tell "tab as content" from "tab as separator" — silently guessing
  # (merging $11 into $2) consumed the path and the session vanished from the
  # corpus with exit 0. Reject the row LOUDLY instead: the human re-edits it.
  awk -F'\t' -v sep="$sep" '
    { sub(/\r$/, "")
      if (NR > 1 && NF != 10) {
        printf "  ! row %d has %d columns (want 10) — fix the tab/newline in it: %.60s\n", NR, NF, $0 > "/dev/stderr"
        next
      }
    }
    NR > 1 && $1 == "keep" { gsub(/[\t\r\n]/, " ", $2); gsub(/[\t\r\n]/, " ", $3)
                             print $1 sep $2 sep $3 sep $4 sep $5 sep $6 sep $7 sep $8 sep $9 sep $10 }
  ' "$src" > "$rowsfile"

  # create up front: a zero-match selection must still yield an empty manifest.
  mtmp="$(mktemp)"; : > "$mtmp"

  # Provenance suffix, merged into every manifest entry below. Empty on the
  # normal gated path so the manifest is byte-identical to before; yolo stamps
  # the entries so a no-human-review run can never masquerade as a reviewed
  # one. Built via jq (`+` merges objects) because the entry is JSON:
  # printf-ing a raw fragment into the object would hand-craft JSON and break
  # on the first free-text field containing a quote. jq is probed as a hard
  # dependency by every caller; `+` on objects is in both jq and jaq.
  #
  # MUST be computed BEFORE the loop: the loop body reads it on every row, and
  # an assignment after the loop is an unbound variable under `set -u` — that
  # killed every finalize run, yolo and gated alike.
  yolo_fields=""
  if [[ $YOLO -eq 1 ]]; then
    # shellcheck disable=SC2016
    yolo_fields="$(jq -c -n '{mode:"yolo", reviewed:false, approved_by:"user-opt-out"}')"
  fi

  # size_bytes/first_prompt are fixed TSV columns read to keep positions
  # aligned; they are never used directly (re-emitted verbatim by finalize).
  # The directive must sit on the line immediately before the command.
  # shellcheck disable=SC2034
  while IFS="$sep" read -r decision reason suggested agent cwd mtime size_bytes n_lines first_prompt f; do
    # \x1f is not IFS whitespace, so a trailing CR survives into the LAST field
    # on Windows, where the TSV may carry CRLF. Strip it from every field used
    # verbatim (the path above all) rather than only from $f.
    f="${f%$'\r'}"; cwd="${cwd%$'\r'}"; agent="${agent%$'\r'}"
    # reason/suggested are agent-written free text: a stray tab shifts every
    # later column and finalize then reads first_prompt as the path (verified:
    # a tab inside reason made a kept session silently vanish from the corpus).
    # Newlines break the TSV outright. Sanitize on ingest, like first_prompt.
    reason="$(printf '%s' "$reason" | tr '\t\r\n' '   ')"
    suggested="$(printf '%s' "$suggested" | tr '\t\r\n' '   ')"
    [[ -z "$f" ]] && continue
    [[ -f "$f" ]] || { echo "  ! missing: $f" >&2; continue; }
    slug=$(printf '%s' "$cwd" | sed 's#^/##; s#/#--#g; s#[^A-Za-z0-9._-]#_#g' | cut -c1-60)
    [[ -z "$slug" ]] && slug="no-workspace"
    base=$(basename "$f")
    dest="$KEEP_ABS/${agent}--${slug}--${base}"
    # `ln -f` is BSD/GNU; coreutils-less environments need the explicit unlink.
    # `--` guards names that begin with a hyphen.
    if [[ $HARDLINK -eq 1 ]]; then
      ln -f -- "$f" "$dest" 2>/dev/null || { rm -f -- "$dest"; ln -- "$f" "$dest"; } \
        || cp -p -- "$f" "$dest"
    else
      cp -p -- "$f" "$dest"
    fi
    sha="$(sha256_of "$dest")"
    # jqd, not jq: every value below is transcript DATA. Under MSYS the plain
    # `jq` would have Git Bash rewrite `cwd`/`source` into Windows paths.
    # shellcheck disable=SC2016
    entry="$(jqd -n -c \
      --arg agent "$agent" --arg cwd "$cwd" --arg src "$f" --arg dest "$dest" \
      --arg decision "$decision" --arg reason "$reason" --arg suggested "$suggested" \
      --arg sha "$sha" --argjson size "$(stat_size "$dest")" --argjson lines "$n_lines" \
      '{agent:$agent, cwd:$cwd, source:$src, kept_as:$dest, sha256:$sha,
        bytes:$size, events:$lines, decision:$decision,
        suggested:$suggested, reason:$reason}')"
    [[ -n "$yolo_fields" ]] && entry="$(printf '%s' "$entry" | jq -c --argjson y "$yolo_fields" '. + $y')"
    printf '%s\n' "$entry" >> "$mtmp"
    kept=$((kept + 1))
  done < "$rowsfile"
  rm -f "$rowsfile"

  # Emit a real JSON array, not NDJSON, so `jq '.[0].source'` works for the
  # human. Wrapped by hand because jq on this box is jaq and `-s` support
  # cannot be assumed.
  if [[ -s "$mtmp" ]]; then
    { printf '[\n'; sed 's/$/,/' "$mtmp" | sed '$s/,$//'; printf '\n]\n'; \
    } > "$OUTDIR/manifest.json"
  else
    printf '[]\n' > "$OUTDIR/manifest.json"
  fi
  rm -f "$mtmp"

  echo "kept $kept sessions -> $KEEP"
  # No approval warning here: on the interactive path (pick / open-review.sh)
  # the fzf ENTER WAS the approval, and a "did the user approve?" note would
  # contradict it. The gate lives in SKILL.md and in review --ui tsv's
  # output — the agent-delegated path — where it is actionable.
  [[ $HARDLINK -eq 1 ]] && echo "(hardlinked)"
  if [[ $YOLO -eq 1 ]]; then
    echo "notice: NO human reviewed the selection (yolo — the user explicitly"
    echo "opted out of review; the manifest records mode=yolo, reviewed=false)."
  fi
  echo "manifest: $OUTDIR/manifest.json"
  echo
  # The pair list goes to a FILE and is read with a CR strip: `jq -r` emits
  # CRLF on Windows, and a stray CR on the path makes cmp exit 2 ("No such
  # file") — indistinguishable from a corrupt copy. A process substitution
  # (`done < <(jq …)`) would additionally block forever if backgrounded.
  echo "verify every copy is byte-identical:"
  # printf, not echo: this text contains backslash escapes, which echo would
  # interpret differently across shells.
  printf '  jq -r %s %s > /tmp/pairs.tsv\n' \
    "'.[] | \"\\(.source)\\t\\(.kept_as)\"'" "$OUTDIR/manifest.json"
  # shellcheck disable=SC2016  # ${d%...} is literal text for the reader to paste
  printf '  while IFS=$\x27\\t\x27 read -r s d; do d="${d%%$\x27\\r\x27}"; cmp -s "$s" "$d" || echo "MISMATCH $s"; done < /tmp/pairs.tsv\n'
  exit 0
fi

# ============================================================== delivery
# One archive for the buyer: OUT/keep/ + OUT/manifest.json at the archive root.
#
# Why an archive at all: the partner has to hand the result over some channel,
# and one file survives a channel that a directory does not. Why it carries the
# MANIFEST rather than a checksum of itself: a checksum proves the transfer was
# intact and says nothing about whether the contents match what was recorded.
# The per-item sha256 that `finalize` already wrote is what makes the received
# batch checkable — so the command verifies every one of them BEFORE packing
# and reads the archive back AFTER.
#
# NOT `package`: that command writes OUT/open-review.sh, a launcher for the
# human review step. Different job, earlier in the pipeline, unrelated file.
if [[ "$cmd" == delivery ]]; then
  OUTDIR_ABS="$(cd "$OUTDIR" 2>/dev/null && pwd)" \
    || { echo "delivery: no such directory: $OUTDIR" >&2; exit 1; }
  KEEP_ABS="$OUTDIR_ABS/keep"
  MAN="$OUTDIR_ABS/manifest.json"

  # ---------------------------------------------------------- refusal path
  # An archive of nothing, or of half a corpus, looks successful to whoever
  # receives it: it is a valid file with a valid checksum. Refuse instead, and
  # name the piece that is missing so the operator knows which command to
  # re-run. Every branch here exits non-zero before any file is written.
  [[ -d "$KEEP_ABS" ]] || {
    echo "delivery: nothing to package — keep/ is missing ($KEEP_ABS); run finalize first" >&2
    exit 1
  }
  [[ -f "$MAN" ]] || {
    echo "delivery: nothing to package — manifest.json is missing ($MAN); run finalize first" >&2
    exit 1
  }

  # Every regular file under keep/, as paths relative to keep/.
  # All scratch files live in $TMP: the EXIT trap set at the top already
  # removes that directory on every exit path, including the refusals below.
  keep_rel="$TMP/keep.rel"
  ( cd "$KEEP_ABS" && find . -type f ) | sed 's#^\./##' | awk 'NF' | sort > "$keep_rel"
  n_keep="$(awk 'END { print NR }' "$keep_rel")"
  [[ "$n_keep" -gt 0 ]] || {
    echo "delivery: nothing to package — keep/ contains no files ($KEEP_ABS); run finalize first" >&2
    exit 1
  }

  jq -e 'type == "array"' "$MAN" >/dev/null 2>&1 || {
    echo "delivery: $MAN is not a JSON array — refusing to package it" >&2
    exit 1
  }
  n_items="$(jq 'length' "$MAN")"
  [[ "$n_items" -gt 0 ]] || {
    echo "delivery: nothing to package — manifest.json lists 0 sessions ($MAN)" >&2
    exit 1
  }

  # ------------------------------------------------- pre-pack verification
  # Manifest -> keep/: every recorded session must be present under its own
  # recorded path AND hash to its recorded sha256. This is the check that makes
  # the archive meaningful; it runs before anything is packed, so a corrupted
  # corpus is never handed over as a file someone can trust.
  pairs="$TMP/pairs.tsv"
  jq -r '.[] | "\(.kept_as // "")\t\(.sha256 // "")"' "$MAN" > "$pairs"
  listed="$TMP/listed.txt"
  : > "$listed"
  bad=0
  while IFS=$'\t' read -r ka sha; do
    ka="${ka%$'\r'}"; sha="${sha%$'\r'}"
    if [[ -z "$ka" || -z "$sha" ]]; then
      echo "  ! manifest entry with no kept_as/sha256 — cannot be verified" >&2
      bad=$((bad + 1)); continue
    fi
    # kept_as must live under THIS keep/: a manifest pointing anywhere else
    # describes a corpus that is not the one being packed.
    case "$ka" in
      "$KEEP_ABS"/*) ;;
      *) echo "  ! outside keep/: $ka" >&2; bad=$((bad + 1)); continue ;;
    esac
    rel="${ka#"$KEEP_ABS"/}"
    if [[ ! -f "$ka" ]]; then
      echo "  ! missing from keep/: $rel" >&2; bad=$((bad + 1)); continue
    fi
    if [[ "$(sha256_of "$ka")" != "$sha" ]]; then
      echo "  ! sha256 mismatch: $rel (recorded $sha)" >&2
      bad=$((bad + 1)); continue
    fi
    printf '%s\n' "$rel" >> "$listed"
  done < "$pairs"

  # keep/ -> manifest: a file with no manifest entry would ship as a corpus
  # member nobody can check. Both directions are needed for "the received batch
  # is checkable", so both are checked.
  if [[ -s "$listed" ]]; then sort -o "$listed" "$listed"; fi
  unlisted="$(comm -23 "$keep_rel" "$listed" | awk 'NF')"
  if [[ -n "$unlisted" ]]; then
    printf '  ! in keep/ but not in the manifest:\n' >&2
    printf '%s\n' "$unlisted" | sed 's/^/      /' >&2
    bad=$((bad + $(printf '%s\n' "$unlisted" | awk 'END { print NR }')))
  fi
  [[ "$bad" -eq 0 ]] || {
    echo "delivery: $bad problem(s) in the corpus — refusing to package it" >&2
    exit 1
  }

  # --------------------------------------------------------- format choice
  # Format follows the PLATFORM, because the partner's extraction tool follows
  # theirs and we never see the receiving side. MSYS/Cygwin is Windows even
  # when the shell looks POSIX.
  case "${OSTYPE:-}" in
    msys*|cygwin*|win32) PLATFORM=windows ;;
    *)                   PLATFORM=posix ;;
  esac
  [[ -n "${MSYSTEM:-}" ]] && PLATFORM=windows
  if [[ "$PLATFORM" == windows ]]; then FMT=zip; else FMT=tar.gz; fi
  why="platform: $PLATFORM"

  # An explicit name carrying a known archive suffix OVERRIDES the platform
  # choice. Writing a tar.gz under a `.zip` name is the one way this command
  # could hand over an archive whose extension lies about its contents, and a
  # named file is exactly the case where the operator has made the choice
  # themselves — the platform rule exists for the operator who has not.
  if [[ -n "$ARCHIVE_OUT" ]]; then
    case "$ARCHIVE_OUT" in
      *.zip)          FMT=zip;    why="from --out .zip" ;;
      *.tar.gz|*.tgz) FMT=tar.gz; why="from --out .${ARCHIVE_OUT##*.}" ;;
    esac
  fi

  # ------------------------------------------------- archive writer ladder
  # The writer is probed by BEHAVIOUR, not by name, because the obvious name
  # lies: Git Bash ships GNU tar, whose `-a -cf x.zip` exits 0 and writes a
  # POSIX TAR — a `.zip` that `unzip` refuses. So each candidate is asked to
  # produce the file and the result is then checked for the format's magic
  # bytes; a candidate that produces the wrong bytes is not accepted.
  # bsdtar is the one tar that writes real zip files. Prefer the PATH copy; on
  # MSYS the Windows-bundled one is reachable through SYSTEMROOT. There is no
  # /mnt/c fallback on purpose: that is WSL reaching across to the Windows
  # side's toolchain, which is a different machine's business.
  find_zip_writer() {
    if command -v bsdtar >/dev/null 2>&1; then command -v bsdtar; return 0; fi
    local root
    if [[ -n "${SYSTEMROOT:-}" ]] && command -v cygpath >/dev/null 2>&1; then
      root="$(cygpath -u "$SYSTEMROOT" 2>/dev/null)"
      [[ -x "$root/System32/tar.exe" ]] && { printf '%s' "$root/System32/tar.exe"; return 0; }
    fi
    return 1
  }

  magic_ok() { # $1=file $2=zip|gz
    local m
    m="$(od -An -tx1 -N2 "$1" 2>/dev/null | tr -d ' \n')"
    case "$2" in
      zip) [[ "$m" == "504b" ]] ;;
      gz)  [[ "$m" == "1f8b" ]] ;;
      *)   return 1 ;;
    esac
  }

  # Pick the writer in THIS shell, before any subshell runs: the report has to
  # name the tool that produced the artifact, and an assignment made inside the
  # staging subshell would not survive to it.
  #
  # Preference order per format, each step a real tool on a real platform:
  #   zip     Info-ZIP `zip` (Windows Git Bash, most Linux distros)
  #        -> bsdtar       (the one tar that writes real zips; on MSYS it is
  #                         C:\Windows\System32\tar.exe, reached via SYSTEMROOT)
  #   tar.gz  `tar -czf`    (GNU or BSD, everywhere)
  # NOT `tar -a -c -f x.zip`, which the issue text suggested: on GNU tar 1.35
  # that exits 0 and writes a POSIX tar whose first bytes are `6b 65`, a file
  # named `.zip` that `unzip` refuses. Measured on this machine, both ways. The
  # magic-byte check below exists because that failure is silent at exit 0.
  WRITER=""; WKIND=""; ZW_BIN=""
  case "$FMT" in
    zip)
      if command -v zip >/dev/null 2>&1; then
        WKIND=zip; WRITER="zip (Info-ZIP)"
      elif ZW_BIN="$(find_zip_writer)"; then
        WKIND=bsdtar; WRITER="$ZW_BIN -a -cf (bsdtar)"
      else
        echo "delivery: no zip writer on this platform (install Info-ZIP 'zip', or take the default .tar.gz)" >&2
        exit 1
      fi ;;
    tar.gz)
      WKIND=tar
      WRITER="tar -czf ($(tar --version 2>/dev/null | awk 'NR==1 { print $1, $NF; exit }'))" ;;
  esac

  write_archive() { # $1=stage-path ; cwd MUST be the corpus root
    case "$WKIND" in
      zip)    zip -q -r -X "$1" keep manifest.json || return 1
              magic_ok "$1" zip || {
                echo "delivery: the zip writer produced a non-zip file — refusing to ship it" >&2
                return 1
              } ;;
      bsdtar) # --no-mac-metadata keeps the members to exactly what was asked for.
              "$ZW_BIN" -a --no-mac-metadata -cf "$1" keep manifest.json || return 1
              magic_ok "$1" zip || {
                echo "delivery: bsdtar produced a non-zip file — refusing to ship it" >&2
                return 1
              } ;;
      tar)    tar -czf "$1" keep manifest.json || return 1
              magic_ok "$1" gz || {
                echo "delivery: tar produced something that is not gzip — refusing to ship it" >&2
                return 1
              } ;;
    esac
  }

  # Four readers deep, because the property being checked is "this archive is
  # readable by the machine that receives it" and no single tool exists on
  # every platform: Windows Git Bash has unzip and no bsdtar, a bare Linux box
  # may have neither and only python3. Each candidate is tried in turn.
  #
  # python3 is last and is probed by EXECUTING it, not by `command -v`: on
  # Windows, `python3` in PATH is frequently the Microsoft Store app-execution
  # alias — a stub that prints "Python was not found" and exits 49. It is a
  # real file at a real path, so a presence check passes while every call
  # fails, and because the failure is on stderr a naive `| grep` would still
  # see the empty stdout as "no members". Requiring a successful no-op call
  # tells the real interpreter from the alias. Measured on this machine:
  # /c/Users/…/WindowsApps/python3 -> rc=49, "Python was not found".
  have_python3() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 -c '' >/dev/null 2>&1
  }

  zip_names() { # $1=archive
    if command -v unzip >/dev/null 2>&1; then unzip -Z1 "$1" 2>/dev/null && return 0; fi
    if command -v zipinfo >/dev/null 2>&1; then zipinfo -1 "$1" 2>/dev/null && return 0; fi
    local zw
    if zw="$(find_zip_writer)"; then "$zw" -tf "$1" 2>/dev/null && return 0; fi
    if have_python3; then
      python3 - "$1" <<'PY' && return 0
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    for name in z.namelist():
        print(name)
PY
    fi
    return 1
  }

  list_members() { # $1=archive
    case "$FMT" in
      zip)    zip_names "$1" ;;
      tar.gz) tar -tzf "$1" ;;
    esac
  }

  # ------------------------------------------------------------ name + write
  # Default name: OUT/<outdir-basename>-<date>.<fmt>. Dated because a partner
  # sends batches over time and two undated files in one channel directory
  # would be indistinguishable.
  if [[ -n "$ARCHIVE_OUT" ]]; then
    target="$ARCHIVE_OUT"
  else
    target="$OUTDIR_ABS/$(basename "$OUTDIR_ABS")-$(date +%Y%m%d).$FMT"
  fi
  tdir="$(dirname "$target")"
  tbase="$(basename "$target")"
  [[ -d "$tdir" ]] || { echo "delivery: no such directory: $tdir" >&2; exit 1; }
  target_abs="$(cd "$tdir" && pwd)/$tbase"

  # Stage under a fresh name in TMP and move into place. Two reasons, both
  # load-bearing: Info-ZIP APPENDS to an existing archive, so a re-run over the
  # same OUTDIR would carry the previous run's members forward (exactly the
  # stale-member bug this is meant not to have); and a failure mid-write must
  # never leave a half archive at the path the operator was told to send.
  stage="$TMP/delivery.$$.$FMT"
  rm -f "$stage"
  ( cd "$OUTDIR_ABS" && write_archive "$stage" ) || { rm -f "$stage"; exit 1; }
  [[ -s "$stage" ]] || { echo "delivery: archive is empty — not shipping it" >&2; rm -f "$stage"; exit 1; }

  # ------------------------------------------------- read the archive back
  # What the writer claims it did is not evidence; what a reader finds inside
  # is. Check the members against the corpus that went in: the exact file set,
  # no strays, and the manifest present.
  acts="$TMP/archive.members"
  list_members "$stage" | tr -d '\r' | awk 'NF' | sort > "$acts" \
    || { echo "delivery: cannot read back $stage" >&2; rm -f "$stage"; exit 1; }

  exp="$TMP/expected.members"
  sed 's#^#keep/#' "$keep_rel" > "$exp"
  printf '%s\n' manifest.json >> "$exp"
  sort -o "$exp" "$exp"

  # File members only: whether a writer also records the `keep/` directory
  # entry is a writer detail, not a property of the delivery.
  act_files="$TMP/archive.files"
  awk '$0 !~ /\/$/' "$acts" > "$act_files"
  n_files="$(awk 'END { print NR }' "$act_files")"
  n_exp="$(awk 'END { print NR }' "$exp")"

  rbad=0
  if [[ "$n_files" -ne "$n_exp" ]]; then
    echo "  ! archive holds $n_files file member(s), corpus has $n_exp" >&2
    rbad=$((rbad + 1))
  fi
  # Set equality, both directions, each named separately: a stray member means
  # the archive unpacks into a scatter of files rather than one directory, and
  # a missing one means the batch is incomplete. `keep/` itself is excluded
  # above, so what is compared is the file set and nothing else.
  stray="$(comm -13 "$exp" "$act_files" | awk 'NF')"
  missing="$(comm -23 "$exp" "$act_files" | awk 'NF')"
  if [[ -n "$stray" ]]; then
    echo "  ! archive members not in the corpus:" >&2
    printf '%s\n' "$stray" | sed 's/^/      /' >&2
    rbad=$((rbad + $(printf '%s\n' "$stray" | awk 'END { print NR }')))
  fi
  if [[ -n "$missing" ]]; then
    echo "  ! corpus files absent from the archive:" >&2
    printf '%s\n' "$missing" | sed 's/^/      /' >&2
    rbad=$((rbad + $(printf '%s\n' "$missing" | awk 'END { print NR }')))
  fi
  grep -Fxq -- 'manifest.json' "$act_files" || {
    echo "  ! the archive has no manifest.json — it cannot be checked against anything" >&2
    rbad=$((rbad + 1))
  }
  [[ "$rbad" -eq 0 ]] || {
    echo "delivery: the archive does not match the corpus — not shipping it" >&2
    rm -f "$stage"; exit 1
  }

  mv -f "$stage" "$target_abs" || { echo "delivery: cannot write $target_abs" >&2; rm -f "$stage"; exit 1; }

  echo "delivery: $n_keep session(s) + manifest.json"
  echo "  format:  $FMT  ($why)"
  echo "  writer:  $WRITER"
  echo "  verify:  $n_items/$n_items manifest entries present and sha256-matched"
  echo "  read back: $n_files member(s), matching the corpus exactly"
  echo "  archive: $target_abs"
  echo "  bytes:   $(stat_size "$target_abs")"
  echo "  files:   $((n_keep + 1)) ($n_keep sessions + manifest.json)"
  echo "  members:"
  list_members "$target_abs" | tr -d '\r' | awk 'NF' | sed 's/^/    /'
  exit 0
fi
