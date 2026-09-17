#!/usr/bin/env bash
# E2E regression for the SPEC item 25 merge chain:
#   global policy -> theme.override -> --override-file -> flags
# merged per key, later winning, with `null` and an empty word list both
# meaning "clear the key" (the stage prints OFF).
#
# The defects this suite exists for are the ones a layering rewrite invites:
#   * a layer silently NOT winning (the theme's override ignored under the
#     global policy, a flag ignored under the override file);
#   * a clear not clearing (null or [] leaving the lower layer's value alive);
#   * a mistyped override key passing silently and running a standard nobody
#     chose;
#   * an empty word list reading as "ran and passed everything" instead of OFF;
#   * a legacy file shape (a theme carrying its own thresholds or exclusion
#     list) being half-read instead of refused.
#
# Fixtures are synthetic .jsonl files under $WORK; the legacy-shape cases run a
# COPY of the engine so the shipped themes dir is never polluted.
#
# Usage: test/merge-chain-e2e.sh [work-dir]   (default /tmp/merge-chain-e2e)
# Dependencies: bash, awk, python3. NOT tmux, NOT fzf, NOT jq.
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
F="$REPO/skills/agent-session-batch-export/scripts/funnel.py"
WORK="${1:-/tmp/merge-chain-e2e}"

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
no()   { fail=$((fail + 1)); echo "  FAIL $1"; }
chk()  { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else no "$1: got '$2' want '$3'"; fi; }
has()  { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1: missing '$3'"; fi; }
hasnt(){ if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1: unexpected '$3'"; fi; }
non0() { if [[ "$2" -ne 0 ]]; then ok "$1 (rc=$2)"; else no "$1: expected failure, rc=0"; fi; }

command -v python3 >/dev/null || { echo "SKIP: python3 not available"; exit 0; }

echo "merge-chain e2e — work dir: $WORK"
echo "script: $(basename "$F")"

# ---------------------------------------------------------------- fixtures
# Three claude_code sessions differing ONLY in user-turn count (1/3/5), so the
# min_user_turns threshold is a clean per-layer discriminator: the global
# policy sets 0 (all survive), the coding theme 3 (s1 dies), a higher layer
# can restate it. Their opening prose carries a coding keyword (调试) because
# the coding theme's topic stage matches its OWN word list — a session that
# fails L6 never reaches L9, and the turn story needs sessions that do. All
# sessions pass every other stage under any parameter set used here: no
# tools, end_turn closure, messages clearing the length floor, and
# pairwise-distinct openings (dedup must not fire).
rm -rf "$WORK"; mkdir -p "$WORK/src"
python3 - "$WORK" <<'PY'
import json, os, sys
w = sys.argv[1]
S = os.path.join(w, "src")


def claude(name, first, later):
    lines = [json.dumps({"type": "user", "message": {"role": "user", "content": first}})]
    for u in later:
        lines.append(json.dumps({"type": "user", "message": {"role": "user", "content": u}}))
        lines.append(json.dumps({"type": "assistant",
            "message": {"role": "assistant", "content": [{"type": "text", "text": "reply " * 40}]},
            "stop_reason": "end_turn"}))
    lines.append(json.dumps({"type": "assistant",
        "message": {"role": "assistant", "content": [{"type": "text", "text": "closing " * 40}]},
        "stop_reason": "end_turn"}))
    p = os.path.join(S, name)
    open(p, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    return p


LATER = ["please expand the section about irrigation canals further" for _ in range(6)]
# 20+ character first messages: they clear the 20-char length floor of the
# global policy, so L5 never interferes with the turn-threshold story.
s1 = claude("s1.jsonl", "帮我调试这段安第斯梯田灌溉脚本的第一处报错", [])
s3 = claude("s3.jsonl", "帮我调试这段潮汐沼泽传感器脚本的第三处报错", LATER[:2])
s5 = claude("s5.jsonl", "帮我调试这段维京长船模拟脚本的第五处报错", LATER[:4])
# A prose session for the L7 exclusion tests: no coding keyword in its topic
# stage survives; the EXCLUSION list is what kills it when supplied.
prs = claude("prs.jsonl", "把这段关于安第斯梯田的观察笔记整理成一份提纲", LATER[:4])

hdr = "agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file"


def cands(name, files):
    with open(os.path.join(w, name), "w", encoding="utf-8") as fh:
        fh.write(hdr + "\n")
        for p in files:
            fh.write(f"claude\t/home/u/proj\t0\t{os.path.getsize(p)}\t9\tfirst\t{p}\n")


cands("candidates.tsv", [s1, s3, s5])
cands("candidates-prs.tsv", [s1, prs])
PY

ovf() { # ovf NAME JSON -> write an override file, echo its path
  printf '%s' "$2" > "$WORK/$1.json" && echo "$WORK/$1.json"
}
survivors() { awk -F'\t' 'NR>1' "$WORK/$1" | wc -l | tr -d ' '; }
hdrline()  { sed -n 's/^\(policy: .*\)$/\1/p' "$WORK/$1"; }
# is_off FILE WORD1 WORD2 -> "yes" when that stage's kill column reads OFF.
# The two words are passed separately: awk's comparison binds tighter than
# concatenation, so `$1 " " $2 == lbl` would compare the WRONG pair.
is_off() {
  awk -v w1="$2" -v w2="$3" -F'[ \t]+' \
    '$1 == w1 && $2 == w2 { print ($4 == "OFF" ? "yes" : "no") }' "$WORK/$1"
}

# ------------------------------------------------- A: layer 1 alone
echo
echo "== A: bare run — global policy only, theme: none =="
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out.a.tsv" > "$WORK/run.a" 2>&1
chk "3 in, 3 out (policy floor is 0)"   "$(survivors out.a.tsv)" "3"
has "header names the standard"         "$(hdrline run.a)" "policy: standard"
has "header says no theme"              "$(hdrline run.a)" "theme: none"
chk "L6 is OFF with no word list"       "$(is_off run.a L6 topic)" "yes"
chk "L7 is OFF with no exclusion list"  "$(is_off run.a L7 noncode)" "yes"
chk "L3 is ON (policy sets 0.3)"        "$(is_off run.a L3 signature)" "no"
chk "L9 is ON (policy sets 0.6)"        "$(is_off run.a L9 dedup)" "no"

# ------------------------------------------------- B: layer 2 beats layer 1
echo
echo "== B: --theme coding — the theme's override wins over the policy =="
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out.b.tsv" --theme coding > "$WORK/run.b" 2>&1
chk "coding's min_user_turns 3 kills s1" "$(survivors out.b.tsv)" "2"
has "header names the theme"             "$(hdrline run.b)" "theme: coding"
hasnt "s1 did not survive"               "$(cat "$WORK/out.b.tsv")" "s1.jsonl"

# ------------------------------------------------- C: layer 3 beats layer 2
echo
echo "== C: --override-file restates min_user_turns over the theme =="
o1="$(ovf turns '{"min_user_turns": 1}')"
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out.c.tsv" \
  --theme coding --override-file "$o1" > "$WORK/run.c" 2>&1
chk "override-file's 1 beats the theme's 3" "$(survivors out.c.tsv)" "3"

# ------------------------------------------------- D: layer 4 beats layer 3
echo
echo "== D: flags beat the override file =="
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out.d.tsv" \
  --theme coding --override-file "$o1" --min-turns 5 > "$WORK/run.d" 2>&1
chk "flag's 5 beats the file's 1" "$(survivors out.d.tsv)" "1"
has "and only s5 survives"        "$(cat "$WORK/out.d.tsv")" "s5.jsonl"

# ------------------------------------------------- E: null clears, stage OFF
echo
echo "== E: null in an override file clears the key =="
o2="$(ovf nosig '{"sig_ratio_min": null}')"
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out.e.tsv" --override-file "$o2" > "$WORK/run.e" 2>&1
chk "cleared sig_ratio_min turns L3 OFF" "$(is_off run.e L3 signature)" "yes"
has "and the row claims no kill" \
  "$(sed -n 's/^\(L3 signature.*\)$/\1/p' "$WORK/run.e")" "off (this pack sets no sig_ratio_min)"
o3="$(ovf nodup '{"dedup_threshold": null}')"
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out.e2.tsv" --override-file "$o3" > "$WORK/run.e2" 2>&1
chk "cleared dedup_threshold turns L9 OFF" "$(is_off run.e2 L9 dedup)" "yes"

# ------------------------------------------- F: null on an always-on stage
echo
echo "== F: null cannot clear a stage with no off state =="
o4="$(ovf badeof '{"require_end_turn": null}')"
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out.f.tsv" --override-file "$o4" > "$WORK/run.f" 2>&1
non0 "clearing require_end_turn is a hard error" "$?"
has "and says why" "$(cat "$WORK/run.f")" "no off state"

# ------------------------------------------------- G: empty list clears too
echo
echo "== G: an empty word list is an explicit clear, so the stage is OFF =="
o5="$(ovf excl '{"exclude_keywords": ["调试"]}')"
python3 "$F" run "$WORK/candidates-prs.tsv" "$WORK/out.g1.tsv" --override-file "$o5" > "$WORK/run.g1" 2>&1
chk "a supplied list turns L7 ON (kills the prose session)" "$(survivors out.g1.tsv)" "1"
o6="$(ovf excl-empty '{"exclude_keywords": []}')"
python3 "$F" run "$WORK/candidates-prs.tsv" "$WORK/out.g2.tsv" --override-file "$o6" > "$WORK/run.g2" 2>&1
chk "an empty list turns L7 OFF" "$(is_off run.g2 L7 noncode)" "yes"
chk "so the prose session survives" "$(survivors out.g2.tsv)" "2"
python3 "$F" run "$WORK/candidates-prs.tsv" "$WORK/out.g3.tsv" \
  --override-file "$o5" --exclude-keywords "" > "$WORK/run.g3" 2>&1
chk "the flag can clear the file's list too" "$(is_off run.g3 L7 noncode)" "yes"

# ------------------------------------------------- H: unknown keys are fatal
echo
echo "== H: an unknown override key is a hard error, never a silent ignore =="
o7="$(ovf typos '{"min_turns": 3}')"
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out.h.tsv" --override-file "$o7" > "$WORK/run.h" 2>&1
non0 "the stage-key spelling is refused" "$?"
has "and names the bad key"    "$(cat "$WORK/run.h")" "min_turns"
has "and lists the legal keys" "$(cat "$WORK/run.h")" "min_user_turns"

# ------------------------------------------------- I: unknown theme names
echo
echo "== I: an unknown theme is refused, listing what exists =="
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out.i.tsv" --theme no-such-theme > "$WORK/run.i" 2>&1
non0 "unknown theme is a hard error" "$?"
has "and says what was looked for" "$(cat "$WORK/run.i")" "no-such-theme.json"
has "and lists the available names" "$(cat "$WORK/run.i")" "coding"
has "including the shipped ones"    "$(cat "$WORK/run.i")" "translation"

# ------------------------------------- J: L6 turns OFF on an empty theme list
echo
echo "== J: multimodal's empty keyword list reads as OFF, not pass-all =="
python3 "$F" run "$WORK/candidates.tsv" "$WORK/out.j.tsv" --theme multimodal > "$WORK/run.j" 2>&1
chk "multimodal run: 3 of 3"        "$(survivors out.j.tsv)" "3"
chk "L6 printed OFF, not a kill 0"  "$(is_off run.j L6 topic)" "yes"
has "header names the theme"        "$(hdrline run.j)" "theme: multimodal"

# ------------------------------------- K: legacy file shapes are refused
echo
echo "== K: a legacy theme carrying its own policy or exclusion list is refused =="
# These run a COPY of the engine: the loaders resolve policy.json and themes/
# relative to the script, so a copied tree is a faithful engine with its own
# data dir, and the shipped themes stay untouched.
ENG="$WORK/engine"
# The engine resolves policy.json as SIBLING of the script and themes/ one
# level UP, so the copy mirrors the shipped scripts/ + themes/ layout.
mkdir -p "$ENG/scripts"
cp "$F" "$ENG/scripts/funnel.py"
cp "$REPO/skills/agent-session-batch-export/scripts/policy.json" "$ENG/scripts/policy.json"
cp -R "$REPO/skills/agent-session-batch-export/themes" "$ENG/themes"
python3 - "$ENG" <<'PY'
import json, os, sys
eng = sys.argv[1]
t = os.path.join(eng, "themes")
legacy_policy = {
    "schema_version": 1, "kind": "theme", "theme": "legacy",
    "keywords": ["k"], "policy": {"min_user_turns": 5},
}
json.dump(legacy_policy, open(os.path.join(t, "legacy-policy.json"), "w"), ensure_ascii=False)
legacy_excl = {
    "schema_version": 1, "kind": "theme", "theme": "legacy",
    "keywords": ["k"], "exclude_keywords": ["debug"],
}
json.dump(legacy_excl, open(os.path.join(t, "legacy-excl.json"), "w"), ensure_ascii=False)
bad_override = {
    "schema_version": 1, "kind": "theme", "theme": "bad",
    "keywords": ["k"], "override": {"no_such_key": 1},
}
json.dump(bad_override, open(os.path.join(t, "bad-override.json"), "w"), ensure_ascii=False)
PY
python3 "$ENG/scripts/funnel.py" run "$WORK/candidates.tsv" "$WORK/out.k1.tsv" --theme legacy-policy > "$WORK/run.k1" 2>&1
non0 "a theme with its own policy block is refused" "$?"
has "and points at the new home" "$(cat "$WORK/run.k1")" "scripts/policy.json"
python3 "$ENG/scripts/funnel.py" run "$WORK/candidates.tsv" "$WORK/out.k2.tsv" --theme legacy-excl > "$WORK/run.k2" 2>&1
non0 "a theme with top-level exclude_keywords is refused" "$?"
has "and points at the direction layer" "$(cat "$WORK/run.k2")" "direction layer"
python3 "$ENG/scripts/funnel.py" run "$WORK/candidates.tsv" "$WORK/out.k3.tsv" --theme bad-override > "$WORK/run.k3" 2>&1
non0 "an unknown key in theme.override is refused" "$?"
has "and names the bad key" "$(cat "$WORK/run.k3")" "no_such_key"

# --------------------------------------------------------------- summary
printf '\n=====================\n'
if [[ $fail -eq 0 ]]; then echo "MERGE-CHAIN E2E: ALL CHECKS PASSED ($pass)"; else echo "MERGE-CHAIN E2E: FAILURES PRESENT ($fail)"; fi
printf '=====================\n'
exit $((fail > 0))
