#!/usr/bin/env bash
# E2E regression for the codex adapter's two semantic defects (issue #11).
#
# The codex event model is not claude's message model, and mapping one onto the
# other without accounting for what codex injects produces two wrong numbers:
#
#   closure   codex writes no `stop_reason` on any record, so the closure layer
#             reached its "pass" verdict through an empty string. Measured: 0 of
#             25 rollouts on this machine carry the field. The buy-side spec
#             (PACK-SPEC § 5) requires the skip to be RECORDED, because "the
#             closure layer passed this file" and "the closure layer did not
#             apply to this file" are different statements about a delivered
#             batch. A claude_code session with an absent `stop_reason` is the
#             opposite case and fails: that format does have the field, so its
#             absence at the last assistant record is a finding about the file.
#
#   turns     codex delivers its own `<environment_context>` block as a
#             `role: "user"` message. Counting it inflates every codex session
#             by one, so the pack's `min_user_turns` floor is off by one for
#             codex input -- on a floor of 5 it admits sessions with 4 real
#             turns. Measured on a one-shot translation rollout: the funnel
#             reported `user_turns 2` for one real request.
#
# Fixtures are synthetic .jsonl files under $WORK. The user's real sessions are
# never read, never written, never needed -- the real-store acceptance run is
# `test/codex-translation-windows.sh`, not part of a regression suite.
#
# Usage: test/codex-semantics-e2e.sh [work-dir]   (default /tmp/codex-sem-e2e)
# Dependencies: bash, awk, python3. NOT tmux, NOT fzf, NOT jq.
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
F="$REPO/skills/agent-session-batch-export/scripts/funnel.py"
WORK="${1:-/tmp/codex-sem-e2e}"

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
no()   { fail=$((fail + 1)); echo "  FAIL $1"; }
chk()  { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else no "$1: got '$2' want '$3'"; fi; }
has()  { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1: missing '$3'"; fi; }
hasnt(){ if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1: unexpected '$3'"; fi; }

command -v python3 >/dev/null || { echo "SKIP: python3 not available"; exit 0; }

echo "codex semantics e2e — work dir: $WORK"
echo "script: $(basename "$F")"

# ---------------------------------------------------------------- fixtures
rm -rf "$WORK"; mkdir -p "$WORK"
python3 - "$WORK" <<'PY'
import json, os, sys
w = sys.argv[1]

# The exact shape codex writes: the block owns the whole message, its content is
# a single `input_text`, and it arrives as an ordinary `role: "user"` message.
ENV_BLOCK = ("<environment_context>\n  <cwd>{cwd}</cwd>\n"
             "  <shell>powershell</shell>\n  <current_date>2026-09-15</current_date>\n"
             "  <timezone>Australia/Perth</timezone>\n  <filesystem>"
             + "<workspace_roots>" + "<root>C:\\Users\\Samuka007</root>" * 12
             + "</workspace_roots></filesystem>\n</environment_context>")
REAL = "翻译 桃花源记 为日文"          # 11 characters -- the measured one-shot request


def codex_user(text):
    return {"type": "response_item", "payload": {
        "type": "message", "role": "user",
        "content": [{"type": "input_text", "text": text}]}}


def codex_assistant(i):
    return {"type": "response_item", "payload": {
        "type": "message", "role": "assistant",
        "content": [{"type": "output_text", "text": f"translated passage {i} " * 30}]}}


def codex_developer(tag, body):
    return {"type": "response_item", "payload": {
        "type": "message", "role": "developer",
        "content": [{"type": "input_text", "text": f"<{tag}>\n{body}\n</{tag}>"}]}}


def codex_reasoning():
    return {"type": "response_item", "payload": {
        "type": "reasoning", "encrypted_content": "XYZ" * 40}}


def write(name, recs):
    p = os.path.join(w, name)
    with open(p, "w", encoding="utf-8") as fh:
        fh.write("\n".join(json.dumps(r) for r in recs) + "\n")
    return p


def codex_session(name, cwd, users):
    """codex's opening sequence, then one assistant turn per user turn."""
    recs = [{"type": "session_meta", "payload": {"model_provider": "OpenAI"}},
            {"type": "event_msg", "payload": {"type": "task_started"}},
            # codex also injects `developer` messages. They never reach the
            # `user` branch; they are here so a filter that keyed on the tag
            # alphabet rather than on role would show up as a wrong count.
            codex_developer("skills_instructions",
                            "## Skills\nA skill is a set of local instructions to follow…"),
            codex_developer("multi_agent_mode",
                            "Do not spawn sub-agents unless the user asks for them."),
            codex_user(ENV_BLOCK.replace("{cwd}", cwd))]
    for i, u in enumerate(users):
        recs += [codex_user(u), codex_reasoning(), codex_assistant(i)]
    return write(name, recs)


def claude(name, user_msgs, last_stop, model="claude-opus-5"):
    """A claude_code .jsonl. `last_stop=None` writes the last assistant record
    with NO stop_reason at all (not an empty string) -- the truncation case."""
    recs = []
    for i, u in enumerate(user_msgs):
        recs.append({"type": "user", "message": {"role": "user", "content": u}})
        rec = {"type": "assistant", "message": {"role": "assistant", "model": model,
               "content": [{"type": "thinking", "thinking": "t", "signature": "A" * 384},
                           {"type": "text", "text": f"reply {i} " * 40}]}}
        sr = last_stop if i == len(user_msgs) - 1 else "end_turn"
        if sr is not None:
            rec["stop_reason"] = sr
        recs.append(rec)
    return write(name, recs)


# Every first user message below is deliberately distinct: dedup compares them
# with 5-gram Jaccard, and a shared opening would collapse two fixtures into one
# and hide the layer the assertion is about.
files = [
    # the measured defect, reproduced: one real request + the injected block
    ("codex", codex_session("codex-oneshot.jsonl", "C:\\Users\\Samuka007", [REAL])),
    # a real multi-turn codex session: three real turns, one injected block
    ("codex", codex_session("codex-multiturn.jsonl", "C:\\Users\\Samuka007\\Documents",
                            ["translate this document into japanese",
                             "continue with part two of the document",
                             "and now the third part of the document please"])),
    # two codex sessions with the SAME real opening and DIFFERENT injected
    # blocks (different cwd): dedup must collapse them, which is only possible
    # if first_user_msg is the real message and not the block
    ("codex", codex_session("codex-twin-a.jsonl", "C:\\work\\alpha",
                            ["write me a long report about terrace farming"])),
    ("codex", codex_session("codex-twin-b.jsonl", "D:\\other\\beta",
                            ["write me a long report about terrace farming"])),
    # a codex file whose only user records are injected blocks
    ("codex", write("codex-all-injected.jsonl", [
        {"type": "session_meta", "payload": {"model_provider": "OpenAI"}},
        codex_user(ENV_BLOCK.replace("{cwd}", "C:\\empty")),
        codex_assistant(0)])),
    # NOT injected: the tag mentioned inside a longer real request
    ("codex", write("codex-inline-mention.jsonl", [
        codex_user("explain why the environment_context tag is delivered as a user message"),
        codex_assistant(0)])),
    # NOT injected: a tagged block codex does not inject
    ("codex", write("codex-handwritten-example.jsonl", [
        codex_user("<example>\nthe user asked for a translation of a classical text\n</example>"),
        codex_assistant(0)])),
    # <user_instructions> IS an injected block (same class as the environment)
    ("codex", write("codex-user-instructions.jsonl", [
        codex_user("<user_instructions>\nalways answer in one paragraph\n</user_instructions>"),
        codex_user("what is the capital of peru"),
        codex_assistant(0)])),
    ("claude", claude("claude-normal.jsonl",
                      ["draft an essay about andean terrace farming"], "end_turn")),
    ("claude", claude("claude-nostop.jsonl",
                      ["summarise the history of tidal marsh restoration"], None)),
    # an earlier turn closed properly, the LAST record did not: the stage must
    # read the last record, not the last non-empty value
    ("claude", write("claude-truncated-tail.jsonl", [
        {"type": "user", "message": {"role": "user",
         "content": "describe viking longship rigging in detail"}},
        {"type": "assistant", "message": {"role": "assistant",
         "content": [{"type": "text", "text": "part one " * 40}]},
         "stop_reason": "end_turn"},
        {"type": "user", "message": {"role": "user",
         "content": "now expand the second section of that description"}},
        {"type": "assistant", "message": {"role": "assistant",
         "content": [{"type": "text", "text": "part two " * 40}]}},
    ])),
]

hdr = "agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file"


def cands(path, entries):
    with open(os.path.join(w, path), "w", encoding="utf-8") as fh:
        fh.write(hdr + "\n")
        for agent, p in entries:
            fh.write(f"{agent}\t/w/x\t0\t{os.path.getsize(p)}\t0\tfirst\t{p}\n")


cands("candidates.tsv", files)
# two rows only: the measured one-shot plus a claude control. Used by the L5
# length assertions so the kill reason under test is the only one in the row.
cands("candidates-2.tsv",
      [f for f in files if f[1].endswith(("codex-oneshot.jsonl", "claude-normal.jsonl"))])

print(f"fixtures: {len(files)} sessions, environment block {len(ENV_BLOCK.replace('{cwd}','C:\\\\Users\\\\Samuka007'))} chars, "
      f"real first message {len(REAL)} chars")
PY

# col BASENAME COLUMN -> the enriched value for that fixture ('' if absent)
col() {
  awk -F'\t' -v want="$1" -v c="$2" '
    NR == 1 { for (i = 1; i <= NF; i++) { if ($i == c) h = i; if ($i == "session_file") f = i } ; next }
    { n = $f; sub(/.*\//, "", n); if (n == want) print $h }' "$WORK/enriched.tsv"
}
# cell Lx FIELD FILE -> one column of a stage's printed row, split on whitespace:
#   `L4 end_turn   11   killed 2     skipped 8    (…)`
#    $1 $2          $3     $4  $5        $6  $7
cell() {
  awk -v lbl="$1" -v fld="$2" -F'[ \t]+' '
    $1 == lbl && $3 ~ /^[0-9]/ { print $fld }' "$WORK/$3"
}
# row LABEL FILE -> a stage's printed row with its reason collapsed to one line.
# The reason column wraps at the table width (textwrap), so a phrase like
# "skip: no stop_reason in this format x8" arrives split across two printed
# lines; joining them lets an assertion name the phrase as the operator wrote
# it. Continuation lines start at the reason column (62 spaces).
# The reason column wraps at the table width (textwrap), so a phrase like
# "skip: no stop_reason in this format x8" can arrive split over two printed
# lines. The row is joined back into one line so an assertion can name the
# phrase as the operator reads it. A stage row starts with its two-word label;
# its continuations are indented past the reason column.
row() {
  awk -v lbl="$1" '
    substr($0, 1, length(lbl)) == lbl && $3 ~ /^[0-9]/ { on = 1; printf "%s ", $0; next }
    on { if ($0 ~ /^ {20,}/) { printf "%s ", $0; next } on = 0 }
  ' "$WORK/$2" | tr -s ' '
}
alive_list() { awk -F'\t' 'NR>1 { n = $NF; sub(/.*\//, "", n); print n }' "$WORK/$1" | sort | tr '\n' ' '; }

# ------------------------------------------- A: injected blocks are not turns
echo
echo "== A: the environment block is not a user turn =="
python3 "$F" enrich "$WORK/candidates.tsv" "$WORK/enriched.tsv" >/dev/null
chk "oneshot: one real turn, not two" "$(col codex-oneshot.jsonl user_turns)" "1"
chk "oneshot: the block is counted apart" "$(col codex-oneshot.jsonl injected_user_messages)" "1"
chk "multiturn: three real turns" "$(col codex-multiturn.jsonl user_turns)" "3"
chk "multiturn: one block" "$(col codex-multiturn.jsonl injected_user_messages)" "1"
chk "all-injected: zero real turns" "$(col codex-all-injected.jsonl user_turns)" "0"
chk "all-injected: the block is still recorded" "$(col codex-all-injected.jsonl injected_user_messages)" "1"
chk "user_instructions is an injected block too" \
  "$(col codex-user-instructions.jsonl injected_user_messages)" "1"
chk "inline mention of the tag is a real turn" \
  "$(col codex-inline-mention.jsonl injected_user_messages)" "0"
chk "inline mention still counts as a turn" \
  "$(col codex-inline-mention.jsonl user_turns)" "1"
chk "a hand-written <example> block is a real turn" \
  "$(col codex-handwritten-example.jsonl injected_user_messages)" "0"
chk "claude carries no injected block" "$(col claude-normal.jsonl injected_user_messages)" "0"
# The `developer` messages codex also injects reach neither count: they are not
# user turns, and they are not injected *user* messages.
chk "developer blocks are neither count" "$(col codex-oneshot.jsonl user_turns)" "1"
chk "developer blocks do not become turns" "$(col codex-multiturn.jsonl user_turns)" "3"

# ------------------------------- B: first_user_msg is the real first message
echo
echo "== B: first_user_msg is the real message, not the block =="
# The real request is 11 characters; the injected block is hundreds. This column
# is the only place the funnel shows which message `first_user_msg` holds.
chk "oneshot: first message is the real one" "$(col codex-oneshot.jsonl first_msg_chars)" "11"
python3 "$F" run "$WORK/candidates-2.tsv" "$WORK/out-cap300.tsv" \
  --min-turns 0 --max-tool-ratio 1.0 --no-end-turn --dedup-threshold 1.0 \
  --topic-keywords "" --max-first-msg-chars 300 --min-user-msg-chars 0 \
  > "$WORK/run.cap300" 2>&1
chk "cap 300: nothing is killed as scaffold noise" "$(cell L5 5 run.cap300)" "0"
hasnt "no scaffold-noise kill is claimed" "$(row 'L5 length' run.cap300)" "scaffold noise"
python3 "$F" run "$WORK/candidates-2.tsv" "$WORK/out-cap10.tsv" \
  --min-turns 0 --max-tool-ratio 1.0 --no-end-turn --dedup-threshold 1.0 \
  --topic-keywords "" --max-first-msg-chars 10 --min-user-msg-chars 0 \
  > "$WORK/run.cap10" 2>&1
has "cap 10 kills the 11-char real request" \
  "$(row 'L5 length' run.cap10)" "first user msg 11 > cap 10"
# If the block were still the first message, the identical pair below would
# differ by cwd alone and survive as two instead of collapsing.
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out-dup.tsv" \
  --min-turns 0 --max-tool-ratio 1.0 --no-end-turn --topic-keywords "" \
  --max-first-msg-chars 0 --min-user-msg-chars 0 > "$WORK/run.dup" 2>&1
# dedup is L9 since the noncode and credential stages joined the order.
chk "dedup collapsed the twin codex pair" "$(cell L9 5 run.dup)" "1"
has "and the survivor list holds one of the two" "$(alive_list out-dup.tsv)" "codex-twin-a.jsonl"

# ------------------------------------------------- C: the closure skip
echo
echo "== C: closure — codex skips, claude with no stop_reason fails =="
# --dedup-threshold 1.0 collapses only exact duplicates, so the counts below are
# the closure layer's own and nothing is removed before it runs.
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out-closure.tsv" \
  --min-turns 0 --max-tool-ratio 1.0 --topic-keywords "" --dedup-threshold 1.0 \
  --max-first-msg-chars 0 --min-user-msg-chars 0 > "$WORK/run.closure" 2>&1
# 8 codex sessions, 3 claude. Codex skips (no field in the format); of the
# claude three, the one with `end_turn` passes and the other two are findings.
chk "codex sessions are SKIPPED, not killed" "$(cell L4 7 run.closure)" "8"
chk "the two claude findings are killed" "$(cell L4 5 run.closure)" "2"
row="$(row 'L4 end_turn' run.closure)"
has "the skip reason is the format, not the data" "$row" "skip: no stop_reason in this format"
has "the claude finding names the absent field" "$row" "last stop_reason absent on claude_code"
alive="$(alive_list out-closure.tsv)"
has  "codex-oneshot survived the closure layer" "$alive" "codex-oneshot.jsonl"
has  "claude-normal survived"                   "$alive" "claude-normal.jsonl"
hasnt "claude-nostop was killed"                "$alive" "claude-nostop.jsonl"
# the truncated tail must not inherit the earlier turn's `end_turn`
hasnt "truncated-tail was killed, not waved through" "$alive" "claude-truncated-tail.jsonl"
# With the stage switched off nothing is judged: the codex skip is a property of
# the stage running, not of the parser.
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out-noet.tsv" \
  --min-turns 0 --max-tool-ratio 1.0 --topic-keywords "" --dedup-threshold 1.0 \
  --no-end-turn --max-first-msg-chars 0 --min-user-msg-chars 0 > "$WORK/run.noet" 2>&1
chk "L4 switched off skips nothing" "$(cell L4 7 run.noet)" "0"
chk "L4 switched off kills nothing" "$(cell L4 5 run.noet)" "0"

# ---------------------------------- D: the table distinguishes skip from pass
echo
echo "== D: a skip is not a pass in the printed table =="
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out-mixed.tsv" \
  --min-turns 0 --max-tool-ratio 1.0 --topic-keywords "" --dedup-threshold 1.0 \
  --max-first-msg-chars 0 --min-user-msg-chars 0 > "$WORK/run.mixed" 2>&1
chk "kill column holds only the real failures" "$(cell L4 5 run.mixed)" "2"
chk "skip column holds the format skips"       "$(cell L4 7 run.mixed)" "8"
has "the row names the skip class" "$(row 'L4 end_turn' run.mixed)" "skip:"
# a stage that judged everything reports `skipped 0`: the two columns are not
# the same number printed twice
chk "L1 (judges everything) reports skipped 0" "$(cell L1 7 run.mixed)" "0"
chk "L1 killed nothing here"                   "$(cell L1 5 run.mixed)" "0"
# The injected-block correction is stated rather than implied: an auditor
# re-running this pack must see the turn counts were reduced, and by how much.
# Six of the eight codex fixtures carry a block (the inline-mention and
# hand-written-example ones carry none, which is what section A asserts), so the
# line must read 6 -- the number of blocks, not the number of sessions.
has "the table states the excluded block count" \
  "$(sed -n 's/^\(inject .*\)$/\1/p' "$WORK/run.mixed")" \
  "6 injected user block(s) excluded from user_turns"
has "and names how many sessions they came from" \
  "$(sed -n 's/^\(inject .*\)$/\1/p' "$WORK/run.mixed")" "6  "
# With no injected block anywhere the line is absent rather than printed as a
# zero, so it never reads as a measurement that was made.
python3 - "$WORK" <<'PY'
import os, sys
w = sys.argv[1]
hdr = "agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file"
p = os.path.join(w, "claude-normal.jsonl")
with open(os.path.join(w, "candidates-claude.tsv"), "w", encoding="utf-8") as fh:
    fh.write(hdr + "\n")
    fh.write(f"claude\t/w/x\t0\t{os.path.getsize(p)}\t0\tfirst\t{p}\n")
PY
python3 "$F" run "$WORK/candidates-claude.tsv" "$WORK/out-c.tsv" \
  --min-turns 0 --max-tool-ratio 1.0 --topic-keywords "" --dedup-threshold 1.0 \
  --max-first-msg-chars 0 --min-user-msg-chars 0 > "$WORK/run.c" 2>&1
chk "no injected block means no inject line" \
  "$(grep -c '^inject' "$WORK/run.c")" "0"

# --------------------------------------------------------------- summary
printf '\n=====================\n'
if [[ $fail -eq 0 ]]; then echo "CODEX SEMANTICS E2E: ALL CHECKS PASSED ($pass)"; else echo "CODEX SEMANTICS E2E: FAILURES PRESENT ($fail)"; fi
printf '=====================\n'
exit $((fail > 0))
