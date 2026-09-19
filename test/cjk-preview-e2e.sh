#!/usr/bin/env bash
# E2E regression for the CJK first_prompt preview truncation (SPEC item 30).
#
# `cut -c` counts BYTES in GNU and MSYS coreutils, so truncating a CJK
# first_prompt at byte 180 can split a character and write invalid UTF-8 into
# candidates.tsv — which killed the funnel's strict UTF-8 reader with a raw
# UnicodeDecodeError (found in the wild; the distributed auto-export task
# document carries a conditional patch for exactly this).
#
# Two arms:
#   A. a misaligned CJK fixture store scanned with the CURRENT scripts must
#      produce a valid-UTF-8 candidates.tsv whose first_prompt cell is
#      character-safe (180 characters), and the funnel must run on it.
#      NOTE: on GNU coreutils >= 9.5 `cut -c` is character-safe and this arm
#      passes even against the pre-fix script; on MSYS2/Git Bash it
#      discriminates. Arm B discriminates everywhere.
#   B. a candidates.tsv with an injected invalid byte must fail the funnel
#      with the actionable "not valid UTF-8 … re-run the scan" message — not
#      a bare traceback.
#
# Usage: test/cjk-preview-e2e.sh [work-dir]     (default /tmp/cjk-preview-e2e)
# Dependencies: bash, python3.
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
SKILL="$REPO/skills/agent-session-batch-export"
CURATE="$SKILL/scripts/curate-sessions.sh"
F="$SKILL/scripts/funnel.py"
WORK="${1:-/tmp/cjk-preview-e2e}"

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
no()   { fail=$((fail + 1)); echo "  FAIL $1"; }
has()  { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1: missing '$3'"; fi; }

command -v python3 >/dev/null || { echo "SKIP: python3 not available"; exit 0; }

echo "cjk-preview e2e — work dir: $WORK"

# ---------------------------------------------------------------- fixtures
# "ab" prefix shifts every character boundary by two bytes, so a byte-based
# cut at 180 lands mid-character (a clean boundary would need 180 % 3 == 0).
rm -rf "$WORK"; mkdir -p "$WORK/home/.codex/sessions"

python3 - "$WORK" <<'PY'
import json
import sys
from pathlib import Path

work = Path(sys.argv[1])
prompt = "ab" + "帮" * 100          # 2 + 300 = 302 bytes; byte 180 is mid-char
lines = [
    {"type": "session_meta", "payload": {"cwd": str(work / "proj")}},
    {"type": "response_item", "payload": {"type": "message", "role": "user",
        "content": [{"type": "input_text", "text": prompt}]}},
    {"type": "response_item", "payload": {"type": "message", "role": "assistant",
        "content": [{"type": "output_text", "text": "好的。"}]}},
]
sess = work / "home/.codex/sessions"
sess.mkdir(parents=True, exist_ok=True)
with open(sess / "rollout-cjk.jsonl", "w", encoding="utf-8") as f:
    for ln in lines:
        f.write(json.dumps(ln, ensure_ascii=False) + "\n")
PY

# ------------------------------------------------- A. producer: char-safe
HOME="$WORK/home" bash "$CURATE" scan -o "$WORK/out" --min-lines 0 > "$WORK/scan.log" 2>&1
if [[ $? == 0 ]]; then ok "scan exits 0 on a CJK-only store"; else no "scan exits nonzero"; fi

python3 - "$WORK" <<'PY'
import sys
from pathlib import Path
work = Path(sys.argv[1])
cand = work / "out/candidates.tsv"
raw = cand.read_bytes()
try:
    text = raw.decode("utf-8")
except UnicodeDecodeError as e:
    print(f"  FAIL candidates.tsv is invalid UTF-8 at byte {e.start}")
    sys.exit(1)
cell = text.splitlines()[1].split("\t")[5]
n = len(cell)
if 0 < n <= 180:
    print(f"  ok   candidates.tsv valid UTF-8; first_prompt cell = {n} characters (char-safe)")
else:
    print(f"  FAIL first_prompt cell is {n} characters — not character-safe truncation")
    sys.exit(1)
PY
if [[ $? == 0 ]]; then ok "producer truncation is character-safe"; else fail=$((fail + 1)); fi

python3 "$F" run "$WORK/out/candidates.tsv" "$WORK/surv.tsv" > "$WORK/run.log" 2>&1
if [[ $? == 0 ]]; then ok "funnel runs on the CJK candidates"; else no "funnel failed on CJK candidates"; fi

# ------------------------------------------- B. reader: actionable failure
python3 - "$WORK" <<'PY'
import sys
from pathlib import Path
work = Path(sys.argv[1])
cand = work / "out/candidates.tsv"
raw = cand.read_bytes()
# inject one dangling lead byte before the final newline: guaranteed invalid
cand.write_bytes(raw[:-1] + b"\xe5\n")
PY

python3 "$F" run "$WORK/out/candidates.tsv" "$WORK/surv2.tsv" > "$WORK/guard.log" 2>&1
rc=$?
if [[ $rc == 1 ]]; then ok "reader exits 1 on invalid UTF-8"; else no "reader exit code: got $rc want 1"; fi
has "reader message names the encoding fault" "$(cat "$WORK/guard.log")" "not valid UTF-8"
has "reader message gives the regen instruction" "$(cat "$WORK/guard.log")" "re-run the scan"
if grep -q "Traceback" "$WORK/guard.log"; then no "reader leaks a raw traceback"; else ok "no raw traceback"; fi

echo "cjk-preview e2e: pass=$pass fail=$fail  work dir: $WORK"
[[ $fail == 0 ]]
