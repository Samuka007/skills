#!/usr/bin/env bash
# CRLF self-check, same design as the sibling skill scripts: every physical
# line of the guard ends in a comment so a CRLF-smudged install loses its CR
# into the comment instead of appending it to a word; exit 3 (distinct from
# usage errors, exit 2).
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
  printf '%s\n' '  reinstall:  npx --yes skills@latest add Samuka007/skills --skill trajectory-packs -g -y' >&2        # CRLF-GUARD
  exit 3                                                                                                               # CRLF-GUARD
fi                                                                                                                     # CRLF-GUARD
# pack-export.sh — expand a buy-side pack into trajectory-funnel parameters and
# drive the existing pipeline end to end.
#
# This script is the DRIVER layer of the trajectory-pack family (DESIGN.md):
# it reads a pack file, resolves every threshold from it (never restating a
# number the pack already carries), and calls the two sibling skills —
#   trajectory-funnel          owns every screening stage (it judges sessions)
#   agent-session-batch-export owns scan/pick/finalize/delivery (it copies,
#                              manifests, verifies, archives)
# The driver screens nothing and copies nothing. A second implementation of
# either is the drift the layering exists to prevent.
#
# Flow:
#   1. resolve engines (both sibling skills must be installed)
#   2. resolve the pack: a direction pack, or named theme packs
#   3. scan (engine) -> per-theme funnel runs (engine) -> per-theme counts
#   4. credential scan over the qualifying set
#   5. pre-export report + confirmation (skipped by -y / --yolo)
#   6. selection installed into the pipeline's own candidates/screen contract
#   7. pick/finalize (engine), pack fields merged into the manifest, delivery
set -uo pipefail

PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # the trajectory-packs skill dir (holds packs/)
PACKS="$PACK_DIR/packs"

INSTALL_CMD='npx skills add Samuka007/skills \
  --skill trajectory-packs --skill trajectory-funnel \
  --skill agent-session-batch-export -g -y'

usage() {
  cat <<'USAGE'
Usage: pack-export.sh (--direction NAME | --theme NAME [--theme NAME ...]) [options]

Pack selection (exactly one form)
  --direction NAME     a file in packs/directions/<NAME>.json — every theme it lists
  --theme NAME         a file in packs/themes/<NAME>.json — repeat for several
                       (--direction and --theme together are a usage error)

Options
  -o, --out DIR        working directory for the run (default ./pack-export-<pack>-<date>)
  -y, --yes            skip the pre-export confirmation prompt
      --yolo           unattended: no picker, export the pack's selection as-is
      --allow-credentials  export sessions that match the credential pattern
                       (unattended runs refuse without it when hits exist)

Scan filters (passed through to the pipeline's scan)
  -a, --agent claude|codex|both   (default both)
  -w, --workspace SUBSTR
      --since YYYY-MM-DD
  -n, --min-lines N
  -h, --help
USAGE
}

die() { printf 'pack-export: %s\n' "$1" >&2; exit "${2:-1}"; }

# ---------------------------------------------------------------- arguments
DIRECTION=""
THEMES=""
OUTDIR=""
YES=0
YOLO=0
ALLOW_CRED=0
AGENT=both
WORKSPACE=""
SINCE=""
MIN_LINES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --direction)      [[ $# -ge 2 ]] || { usage >&2; die "--direction needs a name" 2; }
                      DIRECTION="$2"; shift 2 ;;
    --theme)          [[ $# -ge 2 ]] || { usage >&2; die "--theme needs a name" 2; }
                      THEMES="${THEMES:+$THEMES }$2"; shift 2 ;;
    -o|--out)         [[ $# -ge 2 ]] || { usage >&2; die "-o needs a directory" 2; }
                      OUTDIR="$2"; shift 2 ;;
    -y|--yes)         YES=1; shift ;;
    --yolo)           YOLO=1; shift ;;
    --allow-credentials) ALLOW_CRED=1; shift ;;
    -a|--agent)       [[ $# -ge 2 ]] || { usage >&2; die "--agent needs a value" 2; }
                      AGENT="$2"; shift 2 ;;
    -w|--workspace)   [[ $# -ge 2 ]] || { usage >&2; die "--workspace needs a value" 2; }
                      WORKSPACE="$2"; shift 2 ;;
    --since)          [[ $# -ge 2 ]] || { usage >&2; die "--since needs a value" 2; }
                      SINCE="$2"; shift 2 ;;
    -n|--min-lines)   [[ $# -ge 2 ]] || { usage >&2; die "--min-lines needs a value" 2; }
                      MIN_LINES="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "pack-export: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$DIRECTION" && -n "$THEMES" ]] && { usage >&2; die "--direction with --theme is a usage error: name one direction, or one or more themes, not both" 2; }
[[ -z "$DIRECTION" && -z "$THEMES" ]] && { usage >&2; die "name a pack: --direction <name> or --theme <name>" 2; }

# ------------------------------------------------------------------ engines
# A missing engine must never surface as a confusing downstream failure:
# locate both sibling skills up front, and refuse with the one install
# command that provides all three. Search the sibling of this skill's
# directory first (repo checkout or a skills-CLI install layout), then the
# standard per-user install roots, then the project-local install roots.
FUNNEL=""
ENGINE_DIR=""
for root in "$PACK_DIR/.." "$HOME/.agents/skills" "$HOME/.claude/skills" "$PWD/.agents/skills" "$PWD/.claude/skills"; do
  [[ -z "$FUNNEL" && -f "$root/trajectory-funnel/scripts/funnel.py" ]] && FUNNEL="$root/trajectory-funnel/scripts/funnel.py"
  [[ -z "$ENGINE_DIR" && -f "$root/agent-session-batch-export/scripts/curate-sessions.sh" ]] && ENGINE_DIR="$root/agent-session-batch-export/scripts"
done
if [[ -z "$FUNNEL" || -z "$ENGINE_DIR" || ! -f "$ENGINE_DIR/pick-sessions.sh" ]]; then
  {
    echo "pack-export: a required engine skill is missing:"
    [[ -z "$FUNNEL" ]] && echo "  - trajectory-funnel (scripts/funnel.py)"
    [[ -z "$ENGINE_DIR" ]] && echo "  - agent-session-batch-export (scripts/curate-sessions.sh)"
    [[ -n "$ENGINE_DIR" && ! -f "$ENGINE_DIR/pick-sessions.sh" ]] && echo "  - agent-session-batch-export (scripts/pick-sessions.sh)"
    echo "install all three skills in one command:"
    printf '  %s\n' "$INSTALL_CMD"
  } >&2
  exit 1
fi
CURATE="$ENGINE_DIR/curate-sessions.sh"
PICK="$ENGINE_DIR/pick-sessions.sh"

# JSON reading: the funnel and the pipeline both require jq; resolve the name
# once. Refuse at startup rather than degrade silently halfway through a run.
JQ="$(command -v jq || command -v jaq || true)"
[[ -z "$JQ" ]] && {
  {
    echo "pack-export: no JSON tool on PATH (looked for jq, then jaq)."
    echo "  jq is required by the funnel and the pipeline to read pack files."
    echo "  the three skills install in one command:"
    printf '  %s\n' "$INSTALL_CMD"
  } >&2
  exit 1
}

# The funnel engine is Python. On Windows, `python3` in PATH is frequently the
# Microsoft Store app-execution alias: a real file that exits 49 printing
# "Python was not found", so a presence check passes while every call fails.
# Probe by EXECUTING it — the same shape delivery's reader ladder uses.
if ! python3 -c '' >/dev/null 2>&1; then
  {
    echo "pack-export: python3 on PATH is not usable (it must run 'python3 -c \"\"')."
    echo "  on Windows this is usually the Microsoft Store alias stub, not Python."
    echo "  install Python 3 and retry; the funnel engine needs it."
  } >&2
  exit 1
fi

# ------------------------------------------------------------------ the pack
# Threshold keys the funnel can express, in print order. Any other key in a
# pack's defaults/overrides is either a known-unenforced key (reported, never
# silently applied) or a key this driver does not understand (refused — a
# typo'd threshold must not pass silently, and a new threshold is a driver
# edit by design, DESIGN.md).
KNOWN_KEYS="min_user_turns min_assistant_turns sig_ratio_min require_end_turn max_tool_ratio dedup_threshold min_user_msg_chars max_first_msg_chars topic_match"
UNENFORCED_KEYS="min_assistant_turns"   # no funnel stage consumes these at this engine state

theme_file() { printf '%s/themes/%s.json' "$PACKS" "$1"; }
direction_file() { printf '%s/directions/%s.json' "$PACKS" "$1"; }

# declaring_directions NAME — print the direction pack files that declare
# theme NAME (space-separated). Theme packs carry deltas only; the shared
# defaults live in the direction pack that declares the theme.
declaring_directions() {
  local t="$1" d
  for d in "$PACKS"/directions/*.json; do
    [[ -f "$d" ]] || continue
    if "$JQ" -e --arg t "$t" '.themes | index($t) != null' "$d" >/dev/null 2>&1; then
      printf '%s ' "$d"
    fi
  done
}

# base_defaults NAME — print "file<TAB>defaults-json" for the direction pack
# that declares theme NAME. Refuses (via die, never from inside $()) when no
# direction declares it (no defaults exist) or when several declare it with
# different defaults (the driver cannot pick one honestly).
base_defaults() {
  local t="$1" d dirs defs this
  dirs="$(declaring_directions "$t")"
  [[ -z "$dirs" ]] && die "theme '$t' is not declared by any direction pack in $PACKS/directions/ — its shared defaults have no home; run it through its direction instead"
  defs=""
  for d in $dirs; do
    this="$("$JQ" -c '.defaults' "$d")"
    if [[ -z "$defs" ]]; then defs="$this"
    elif [[ "$this" != "$defs" ]]; then
      die "theme '$t' is declared by several direction packs with DIFFERENT defaults — name the direction with --direction (the pack files disagree, so the driver cannot pick one)"
    fi
  done
  printf '%s\t%s\n' "${dirs%% *}" "$defs"
}

PACK_ID=""           # manifest identity: the direction pack's, or null for a theme run
PACK_VERSION=""
DIRECTION_NAME=""
BASE_DESC=""         # human-readable origin of the shared defaults (printed)

if [[ -n "$DIRECTION" ]]; then
  DJSON="$(direction_file "$DIRECTION")"
  [[ -f "$DJSON" ]] || { usage >&2; die "no direction pack '$DIRECTION' (looked for $DJSON)" 2; }
  [[ "$("$JQ" -r '.kind' "$DJSON")" == "direction" ]] || die "$DJSON is not a direction pack (kind != direction)"
  PACK_ID="$("$JQ" -r '.pack_id' "$DJSON")"
  PACK_VERSION="$("$JQ" -r '.pack_version // empty' "$DJSON")"
  DIRECTION_NAME="$DIRECTION"
  BASE_DESC="direction pack $PACK_ID"
  DEFAULTS_JSON="$("$JQ" -c '.defaults' "$DJSON")"
  while IFS= read -r t; do THEME_NAMES="${THEME_NAMES:+$THEME_NAMES }$t"; done < <("$JQ" -r '.themes[]' "$DJSON")
  [[ -z "$THEME_NAMES" ]] && die "direction pack $DIRECTION lists no themes"
else
  for t in $THEMES; do
    f="$(theme_file "$t")"
    [[ -f "$f" ]] || { usage >&2; die "no theme pack '$t' (looked for $f)" 2; }
  done
  # canonical theme names from the files, in the order given
  for t in $THEMES; do
    c="$("$JQ" -r '.theme // empty' "$(theme_file "$t")")"
    THEME_NAMES="${THEME_NAMES:+$THEME_NAMES }${c:-$t}"
  done
  BASE_DESC="the declaring direction pack's defaults (theme packs carry deltas only)"
fi

# unknown-threshold guard on the direction pack's own defaults (once, not per
# theme): a key nobody maps is a typo or a new threshold — loud, never silent
if [[ -n "$DIRECTION" ]]; then
  unknown="$("$JQ" -r --arg k "$KNOWN_KEYS" '.defaults | ($k | split(" ")) as $known | keys[] | select(. as $x | ($known | index($x)) == null)' "$DJSON" 2>/dev/null || true)"
  [[ -n "$unknown" ]] && die "$DJSON defaults carry keys the driver does not map: $(printf '%s ' $unknown)— fix the pack or teach the driver (a restated or typo'd threshold must never pass silently)"
fi

# Per-theme resolution table, one line per theme (theme names and compact JSON
# carry no spaces, so space-separation is unambiguous):
#   name <sp> report_only(0/1) <sp> defaults-file <sp> overrides-json
RESOLVED=""
unenf=""
last_djson=""
for t in $THEME_NAMES; do
  f="$(theme_file "$t")"
  [[ -f "$f" ]] || die "theme pack for '$t' missing ($f) — the pack is incomplete"
  [[ "$("$JQ" -r '.kind // "theme"' "$f")" == "theme" ]] || die "$f is not a theme pack"
  ro="$("$JQ" -r '.report_only // false' "$f")"
  [[ "$ro" == "true" || "$ro" == "false" ]] || die "$f: report_only must be true/false"
  ovr="$("$JQ" -c '.overrides // {}' "$f")"
  unknown="$("$JQ" -r --arg k "$KNOWN_KEYS" '($k | split(" ")) as $known | keys[] | select(. as $x | ($known | index($x)) == null)' <<<"$ovr" 2>/dev/null || true)"
  [[ -n "$unknown" ]] && die "$f overrides carry keys the driver does not map: $(printf '%s ' $unknown)— fix the pack or teach the driver (a restated or typo'd threshold must never pass silently)"
  if [[ -n "$DIRECTION" ]]; then
    dfile="$DJSON"
    djson="$DEFAULTS_JSON"
  else
    # base_defaults prints its own refusal reason and returns non-zero; a
    # bare $( ) would swallow the exit and continue with an empty result
    if ! bd="$(base_defaults "$t")"; then exit 1; fi
    dfile="${bd%%$'\t'*}"
    djson="${bd#*$'\t'}"
  fi
  unknown="$("$JQ" -r --arg k "$KNOWN_KEYS" '($k | split(" ")) as $known | keys[] | select(. as $x | ($known | index($x)) == null)' <<<"$djson" 2>/dev/null || true)"
  [[ -n "$unknown" ]] && die "defaults for theme '$t' carry keys the driver does not map: $(printf '%s ' $unknown)— fix the pack or teach the driver"
  # keys the pack sets but no funnel stage consumes: reported once per
  # distinct defaults block, never silently applied
  if [[ "$djson" != "$last_djson" ]]; then
    for k in $UNENFORCED_KEYS; do
      if "$JQ" -e --arg k "$k" '.[$k] != null' <<<"$djson" >/dev/null 2>&1; then
        case " $unenf " in *" $k "*) ;; *) unenf="${unenf:+$unenf }$k";; esac
      fi
    done
    last_djson="$djson"
  fi
  # topic_match is the funnel's built-in "any keyword" semantics; anything else
  # has no engine expression and must not run silently under wrong semantics
  tm="$("$JQ" -r '.topic_match // "any"' "$dfile")"
  [[ "$tm" == "any" ]] || die "pack sets topic_match=$tm, but the funnel expresses 'any' only — refusing to screen under different semantics"
  r="0"; [[ "$ro" == "true" ]] && r="1"
  RESOLVED="${RESOLVED:+$RESOLVED\n}$t $r $dfile $ovr"
done

# ---------------------------------------------------------------- header
slug="${DIRECTION:-$(printf '%s' "$THEME_NAMES" | tr ' ' '-')}"
if [[ -z "$OUTDIR" ]]; then
  OUTDIR="./pack-export-${slug}-$(date +%Y%m%d-%H%M)"
fi
echo "pack: ${PACK_ID:-themes: $(printf '%s' "$THEME_NAMES" | tr ' ' ',')}${PACK_VERSION:+ v$PACK_VERSION}${DIRECTION_NAME:+ (direction $DIRECTION_NAME)}"
echo "themes: $THEME_NAMES"
if [[ -n "$DIRECTION" ]]; then
  echo "thresholds ($BASE_DESC): $("$JQ" -r '.defaults | to_entries | map("\(.key)=\(.value)") | join(" ")' "$DJSON")"
else
  echo "thresholds: resolved per theme below (each theme names its declaring direction's defaults)"
fi
# per-theme overrides, only where a theme actually carries one
while IFS= read -r line; do
  t="${line%% *}"; rest="${line#* }"; ro="${rest%% *}"; rest="${rest#* }"; ovr="${rest#* }"
  [[ "$ovr" != "{}" && "$ro" == "0" ]] && echo "overrides $t: $("$JQ" -r 'to_entries | map("\(.key)=\(.value)") | join(" ")' <<<"$ovr")"
done <<<"$(printf '%b' "$RESOLVED")"
[[ -n "$unenf" ]] && echo "note: pack sets $(printf '%s' "$unenf" | sed 's/ $//'), which no funnel stage consumes — NOT enforced by this engine state"
echo "out: $OUTDIR"
echo

# ---------------------------------------------------------------- run setup
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.pack"

CAND="$TMP/candidates.tsv"
SCREEN="$TMP/screen.tsv"

# ---------------------------------------------------------------- 1. scan
scan_args=(-o "$TMP" --agent "$AGENT" --min-lines "$MIN_LINES")
[[ -n "$WORKSPACE" ]] && scan_args+=(--workspace "$WORKSPACE")
[[ -n "$SINCE" ]] && scan_args+=(--since "$SINCE")
echo "== scan =="
bash "$CURATE" scan "${scan_args[@]}" || die "the pipeline's scan failed"
[[ -f "$CAND" ]] || die "scan wrote no candidates.tsv"
scanned="$(awk -F'\t' 'NR>1' "$CAND" | wc -l | tr -d ' ')"
echo

# ------------------------------------------------- 2. per-theme funnel runs
# Each selecting theme is screened by the funnel with its own resolved
# thresholds and keyword list; the driver only transcribes the engine's
# verdicts into counts and, later, the selection. Report-only themes run no
# screen: they are counted (when the engine can) and reported, never a gate.
counts_tsv="$TMP/.pack/counts.tsv"   # idx \t theme \t count(-1 = n/a) \t report_only
: > "$counts_tsv"
theme_map="$TMP/.pack/thememap.tsv"  # session_file \t comma-separated themes
: > "$theme_map"
i=0
printf '%b\n' "$RESOLVED" | while IFS= read -r line; do
  tname="${line%% *}"; rest="${line#* }"; ro="${rest%% *}"; rest="${rest#* }"; dfile="${rest%% *}"; ovr="${rest#* }"
  i=$((i + 1))
  if [[ "$ro" == "1" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$i" "$tname" "-1" "1" >> "$counts_tsv"
    echo "== theme: $tname (report-only — counted, never a pass/fail) =="
    # the engine emits no counter for it; the count stays n/a rather than a
    # fabricated zero (PACK-SPEC: a zero is reported as a zero, never padded)
    continue
  fi
  # -n is load-bearing: without it jq reads the theme-loop's own stdin pipe
  # (the remaining theme lines), fails to parse them as JSON, and starves the
  # loop — the classic read-from-stdin-inside-while-read trap
  resolved="$("$JQ" -nc --argjson d "$("$JQ" -c '.defaults' "$dfile")" --argjson o "$ovr" '$d + $o')"
  min_turns="$("$JQ" -r '.min_user_turns // empty' <<<"$resolved")"
  mtr="$("$JQ" -r '.max_tool_ratio // empty' <<<"$resolved")"
  ret="$("$JQ" -r 'if .require_end_turn == null then "" else (.require_end_turn | tostring) end' <<<"$resolved")"
  mumc="$("$JQ" -r '.min_user_msg_chars // empty' <<<"$resolved")"
  mfmc="$("$JQ" -r '.max_first_msg_chars // empty' <<<"$resolved")"
  dt="$("$JQ" -r '.dedup_threshold // empty' <<<"$resolved")"
  sig="$("$JQ" -r '.sig_ratio_min // empty' <<<"$resolved")"
  kw="$("$JQ" -c '.keywords // []' "$(theme_file "$tname")" | "$JQ" -r 'join(",")')"
  out="$TMP/.pack/$tname.survivors.tsv"
  echo "== theme: $tname =="
  [[ -z "$DIRECTION" ]] && echo "  resolved: $("$JQ" -r 'to_entries | map("\(.key)=\(.value)") | join(" ")' <<<"$resolved")"
  fargs=(run "$CAND" "$out" --preset report)
  [[ -n "$min_turns" ]] && fargs+=(--min-turns "$min_turns")
  [[ -n "$mtr" ]] && fargs+=(--max-tool-ratio "$mtr")
  [[ "$ret" == "false" ]] && fargs+=(--no-end-turn)
  [[ -n "$mumc" ]] && fargs+=(--min-user-msg-chars "$mumc")
  [[ -n "$mfmc" ]] && fargs+=(--max-first-msg-chars "$mfmc")
  [[ -n "$dt" ]] && fargs+=(--dedup-threshold "$dt")
  [[ -n "$sig" ]] && fargs+=(--sig-ratio-min "$sig")
  fargs+=(--topic-keywords "$kw")
  python3 "$FUNNEL" "${fargs[@]}" || die "the funnel failed on theme $tname"
  c="$(($(wc -l < "$out") - 1))"
  printf '%s\t%s\t%s\t%s\n' "$i" "$tname" "$c" "0" >> "$counts_tsv"
  awk -v t="$tname" -F'\t' 'NR>1 && $NF != "" { print $NF "\t" t }' "$out" >> "$theme_map"
done

# union of qualifying sessions + per-session theme attribution, in scan order
LC_ALL=C sort -o "$theme_map" "$theme_map"
awk -F'\t' '{ if ($1 == prev) { out = out "," $2; next }
              if (prev != "") print prev "\t" out
              prev = $1; out = $2 }
            END { if (prev != "") print prev "\t" out }' "$theme_map" > "$theme_map.merged"
mv "$theme_map.merged" "$theme_map"
awk -F'\t' '{ print $1 }' "$theme_map" > "$TMP/.pack/union"
qualified="$(awk 'END { print NR }' "$TMP/.pack/union")"

# ------------------------------------------------------- 3. credentials
# The pack buys byte-identical sessions (PACK-SPEC §1), so a key inside one is
# a key shipped. Count qualifying sessions whose text matches the credential
# pattern; flagged rows are never pre-selected interactively, and unattended
# runs refuse to export them without the explicit --allow-credentials.
# The pattern is driver-owned: the packs name the POLICY (delivery.credentials)
# but no pattern, and the reference bundle recorded credential_hits without
# pinning shapes. Conservative high-signal shapes only — a false positive
# costs a real session, so prose mentioning "an API key" must not match.
CRED_RE='(sk-ant-[A-Za-z0-9_-]{10,}|sk-(proj-)?[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|AIza[0-9A-Za-z_-]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'
cred_hits=0
: > "$TMP/.pack/cred"
while IFS= read -r f; do
  if grep -Eq "$CRED_RE" "$f" 2>/dev/null; then
    cred_hits=$((cred_hits + 1))
    printf '%s\n' "$f" >> "$TMP/.pack/cred"
  fi
done < "$TMP/.pack/union"

# ------------------------------------------------------- 4. pre-export report
echo
echo "this pack qualifies $qualified sessions from $scanned scanned:"
sort -t"$(printf '\t')" -k4,4n -k3,3nr -k1,1n "$counts_tsv" | while IFS="$(printf '\t')" read -r _idx t c ro; do
  if [[ "$ro" == "1" ]]; then
    printf '  %-16s n/a  (report-only)\n' "$t"
  else
    printf '  %-16s %s\n' "$t" "$c"
  fi
done
# report-only themes name counters the engine does not emit: say so once
if awk -F'\t' '$4 == 1' "$counts_tsv" | grep -q .; then
  ro_list="$(awk -F'\t' '$4 == 1 { printf "%s ", $2 }' "$counts_tsv")"
  echo "  note: report-only theme(s) (${ro_list% }) declare counters the funnel does not emit —"
  echo "        their count is n/a (not a fabricated zero), pending a mechanism change"
fi
echo "credentials: $cred_hits qualifying session(s) match the credential pattern"

# ------------------------------------------------------- 5. credential gate
# Unattended means --yolo: no picker, no human eyes on the selection. The
# picker flow always has a human (the picker itself, or the terminal it
# spawns): flagged rows arrive unselected with their reason, and choosing them
# is the human's informed call. The refusal below applies to --yolo only.
# Redaction is not offered — it would break the byte-identity guarantee the
# delivery rests on.
if [[ "$cred_hits" -gt 0 && "$ALLOW_CRED" -eq 0 && "$YOLO" -eq 1 ]]; then
  {
    echo "pack-export: refusing to export: $cred_hits session(s) match the credential pattern."
    echo "  these sessions are your machine's history and may contain your own keys."
    echo "  re-run with --allow-credentials to export them anyway (recorded in the manifest),"
    echo "  or run interactively, where flagged rows are left unselected."
  } >&2
  exit 1
fi
[[ "$cred_hits" -gt 0 && "$ALLOW_CRED" -eq 1 ]] && \
  echo "warning: $cred_hits session(s) with credential-like text WILL be exported (--allow-credentials)"

if [[ "$qualified" -eq 0 ]]; then
  echo
  echo "0 sessions qualify — nothing to export. No directory was written."
  exit 0
fi

# ------------------------------------------------------- 6. confirmation
if [[ "$YES" -eq 1 || "$YOLO" -eq 1 ]]; then
  echo "confirmation skipped ($([[ "$YOLO" -eq 1 ]] && echo --yolo || echo -y))"
else
  printf 'continue? [y/N] '
  ans=""
  if ! read -r ans; then
    echo
    die "no answer on stdin — pass -y to accept the report or --yolo for an unattended run"
  fi
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "aborted at the confirmation prompt — nothing was exported."; exit 0 ;;
  esac
fi
echo

# ------------------------------------- 7. install the selection into the pipe
# Everything up to here lived in a scratch dir so an aborted run writes
# nothing. Now materialize OUTDIR: the full scan archived (the funnel's own
# --in-place contract shape), candidates.tsv replaced by the union the pack
# qualified, and the picker's screen scaffold carrying the credential marks.
OUTDIR_ABS="$(mkdir -p "$OUTDIR" && cd "$OUTDIR" && pwd)"
mv "$CAND" "$OUTDIR_ABS/candidates.full.tsv"
awk -F'\t' 'NR==FNR { if ($1 != "") U[$1] = 1; next }
            FNR == 1 { print; next }
            ($NF in U)' "$TMP/.pack/union" "$OUTDIR_ABS/candidates.full.tsv" > "$CAND"
cp "$CAND" "$OUTDIR_ABS/candidates.tsv"

cred_reason="credential pattern matched — not exported"
[[ "$ALLOW_CRED" -eq 1 ]] && cred_reason="credential pattern matched (exported: --allow-credentials)"
awk -F'\t' -v cf="$TMP/.pack/cred" -v msg="$cred_reason" '
  BEGIN { OFS = "\t"; while ((getline l < cf) > 0) if (l != "") C[l] = 1 }
  NR == 1 { print $0, "suggested", "reason"; next }
  { r = ""; if ($NF in C) r = msg; print $0, "", r }
' "$OUTDIR_ABS/candidates.tsv" > "$SCREEN"
cp "$SCREEN" "$OUTDIR_ABS/screen.tsv"
mv "$TMP/.pack" "$OUTDIR_ABS/.pack"

echo "selection installed: $qualified session(s) in $OUTDIR_ABS/candidates.tsv"
echo

# -------------------------------------------- 8. pick/finalize, then delivery
if [[ "$YOLO" -eq 1 ]]; then
  bash "$PICK" -o "$OUTDIR_ABS" -y --review-only --yolo || die "the pipeline's yolo export failed"
else
  bash "$PICK" -o "$OUTDIR_ABS" -y --review-only || die "the pipeline's pick/finalize failed (the picker was aborted or errored)"
fi

MANIFEST="$OUTDIR_ABS/manifest.json"
[[ -f "$MANIFEST" ]] || die "no manifest after finalize — the pipeline did not complete"
kept="$("$JQ" 'length' "$MANIFEST")"
if [[ "$kept" -eq 0 ]]; then
  echo "the selection came out empty after review — nothing to deliver."
  exit 0
fi

# ------------------------------------------- 9. pack fields into the manifest
# The mechanism issue #2 established: a JSON object merged into each entry,
# never a hand-built fragment. The pipeline's manifest is an ARRAY of entries,
# so the pack-level facts land per entry; the per-session themes come from the
# driver's own attribution map (which theme runs qualified this session).
theme_packs="$("$JQ" -n '{}')"
for t in $THEME_NAMES; do
  f="$(theme_file "$t")"
  tp_id="$("$JQ" -r '.pack_id // empty' "$f")"
  tp_ver="$("$JQ" -r '.pack_version // empty' "$f")"
  # -n: these jq calls have no input file; without it they read the script's
  # stdin and emit nothing (exit 0), poisoning the next --argjson
  theme_packs="$("$JQ" -nc --argjson a "$theme_packs" --arg k "$t" --arg v "${tp_id:+$tp_id@}${tp_ver:-unknown}" '$a + {($k): $v}')"
done
theme_counts="$("$JQ" -n '{}')"
while IFS="$(printf '\t')" read -r _idx t c ro; do
  if [[ "$ro" == "1" ]]; then v=null; else v="$c"; fi
  theme_counts="$("$JQ" -nc --argjson a "$theme_counts" --arg k "$t" --argjson v "$v" '$a + {($k): $v}')"
done < "$OUTDIR_ABS/.pack/counts.tsv"

pack_obj="$("$JQ" -nc \
  --arg pid "$PACK_ID" --arg pver "$PACK_VERSION" --arg dir "$DIRECTION_NAME" \
  --argjson tcounts "$theme_counts" --argjson tpacks "$theme_packs" \
  --argjson allow "$ALLOW_CRED" --argjson hits "$cred_hits" \
  '{pack_id: (if $pid == "" then null else $pid end),
    pack_version: (if $pver == "" then null else $pver end),
    direction: (if $dir == "" then null else $dir end),
    theme_counts: $tcounts, theme_packs: $tpacks,
    allow_credentials: ($allow == 1), credential_hits: $hits}')"

"$JQ" --argjson p "$pack_obj" --rawfile tm "$OUTDIR_ABS/.pack/thememap.tsv" '
  ($tm | split("\n") | map(select(length > 0)) | map(split("\t"))
       | map({ key: .[0], value: (.[1] | split(",")) }) | from_entries) as $m
  | map(. + $p + { themes: ($m[.source] // []) })
' "$MANIFEST" > "$MANIFEST.tmp" || die "manifest merge failed — $MANIFEST left untouched"
mv "$MANIFEST.tmp" "$MANIFEST"
echo "manifest: pack fields merged into $kept entr$([[ "$kept" -eq 1 ]] && echo y || echo ies) ($MANIFEST)"

echo
echo "== delivery =="
bash "$CURATE" delivery -o "$OUTDIR_ABS" || die "delivery failed"

arc="$(ls -t "$OUTDIR_ABS"/*.tar.gz "$OUTDIR_ABS"/*.zip 2>/dev/null | sed -n 1p)"
echo
echo "pack-export: done"
echo "  out:      $OUTDIR_ABS"
echo "  manifest: $MANIFEST"
echo "  archive:  ${arc:-see delivery output above}"
