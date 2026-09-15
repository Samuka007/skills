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
  -n, --min-lines N
  -h, --help
USAGE
}

die() { printf 'export-direction: %s\n' "$1" >&2; exit "${2:-1}"; }

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
# Probe by EXECUTING. On Windows `python3` in PATH is frequently the Microsoft
# Store app-execution alias: a real file at a real path that exits 49 printing
# "Python was not found", so `command -v` succeeds while every call fails.
# Measured on this machine: python3 and python are both that stub, py is absent.
if ! python3 -c '' >/dev/null 2>&1; then
  {
    echo "export-direction: python3 on PATH cannot run (it must satisfy: python3 -c '')."
    echo
    echo "  the deterministic funnel is Python. There is no fallback: selecting"
    echo "  sessions any other way would not be reproducible by the recipient."
    echo
    echo "  on Windows, python3 in PATH is usually the Microsoft Store alias stub"
    echo "  rather than an interpreter. Install real Python and reopen the shell:"
    echo
    echo "      winget install Python.Python.3.13"
    echo
    echo "  then re-run this command."
  } >&2
  exit 1
fi

JQ="$(command -v jq || command -v jaq || true)"
[[ -n "$JQ" ]] || {
  {
    echo "export-direction: no JSON tool on PATH (looked for jq, then jaq)."
    echo "  reading the direction file and stamping the manifest both need one."
    echo "  Windows Git Bash:  scoop install jq   (or: winget install jqlang.jq)"
  } >&2
  exit 1
}

# ------------------------------------------------------------------ direction
DIR_NAME="$("$JQ" -r '.direction // empty' "$DIRECTION_FILE")"
DIR_SKILL="$("$JQ" -r '.skill // empty' "$DIRECTION_FILE")"
THEME_NAMES="$("$JQ" -r '.themes // [] | .[]' "$DIRECTION_FILE" | tr '\n' ' ')"
THEME_NAMES="${THEME_NAMES% }"
[[ -n "$THEME_NAMES" ]] || die "direction file lists no themes: $DIRECTION_FILE" 2

# A direction names themes; it must not carry thresholds. Catching this here is
# what keeps a second copy of a number from appearing in a direction bundle.
stray="$("$JQ" -r '[paths(scalars) | join(".")] | map(select(test("policy|threshold|keyword|min_|max_|_ratio"))) | .[]' "$DIRECTION_FILE" 2>/dev/null || true)"
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
  ro="$("$JQ" -r '.report_only // false' "$tf")"
  if [[ "$ro" == "true" ]]; then
    echo "== theme: $t (report-only — counted, never selected) =="
    printf '%s\t%s\t%s\n' "$t" "n/a" "1" >> "$counts"
    continue
  fi
  echo "== theme: $t =="
  surv="$TMP/.direction/$t.survivors.tsv"
  python3 "$FUNNEL" run "$CAND" "$surv" --policy "$tf" || die "the funnel failed on theme $t"
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
  python3 "$FUNNEL" enrich "$union_cand" "$enr" >/dev/null || die "enrich failed over the union"
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
kept="$("$JQ" 'length' "$MANIFEST")"
[[ "$kept" -gt 0 ]] || die "finalize kept nothing despite $qualified qualifying sessions"

# ------------------------------------------- 9. direction fields per entry
theme_counts="$("$JQ" -n '{}')"
while IFS="$(printf '\t')" read -r t n ro; do
  if [[ "$ro" == "1" ]]; then v=null; else v="$n"; fi
  theme_counts="$("$JQ" -nc --argjson a "$theme_counts" --arg k "$t" --argjson v "$v" '$a + {($k): $v}')"
done < "$counts"

dir_obj="$("$JQ" -nc \
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

"$JQ" --argjson d "$dir_obj" --rawfile tm "$thememap" '
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
