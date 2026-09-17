#!/usr/bin/env bash
# E2E regression for the thinking-signature layer (issue #9, PACK-SPEC § 4).
#
# The layer has four classes to survive, and they are not two:
#   present  thinking blocks with a non-empty `signature`  -> ratio computed
#   empty    thinking blocks with `signature: ""`          -> fails the floor
#   absent   no thinking block at all (codex)              -> SKIPS, not fails
#   redacted `redacted_thinking` only (safety redaction)   -> absent, counted
#                                                             separately
# `empty` vs `absent` is the load-bearing distinction: a batch where every
# claude_code session reports `empty` is a finding about the partner's relay,
# and failing codex for having no signature field at all would exclude a format
# the purchase explicitly covers.
#
# Fixtures are synthetic .jsonl files under $WORK. The user's real sessions are
# never read, never written, never needed — the real-store table is a separate
# acceptance run, not part of a regression suite.
#
# Usage: test/signature-e2e.sh [work-dir]        (default /tmp/signature-e2e)
# Dependencies: bash, awk, python3. NOT tmux, NOT fzf.
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
F="$REPO/skills/agent-session-batch-export/scripts/funnel.py"
WORK="${1:-/tmp/signature-e2e}"

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
no()   { fail=$((fail + 1)); echo "  FAIL $1"; }
chk()  { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else no "$1: got '$2' want '$3'"; fi; }
has()  { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1: missing '$3'"; fi; }
hasnt(){ if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1: unexpected '$3'"; fi; }

command -v python3 >/dev/null || { echo "SKIP: python3 not available"; exit 0; }

echo "signature e2e — work dir: $WORK"
echo "script: $(basename "$F")"

# ---------------------------------------------------------------- fixtures
rm -rf "$WORK"; mkdir -p "$WORK"
python3 - "$WORK" <<'PY'
import json, os, sys
w = sys.argv[1]
SIG = "A" * 384                      # the real signature length measured on this box
THINK_SIGNED = {"type": "thinking", "thinking": "let me work this out", "signature": SIG}
THINK_UNSIGNED = {"type": "thinking", "thinking": "let me work this out " * 30,
                  "signature": ""}   # text INTACT, signature stripped
REDACTED = {"type": "redacted_thinking", "data": "ENCRYPTED-REASONING-BLOB"}


def claude(name, per_assistant, n_assistant, model, subject):
    """A claude_code .jsonl whose every assistant turn carries `per_assistant`
    thinking-ish blocks followed by text. The opening prose is distinct per
    fixture on purpose: the dedup stage compares first user messages, and a
    shared opening would collapse two fixtures into one and hide the layer this
    suite is about."""
    lines = [json.dumps({"type": "user", "message": {
        "role": "user", "content": f"write me a long report about {subject}"}})]
    for i in range(n_assistant):
        content = list(per_assistant) + [{"type": "text", "text": f"reply {i} " * 40}]
        lines.append(json.dumps({"type": "assistant", "message": {
            "role": "assistant", "model": model, "content": content},
            "stop_reason": "end_turn"}))
        if i < n_assistant - 1:
            lines.append(json.dumps({"type": "user", "message": {
                "role": "user", "content": f"expand section {i} of that report please"}}))
    p = os.path.join(w, name)
    open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    return p


def codex(name):
    """A codex rollout: reasoning arrives as encrypted_content and there is no
    signature field anywhere — the `absent` class."""
    rec = [{"type": "session_meta", "payload": {"model_provider": "OpenAI"}},
           {"type": "event_msg", "payload": {"type": "task_started"}}]
    rec.append({"type": "response_item", "payload": {"type": "message", "role": "user",
                 "content": [{"type": "input_text",
                              "text": "translate this document about terrace farming"}]}})
    for i in range(3):
        rec.append({"type": "response_item", "payload": {
            "type": "reasoning", "encrypted_content": "XYZ" * 40}})
        rec.append({"type": "response_item", "payload": {"type": "message", "role": "assistant",
                    "content": [{"type": "output_text", "text": f"translation {i} " * 40}]}})
        rec.append({"type": "response_item", "payload": {"type": "message", "role": "user",
                    "content": [{"type": "input_text",
                                 "text": f"continue with part {i} of the document"}]}})
    p = os.path.join(w, name)
    open(p, "w", encoding="utf-8").write(
        "\n".join(json.dumps(r) for r in rec) + "\n")
    return p


files = [
    ("claude", "present.jsonl", claude("present.jsonl", [THINK_SIGNED] * 3, 4,
                                       "claude-opus-5", "andean terrace farming")),
    ("claude", "empty.jsonl", claude("empty.jsonl", [THINK_UNSIGNED] * 2, 3,
                                     "claude-opus-4-8-fast", "tidal marsh restoration")),
    ("claude", "redacted.jsonl", claude("redacted.jsonl", [REDACTED], 3,
                                        "claude-opus-5", "viking longship rigging")),
    ("claude", "mixed.jsonl", claude("mixed.jsonl", [THINK_SIGNED, THINK_UNSIGNED,
                                                     THINK_UNSIGNED], 3,
                                     "claude-opus-5", "saffron harvesting in kashmir")),
    ("codex", "codex.jsonl", codex("codex.jsonl")),
]
hdr = "agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file"
with open(os.path.join(w, "candidates.tsv"), "w", encoding="utf-8") as fh:
    fh.write(hdr + "\n")
    for agent, _n, p in files:
        fh.write(f"{agent}\t/w/x\t0\t{os.path.getsize(p)}\t0\tfirst\t{p}\n")
PY

# col BASENAME COLUMN -> the enriched value for that fixture ('' if absent)
col() {
  awk -F'\t' -v want="$1" -v c="$2" '
    NR == 1 { for (i = 1; i <= NF; i++) { if ($i == c) h = i; if ($i == "session_file") f = i } ; next }
    { n = $f; sub(/.*\//, "", n); if (n == want) print $h }' "$WORK/enriched.tsv"
}
# cell LABEL FIELD -> the funnel table row for LABEL, FIELD 5 (killed) or 7 (skipped)
cell() {
  awk -v lbl="$1" -v fld="$2" -F'[ \t]+' '
    $1 == "L3" && $2 == "signature" { print (fld == 5 ? $5 : $7) }' "$WORK/run.$3"
}

# ------------------------------------------------- A: enrich reports states
echo
echo "== A: enrich states =="
python3 "$F" enrich "$WORK/candidates.tsv" "$WORK/enriched.tsv" >/dev/null
chk "present: state"          "$(col present.jsonl signature_state)"  "present"
chk "present: ratio"          "$(col present.jsonl signature_ratio)"  "1.00"
chk "present: signed blocks"  "$(col present.jsonl signature_present)" "12"
chk "present: unsigned"       "$(col present.jsonl signature_empty)"  "0"
chk "present: redacted"       "$(col present.jsonl redacted_blocks)"  "0"
chk "empty: state"            "$(col empty.jsonl signature_state)"    "empty"
chk "empty: ratio"            "$(col empty.jsonl signature_ratio)"    "0.00"
chk "empty: signed blocks"    "$(col empty.jsonl signature_present)"  "0"
chk "empty: unsigned"         "$(col empty.jsonl signature_empty)"    "6"
# the thinking TEXT is intact in the empty fixture — the state must key on the
# signature, not on the text (PACK-SPEC § 3: "thinking text is not the signal")
chk "empty: thinking text present" "$(col empty.jsonl assistant_turns)" "3"
chk "redacted: state"         "$(col redacted.jsonl signature_state)"  "absent"
chk "redacted: not a thinking block" "$(col redacted.jsonl thinking_blocks)" "0"
chk "redacted: counted apart" "$(col redacted.jsonl redacted_blocks)" "3"
chk "redacted: ratio"         "$(col redacted.jsonl signature_ratio)" "0.00"
chk "codex: state"            "$(col codex.jsonl signature_state)"    "absent"
chk "codex: no thinking"      "$(col codex.jsonl thinking_blocks)"    "0"
chk "codex: ratio"            "$(col codex.jsonl signature_ratio)"    "0.00"
chk "mixed: state"            "$(col mixed.jsonl signature_state)"    "present"
chk "mixed: ratio"            "$(col mixed.jsonl signature_ratio)"    "0.33"
chk "mixed: 9 thinking blocks" "$(col mixed.jsonl thinking_blocks)"   "9"
# thinking_blocks is present + empty, always
chk "mixed: blocks = present+empty" \
  "$(col mixed.jsonl thinking_blocks)" \
  "$(( $(col mixed.jsonl signature_present) + $(col mixed.jsonl signature_empty) ))"

# --------------------------------------------- B: the layer is OFF once cleared
echo
echo "== B: the policy's floor cleared (--no-signature) means OFF, and it says so =="
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out.tsv" --no-signature \
  --min-turns 1 --max-tool-ratio 1.0 --no-end-turn --topic-keywords "" \
  > "$WORK/run.off" 2>&1
row="$(sed -n 's/^\(L3 signature.*\)$/\1/p' "$WORK/run.off")"
has "table marks it OFF"  "$row" "OFF"
hasnt "no kill is claimed" "$row" "killed 1"
chk "survivors unchanged" "$(awk -F'\t' 'NR>1' "$WORK/out.tsv" | wc -l | tr -d ' ')" "5"
# The row must still be THERE. An auditor telling "the layer ran and skipped
# codex" from "the layer never ran" has only the table to read, so a vanished
# row would make those two identical.
chk "the off row is still printed, not dropped" \
  "$(grep -c '^L3 signature' "$WORK/run.off")" "1"
# L0 scan + the nine stages (L7 noncode and L8 credential joined the order, so
# dedup is L9). The count is asserted, not the labels: the invariant is that a
# gated-off stage still occupies a row, so "never ran" cannot read as "ran and
# passed everything".
chk "and every stage keeps its row" \
  "$(grep -cE '^L[0-9] ' "$WORK/run.off")" "10"
has "the off reason names the key that turns it on" "$row" "sig_ratio_min"

# --------------------------------- C: on -> present passes, empty fails, skips
echo
echo "== C: --sig-ratio-min 0.30 =="
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out.tsv" \
  --min-turns 1 --max-tool-ratio 1.0 --no-end-turn --topic-keywords "" \
  --sig-ratio-min 0.30 > "$WORK/run.on" 2>&1
row="$(sed -n 's/^\(L3 signature.*\)$/\1/p' "$WORK/run.on")"
chk "killed exactly the empty one" "$(cell L3 5 on)" "1"
chk "skipped the two absent ones"  "$(cell L3 7 on)" "2"
chk "4 of 5 survive" "$(awk -F'\t' 'NR>1' "$WORK/out.tsv" | wc -l | tr -d ' ')" "4"
# skipped ≠ killed: both classes are named in the same row, so the table alone
# tells a reader which sessions were rejected and which could not be judged
has "row names the fail class" "$row" "signature_ratio"
has "row names the skip class" "$row" "skip:"
survivors() { awk -F'\t' 'NR>1 { n = $NF; sub(/.*\//, "", n); print n }' "$WORK/out.tsv" | sort | tr '\n' ' '; }
has "present survived" "$(survivors)" "present.jsonl"
has "mixed survived"   "$(survivors)" "mixed.jsonl"
has "redacted survived (absent skips)" "$(survivors)" "redacted.jsonl"
has "codex survived (absent skips)"    "$(survivors)" "codex.jsonl"
hasnt "empty was killed" "$(survivors)" "empty.jsonl"

# -------------------------------------------- D: the floor actually decides
echo
echo "== D: the ratio floor discriminates (mixed.jsonl is 0.33) =="
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out.tsv" \
  --min-turns 1 --max-tool-ratio 1.0 --no-end-turn --topic-keywords "" \
  --sig-ratio-min 0.34 > "$WORK/run.hi" 2>&1
chk "floor above the ratio kills it" "$(cell L3 5 hi)" "2"
has "above-floor reason is the ratio" "$(sed -n 's/^\(L3 signature.*\)$/\1/p' "$WORK/run.hi")" "signature_ratio"
hasnt "mixed did not survive" "$(awk -F'\t' 'NR>1' "$WORK/out.tsv")" "mixed.jsonl"

# --------------------------------------------------------------- summary
printf '\n=====================\n'
if [[ $fail -eq 0 ]]; then echo "SIGNATURE E2E: ALL CHECKS PASSED ($pass)"; else echo "SIGNATURE E2E: FAILURES PRESENT ($fail)"; fi
printf '=====================\n'
exit $((fail > 0))
