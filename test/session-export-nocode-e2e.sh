#!/usr/bin/env bash
# Focused acceptance test for the thin session-export-nocode direction adapter.
# Phase A stubs the base runner and proves argument policy and sibling
# discovery without copying sessions. Phase B swaps in the real base skill and
# runs the pipeline over a fixture store: credential exclusion and disclosure,
# the --allow-credentials override, the --credential-hard-gate refusal, the
# all-excluded edge, and the --confirm checkpoint in both answers.
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
echo "== direction.json has exactly the four themes and no copied policy =="
expected_themes="$WORK/expected-themes"
actual_themes="$WORK/actual-themes"
cat > "$expected_themes" <<'THEMES'
role-play
writing
planning
report-analysis
THEMES
awk '
  /"themes"[[:space:]]*:/ { inside = 1; next }
  inside && /\]/ { exit }
  inside {
    line = $0
    # v2 entries are objects: one `"theme": "<name>"` per line. Extract the
    # value with plain POSIX awk (RSTART/RLENGTH, no gawk-only 3-arg match).
    if (match(line, /"theme"[[:space:]]*:[[:space:]]*"[^"]*"/)) {
      val = substr(line, RSTART, RLENGTH)
      sub(/^.*:[[:space:]]*"/, "", val)
      sub(/"$/, "", val)
      if (val != "") print val
    }
  }
' "$SKILL/direction.json" > "$actual_themes"
if cmp -s "$expected_themes" "$actual_themes"; then
  ok "direction theme list is exactly four names in order (SPEC item 29)"
else
  no "direction theme list differs from the four-name contract"
fi
if contains_file "$SKILL/direction.json" '"schema_version": 2'; then
  ok "direction is schema_version 2"
else
  no "direction schema_version is not 2"
fi
if contains_file "$SKILL/direction.json" '"override"'; then
  ok "direction carries the root override block"
else
  no "direction is missing the root override block"
fi
# The one thing the override exists for: the shared coding-signal exclusion
# list. Its length is the shipped contract (the 25 coding signals every theme
# in this family judges with); a silent shrink would quietly stop excluding.
excl_count="$(awk '
  /"exclude_keywords"/ { inside = 1; next }
  inside && /\]/ { exit }
  inside { n += gsub(/,/, ","); pending = 1 }
  END { print n + pending + 0 }
' "$SKILL/direction.json")"
chk "the shared exclusion list ships 25 signals" "25" "$excl_count"
for forbidden in defaults overrides keywords min_assistant_turns \
  sig_ratio_min require_end_turn max_tool_ratio dedup_threshold policy; do
  if contains_file "$SKILL/direction.json" "\"$forbidden\""; then
    no "direction does not copy policy key $forbidden"
  else
    ok "direction omits policy key $forbidden"
  fi
done
# The override carries exactly one deliberate number: the purchase's own
# packaging bar (decision of 2026-09-21 — the reference bundle's caliber).
# Every other policy threshold stays in the base skill's policy.json; a
# direction restating one of those is smuggling engine calibration.
if contains_file "$SKILL/direction.json" '"min_user_turns": 5'; then
  ok "direction pins the packaging bar min_user_turns=5 (the reference bundle's caliber)"
else
  no "direction does not pin the packaging bar min_user_turns=5"
fi

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
echo "== request matrix: unattended is the default, --confirm is the switch =="
RUN_HOME="$WORK/home"
mkdir -p "$RUN_HOME"
case_no=0
run_case() {
  local label="$1"
  local want_yolo="$2"
  shift 2
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
        --out "$out" "$@" 2>&1
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

# The retired phrase gate is gone: EVERY wording takes the same unattended
# path, and only the explicit --confirm switch removes --yolo.
run_case "phrase-direct-export" 1 --request "请直接导出这批非代码轨迹"
run_case "phrase-no-need-confirm" 1 --request "无需确认，直接交付"
run_case "phrase-dont-confirm" 1 --request "不用确认，请导出"
run_case "phrase-no-need2" 1 --request "无须确认，开始导出"
run_case "plain-ask" 1 --request "帮我导出"
run_case "empty-request" 1 --request ""
run_case "prepare-only" 1 --request "请准备一下"
run_case "no-request-flag" 1

# --confirm withholds --yolo, and wins when both are given: the conservative
# reading of a contradictory command line. The [y/N] prompt itself is proven
# against the real runner in phase B.
run_case "confirm-with-request" 0 --request "先确认再导" --confirm
run_case "confirm-bare" 0 --confirm
run_case "confirm-wins-over-yolo" 0 --yolo --confirm

# Forwarding contract, once, with every forwardable option set. The workspace
# value deliberately contains a retired gate phrase: a value is a value, and
# must arrive at the runner intact rather than be reinterpreted.
run_case "forwarders" 1 \
  --allow-credentials --agent codex \
  --workspace "demo 直接导出 workspace" \
  --since 2026-01-02 --min-lines 0
cap="$WORK/capture-forwarders"
chk "forwarders forwards credentials choice" "$(arg_count "$cap" "--allow-credentials")" "1"
chk "forwarders forwards agent filter" "$(arg_value "$cap" "--agent")" "codex"
chk "forwarders forwards workspace as one value" \
  "$(arg_value "$cap" "--workspace")" "demo 直接导出 workspace"
chk "forwarders forwards since filter" "$(arg_value "$cap" "--since")" "2026-01-02"
chk "forwarders forwards zero min-lines" "$(arg_value "$cap" "--min-lines")" "0"

echo
echo "== clean output remains free of selection files =="
CLEAN_OUT="$WORK/clean-out"
CLEAN_CAPTURE="$WORK/clean-capture"
mkdir -p "$CLEAN_OUT"
CAPTURE_FILE="$CLEAN_CAPTURE" RUNNER_LOG="$RUNNER_LOG" HOME="$RUN_HOME" \
  bash "$SKILL/scripts/session-export-nocode.sh" \
    --out "$CLEAN_OUT" >/dev/null 2>&1
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

echo
echo "== phase B: the real pipeline over a fixture store =="
command -v jq >/dev/null 2>&1 || { echo "session-export-nocode e2e: phase B needs jq"; exit 1; }
python3 -c '' >/dev/null 2>&1 || { echo "session-export-nocode e2e: phase B needs a working python3"; exit 1; }

# Swap the stub for the real base skill and build a three-session codex store,
# all under the planning theme: a clean multi-turn session, a multi-turn
# session carrying an API-key shape, and a one-turn session. The two multi-turn
# entries match the direction's packaging bar (min_user_turns=5), so the only
# difference between the first two is the credential; the one-turn entry
# satisfies the theme but dies at the bar, which is the floor doing its job.
rm -rf "$BASE"
mkdir -p "$BASE"
cp -R "$REPO/skills/agent-session-batch-export/." "$BASE/"
STORE="$RUN_HOME/.codex/sessions/2026/09/15"
mkdir -p "$STORE"
meta='{"type":"session_meta","payload":{"cwd":"/home/demo/notes","model_provider":"OpenAI"}}'
mkcodex() { # name  first-user-text  filler-prefix  filler-count
  local name="$1" first="$2" mark="$3" n="$4" i
  { printf '%s\n' "$meta"
    printf '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":%s}]}}\n' \
      "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$first")"
    printf '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"好的，方案如下。"}]}}\n'
    for ((i = 2; i <= n + 1; i++)); do
      printf '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":%s}]}}\n' \
        "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "${mark}第${i}项请再补充说明细节。")"
      printf '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"好的，第%s项已补充。"}]}}\n' "$i"
    done
  } > "$STORE/rollout-$name.jsonl"
}
mkcodex short-c '帮我做一份五一活动的营销策划，包含时间表和预算方案' '' 0
mkcodex plan-a '帮我做一份五一活动的营销策划，包含时间表和预算方案' '线下场地的活动流程' 5
mkcodex leak-b '这是我的密钥 sk-ant-abcdefghij0123456789，帮我顺便核对营销策划的预算方案' '华北区域的报表口径' 5

launcher() { # outdir  args...
  local out="$1"; shift
  rm -rf "$out"
  HOME="$RUN_HOME" bash "$SKILL/scripts/session-export-nocode.sh" --out "$out" "$@" 2>&1
}

# Default: the credential hit is excluded and disclosed; the rest delivers.
o1="$(launcher "$WORK/real/excl")"
chk "default run delivers despite a credential hit" "0" "$?"
has "the exclusion is disclosed per file" "$o1" "excluded: "
has "with the credential kind" "$o1" "[anthropic_key]"
has "and the summary line" "$o1" \
  "credential exclusions: 1 session(s) excluded (nothing from them was written)"
m1="$WORK/real/excl/manifest.json"
chk "the delivery holds exactly the clean session" "1" "$(jq 'length' "$m1")"
has "the manifest names the excluded source" \
  "$(jq -r '.[0].credential_exclusions[0].source' "$m1")" "rollout-leak-b.jsonl"
chk "the manifest records the exclusion kind" "anthropic_key" \
  "$(jq -r '.[0].credential_exclusions[0].kinds[0]' "$m1")"
chk "one exclusion recorded" "1" "$(jq -r '.[0].credential_excluded' "$m1")"
chk "allow_credentials stays false by default" "false" "$(jq -r '.[0].allow_credentials' "$m1")"
chk "unattended run records batch_confirmed=false" "false" "$(jq -r '.[0].batch_confirmed' "$m1")"
chk "the excluded row is absent from decisions.tsv" "0" \
  "$(awk 'index($0, "leak-b") { n++ } END { print n + 0 }' "$WORK/real/excl/decisions.tsv")"
chk "and absent from the delivered manifest entries" "0" \
  "$(jq '[.[] | select(.source | test("leak-b"))] | length' "$m1")"
has "the packaging bar kills the one-turn session" "$o1" "user_turns 1 < 5"
chk "and the sub-floor session is absent from the delivery" "0" \
  "$(jq '[.[] | select(.source | test("short-c"))] | length' "$m1")"

# --allow-credentials: the explicit human decision includes the hit.
o2="$(launcher "$WORK/real/allow" --allow-credentials)"
chk "the explicit flag includes the hit" "0" "$?"
has "with a warning that they will be exported" "$o2" "WILL be exported"
m2="$WORK/real/allow/manifest.json"
chk "the two multi-turn survivors delivered" "2" "$(jq 'length' "$m2")"
chk "the manifest records the human decision" "true" "$(jq -r '.[0].allow_credentials' "$m2")"
chk "nothing was excluded" "0" "$(jq -r '.[0].credential_excluded' "$m2")"
chk "and the exclusions list is empty" "0" "$(jq -r '.[0].credential_exclusions | length' "$m2")"
chk "one key counts once" "1" "$(jq -r '.[0].credential_hits' "$m2")"

# --credential-hard-gate (a driver flag; called here directly): any hit, no
# output, exit 3.
o3="$(HOME="$RUN_HOME" bash "$BASE/scripts/export-direction.sh" \
  --direction-file "$SKILL/direction.json" -o "$WORK/real/hard" \
  --yolo --credential-hard-gate 2>&1)"
hg_rc=$?
chk "the hard gate refuses the batch" "3" "$hg_rc"
has "the refusal says so" "$o3" "refusing the batch"
has "and names the posture flag" "$o3" "--credential-hard-gate"
chk "and writes nothing at all" "absent" \
  "$(test -e "$WORK/real/hard" && echo present || echo absent)"

# All-excluded edge: the honest report, no empty package. Short-c is parked
# with plan-a: the bar already removes it, and the edge being tested is the
# credential exclusion, not the turn floor.
mv "$STORE/rollout-plan-a.jsonl" "$WORK/plan-a.parked"
mv "$STORE/rollout-short-c.jsonl" "$WORK/short-c.parked"
o4="$(launcher "$WORK/real/none")"
chk "an all-excluded run still succeeds honestly" "0" "$?"
has "it says nothing remains" "$o4" "0 sessions remain"
has "and why" "$o4" "excluded as credential-bearing"
chk "and no directory was written" "absent" \
  "$(test -e "$WORK/real/none" && echo present || echo absent)"
mv "$WORK/plan-a.parked" "$STORE/rollout-plan-a.jsonl"
mv "$WORK/short-c.parked" "$STORE/rollout-short-c.jsonl"

# --confirm answered y: the batch-level checkpoint, batch_confirmed=true.
o5="$(printf 'y\n' | launcher "$WORK/real/confirm" --confirm)"
chk "confirm answered y delivers" "0" "$?"
has "the runner asked once" "$o5" "[y/N]"
m5="$WORK/real/confirm/manifest.json"
chk "the manifest records the batch confirmation" "true" "$(jq -r '.[0].batch_confirmed' "$m5")"
chk "and the delivery holds the clean session" "1" "$(jq 'length' "$m5")"

# --confirm at EOF: fail-closed, nothing written.
o6="$(launcher "$WORK/real/eof" --confirm </dev/null)"
eof_rc=$?
non0 "EOF at the prompt fails closed" "$eof_rc"
has "the failure says why" "$o6" "no answer on stdin"
chk "and nothing was written" "absent" \
  "$(test -e "$WORK/real/eof" && echo present || echo absent)"

rm -f "$STORE/rollout-leak-b.jsonl" "$STORE/rollout-plan-a.jsonl" \
  "$STORE/rollout-short-c.jsonl"

printf '\n=====================\n'
if [[ "$fail" -eq 0 ]]; then
  echo "SESSION-EXPORT-NOCODE E2E: ALL CHECKS PASSED ($pass checks)"
else
  echo "SESSION-EXPORT-NOCODE E2E: FAILURES PRESENT ($fail failed, $pass passed)"
fi
printf '=====================\n'
exit "$fail"
