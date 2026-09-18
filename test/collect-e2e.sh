#!/usr/bin/env bash
# E2E regression for the collection posture (SPEC item 27).
#
# collect promises the opposite of `run`, and every promise here is load-
# bearing: zero model tokens, NO thresholds (a zero-turn session survives),
# policy.json never read, and the only drops are the two unambiguous junk
# classes — structurally dead rows and exact duplicates. Everything else is
# annotation: the new columns carry values derivable from the raw parse, and
# each pool row ships a row card a buyer's model can judge in a few hundred
# tokens.
#
# Fixtures are synthetic .jsonl files under $WORK. The user's real sessions
# are never read, never written, never needed.
#
# Usage: test/collect-e2e.sh [work-dir]        (default /tmp/collect-e2e)
# Dependencies: bash, python3.
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
SKILL="$REPO/skills/agent-session-batch-export"
F="$SKILL/scripts/funnel.py"
WORK="${1:-/tmp/collect-e2e}"

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
no()   { fail=$((fail + 1)); echo "  FAIL $1"; }
chk()  { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else no "$1: got '$2' want '$3'"; fi; }
has()  { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1: missing '$3'"; fi; }

command -v python3 >/dev/null || { echo "SKIP: python3 not available"; exit 0; }

echo "collect e2e — work dir: $WORK"
echo "script: $(basename "$F")"

# ---------------------------------------------------------------- fixtures
rm -rf "$WORK"; mkdir -p "$WORK/sessions"

python3 - "$WORK" <<'PY'
import json
import sys
from pathlib import Path

work = Path(sys.argv[1])
sess = work / "sessions"

# claude fixture: tool pairing, repeats, error streaks, verification calls,
# image modality, one missing result, one orphan result, one network call.
def claude_user(blocks):
    return {"type": "user", "message": {"role": "user", "content": blocks}}

def claude_assistant(blocks, stop):
    return {"type": "assistant", "message": {"role": "assistant", "content": blocks},
            "stop_reason": stop}

bash_input = {"command": "pytest -q", "timeout": 30}
records = [
    claude_user([{"type": "text",
                  "text": "帮我修改这段代码 ```python\nprint(1)\n```"}]),
    claude_assistant([
        {"type": "text", "text": "好的，我先运行测试"},
        {"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": bash_input},
    ], "tool_use"),
    claude_user([{"type": "tool_result", "tool_use_id": "toolu_1",
                  "is_error": True, "content": "1 failed"}]),
    claude_assistant([
        {"type": "tool_use", "id": "toolu_2", "name": "Bash", "input": bash_input},
    ], "tool_use"),
    claude_user([{"type": "tool_result", "tool_use_id": "toolu_2",
                  "is_error": True, "content": "still failing"}]),
    claude_assistant([
        {"type": "tool_use", "id": "toolu_3", "name": "Bash", "input": bash_input},
    ], "tool_use"),
    claude_user([{"type": "tool_result", "tool_use_id": "toolu_3",
                  "content": "all passed"}]),
    claude_user([
        {"type": "text", "text": "再看看输出"},
        {"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                     "data": "aGk="}},
        {"type": "tool_result", "tool_use_id": "toolu_9", "content": "orphan"},
    ]),
    claude_assistant([
        {"type": "text", "text": "修好了"},
        {"type": "tool_use", "id": "toolu_4", "name": "WebSearch",
         "input": {"query": "weather"}},
    ], "end_turn"),
]
(sess / "claude-ann.jsonl").write_text(
    "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in records),
    encoding="utf-8",
)

# codex fixture: synthetic wrapper first user message, refusal-shaped first
# assistant reply, explicit failure markers, a truncation marker, one call
# with no output, one orphan output, a live-service call.
def ci(text):
    return {"type": "input_text", "text": text}

def msg(role, items):
    return {"type": "response_item",
            "payload": {"type": "message", "role": role, "content": items}}

codex = [
    {"type": "session_meta",
     "payload": {"cwd": "/home/demo/proj", "model_provider": "OpenAI"}},
    msg("user", [ci("The following is the Codex agent history\n请帮我翻译这段话")]),
    msg("assistant", [{"type": "output_text",
                       "text": "我不能帮助您完成这个请求"}]),
    {"type": "response_item", "payload": {
        "type": "function_call", "name": "shell", "call_id": "call_a",
        "arguments": json.dumps({
            "command": ["bash", "-lc", "cargo test"], "workdir": "/x"})}},
    {"type": "response_item", "payload": {
        "type": "function_call_output", "call_id": "call_a",
        "output": json.dumps({"output": "ok", "metadata": {"exit_code": 0}})}},
    {"type": "response_item", "payload": {
        "type": "function_call", "name": "shell", "call_id": "call_b",
        "arguments": json.dumps({
            "command": ["bash", "-lc", "npm test"], "workdir": "/x"})}},
    {"type": "response_item", "payload": {
        "type": "function_call_output", "call_id": "call_b",
        "output": "Error: upstream refused the connection"}},
    {"type": "response_item", "payload": {
        "type": "function_call", "name": "web_search", "call_id": "call_c",
        "arguments": json.dumps({"query": "nixos release"})}},
    {"type": "response_item", "payload": {
        "type": "function_call", "name": "shell", "call_id": "call_d",
        "arguments": json.dumps({
            "command": ["bash", "-lc", "make build"], "workdir": "/x"})}},
    {"type": "response_item", "payload": {
        "type": "function_call_output", "call_id": "call_d",
        "output": "error: no rule to make target"}},
    {"type": "response_item", "payload": {
        "type": "custom_tool_call", "name": "exec", "call_id": "call_e",
        "input": 'const r = await tools.exec_command({cmd:"tsc -p ."});'}},
    {"type": "response_item", "payload": {
        "type": "custom_tool_call_output", "call_id": "call_e",
        "output": [ci("Warning: truncated output (original token count: 999)\nfoo")]}},
    {"type": "response_item", "payload": {
        "type": "custom_tool_call_output", "call_id": "call_ghost",
        "output": [ci("orphan result")]}},
]
(sess / "codex-ann.jsonl").write_text(
    "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in codex),
    encoding="utf-8",
)

# exact duplicate: byte-identical, later row must drop with a detail pointer.
(sess / "codex-ann-copy.jsonl").write_bytes(
    (sess / "codex-ann.jsonl").read_bytes()
)

# structurally dead rows: neither parser accepts them.
(sess / "dead.txt").write_text("not a session format\njust two lines\n",
                               encoding="utf-8")
(sess / "dead2.jsonl").write_text('{"type":"other"}\n', encoding="utf-8")

# a zero-turn session: collect must keep it — no L1, no threshold at all.
(sess / "assistant-only.jsonl").write_text(
    json.dumps(claude_assistant([{"type": "text", "text": "hello"}], "end_turn"))
    + "\n",
    encoding="utf-8",
)

# candidates.tsv over the fixtures.
sess_dir = str(sess)
rows = [
    ("claude", "claude-ann.jsonl"),
    ("codex", "codex-ann.jsonl"),
    ("codex", "codex-ann-copy.jsonl"),
    ("claude", "dead.txt"),
    ("claude", "dead2.jsonl"),
    ("claude", "assistant-only.jsonl"),
]
lines = ["agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file"]
for agent, name in rows:
    p = sess / name
    lines.append(f"{agent}\t/home/demo\t0\t{p.stat().st_size}\t1\t\t{sess_dir}/{name}")
(work / "candidates.tsv").write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

# ------------------------------------------------------------------- run
out="$(python3 "$F" collect "$WORK/candidates.tsv" "$WORK/out" 2>&1)"; rc=$?
chk "collect exits 0" "$rc" "0"
has "stdout reports pool count" "$out" "collected 3 / 6 rows"
has "stdout reports drops" "$out" "dropped 3 (exact_duplicate 1, unparseable 2)"
has "stdout names no-thresholds" "$out" "no thresholds"

# --------------------------------------------------------- dropped.tsv
chk "dropped rows" "$(awk -F'\t' 'NR>1' "$WORK/out/dropped.tsv" | wc -l | tr -d ' ')" "3"
chk "dead.txt dropped unparseable" \
  "$(awk -F'\t' '$2 ~ /dead\.txt$/ {print $3}' "$WORK/out/dropped.tsv")" "unparseable"
chk "copy dropped exact_duplicate" \
  "$(awk -F'\t' '$2 ~ /codex-ann-copy\.jsonl$/ {print $3}' "$WORK/out/dropped.tsv")" "exact_duplicate"
chk "duplicate detail points at kept original" \
  "$(awk -F'\t' '$2 ~ /codex-ann-copy\.jsonl$/ && index($4, "codex-ann.jsonl") > 0' "$WORK/out/dropped.tsv" | wc -l | tr -d ' ')" "1"

# ------------------------------------------------------------- pool.tsv
chk "pool rows" "$(awk -F'\t' 'NR>1' "$WORK/out/pool.tsv" | wc -l | tr -d ' ')" "3"
chk "zero-turn session survives (no L1 in collect)" \
  "$(awk -F'\t' '$7 ~ /assistant-only\.jsonl$/ && $8 == "0"' "$WORK/out/pool.tsv" | wc -l | tr -d ' ')" "1"

# column names + per-row values, asserted by header name.
if python3 - "$WORK/out/pool.tsv" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
header = lines[0].split("\t")
annotation = [
    "tool_calls_missing_results", "tool_results_orphan", "tool_repeat_max",
    "tool_error_streak_max", "verification_commands", "refusal_proxy",
    "synthetic_wrapper", "single_shot", "input_modalities", "capabilities",
    "tools_unmapped", "replay_blockers",
]
problems = []

def cell(row, name):
    return row[header.index(name)]

# 1. the annotation columns exist, in order, appended after the enrich block.
tail = header[-len(annotation):]
if tail != annotation:
    problems.append(f"annotation columns misplaced: {tail}")

# 2. new columns append AFTER the last shipped enrich column.
if header[-len(annotation) - 1] != "credential_kinds":
    problems.append("annotation columns do not sit after credential_kinds")

rows = {}
for ln in lines[1:]:
    r = ln.split("\t")
    rows[r[header.index("session_file")].rsplit("/", 1)[-1]] = r

c = rows.get("claude-ann.jsonl")
if c is None:
    problems.append("claude-ann.jsonl missing from pool")
else:
    want = {
        "tool_calls_missing_results": "1",
        "tool_results_orphan": "1",
        "tool_repeat_max": "3",
        "tool_error_streak_max": "2",
        "verification_commands": "3",
        "refusal_proxy": "0",
        "synthetic_wrapper": "0",
        "single_shot": "0",
        "input_modalities": "text,code,image",
        "capabilities": "capability.code_execution,capability.web_search",
        "tools_unmapped": "0",
        "replay_blockers": "missing_tool_results,external_service",
    }
    for k, v in want.items():
        if cell(c, k) != v:
            problems.append(f"claude {k}: got {cell(c, k)!r} want {v!r}")

x = rows.get("codex-ann.jsonl")
if x is None:
    problems.append("codex-ann.jsonl missing from pool")
else:
    want = {
        "tool_calls_missing_results": "1",
        "tool_results_orphan": "1",
        "tool_repeat_max": "1",
        "tool_error_streak_max": "2",
        "verification_commands": "4",
        "refusal_proxy": "1",
        "synthetic_wrapper": "1",
        "single_shot": "1",
        "input_modalities": "text",
        "capabilities": "capability.code_execution,capability.web_search",
        "tools_unmapped": "0",
        "replay_blockers":
            "missing_tool_results,truncated_output,external_service",
    }
    for k, v in want.items():
        if cell(x, k) != v:
            problems.append(f"codex {k}: got {cell(x, k)!r} want {v!r}")
    # existing enrich columns unchanged on codex: no signature field at all.
    if cell(x, "signature_state") != "absent":
        problems.append("codex signature_state changed")

if problems:
    for p in problems:
        print(f"  POOL-FAIL {p}")
    sys.exit(1)
PY
then ok "pool.tsv column names and values"
else no "pool.tsv column names and values"; fi

# ---------------------------------------------------------- row cards
CARD_KEYS='"source","agent","first_prompt","user_turns","assistant_turns","tool_uses","capabilities","input_modalities","single_shot","refusal_proxy","synthetic_wrapper","tool_calls_missing_results","tool_error_streak_max","verification_commands","theme_hits"'
chk "card count == pool rows" "$(wc -l < "$WORK/out/row-cards.jsonl" | tr -d ' ')" "3"
if python3 - "$WORK/out/row-cards.jsonl" "$CARD_KEYS" <<'PY'
import json
import sys

problems = []
cards = [json.loads(ln) for ln in open(sys.argv[1], encoding="utf-8") if ln.strip()]
keys = [k.strip('"') for k in sys.argv[2].split(",")]
for i, card in enumerate(cards):
    if list(card) != keys:
        problems.append(f"card {i}: key set/order {list(card)}")
    for k in ("source", "agent", "first_prompt", "capabilities", "input_modalities"):
        if not isinstance(card[k], str):
            problems.append(f"card {i}: {k} not a string")
    for k in ("user_turns", "assistant_turns", "tool_uses", "single_shot",
              "refusal_proxy", "synthetic_wrapper",
              "tool_calls_missing_results", "tool_error_streak_max",
              "verification_commands"):
        if not isinstance(card[k], int):
            problems.append(f"card {i}: {k} not an int")
    if not isinstance(card["theme_hits"], list):
        problems.append(f"card {i}: theme_hits not a list")
by_src = {c["source"].rsplit("/", 1)[-1]: c for c in cards}
c = by_src.get("claude-ann.jsonl")
if c is not None and not c["first_prompt"].startswith("帮我修改这段代码"):
    problems.append("claude card first_prompt is not the first user message")
if c is not None and (c["user_turns"] != 2 or c["tool_uses"] != 4):
    problems.append("claude card counts drifted from the parse")
x = by_src.get("codex-ann.jsonl")
if x is not None and (x["single_shot"] != 1 or x["refusal_proxy"] != 1
                      or x["synthetic_wrapper"] != 1):
    problems.append("codex card flag values drifted")
if problems:
    for p in problems:
        print(f"  CARD-FAIL {p}")
    sys.exit(1)
PY
then ok "card structure (keys, order, types, flags)"
else no "card structure (keys, order, types, flags)"; fi

# theme_hits with --theme: the SAME pool, keywords hit over first 3 user msgs.
if python3 "$F" collect "$WORK/candidates.tsv" "$WORK/out-t" --theme writing >/dev/null 2>&1 \
   && python3 - "$WORK/out-t/row-cards.jsonl" <<'PY'
import json
import sys

cards = {c["source"].rsplit("/", 1)[-1]: c
         for c in map(json.loads, open(sys.argv[1], encoding="utf-8"))}
hits = cards["claude-ann.jsonl"]["theme_hits"]
assert hits == ["修改"], f"claude theme_hits: {hits}"
assert cards["codex-ann.jsonl"]["theme_hits"] == [], "codex should not hit writing"
assert cards["assistant-only.jsonl"]["theme_hits"] == [], "hello must not hit writing"
PY
then ok "theme_hits hit list under --theme writing"
else no "theme_hits hit list under --theme writing"; fi

if python3 - "$WORK/out/row-cards.jsonl" <<'PY'
import json
import sys

cards = {c["source"].rsplit("/", 1)[-1]: c
         for c in map(json.loads, open(sys.argv[1], encoding="utf-8"))}
assert all(c["theme_hits"] == [] for c in cards.values()), \
    "no-theme run must leave theme_hits empty"
PY
then ok "theme_hits empty without --theme"
else no "theme_hits empty without --theme"; fi

# first_prompt truncation honors --max-first-prompt-chars.
if python3 "$F" collect "$WORK/candidates.tsv" "$WORK/out-n" \
     --max-first-prompt-chars 10 >/dev/null 2>&1 \
   && python3 - "$WORK/out-n/row-cards.jsonl" <<'PY'
import json
import sys

cards = {c["source"].rsplit("/", 1)[-1]: c
         for c in map(json.loads, open(sys.argv[1], encoding="utf-8"))}
assert len(cards["codex-ann.jsonl"]["first_prompt"]) == 10, "truncation length"
PY
then ok "first_prompt honors --max-first-prompt-chars"
else no "first_prompt honors --max-first-prompt-chars"; fi

# ------------------------------------ collect reads no policy.json (proof)
# Copy the skill, DELETE the global policy, and compare: collect must succeed
# (it is not a delivery posture), `run` must die loudly. That contrast is the
# proof the collection path never reaches for the policy file.
TMP_SKILL="$WORK/skill-nopolicy"
mkdir -p "$TMP_SKILL/scripts" "$TMP_SKILL/themes"
cp "$F" "$TMP_SKILL/scripts/funnel.py"
cp "$SKILL"/themes/*.json "$TMP_SKILL/themes/"
if python3 "$TMP_SKILL/scripts/funnel.py" collect \
     "$WORK/candidates.tsv" "$WORK/out-np" --theme writing >/dev/null 2>&1; then
  ok "collect succeeds with policy.json absent"
else
  no "collect succeeds with policy.json absent"
fi
python3 "$TMP_SKILL/scripts/funnel.py" run \
  "$WORK/candidates.tsv" "$WORK/.unused" >/dev/null 2>&1
runrc=$?
if [[ $runrc != 0 ]]; then ok "run refuses without policy.json (rc=$runrc)"
else no "run should refuse without policy.json"; fi

# ----------------------------------------- enrich carries the same columns
python3 "$F" enrich "$WORK/candidates.tsv" "$WORK/enriched.tsv" >/dev/null 2>&1
chk "enrich exits 0" "$?" "0"
if python3 - "$WORK/enriched.tsv" <<'PY'
import sys

header = open(sys.argv[1], encoding="utf-8").readline().rstrip("\n").split("\t")
annotation = [
    "tool_calls_missing_results", "tool_results_orphan", "tool_repeat_max",
    "tool_error_streak_max", "verification_commands", "refusal_proxy",
    "synthetic_wrapper", "single_shot", "input_modalities", "capabilities",
    "tools_unmapped", "replay_blockers",
]
assert header[-len(annotation):] == annotation, "enrich lacks annotation columns"
assert header[-len(annotation) - 1] == "credential_kinds", "annotation columns misplaced"
PY
then ok "enrich appends the annotation columns"
else no "enrich appends the annotation columns"; fi

echo
echo "collect e2e: pass=$pass fail=$fail  work dir: $WORK"
[[ $fail == 0 ]]
