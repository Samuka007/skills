#!/usr/bin/env bash
# CRLF self-check. Every physical line in this guard ends in a comment so a
# CRLF-smudged install cannot append a carriage return to a shell word.
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
  printf '%s\n' '  reinstall:  npx --yes skills@latest add Samuka007/skills --skill session-export-nocode -g -y' >&2   # CRLF-GUARD
  exit 3                                                                                                               # CRLF-GUARD
fi                                                                                                                     # CRLF-GUARD

# Thin direction adapter. The base skill owns the export pipeline; this file
# only resolves it, reads the request for the explicit review opt-out, and
# forwards the shared runner arguments.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIRECTION_FILE="$SKILL_DIR/direction.json"

usage() {
  cat <<'USAGE'
Usage: session-export-nocode.sh --request TEXT --out DIR [options]

Required
  --request TEXT       the user's complete request (used only for opt-out policy)
  -o, --out DIR       output directory for the base runner

Forwarded to agent-session-batch-export
      --allow-credentials
  -a, --agent NAME
  -w, --workspace STR
      --since DATE
  -n, --min-lines N
  -h, --help

The launcher adds --yolo only when TEXT contains one of:
  直接导出  无需确认  不用确认  无须确认
USAGE
}

die() {
  printf 'session-export-nocode: %s\n' "$1" >&2
  exit "${2:-1}"
}

REQUEST=""
REQUEST_SET=0
OUTDIR=""
FORWARD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --request)
      [[ $# -ge 2 ]] || die "--request needs a value" 2
      REQUEST="$2"
      REQUEST_SET=1
      shift 2
      ;;
    --request=*)
      REQUEST="${1#*=}"
      REQUEST_SET=1
      shift
      ;;
    -o|--out)
      [[ $# -ge 2 ]] || die "$1 needs a value" 2
      OUTDIR="$2"
      shift 2
      ;;
    --out=*)
      OUTDIR="${1#*=}"
      shift
      ;;
    --allow-credentials)
      FORWARD_ARGS+=("$1")
      shift
      ;;
    -a|--agent|-w|--workspace|--since|-n|--min-lines)
      [[ $# -ge 2 ]] || die "$1 needs a value" 2
      FORWARD_ARGS+=("$1" "$2")
      shift 2
      ;;
    --yolo)
      die "--yolo is derived from --request; use one of the explicit opt-out phrases" 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (see --help)" 2
      ;;
  esac
done

[[ "$REQUEST_SET" -eq 1 ]] || { usage >&2; die "--request is required" 2; }
[[ -n "$OUTDIR" ]] || { usage >&2; die "--out is required and cannot be empty" 2; }
[[ -f "$DIRECTION_FILE" ]] || die "bundled direction file is missing: $DIRECTION_FILE"

# A skills-CLI installation places sibling skills under the same directory.
# The remaining roots cover the standard user and project-local layouts.
BASE_RUNNER=""
for root in \
  "$SKILL_DIR/.." \
  "${HOME:-}/.agents/skills" \
  "${HOME:-}/.claude/skills" \
  "${PWD:-.}/.agents/skills" \
  "${PWD:-.}/.claude/skills"; do
  candidate="$root/agent-session-batch-export/scripts/export-direction.sh"
  if [[ -f "$candidate" ]]; then
    BASE_RUNNER="$candidate"
    break
  fi
done

if [[ -z "$BASE_RUNNER" ]]; then
  {
    echo "session-export-nocode: the base skill is missing."
    echo "Expected: agent-session-batch-export/scripts/export-direction.sh"
    echo "Install both published skills together:"
    echo "  npx skills add Samuka007/skills --skill session-export-nocode --skill agent-session-batch-export -g -y"
  } >&2
  exit 1
fi

RUNNER_ARGS=(--direction-file "$DIRECTION_FILE" --out "$OUTDIR")
RUNNER_ARGS+=("${FORWARD_ARGS[@]}")

# These are the only accepted natural-language opt-outs. This is deliberately
# a substring match: the policy says the request must contain the exact phrase.
case "$REQUEST" in
  *直接导出*|*无需确认*|*不用确认*|*无须确认*)
    RUNNER_ARGS+=(--yolo)
    ;;
esac

# Do not intercept or reinterpret runner output: Python preflight and
# credential-refusal messages are actionable states owned by the base skill.
exec bash "$BASE_RUNNER" "${RUNNER_ARGS[@]}"
