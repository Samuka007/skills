#!/usr/bin/env bash
# CRLF self-check, same design as the sibling scripts: every physical line of
# the guard ends in a comment so a CRLF-smudged install loses its CR into the
# comment instead of appending it to a shell word. Exit 3 is distinct from a
# usage error (2).
__crlf_hit=0                                                                                                            # CRLF-GUARD
if [[ -f "${BASH_SOURCE[0]}" && -r "${BASH_SOURCE[0]}" ]]; then                                                         # CRLF-GUARD
  while IFS= read -r __crlf_line || [[ -n "$__crlf_line" ]]; do                                                         # CRLF-GUARD
    if [[ "$__crlf_line" == *$'\r'* ]]; then __crlf_hit=1; break; fi                                                    # CRLF-GUARD
  done < "${BASH_SOURCE[0]}"                                                                                            # CRLF-GUARD
fi                                                                                                                      # CRLF-GUARD
if [[ "$__crlf_hit" -eq 1 ]]; then                                                                                      # CRLF-GUARD
  printf '%s\n' 'this script was installed with CRLF (Windows) line endings and cannot run under bash.' >&2             # CRLF-GUARD
  printf '%s\n' 'fix either way:' >&2                                                                                   # CRLF-GUARD
  printf '%s\n' "  dos2unix \"${BASH_SOURCE[0]}\"" >&2                                                                  # CRLF-GUARD
  printf '%s\n' '  reinstall:  npx --yes skills@latest add Samuka007/skills --skill agent-session-batch-export -g -y' >&2 # CRLF-GUARD
  exit 3                                                                                                                # CRLF-GUARD
fi                                                                                                                      # CRLF-GUARD
#
# export-direction.sh — run a direction end to end with a deterministic
# selection.
#
# WHAT MAKES THIS DIFFERENT from the interactive path in SKILL.md: no agent
# screens anything. The Python funnel decides which sessions qualify, this
# script writes that decision straight into the pipeline's own decisions.tsv,
# and no `screen.tsv` suggestion step exists. An agent invoking this may read
# the funnel table to abort on a catastrophic run, and may not edit its output.
#
# Layering (one source of truth each):
#   themes/<name>.json          every threshold and word list  (policy)
#   scripts/funnel.py           every screening stage           (mechanism)
#   scripts/curate-sessions.sh  copy, manifest, verify, archive (pipeline)
# The direction file adds only a theme list. This script restates no threshold;
# if you find a number here that a theme already carries, that is the drift the
# layering exists to prevent.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
THEMES_DIR="$SKILL_DIR/themes"
FUNNEL="$SCRIPT_DIR/funnel.py"
CURATE="$SCRIPT_DIR/curate-sessions.sh"

usage() {
  cat <<'USAGE'
Usage: export-direction.sh --direction-file FILE --out DIR [options]

Required
      --direction-file FILE   a direction JSON: metadata + a `themes` array
  -o, --out DIR               working directory for this run

Options
      --yolo                  unattended: skip the confirmation prompt. The
                              caller must already hold the user's explicit
                              opt-out; this script does not interpret prose
      --allow-credentials     export sessions carrying credential shapes
                              (recorded in the manifest). Without it, any hit
                              refuses the whole batch
      --no-delivery           stop after the manifest; write no archive

Scan filters (passed to the pipeline's scan)
  -a, --agent claude|codex|both   (default both)
  -w, --workspace SUBSTR
      --since YYYY-MM-DD
  -n, --min-lines N               drop sessions whose FILE has fewer than N
                                  lines
  -h, --help

Two length controls, and they are not the same thing
  `--min-lines` is a FILE line-count floor and nothing else. A request not to
  drop short sessions means this flag: pass 0 and every scanned file stays a
  candidate.

  Whether a session's MESSAGES are long enough is separate policy, not a flag:
  each theme carries a per-message character floor under the key
  `policy.min_user_msg_chars`, applied by the funnel's L5 length stage. No
  option of this script reaches it. When L5 kills, this run prints that theme
  key; the value itself stays in the theme file, which is the only place it
  can be changed.
USAGE
}

die() { printf 'export-direction: %s\n' "$1" >&2; exit "${2:-1}"; }

# The one funnel stage a caller can mistake for `--min-lines`: both are called
# "length", and only one of them is a flag. Its thresholds are theme policy no
# option of this script reaches, so a caller told to stop dropping short
# sessions sets `--min-lines 0`, watches L5 kill on `min_user_msg_chars`
# anyway, and has no way to tell the two controls apart: the funnel table
# reports the comparison faithfully, but a comparison is not a place a caller
# can act. What this adds is the one thing the table cannot say — which theme
# key produced the kill — and never its value, because the value is policy and
# lives in the theme file this run does not own.
l5_note() { # $1 funnel table file, $2 theme name, $3 theme file
  local table="$1" theme="$2" path="$3" killed block
  killed="$(awk '/^L[0-9]/ { l5 = ($1 == "L5") }
                l5 { for (i = 1; i < NF; i++)
                       if ($i == "killed") { n = $(i + 1); gsub(/,/, "", n); k += n } }
                END { print k + 0 }' "$table")"
  [[ "${killed:-0}" -gt 0 ]] || return 0
  # Continuation lines hang under the row, so the whole block is read: a wrapped
  # reason can push its second class onto the next line.
  block="$(awk '/^L[0-9]/ { l5 = ($1 == "L5") } l5' "$table")"
  if [[ "$block" == *"longest later user msg"* ]]; then
    printf 'note: theme %s killed %s session(s) at L5 length on the theme key\n' "$theme" "$killed"
    printf '      `min_user_msg_chars` — a per-MESSAGE character floor, in\n'
    printf '      %s\n' "$path"
    printf '      `--min-lines` floors the line count of a session FILE and cannot\n'
    printf '      reach this stage, so no value of it revives these rows; the key\n'
    printf '      above is the one to change.\n'
  fi
  if [[ "$block" == *"first user msg"* && "$block" == *"> cap"* ]]; then
    printf 'note: theme %s killed %s session(s) at L5 length on the theme key\n' "$theme" "$killed"
    printf '      `max_first_msg_chars` — the first-message cap, in\n'
    printf '      %s\n' "$path"
    printf '      Also unreachable from this command line; only the theme changes it.\n'
  fi
}

DIRECTION_FILE=""
OUTDIR=""
YOLO=0
ALLOW_CRED=0
NO_DELIVERY=0
AGENT=both
WORKSPACE=""
SINCE=""
MIN_LINES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --direction-file) [[ $# -ge 2 ]] || { usage >&2; die "--direction-file needs a path" 2; }
                      DIRECTION_FILE="$2"; shift 2 ;;
    -o|--out)         [[ $# -ge 2 ]] || { usage >&2; die "-o needs a directory" 2; }
                      OUTDIR="$2"; shift 2 ;;
    --yolo)           YOLO=1; shift ;;
    --allow-credentials) ALLOW_CRED=1; shift ;;
    --no-delivery)    NO_DELIVERY=1; shift ;;
    -a|--agent)       [[ $# -ge 2 ]] || { usage >&2; die "--agent needs a value" 2; }
                      AGENT="$2"; shift 2 ;;
    -w|--workspace)   [[ $# -ge 2 ]] || { usage >&2; die "--workspace needs a value" 2; }
                      WORKSPACE="$2"; shift 2 ;;
    --since)          [[ $# -ge 2 ]] || { usage >&2; die "--since needs a value" 2; }
                      SINCE="$2"; shift 2 ;;
    -n|--min-lines)   [[ $# -ge 2 ]] || { usage >&2; die "--min-lines needs a value" 2; }
                      MIN_LINES="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "export-direction: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$DIRECTION_FILE" ]] || { usage >&2; die "--direction-file is required" 2; }
[[ -n "$OUTDIR" ]] || { usage >&2; die "--out is required" 2; }
[[ -f "$DIRECTION_FILE" ]] || die "no such direction file: $DIRECTION_FILE" 2
[[ -f "$FUNNEL" ]] || die "the funnel engine is missing: $FUNNEL"
[[ -f "$CURATE" ]] || die "the pipeline is missing: $CURATE"

# ------------------------------------------------------------------ preflight
# Python is a PREREQUISITE, not a branch. There is no non-Python path: the
# deterministic funnel is the whole point of a direction run, and a semantic
# fallback would replace a reproducible selection with an unreproducible one.
#
# RESOLVE an interpreter rather than assuming one spelling. Measured on Windows
# after `winget install Python.Python.3.13` succeeded:
#   * `python3` and `python` in PATH are both the Microsoft Store
#     app-execution alias — a real file at a real path that exits 49 printing
#     "Python was not found", so `command -v` succeeds while every call fails;
#   * the python.org installer writes `python.exe` but NO `python3.exe`;
#   * no `py.exe` launcher exists;
#   * Git Bash's PATH gains no Python directory at all.
# So a probe of `python3` alone tells a user who did exactly what we asked that
# their Python is missing. Every candidate below is probed by EXECUTING it.
# An array, because a candidate can be two words (`py -3`) and a path can hold
# spaces; a plain string would need word splitting that also splits the path.
PY_CMD=()
py_ok() { "$@" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; }

# The override is read FIRST, before discovery and before any failure exit. It
# used to sit after the exit, which made the one escape hatch unreachable in
# exactly the case it exists for — and the error message named it, so the
# instruction could not be followed. Same defect class as item 22.
if [[ -n "${SESSION_EXPORT_PYTHON:-}" ]]; then
  py_ok "$SESSION_EXPORT_PYTHON" \
    || die "SESSION_EXPORT_PYTHON is set to '$SESSION_EXPORT_PYTHON', which does not run as Python 3.9+"
  PY_CMD=("$SESSION_EXPORT_PYTHON")
fi
if [[ "${#PY_CMD[@]}" -eq 0 ]]; then
  for cand in python3 python py; do
    command -v "$cand" >/dev/null 2>&1 || continue
    if [[ "$cand" == py ]]; then
      py_ok "$cand" -3 && { PY_CMD=("$cand" -3); break; }
    else
      py_ok "$cand" && { PY_CMD=("$cand"); break; }
    fi
  done
fi
if [[ "${#PY_CMD[@]}" -eq 0 ]]; then
  # Standard per-user and system install roots the Windows installers use. The
  # newest is taken first so a machine with several keeps the current one.
  # Every variable carries a default: `set -u` is on, and LOCALAPPDATA does not
  # exist off Windows, so a bare expansion would abort with "unbound variable"
  # instead of reaching the actionable message below.
  for c in \
    "${LOCALAPPDATA:-/nonexistent}/Programs/Python"/Python3*/python.exe \
    "${USERPROFILE:-$HOME}/AppData/Local/Programs/Python"/Python3*/python.exe \
    /c/Users/*/AppData/Local/Programs/Python/Python3*/python.exe \
    /c/Python3*/python.exe \
    "${HOME:-/nonexistent}/scoop/apps/python/current/python.exe"
  do
    [[ -x "$c" ]] || continue
    py_ok "$c" && PY_CMD=("$c")
  done
fi
if [[ "${#PY_CMD[@]}" -eq 0 ]]; then
  {
    echo "export-direction: no usable Python 3.9+ found."
    echo
    echo "  the deterministic funnel is Python. There is no fallback: selecting"
    echo "  sessions any other way would not be reproducible by the recipient."
    echo
    echo "  tried, by running each one: python3, python, py -3, and the standard"
    echo "  Windows install roots. On Windows the python3 in PATH is usually the"
    echo "  Microsoft Store alias stub rather than an interpreter."
    echo
    echo "      scoop install python          # verified: provides python3"
    echo "      winget install Python.Python.3.13"
    echo
    echo "  scoop shims both python and python3 and is on this script's probe"
    echo "  list. The winget installer writes python.exe but no python3.exe and"
    echo "  does not add itself to Git Bash's PATH, so after it either reopen"
    echo "  the shell (this script finds the install directory itself) or point"
    echo "  it at the interpreter directly:"
    echo
    echo "      SESSION_EXPORT_PYTHON=/c/path/to/python.exe $0 …"
  } >&2
  exit 1
fi
echo "python:    ${PY_CMD[*]}"

JQ="$(command -v jq || command -v jaq || true)"
[[ -n "$JQ" ]] || {
  {
    echo "export-direction: no JSON tool on PATH (looked for jq, then jaq)."
    echo "  reading the direction file and stamping the manifest both need one."
    echo "  Windows Git Bash:  scoop install jq   (or: winget install jqlang.jq)"
  } >&2
  exit 1
}

# Windows-native jq writes CRLF on stdout even when its input is LF-clean.
# Measured on this machine: direction.json and every theme file report a CR
# count of 0, yet `jq -r '.themes[]'` under scoop's jq-1.8.2 returns each name
# with a trailing \r. That turned a theme name into `translation\r`, and the
# path built from it does not exist — so the runner reported the shipped theme
# as missing on a correct installation.
#
# Stripped at ONE chokepoint rather than at each call site: there are ten reads,
# and a fix repeated ten times is a fix the eleventh reader forgets. Raw CR
# bytes cannot be significant here — a CR inside a JSON string arrives escaped
# as the two characters \r, not as a CR byte.
jqr() { "$JQ" "$@" | tr -d '\r'; }

# ------------------------------------------------------------------ direction
DIR_NAME="$(jqr -r '.direction // empty' "$DIRECTION_FILE")"
DIR_SKILL="$(jqr -r '.skill // empty' "$DIRECTION_FILE")"
THEME_NAMES="$(jqr -r '.themes // [] | .[]' "$DIRECTION_FILE" | tr '\n' ' ')"
THEME_NAMES="${THEME_NAMES% }"
[[ -n "$THEME_NAMES" ]] || die "direction file lists no themes: $DIRECTION_FILE" 2

# A direction names themes; it must not carry thresholds. Catching this here is
# what keeps a second copy of a number from appearing in a direction bundle.
stray="$(jqr -r '[paths(scalars) | join(".")] | map(select(test("policy|threshold|keyword|min_|max_|_ratio"))) | .[]' "$DIRECTION_FILE" 2>/dev/null || true)"
[[ -z "$stray" ]] || die "direction file carries policy keys, which belong in a theme: $(echo "$stray" | tr '\n' ' ')" 2

for t in $THEME_NAMES; do
  [[ -f "$THEMES_DIR/$t.json" ]] || die "direction names theme '$t', but $THEMES_DIR/$t.json does not exist" 2
done

echo "direction: ${DIR_NAME:-<unnamed>}${DIR_SKILL:+  (skill: $DIR_SKILL)}"
echo "themes:    $THEME_NAMES"
echo "out:       $OUTDIR"
echo

# Scratch first: an aborted or refused run must leave nothing behind, so OUTDIR
# is not created until the selection is settled and confirmed.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/export-direction.XXXXXX")" || die "cannot create a scratch directory"
cleanup() { [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

# ----------------------------------------------------------------- 1. scan
echo "== scan =="
scan_args=(scan -o "$TMP" --agent "$AGENT" --min-lines "$MIN_LINES")
[[ -n "$WORKSPACE" ]] && scan_args+=(--workspace "$WORKSPACE")
[[ -n "$SINCE" ]] && scan_args+=(--since "$SINCE")
bash "$CURATE" "${scan_args[@]}" || die "scan failed"
CAND="$TMP/candidates.tsv"
[[ -f "$CAND" ]] || die "scan wrote no candidates.tsv"
scanned="$(($(wc -l < "$CAND") - 1))"

# --------------------------------------------------- 2. per-theme funnel runs
# One funnel run per theme, each reading that theme's file for every threshold.
# A report-only theme is COUNTED and never contributes to the union: its keyword
# list is empty, so its topic stage passes everything, and folding it in would
# select the entire scan under a theme that exists only to report counters.
mkdir -p "$TMP/.direction"
counts="$TMP/.direction/counts.tsv"
thememap="$TMP/.direction/thememap.tsv"
: > "$counts"
: > "$thememap"

for t in $THEME_NAMES; do
  tf="$THEMES_DIR/$t.json"
  ro="$(jqr -r '.report_only // false' "$tf")"
  if [[ "$ro" == "true" ]]; then
    echo "== theme: $t (report-only — counted, never selected) =="
    printf '%s\t%s\t%s\n' "$t" "n/a" "1" >> "$counts"
    continue
  fi
  echo "== theme: $t =="
  surv="$TMP/.direction/$t.survivors.tsv"
  # The table is tee'd so the run can still name the theme key behind an L5
  # kill below it; the copy lives outside `.direction/`, which is copied into
  # the delivered run directory, so the corpus gains no new artifact.
  ftab="$TMP/funnel-$t.txt"
  "${PY_CMD[@]}" "$FUNNEL" run "$CAND" "$surv" --policy "$tf" | tee "$ftab" \
    || die "the funnel failed on theme $t"
  l5_note "$ftab" "$t" "$tf"
  n="$(($(wc -l < "$surv") - 1))"
  printf '%s\t%s\t%s\n' "$t" "$n" "0" >> "$counts"
  awk -v t="$t" -F'\t' 'NR > 1 && $NF != "" { print $NF "\t" t }' "$surv" >> "$thememap"
done

# Union in scan order, with each session's qualifying themes joined.
LC_ALL=C sort -o "$thememap" "$thememap"
awk -F'\t' '{ if ($1 == prev) { out = out "," $2; next }
              if (prev != "") print prev "\t" out
              prev = $1; out = $2 }
            END { if (prev != "") print prev "\t" out }' "$thememap" > "$thememap.merged"
mv "$thememap.merged" "$thememap"
awk -F'\t' '{ print $1 }' "$thememap" > "$TMP/.direction/union"
qualified="$(awk 'END { print NR + 0 }' "$TMP/.direction/union")"

# ------------------------------------------------------------ 3. credentials
# The scanner is the funnel's L8 stage; `enrich` is how its per-session columns
# are read back. One implementation, and the policy decision (refuse or record)
# lives here where --allow-credentials is.
#
# This is disclosure and determinism, NOT a security boundary. An agent that
# rewrites its own artifacts is not stopped by it, and nothing here should be
# read as claiming otherwise.
cred_hits=0
cred_kinds=""
if [[ "$qualified" -gt 0 ]]; then
  union_cand="$TMP/.direction/union-candidates.tsv"
  awk -F'\t' 'NR == FNR { if ($1 != "") U[$1] = 1; next }
              FNR == 1 { print; next }
              ($NF in U)' "$TMP/.direction/union" "$CAND" > "$union_cand"
  enr="$TMP/.direction/union-enriched.tsv"
  "${PY_CMD[@]}" "$FUNNEL" enrich "$union_cand" "$enr" >/dev/null || die "enrich failed over the union"
  cred_hits="$(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
                           h["credential_hit"] && $h["credential_hit"] == "1" { n++ }
                           END { print n + 0 }' "$enr")"
  cred_kinds="$(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) h[$i] = i; next }
                            h["credential_kinds"] && $h["credential_kinds"] != "" { print $h["credential_kinds"] }' "$enr" \
                | tr ',' '\n' | LC_ALL=C sort -u | tr '\n' ',')"
  cred_kinds="${cred_kinds%,}"
fi

# ------------------------------------------------------- 4. pre-export report
echo
echo "this direction qualifies $qualified session(s) from $scanned scanned:"
while IFS="$(printf '\t')" read -r t n ro; do
  if [[ "$ro" == "1" ]]; then
    printf '  %-16s n/a  (report-only)\n' "$t"
  else
    printf '  %-16s %s\n' "$t" "$n"
  fi
done < "$counts"
if [[ "$cred_hits" -gt 0 ]]; then
  echo "credentials: $cred_hits qualifying session(s) carry credential shapes ($cred_kinds)"
else
  echo "credentials: none in the qualifying sessions"
fi

# ------------------------------------------------------- 5. credential gate
if [[ "$cred_hits" -gt 0 && "$ALLOW_CRED" -eq 0 ]]; then
  {
    echo
    echo "export-direction: refusing the batch — $cred_hits session(s) carry credential shapes."
    echo "  these are your own machine's history and may hold your keys."
    echo "  re-run with --allow-credentials to export them anyway (recorded in the"
    echo "  manifest), or use the interactive review path where flagged rows arrive"
    echo "  unselected. Redaction is not offered: it would break byte-identity."
    echo "  nothing was written."
  } >&2
  exit 3
fi
[[ "$cred_hits" -gt 0 ]] && \
  echo "warning: $cred_hits session(s) with credential shapes WILL be exported (--allow-credentials)"

if [[ "$qualified" -eq 0 ]]; then
  echo
  echo "0 sessions qualify — nothing to export. No directory was written."
  exit 0
fi

# ------------------------------------------------------- 6. confirmation
if [[ "$YOLO" -eq 1 ]]; then
  echo "confirmation skipped (--yolo)"
else
  printf 'export these %s session(s)? [y/N] ' "$qualified"
  ans=""
  if ! read -r ans; then
    echo
    die "no answer on stdin — pass --yolo for an unattended run"
  fi
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "aborted at the confirmation prompt — nothing was exported."; exit 0 ;;
  esac
fi
echo

# ------------------------------------------- 7. install the funnel's decision
# The funnel's survivors ARE the decision: decisions.tsv is written straight
# from them with decision=keep, and no screen.tsv suggestion step exists. This
# is the difference between the direction path and the interactive one — there
# is no row for an agent to fill, so there is none for it to get wrong.
OUTDIR_ABS="$(mkdir -p "$OUTDIR" && cd "$OUTDIR" && pwd)"
cp "$CAND" "$OUTDIR_ABS/candidates.full.tsv"
awk -F'\t' 'NR == FNR { if ($1 != "") U[$1] = 1; next }
            FNR == 1 { print; next }
            ($NF in U)' "$TMP/.direction/union" "$OUTDIR_ABS/candidates.full.tsv" \
  > "$OUTDIR_ABS/candidates.tsv"

cred_note="credential shapes present (exported: --allow-credentials)"
# decisions.tsv layout, straight from `review --ui tsv` (curate-sessions.sh:520):
#   decision  reason  suggested  agent cwd mtime size_bytes n_lines first_prompt session_file
# Ten columns, and the three verdict columns come FIRST. `suggested` carries the
# same value as `decision` here on purpose: on this path the funnel's survivor
# set IS both the recommendation and the decision, so a differing pair would
# imply a screening step that does not exist.
awk -F'\t' -v ck="$TMP/.direction/union-enriched.tsv" -v msg="$cred_note" '
  BEGIN {
    OFS = "\t"
    while ((getline l < ck) > 0) {
      nf = split(l, a, "\t")
      if (++ln == 1) { for (i = 1; i <= nf; i++) H[a[i]] = i; continue }
      if (H["credential_hit"] && a[H["credential_hit"]] == "1") C[a[H["session_file"]]] = 1
    }
  }
  NR == 1 { print "decision", "reason", "suggested", $1, $2, $3, $4, $5, $6, $7; next }
  { r = "selected by the funnel"; if ($NF in C) r = r " - " msg
    print "keep", r, "keep", $1, $2, $3, $4, $5, $6, $7 }
' "$OUTDIR_ABS/candidates.tsv" > "$OUTDIR_ABS/decisions.tsv"

cp -R "$TMP/.direction" "$OUTDIR_ABS/.direction"
echo "selection installed: $qualified session(s) chosen by the funnel"
echo "  (decisions.tsv written from the funnel's survivors; no screening step)"
echo

# ------------------------------------------------------------- 8. materialize
echo "== finalize =="
# --yolo stamps mode=yolo / reviewed=false, which is the truth on this path in
# both cases: no human ever reviewed individual rows. A confirmation answered
# `y` approved the BATCH, and that is recorded separately below.
bash "$CURATE" finalize -o "$OUTDIR_ABS" --yolo || die "finalize failed"

MANIFEST="$OUTDIR_ABS/manifest.json"
[[ -f "$MANIFEST" ]] || die "no manifest after finalize"
kept="$(jqr 'length' "$MANIFEST")"
[[ "$kept" -gt 0 ]] || die "finalize kept nothing despite $qualified qualifying sessions"

# ------------------------------------------- 9. direction fields per entry
theme_counts="$(jqr -n '{}')"
while IFS="$(printf '\t')" read -r t n ro; do
  if [[ "$ro" == "1" ]]; then v=null; else v="$n"; fi
  theme_counts="$(jqr -nc --argjson a "$theme_counts" --arg k "$t" --argjson v "$v" '$a + {($k): $v}')"
done < "$counts"

dir_obj="$(jqr -nc \
  --arg dir "$DIR_NAME" --arg skill "$DIR_SKILL" \
  --argjson tc "$theme_counts" \
  --argjson allow "$ALLOW_CRED" --argjson hits "$cred_hits" \
  --argjson conf "$([[ "$YOLO" -eq 1 ]] && echo 0 || echo 1)" \
  --argjson scanned "$scanned" \
  '{direction: (if $dir == "" then null else $dir end),
    direction_skill: (if $skill == "" then null else $skill end),
    selection: "funnel-deterministic",
    batch_confirmed: ($conf == 1),
    scanned: $scanned,
    theme_counts: $tc,
    allow_credentials: ($allow == 1),
    credential_hits: $hits}')"

jqr --argjson d "$dir_obj" --rawfile tm "$thememap" '
  ($tm | split("\n") | map(select(length > 0)) | map(split("\t"))
       | map({ key: .[0], value: (.[1] | split(",")) }) | from_entries) as $m
  | map(. + $d + { themes: ($m[.source] // []) })
' "$MANIFEST" > "$MANIFEST.tmp" || die "manifest merge failed — $MANIFEST left untouched"
mv "$MANIFEST.tmp" "$MANIFEST"
echo "manifest: direction fields merged into $kept entr$([[ "$kept" -eq 1 ]] && echo y || echo ies)"

# ---------------------------------------------------------------- 10. delivery
if [[ "$NO_DELIVERY" -eq 0 ]]; then
  echo
  echo "== delivery =="
  bash "$CURATE" delivery -o "$OUTDIR_ABS" || die "delivery failed"
fi

echo
echo "export-direction: done"
echo "  out:      $OUTDIR_ABS"
echo "  manifest: $MANIFEST"
