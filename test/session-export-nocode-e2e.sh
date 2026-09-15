#!/usr/bin/env bash
# Focused acceptance test for the thin session-export-nocode direction adapter.
# The base runner is a stub: this test proves argument policy and sibling
# discovery without copying sessions or exercising the base pipeline.
set -uo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
WORK="${1:-/tmp/session-export-nocode-e2e}"
SOURCE_SKILL="$REPO/skills/session-export-nocode"

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
no() {
  fail=$((fail + 1))
  echo "  FAIL $1"
}
chk() {
  if [[ "$2" == "$3" ]]; then
    ok "$1 ($2)"
  else
    no "$1: got '$2' want '$3'"
  fi
}
has() {
  if [[ "$2" == *"$3"* ]]; then
    ok "$1"
  else
    no "$1: missing '$3'"
  fi
}
hasnt() {
  if [[ "$2" != *"$3"* ]]; then
    ok "$1"
  else
    no "$1: unexpected '$3'"
  fi
}
non0() {
  if [[ "$2" -ne 0 ]]; then
    ok "$1 (rc=$2)"
  else
    no "$1: expected non-zero, got $2"
  fi
}
contains_file() {
  awk -v needle="$2" 'index($0, needle) { found = 1 } END { exit found ? 0 : 1 }' "$1"
}
has_arg() {
  awk -v want="$2" '$0 == want { found = 1 } END { exit found ? 0 : 1 }' "$1"
}
arg_count() {
  awk -v want="$2" '$0 == want { count++ } END { print count + 0 }' "$1"
}
arg_value() {
  awk -v want="$2" '
    $0 == want {
      if (getline value > 0) {
        print value
        found = 1
      }
      exit
    }
    END { if (!found) exit 1 }
  ' "$1"
}

rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "session-export-nocode e2e — work dir: $WORK"

# ------------------------------------------------------------------ install
# Recreate the standard skills-CLI sibling layout and put only a stub at the
# base runner path. The adapter must discover this path without an override.
INSTALL="$WORK/install/skills"
SKILL="$INSTALL/session-export-nocode"
BASE="$INSTALL/agent-session-batch-export"
mkdir -p "$SKILL/scripts" "$BASE/scripts"
cp "$SOURCE_SKILL/SKILL.md" "$SKILL/SKILL.md"
cp "$SOURCE_SKILL/direction.json" "$SKILL/direction.json"
cp "$SOURCE_SKILL/scripts/session-export-nocode.sh" "$SKILL/scripts/session-export-nocode.sh"

CAPTURE_FILE=""
RUNNER_LOG="$WORK/runner.log"
: > "$RUNNER_LOG"
cat > "$BASE/scripts/export-direction.sh" <<'STUB'
#!/usr/bin/env bash
set -u
: "${CAPTURE_FILE:?CAPTURE_FILE must be set}"
: "${RUNNER_LOG:?RUNNER_LOG must be set}"
printf '%s\n' "$@" > "$CAPTURE_FILE"
printf 'called\n' >> "$RUNNER_LOG"

out=""
previous=""
for arg in "$@"; do
  if [[ "$previous" == "--out" ]]; then
    out="$arg"
  fi
  previous="$arg"
done
[[ -n "$out" ]] && printf 'stub runner reached\n' > "$out/stub-runner-reached"
exit 0
STUB
chmod +x "$BASE/scripts/export-direction.sh" "$SKILL/scripts/session-export-nocode.sh"

echo
echo "== frontmatter and thin-bundle shape =="
has "describes a human-invoked command" "$(sed -n '1,8p' "$SKILL/SKILL.md")" "Human-invoked /session-export-nocode"
has "describes explicit non-code export" "$(sed -n '1,8p' "$SKILL/SKILL.md")" "explicit user request"
has "documents the shared runner contract" "$(cat "$SKILL/SKILL.md")" "export-direction.sh"
has "documents the Python action" "$(cat "$SKILL/SKILL.md")" "winget install Python.Python.3.13"
has "documents the credential action" "$(cat "$SKILL/SKILL.md")" "--allow-credentials"
has "documents the canonical screen file" "$(cat "$SKILL/SKILL.md")" "screen.tsv"
has "documents the canonical decision file" "$(cat "$SKILL/SKILL.md")" "decisions.tsv"

echo
echo "== direction.json has exactly the six themes and no copied policy =="
expected_themes="$WORK/expected-themes"
actual_themes="$WORK/actual-themes"
cat > "$expected_themes" <<'THEMES'
translation
rewriting
generation
role-play
data-analysis
multimodal
THEMES
awk '
  /"themes"[[:space:]]*:/ { inside = 1; next }
  inside && /\]/ { exit }
  inside {
    line = $0
    gsub(/[",[:space:]]/, "", line)
    if (line != "") print line
  }
' "$SKILL/direction.json" > "$actual_themes"
if cmp -s "$expected_themes" "$actual_themes"; then
  ok "direction theme list is exactly six names in order"
else
  no "direction theme list differs from the six-name contract"
fi
for forbidden in defaults overrides keywords min_user_turns min_assistant_turns \
  sig_ratio_min require_end_turn max_tool_ratio dedup_threshold; do
  if contains_file "$SKILL/direction.json" "\"$forbidden\""; then
    no "direction does not copy policy key $forbidden"
  else
    ok "direction omits policy key $forbidden"
  fi
done

# No mechanism or theme bundle may be hidden inside this published direction.
for forbidden_path in \
  "$SKILL/scripts/export-direction.sh" \
  "$SKILL/scripts/curate-sessions.sh" \
  "$SKILL/scripts/pick-sessions.sh" \
  "$SKILL/scripts/funnel.py" \
  "$SKILL/funnel.py" \
  "$SKILL/themes" \
  "$SKILL/packs"; do
  if [[ -e "$forbidden_path" ]]; then
    no "no duplicate engine/theme payload at ${forbidden_path#"$SKILL"/}"
  else
    ok "no duplicate engine/theme payload at ${forbidden_path#"$SKILL"/}"
  fi
done

echo
echo "== missing base skill is an actionable refusal =="
MISSING_ROOT="$WORK/missing/skills"
MISSING_SKILL="$MISSING_ROOT/session-export-nocode"
mkdir -p "$MISSING_ROOT" "$WORK/empty-home"
cp -R "$SKILL" "$MISSING_SKILL"
missing_out="$WORK/missing-out"
missing_text="$(
  cd "$MISSING_ROOT" &&
    HOME="$WORK/empty-home" bash "$MISSING_SKILL/scripts/session-export-nocode.sh" \
      --request "帮我导出" --out "$missing_out" 2>&1
)"
missing_rc=$?
non0 "missing base exits non-zero" "$missing_rc"
has "missing base names the required runner" "$missing_text" "agent-session-batch-export/scripts/export-direction.sh"
has "missing base prints the install command" "$missing_text" "npx skills add Samuka007/skills"
has "install command names the base skill" "$missing_text" "--skill agent-session-batch-export"
chk "missing base does not call the stub" "$(wc -l < "$RUNNER_LOG" | tr -d ' ')" "0"

echo
echo "== request phrase matrix =="
RUN_HOME="$WORK/home"
mkdir -p "$RUN_HOME"
case_no=0
run_case() {
  local label="$1"
  local request="$2"
  local want_yolo="$3"
  local out="$WORK/runs/$label"
  local capture="$WORK/capture-$label"
  local result
  local rc
  local file
  local before
  local count
  case_no=$((case_no + 1))
  mkdir -p "$out"

  # Sentinel files prove this adapter neither edits nor consumes agent-written
  # selection artifacts. The base stub also deliberately leaves them alone.
  for file in candidates.tsv screen.tsv decisions.tsv; do
    printf 'sentinel for %s\n' "$label" > "$out/$file"
    cp "$out/$file" "$out/$file.before"
  done

  result="$(
    CAPTURE_FILE="$capture" RUNNER_LOG="$RUNNER_LOG" HOME="$RUN_HOME" \
      bash "$SKILL/scripts/session-export-nocode.sh" \
        --request "$request" --out "$out" \
        --allow-credentials --agent codex \
        --workspace "demo 直接导出 workspace" \
        --since 2026-01-02 --min-lines 0 2>&1
  )"
  rc=$?
  chk "$label exits successfully" "$rc" "0"
  if [[ -e "$out/stub-runner-reached" ]]; then
    ok "$label reaches the stub runner"
  else
    no "$label did not reach the stub runner (output: $result)"
  fi
  chk "$label passes the direction file" \
    "$(arg_value "$capture" "--direction-file")" "$SKILL/direction.json"
  chk "$label passes the output directory" \
    "$(arg_value "$capture" "--out")" "$out"
  chk "$label forwards credentials choice" "$(arg_count "$capture" "--allow-credentials")" "1"
  chk "$label forwards agent filter" "$(arg_value "$capture" "--agent")" "codex"
  chk "$label forwards workspace as one value" \
    "$(arg_value "$capture" "--workspace")" "demo 直接导出 workspace"
  chk "$label forwards since filter" "$(arg_value "$capture" "--since")" "2026-01-02"
  chk "$label forwards zero min-lines" "$(arg_value "$capture" "--min-lines")" "0"
  chk "$label does not forward the natural-language request" "$(arg_count "$capture" "--request")" "0"
  count="$(arg_count "$capture" "--yolo")"
  chk "$label yolo flag policy" "$count" "$want_yolo"
  if [[ "$want_yolo" == 1 ]]; then
    chk "$label appends yolo after forwarded arguments" "$(awk 'END { print }' "$capture")" "--yolo"
  else
    hasnt "$label has no yolo argument" "$(cat "$capture")" "--yolo"
  fi
  for file in candidates.tsv screen.tsv decisions.tsv; do
    before="$out/$file.before"
    if cmp -s "$before" "$out/$file"; then
      ok "$label leaves $file unchanged"
    else
      no "$label edits $file"
    fi
  done
  if [[ ! -e "$out/runner-created-screen.tsv" && ! -e "$out/runner-created-decisions.tsv" ]]; then
    ok "$label creates no agent selection files"
  else
    no "$label created an agent selection file"
  fi
}

run_case "direct-export" "请直接导出这批非代码轨迹" 1
run_case "without-confirmation" "无需确认，直接交付" 1
run_case "dont-confirm" "不用确认，请导出" 1
run_case "no-need-confirm" "无须确认，开始导出" 1
run_case "ask-export" "帮我导出" 0
run_case "empty-request" "" 0
run_case "prepare-only" "请准备一下" 0

echo
echo "== clean output remains free of selection files =="
CLEAN_OUT="$WORK/clean-out"
CLEAN_CAPTURE="$WORK/clean-capture"
mkdir -p "$CLEAN_OUT"
CAPTURE_FILE="$CLEAN_CAPTURE" RUNNER_LOG="$RUNNER_LOG" HOME="$RUN_HOME" \
  bash "$SKILL/scripts/session-export-nocode.sh" \
    --request "请准备一下" --out "$CLEAN_OUT" >/dev/null 2>&1
clean_rc=$?
chk "clean-output invocation exits successfully" "$clean_rc" "0"
for file in candidates.tsv screen.tsv decisions.tsv; do
  if [[ ! -e "$CLEAN_OUT/$file" ]]; then
    ok "clean output has no $file"
  else
    no "clean output unexpectedly has $file"
  fi
done

chk "stub call count equals phrase cases plus clean case" \
  "$(wc -l < "$RUNNER_LOG" | tr -d ' ')" "$((case_no + 1))"

printf '\n=====================\n'
if [[ "$fail" -eq 0 ]]; then
  echo "SESSION-EXPORT-NOCODE E2E: ALL CHECKS PASSED ($pass checks)"
else
  echo "SESSION-EXPORT-NOCODE E2E: FAILURES PRESENT ($fail failed, $pass passed)"
fi
printf '=====================\n'
exit "$fail"
