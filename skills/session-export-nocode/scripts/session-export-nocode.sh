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
# only resolves it and forwards the shared runner arguments. The default is
# unattended: --yolo is ALWAYS passed, because nothing on this path needs a
# judgment call (the policy plus the direction's themes decide the selection,
# deterministically) and nothing leaves this machine. --confirm is the one
# switch that reintroduces a checkpoint.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIRECTION_FILE="$SKILL_DIR/direction.json"

usage() {
  cat <<'USAGE'
Usage: session-export-nocode.sh --out DIR [--confirm] [options]

Required
  -o, --out DIR       output directory for the base runner

Optional
      --confirm       run attended: the base runner asks one batch-level
                      [y/N] before exporting. y delivers (manifest
                      batch_confirmed=true); EOF or any other answer
                      exports nothing. Wins over --yolo if both are given
      --request TEXT  accepted for backward compatibility with earlier
                      callers; used by no gate and forwarded nowhere
      --yolo          the default behavior already; accepted so old
                      command lines keep working
      --allow-credentials
  -a, --agent NAME
  -w, --workspace STR
      --since DATE
  -n, --min-lines N
  -h, --help

Unmarked options are forwarded to agent-session-batch-export. The base
runner excludes credential-bearing sessions from the delivery by default
and reports each exclusion; --allow-credentials includes them (an explicit
human decision, recorded in the manifest).
USAGE
}

die() {
  printf 'session-export-nocode: %s\n' "$1" >&2
  exit "${2:-1}"
}

OUTDIR=""
CONFIRM=0
FORWARD_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --request)
      [[ $# -ge 2 ]] || die "--request needs a value" 2
      shift 2
      ;;
    --request=*)
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
    --confirm)
      CONFIRM=1
      shift
      ;;
    --yolo)
      # The default behavior; accepted so old invocations keep working.
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (see --help)" 2
      ;;
  esac
done

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
  if [[ -f "$root/agent-session-batch-export/scripts/export-direction.sh" ]]; then
    BASE_RUNNER="$root/agent-session-batch-export/scripts/export-direction.sh"
    break
  fi
done

if [[ -z "$BASE_RUNNER" ]]; then
  {
    echo "session-export-nocode: cannot find the base skill's runner."
    echo "  expected agent-session-batch-export/scripts/export-direction.sh next"
    echo "  to this skill, in ~/.agents/skills, ~/.claude/skills, or"
    echo "  ./.agents/skills. Install the two skills together:"
    echo
    echo "    npx skills add Samuka007/skills \\"
    echo "      --skill session-export-nocode --skill agent-session-batch-export -g -y"
  } >&2
  exit 1
fi

RUNNER_ARGS=(--direction-file "$DIRECTION_FILE" --out "$OUTDIR")
RUNNER_ARGS+=("${FORWARD_ARGS[@]}")

# Unattended is the default; --confirm is the exception, and passing both
# asks rather than overrides — the conservative reading of a contradictory
# command line. No combination is rejected: the request text is accepted
# and ignored, and --yolo by hand is the default spelled out.
if [[ "$CONFIRM" -eq 0 ]]; then
  RUNNER_ARGS+=(--yolo)
fi

# Do not intercept or reinterpret runner output: Python preflight and
# credential-disposition messages are actionable states owned by the base
# skill.
exec bash "$BASE_RUNNER" "${RUNNER_ARGS[@]}"
