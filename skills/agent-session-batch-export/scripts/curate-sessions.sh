#!/usr/bin/env bash
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

usage() {
  cat <<'USAGE'
Usage: curate-sessions.sh <command> [options]

Commands
  scan        enumerate candidate sessions -> OUT/candidates.tsv
  review      human keep/drop pass        -> OUT/decisions.tsv
  finalize    materialize kept raw JSONL  -> OUT/keep/ + OUT/manifest.json
  validate    sanity-check a candidates/decisions TSV (column shape)

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
      --hardlink        hardlink instead of copy (read-only analysis only:
                        a downstream writer would corrupt the original)
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
    -o|--out)       OUTDIR="$2"; shift 2 ;;
    --ui)           UI="$2"; shift 2 ;;
    --resume)       RESUME=1; shift ;;
    --from)         FROM="$2"; shift 2 ;;
    --hardlink)     HARDLINK=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

for dep in jq rg find awk sed grep sort cut mktemp; do
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
  scan|review|finalize|validate) ;;
  ""|-h|--help) usage; exit 0 ;;
  *) echo "unknown command: $cmd" >&2; usage; exit 2 ;;
esac

CAND="$OUTDIR/candidates.tsv"
DEC="$OUTDIR/decisions.tsv"
mkdir -p "$OUTDIR"

# ============================================================== scan
if [[ "$cmd" == scan ]]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

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
          mtime="$(stat_pair "$f")"; mtime="${mtime#* }"
          printf '%s\t%s\t%s\t%s\n' "$1" "$cwd" "$mtime" "$f"
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
    NF >= 4 {
      if (w != "" && index($2, w) == 0) next
      if (since_e + 0 > 0 && ($3 + 0) < since_e + 0) next
      print
    }' "$TMP/all.tsv" > "$TMP/f1.tsv"

  header=$'agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file'
  printf '%s\n' "$header" > "$CAND"

  n=0
  while IFS=$'\t' read -r agent cwd mtime f; do
    size=$(stat_size "$f")
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
  echo
  echo "next: hand this file to the agent for topic screening (it adds"
  echo "      'suggested' and 'reason' columns), then run: $0 review -o $OUTDIR"
  exit 0
fi

# ============================================================== validate
if [[ "$cmd" == validate ]]; then
  src="${FROM:-$CAND}"
  [[ -f "$src" ]] || { echo "no such file: $src" >&2; exit 1; }
  echo "== $src =="
  # candidates.tsv is 7 cols; decisions.tsv is 10 (it embeds the candidate cols
  # behind decision/reason/suggested). Judge by the header, not a hardcoded n.
  awk -F'\t' '
    NR == 1 {
      print "columns(" NF "): " $0
      want = ($1 == "decision") ? 10 : 7
      print "expected cols: " want
      next
    }
    NF != want { bad++ }
    END { if (bad) print "MALFORMED rows (expected " want " cols): " bad
          else     print "shape ok (" want " cols)" }' "$src"
  awk -F'\t' 'NR==1{ for(i=1;i<=NF;i++) h[$i]=i; next }
              { if ("decision" in h) { d=$h["decision"]; if (d!="") c[d]++ } }
              END { for (k in c) printf "decision=%s: %d\n", k, c[k] }' "$src"
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
    export CAND PREVIEW_PROSE="$TMP/preview_prose"
    cat > "$TMP/preview.sh" <<'PEOF'
#!/usr/bin/env bash
f="$(printf '%s' "$FZF_PROMPT" | true)"
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
    # tsv mode: emit decisions.tsv with a blank decision column for hand-editing
    { printf 'decision\treason\tsuggested\tagent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file\n'
      if [[ -n "$prev" ]]; then cat "$prev"; else
        awk -F'\t' 'FNR == 1 { next } { print "\t\t\t" $0 }' "$CAND"
      fi
    } > "$DEC"
    echo "wrote $DEC"
    echo "edit the decision column to keep|drop (reason is free text), then run:"
    echo "  $0 finalize -o $OUTDIR"
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
  awk -F'\t' -v sep="$sep" '
    { sub(/\r$/, "") }
    NR > 1 && $1 == "keep" { print $1 sep $2 sep $3 sep $4 sep $5 sep $6 sep $7 sep $8 sep $9 sep $10 }
  ' "$src" > "$rowsfile"

  # create up front: a zero-match selection must still yield an empty manifest.
  mtmp="$(mktemp)"; : > "$mtmp"

  # size_bytes/first_prompt are fixed TSV columns read to keep positions
  # aligned; they are never used directly (re-emitted verbatim by finalize).
  # The directive must sit on the line immediately before the command.
  # shellcheck disable=SC2034
  while IFS="$sep" read -r decision reason suggested agent cwd mtime size_bytes n_lines first_prompt f; do
    # \x1f is not IFS whitespace, so a trailing CR survives into the LAST field
    # on Windows, where the TSV may carry CRLF. Strip it from every field used
    # verbatim (the path above all) rather than only from $f.
    f="${f%$'\r'}"; cwd="${cwd%$'\r'}"; agent="${agent%$'\r'}"
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
    # shasum ships with macOS; sha256sum with GNU and Git Bash. Probe once.
    if [[ -z "${SHA_CMD:-}" ]]; then
      if command -v sha256sum >/dev/null; then SHA_CMD="sha256sum"
      elif command -v shasum  >/dev/null; then SHA_CMD="shasum -a 256"
      else SHA_CMD=""; fi
    fi
    if [[ -n "$SHA_CMD" ]]; then
      sha=$($SHA_CMD "$dest" | cut -d" " -f1)
    else
      sha="unavailable-no-sha256-tool"
    fi
    # jqd, not jq: every value below is transcript DATA. Under MSYS the plain
    # `jq` would have Git Bash rewrite `cwd`/`source` into Windows paths.
    # shellcheck disable=SC2016
    printf '%s\n' "$(jqd -n -c \
      --arg agent "$agent" --arg cwd "$cwd" --arg src "$f" --arg dest "$dest" \
      --arg decision "$decision" --arg reason "$reason" --arg suggested "$suggested" \
      --arg sha "$sha" --argjson size "$(stat_size "$dest")" --argjson lines "$n_lines" \
      '{agent:$agent, cwd:$cwd, source:$src, kept_as:$dest, sha256:$sha,
        bytes:$size, events:$lines, decision:$decision,
        suggested:$suggested, reason:$reason}')" >> "$mtmp"
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
  [[ $HARDLINK -eq 1 ]] && echo "(hardlinked)"
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
