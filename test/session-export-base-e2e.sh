#!/usr/bin/env bash
# End-to-end over the deterministic direction runner
# (skills/agent-session-batch-export/scripts/export-direction.sh).
#
# Every check here is a contract a plausible bug would break, and two of them
# already did during implementation:
#
#   * decisions.tsv is ten columns with the three verdict columns FIRST. The
#     first version of the runner wrote nine in the wrong order and finalize
#     refused the batch.
#   * one `sk-ant-…` key was counted twice and reported under two vendors,
#     because the openai_key pattern also matched it.
#
# Fixtures rather than the real stores: this must give the same answer on any
# machine, and a test that reads ~/.codex says nothing repeatable about the
# runner. The one real-data assertion lives in codex-translation-windows.sh.
set -uo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
SKILL="$REPO/skills/agent-session-batch-export"
RUNNER="$SKILL/scripts/export-direction.sh"
DIRJSON="$REPO/skills/session-export-nocode/direction.json"
W="${1:-/tmp/session-export-base-e2e}"

pass=0; fail=0
chk() { # label want got
  if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else printf '  FAIL %s\n         want %q\n         got  %q\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}
has() { # label haystack needle
  if [[ "$2" == *"$3"* ]]; then printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else printf '  FAIL %s\n         %q not in output\n' "$1" "$3"; fail=$((fail + 1)); fi
}
lacks() {
  if [[ "$2" != *"$3"* ]]; then printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else printf '  FAIL %s\n         %q unexpectedly present\n' "$1" "$3"; fail=$((fail + 1)); fi
}

command -v jq >/dev/null 2>&1 || { echo "session-export-base-e2e: needs jq"; exit 1; }
python3 -c '' >/dev/null 2>&1 || { echo "session-export-base-e2e: needs a working python3"; exit 1; }

rm -rf "$W"; mkdir -p "$W"
H="$W/home"
S="$H/.codex/sessions/2026/09/15"
mkdir -p "$S" "$H/.claude/projects/demo"

# A codex session needs a session_meta line: scan reads cwd from it and skips
# any file where cwd is empty (curate-sessions.sh). A fixture without it is
# invisible, which looks exactly like a broken funnel.
meta='{"type":"session_meta","payload":{"cwd":"/home/demo/notes","model_provider":"OpenAI"}}'
mkcodex() { # name  user-text
  { printf '%s\n' "$meta"
    printf '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":%s}]}}\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2")"
    printf '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"text":"ok"}]}}\n'
  } > "$S/rollout-$1.jsonl"
}

# One-shot translation: the case the family exists to buy. Its whole request is
# eleven characters and the work is in the answer.
mkcodex oneshot '翻译 桃花源记 为日文'
# Coding work that also says "翻译". A positive keyword list selects it; the
# noncode stage is what rejects it.
mkcodex coding  '帮我重构这个模块并修复报错，翻译一下注释'
# Zero real user turns: only an injected context block. Must reach later stages
# rather than being filed as "unparseable".
mkcodex zeroturn '<environment_context><cwd>/x</cwd></environment_context>'

# This suite tests the RUNNER contract, not the purchase. The shipped
# direction's theme list is allowed to move (SPEC item 29 narrowed it to four,
# dropping `translation`), and a fixture whose export depends on a theme that
# is no longer bought would fail for a reason that says nothing about the
# runner. So the tests run against the shipped direction with `translation`
# and the report-only `multimodal` added: same root override, same schema
# gate, plus the one-shot case this family exists to buy and the one
# report-only theme the manifest contract is pinned against. Composed here,
# from the shipped file, every run.
TESTDIRJSON="$W/direction.json"
jq --slurpfile d "$DIRJSON" -n \
  '$d[0] | .themes = ([{theme: "translation"}, {theme: "multimodal"}] + .themes)' \
  > "$TESTDIRJSON"

run() { # outdir extra-args...
  local out="$1"; shift
  rm -rf "$out"
  HOME="$H" bash "$RUNNER" --direction-file "$TESTDIRJSON" -o "$out" "$@" 2>&1
}

echo "== the funnel decides, and it decides the same way twice =="
o1="$(run "$W/r1" --yolo)"; rc1=$?
chk "a clean run succeeds" "0" "$rc1"
has "the report says there was no screening step" "$o1" "no screening step"
has "the coding session dies at the noncode stage" "$o1" "L7 noncode"
# The zero-turn fixture must not be killed by the turn floor: min_user_turns is
# 0 in this family, and a parser returning None for it would have filed it as an
# unreadable file instead.
#
# The invariant is that NO turn row kills anything, so that is what is asserted.
# The expected row count is derived from the direction's theme entries rather
# than written here, because a hard-coded count would fail the day a theme is
# added — which would say nothing about the turn floor.
selecting="$(jq -r --slurpfile d "$TESTDIRJSON" -n \
  '$d[0].themes[] | .theme' | while read -r t; do
     [[ "$(jq -r '.report_only // false' "$SKILL/themes/$t.json")" == "true" ]] || echo "$t"
   done | wc -l | tr -d ' ')"
chk "the turn stage ran once per selecting theme" "$selecting" \
  "$(printf '%s\n' "$o1" | grep -cE '^L1 turns ')"
chk "and the turn floor killed nothing" "0" \
  "$(printf '%s\n' "$o1" | grep -cE '^L1 turns .* killed [1-9]')"
lacks "and nothing was reported unparseable" "$o1" "unparseable"

sel() { jq -r '[.[] | {s: .source, h: .sha256, t: (.themes // [] | sort)}] | sort_by(.s)' "$1/manifest.json"; }
run "$W/r2" --yolo >/dev/null; chk "a second run succeeds" "0" "$?"
chk "same selection and same hashes" "$(sel "$W/r1")" "$(sel "$W/r2")"

echo
echo "== the selection is installed, not suggested =="
# Ten columns, verdict first. This is the shape review --ui tsv writes and
# finalize reads; getting it wrong fails the run, so it is worth pinning.
hdr="$(head -1 "$W/r1/decisions.tsv")"
chk "decisions.tsv has ten columns" "10" "$(awk -F'\t' 'NR==1{print NF}' "$W/r1/decisions.tsv")"
chk "and the verdict columns come first" "decision	reason	suggested" \
  "$(printf '%s' "$hdr" | cut -f1-3)"
chk "every row is a keep" "0" \
  "$(awk -F'\t' 'NR>1 && $1 != "keep"' "$W/r1/decisions.tsv" | wc -l | tr -d ' ')"
has "and says the funnel chose it" "$(sed -n '2p' "$W/r1/decisions.tsv")" "selected by the funnel"
# No screening step exists on this path, so there is no row for an agent to
# fill — which is the difference between this and the interactive pipeline.
chk "no screen.tsv is produced" "absent" \
  "$(test -e "$W/r1/screen.tsv" && echo present || echo absent)"

echo
echo "== copies are byte-identical and the manifest says how they were chosen =="
# Python recomputes the bytes and the digest; jq reads the JSON fields, so a
# Python bool never reaches a comparison against JSON's `false`.
python3 - "$W/r1/manifest.json" > "$W/verify.txt" <<'PY'
import hashlib, json, pathlib, sys
m = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
bad = [e for e in m
       if pathlib.Path(e["source"]).read_bytes() != pathlib.Path(e["kept_as"]).read_bytes()
       or hashlib.sha256(pathlib.Path(e["source"]).read_bytes()).hexdigest() != e["sha256"]]
print(len(m), len(bad), sep="\t")
PY
IFS=$'\t' read -r n_entries n_bad < "$W/verify.txt"
chk "the one-shot translation was exported" "1" "$n_entries"
chk "bytes and sha256 both match the original" "0" "$n_bad"
chk "the manifest records how it was selected" "funnel-deterministic" \
  "$(jq -r '.[0].selection' "$W/r1/manifest.json")"
chk "and that no human confirmed the batch (--yolo)" "false" \
  "$(jq -r '.[0].batch_confirmed' "$W/r1/manifest.json")"
chk "the manifest records the global policy file" "$SKILL/scripts/policy.json" \
  "$(jq -r '.[0].policy.file' "$W/r1/manifest.json")"
chk "and the policy digest matches the shipped file" \
  "$(sha256sum "$SKILL/scripts/policy.json" | cut -d' ' -f1)" \
  "$(jq -r '.[0].policy.sha256' "$W/r1/manifest.json")"

echo
echo "== credentials refuse the batch, and only an explicit flag proceeds =="
mkcodex leak '翻译这段文本 sk-ant-abcdefghij0123456789'
o3="$(run "$W/cred" --yolo)"; chk "a credential hit refuses" "3" "$?"
has "the refusal says so" "$o3" "refusing the batch"
has "and names the flag that overrides it" "$o3" "--allow-credentials"
# Nothing may be left behind: a half-written directory would let a caller
# mistake a refusal for a delivery.
chk "and writes nothing at all" "absent" \
  "$(test -e "$W/cred" && echo present || echo absent)"

o4="$(run "$W/allow" --yolo --allow-credentials)"; chk "the explicit flag proceeds" "0" "$?"
has "with a warning that they will be exported" "$o4" "WILL be exported"
chk "the manifest records the decision" "true" "$(jq -r '.[0].allow_credentials' "$W/allow/manifest.json")"
# One key, one hit. Two overlapping patterns previously counted it twice and
# reported it under two vendors; an inflated disclosure is worse than none
# because the reader cannot tell it is wrong.
chk "one key counts once" "1" "$(jq -r '.[0].credential_hits' "$W/allow/manifest.json")"
chk "under one vendor name" "anthropic_key" \
  "$(HOME="$H" python3 "$SKILL/scripts/funnel.py" enrich "$W/allow/candidates.full.tsv" "$W/enr.tsv" >/dev/null 2>&1
     awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next} $h["credential_kinds"]!=""{print $h["credential_kinds"]}' "$W/enr.tsv" | sort -u)"
rm -f "$S/rollout-leak.jsonl"

echo
echo "== a direction may name themes and nothing else =="
# A threshold in a direction file is a second copy of a number the policy
# layers already own, which is the drift the layering exists to prevent. The
# same gate rejects the v1 direction shape (a plain-string themes array):
# silently half-reading an old file would run a bundle its author did not write.
jq '. + {policy: {min_user_turns: 9}}' "$DIRJSON" > "$W/bad-policy.json"
o5="$(HOME="$H" bash "$RUNNER" --direction-file "$W/bad-policy.json" -o "$W/x" --yolo 2>&1)"
chk "a policy key is refused" "2" "$?"
has "and says where thresholds belong" "$o5" "belong in scripts/policy.json"

jq '.themes = ["translation", "no-such-theme"]' "$DIRJSON" > "$W/legacy.json"
o="$(HOME="$H" bash "$RUNNER" --direction-file "$W/legacy.json" -o "$W/l" --yolo 2>&1)"
chk "a v1 (string) themes array is refused" "2" "$?"
has "and says why" "$o" "non-object theme entry"

jq '.themes = [{theme: "translation"}, {theme: "no-such-theme"}]' "$DIRJSON" > "$W/bad-theme.json"
o6="$(HOME="$H" bash "$RUNNER" --direction-file "$W/bad-theme.json" -o "$W/y" --yolo 2>&1)"
chk "an unknown theme is refused" "2" "$?"
has "and names the file it looked for" "$o6" "no-such-theme.json"

echo
echo "== a report-only theme is counted, never selected =="
# multimodal has an empty keyword list, so its topic stage is OFF. Folding it
# into the union would select the entire scan under a theme that exists only
# to report counters.
chk "multimodal reports n/a rather than a count" "null" \
  "$(jq -r '.[0].entries[] | select(.theme == "multimodal") | .count' "$W/r1/manifest.json")"
chk "and no exported session claims it" "0" \
  "$(jq -r '[.[] | select((.themes // []) | index("multimodal"))] | length' "$W/r1/manifest.json")"
chk "the manifest records one entry per direction theme" "6" \
  "$(jq -r '.[0].entries | length' "$W/r1/manifest.json")"
chk "each entry carries the direction's root override" "6" \
  "$(jq -r --slurpfile d "$DIRJSON" \
     '[.[] | select((.override == ($d[0].override // {})))] | length' \
     <(jq '.[0].entries' "$W/r1/manifest.json"))"

echo
echo "== the confirmation prompt is a real prompt in a real terminal =="
# Driven through tmux rather than a redirect, because the prompt is a thing the
# user SEES: a non-interactive run of the same code asserts the exit status, not
# the surface. The asymmetry is why this is worth a terminal — a wrongly
# withheld export costs one re-run, and a wrongly authorised one has already
# left the machine.
if ! command -v tmux >/dev/null 2>&1; then
  printf '  FAIL %s\n' "tmux absent: the prompt cannot be driven, so it is NOT verified"
  fail=$((fail + 1))
else
  SESS="seb$$"
  tmux kill-session -t "$SESS" 2>/dev/null || true
  tmux new-session -d -s "$SESS" -x 200 -y 50
  wait_for() { # pattern
    local i
    for i in $(seq 1 60); do
      sleep 0.5
      tmux capture-pane -p -t "$SESS" | grep -q "$1" && return 0
    done
    return 1
  }

  # `n` must abort and leave nothing behind. A prompt that treated any answer
  # as consent would pass a redirect-based test and fail here.
  rm -rf "$W/prompt-no"
  tmux send-keys -t "$SESS" \
    "HOME='$H' bash '$RUNNER' --direction-file '$TESTDIRJSON' -o '$W/prompt-no'" Enter
  if wait_for 'export these'; then
    printf '  ok   %s\n' "the prompt is rendered on a terminal"; pass=$((pass + 1))
    prompt_line="$(tmux capture-pane -p -t "$SESS" | grep -o 'export these .* \[y/N\]' | sed -n 1p)"
    has "and it defaults to no, visibly" "$prompt_line" "[y/N]"
    tmux send-keys -t "$SESS" "n" Enter
    if wait_for 'aborted at the confirmation prompt'; then
      printf '  ok   %s\n' "answering n aborts"; pass=$((pass + 1))
    else
      printf '  FAIL %s\n' "answering n did not abort"; fail=$((fail + 1))
    fi
    chk "and nothing was written" "absent" \
      "$(test -e "$W/prompt-no" && echo present || echo absent)"
  else
    printf '  FAIL %s\n' "the prompt never appeared"; fail=$((fail + 1))
  fi

  # `y` proceeds, and the manifest must record that a human confirmed THIS
  # batch — the one field that distinguishes it from the --yolo run above.
  rm -rf "$W/prompt-yes"
  tmux send-keys -t "$SESS" \
    "HOME='$H' bash '$RUNNER' --direction-file '$TESTDIRJSON' -o '$W/prompt-yes'" Enter
  if wait_for 'export these'; then
    tmux send-keys -t "$SESS" "y" Enter
    if wait_for 'export-direction: done'; then
      printf '  ok   %s\n' "answering y exports"; pass=$((pass + 1))
      chk "and the manifest records the batch as confirmed" "true" \
        "$(jq -r '.[0].batch_confirmed' "$W/prompt-yes/manifest.json")"
      chk "while the selection is still the funnel's" "funnel-deterministic" \
        "$(jq -r '.[0].selection' "$W/prompt-yes/manifest.json")"
      chk "and it is the same session the yolo run chose" \
        "$(jq -r '.[0].sha256' "$W/r1/manifest.json")" \
        "$(jq -r '.[0].sha256' "$W/prompt-yes/manifest.json")"
    else
      printf '  FAIL %s\n' "answering y did not complete"; fail=$((fail + 1))
    fi
  else
    printf '  FAIL %s\n' "the prompt never appeared on the second run"; fail=$((fail + 1))
  fi
  tmux kill-session -t "$SESS" 2>/dev/null || true
fi

echo
printf 'SESSION-EXPORT-BASE E2E: %s (%d passed' \
  "$([[ "$fail" -eq 0 ]] && echo "ALL CHECKS PASSED" || echo "$fail FAILED")" "$pass"
[[ "$fail" -gt 0 ]] && printf ', %d failed' "$fail"
printf ')\n'
[[ "$fail" -eq 0 ]] || exit 1
