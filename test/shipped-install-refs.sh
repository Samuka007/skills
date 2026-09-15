#!/usr/bin/env bash
# Static check: every install command a shipped file prints must name a skill
# this repository can install. "Shipped" is everything under skills/ — the
# installer copies a skill directory whole — so a name printed there reaches a
# partner's machine, and no later edit here can correct the copy.
#
# The failure this guards (SPEC/README.md item 22). A retired skill's driver
# told its user to run
#   npx skills add Samuka007/skills --skill trajectory-packs \
#     --skill trajectory-funnel --skill agent-session-batch-export
# Neither retired directory is in this repository any more. The installer
# answers `Selected 2 skills … Installed 2 skills ✓✓` and silently drops a name
# it cannot resolve, so following the instruction looked like it had worked and
# the same error came back.
#
# A name is installable when its directory carries a SKILL.md: that file is
# what the installer enumerates. A directory without one is invisible to it,
# which is how `trajectory-funnel` came to be named in a command that could
# never satisfy it.
#
# docs/ is deliberately out of scope. The release notes have to quote the
# broken command and the installer's reply to be of any use, and a quotation is
# not an instruction — widening the scan there would fail on the record of the
# defect rather than on the defect.
#
# Usage: test/shipped-install-refs.sh
# Portable: Linux, macOS, Windows Git Bash.
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
SKILLS="$REPO/skills"
fail=0

if [[ ! -d "$SKILLS" ]]; then echo "FAIL: no skills/ directory under $REPO"; exit 1; fi

names=()
for d in "$SKILLS"/*/; do
  [[ -f "$d/SKILL.md" ]] || continue
  names+=("$(basename "$d")")
done

is_installable() {
  local n
  for n in "${names[@]}"; do
    if [[ "$n" == "$1" ]]; then return 0; fi
  done
  return 1
}

# Print every skill name an install command in $1 asks for. Backslash-newline
# continuations are joined first, so a command split across lines is read whole
# (the direction skill's SKILL.md wraps its command that way). CR is stripped
# so a CRLF working tree does not turn a name into a false failure.
skill_names_in() {
  awk '
    function scan(s,   n, t, i, v) {
      n = split(s, t, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        if (t[i] == "--skill" && i < n) { v = t[i + 1] }
        else if (t[i] ~ /^--skill=/)    { v = substr(t[i], 9) }
        else { continue }
        gsub(/\r/, "", v)
        sub(/[,;]+$/, "", v)
        if (v != "") print v
      }
    }
    { buf = buf " " $0 }
    !/\\$/ { scan(buf); buf = "" }
    END { if (buf != "") scan(buf) }
  ' "$1"
}

echo "repo:  $REPO"
echo "bash:  $BASH_VERSION ${MSYSTEM:-}"
echo "installable skills (skills/<name>/SKILL.md): ${names[*]:-none}"

step_files=0
step_refs=0
step_bad=0

echo "--- install references in shipped files ---"
while IFS= read -r f; do
  step_files=$((step_files + 1))
  rel="${f#"$REPO"/}"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    step_refs=$((step_refs + 1))
    if is_installable "$name"; then
      printf '  OK   %s  --skill %s\n' "$rel" "$name"
    else
      printf '  FAIL %s  --skill %s  (skills/%s/SKILL.md does not exist)\n' "$rel" "$name" "$name"
      step_bad=$((step_bad + 1))
      fail=1
    fi
  done < <(skill_names_in "$f")
done < <(find "$SKILLS" -type f -not -name '*.pyc' -print | sort)

echo "--- the scan itself ---"
if [[ ${#names[@]} -gt 0 ]]; then
  echo "  OK   installable skills named: ${#names[@]}"
else
  echo "  FAIL no skills/<name>/SKILL.md found — nothing could be validated"; fail=1
fi
if [[ $step_files -gt 0 ]]; then
  echo "  OK   shipped files read: $step_files"
else
  echo "  FAIL no shipped file read — the walk found nothing"; fail=1
fi
if [[ $step_refs -gt 0 ]]; then
  echo "  OK   install references checked: $step_refs (unresolved: $step_bad)"
else
  echo "  FAIL no install reference found in any shipped file — this check would pass without checking anything"
  fail=1
fi

printf '\n=====================================\n'
if [[ $fail -eq 0 ]]; then echo "RESULT: ALL CHECKS PASSED"; else echo "RESULT: FAILURES PRESENT"; fi
echo "====================================="
exit $fail
