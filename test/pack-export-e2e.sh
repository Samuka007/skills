#!/usr/bin/env bash
# E2E regression for pack-export.sh (issue #12): the driver that expands a
# buy-side pack and drives the existing pipeline (scan -> funnel -> pick ->
# delivery) without reimplementing screening or copying.
#
# Fixtures are synthetic claude_code sessions under a fake $HOME
# ($WORK/home/.claude/projects); the user's real stores are never read. Each
# fixture is built to pass or fail specific pack gates so the assertions
# discriminate: a session that fails ONLY the role-play pack's min_user_turns
# override (10, vs the direction default of 5) proves the threshold was read
# from the pack file, not restated in the driver.
#
# Usage: test/pack-export-e2e.sh [work-dir]   (default /tmp/pack-export-e2e)
# Dependencies: bash, jq (or jaq), python3, tar — the same surface the
# pipeline itself requires. No tmux/fzf: every run here is unattended (--yolo),
# which is the point for a driver acceptance, not a gap.
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
DRIVER="$REPO/skills/trajectory-packs/scripts/pack-export.sh"
WORK="${1:-/tmp/pack-export-e2e}"

pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
no()   { fail=$((fail + 1)); echo "  FAIL $1"; }
chk()  { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else no "$1: got '$2' want '$3'"; fi; }
has()  { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1: missing '$3'"; fi; }
hasnt(){ if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1: unexpected '$3'"; fi; }
non0() { if [[ "$2" -ne 0 ]]; then ok "$1 (rc=$2)"; else no "$1: expected non-zero, got $2"; fi; }

# ---------------------------------------------------------------- fixtures
# mksess FILE NAME KEYWORD TURNS SIG LATERBODY
#   NAME makes the first user message unique (the dedup stage keys on it).
#   LATERBODY is the exact text of user messages 2..TURNS (stage L5 floors
#   their length: >=20 chars passes the direction default, 5..19 passes only
#   the translation pack's min_user_msg_chars=5 override).
#   SIG: signed -> non-empty thinking signature; empty -> stripped signature.
mksess() {
  local file="$1" name="$2" kw="$3" turns="$4" sig="$5" later="$6" i body
  : > "$file"
  for i in $(seq 1 "$turns"); do
    if [[ "$i" -eq 1 ]]; then
      body="${kw}：${name} 的会话任务内容，用于让首条用户消息与其它会话区分开来。"
    else
      body="$later"
    fi
    printf '{"type":"user","cwd":"/home/demo/%s","message":{"role":"user","content":"%s"}}\n' "$name" "$body" >> "$file"
    if [[ "$sig" == "empty" ]]; then
      printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","signature":"","thinking":"推理内容"},{"type":"text","text":"回答内容"}]},"stop_reason":"end_turn"}\n' >> "$file"
    else
      printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","signature":"sig-%s-%s","thinking":"推理内容"},{"type":"text","text":"回答内容"}]},"stop_turn_reason":"end_turn","stop_reason":"end_turn"}\n' "$name" "$i" >> "$file"
    fi
  done
}

# build_store DIR — the clean store: what the direction pack should select.
#   s1 translation(6 turns)  s2 role-play(11 turns)  s3 generation(6 turns)
#   s4 no keyword            s6 role-play keyword but only 6 turns (killed by
#                            the role-play pack's min_user_turns=10 override;
#                            would pass the direction default of 5)
#   s7 translation, 5 turns, later msgs 6 chars (passes the translation pack's
#                            min_user_msg_chars=5 override; would fail the
#                            direction default of 20)
#   s8 translation but stripped signatures (killed by the pack's sig floor)
build_store() {
  local root="$1"
  rm -rf "$root"; mkdir -p "$root/.claude/projects/-demo"
  d="$root/.claude/projects/-demo"
  long="这是一段后续的用户消息内容，用来满足长度门槛的要求。"
  short="短消息内容。"
  mksess "$d/s1.jsonl" s1 "请翻译这段文字为日文"        6  signed "$long"
  mksess "$d/s2.jsonl" s2 "扮演一个角色进行剧情演绎"    11 signed "$long"
  mksess "$d/s3.jsonl" s3 "帮我撰写一篇报告"            6  signed "$long"
  mksess "$d/s4.jsonl" s4 "随便聊聊今天的天气"          6  signed "$long"
  mksess "$d/s6.jsonl" s6 "扮演角色说话"                6  signed "$long"
  mksess "$d/s7.jsonl" s7 "翻译这句成英文"              5  signed "$short"
  mksess "$d/s8.jsonl" s8 "翻译这段文言文"              5  empty  "$long"
}

# build_cred_store DIR — the clean store plus s5, a translation session whose
# text carries a fake Anthropic-shaped key (the credential path's fixture).
build_cred_store() {
  build_store "$1"
  mksess "$1/.claude/projects/-demo/s5.jsonl" s5 "翻译这份文档为中文" 6 signed "$long"
  # embed the fake key inside one user message (raw file text is what ships)
  printf '{"type":"user","cwd":"/home/demo/s5","message":{"role":"user","content":"配置里的密钥是 sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWx 请不要泄露"}}\n' \
    >> "$1/.claude/projects/-demo/s5.jsonl"
}

sources() { # $1 = manifest -> space-separated kept source basenames
  jq -r '.[].source | sub(".*/"; "")' "$1" 2>/dev/null | sort | tr '\n' ' '
}
manifest_theme_counts() { jq -c '.[0].theme_counts' "$1" 2>/dev/null; }
archive_of() { # $1 = out dir -> the delivery archive (any supported suffix)
  ls -t "$1"/*.tar.gz "$1"/*.zip 2>/dev/null | sed -n 1p
}
list_members() { # $1 = archive
  case "$1" in
    *.zip) unzip -Z1 "$1" 2>/dev/null || zipinfo -1 "$1" 2>/dev/null ;;
    *)     tar -tzf "$1" ;;
  esac
}
cmp_bad() { # $1 = manifest -> copies not byte-identical to their source
  local bad=0 s d
  jq -r '.[] | "\(.source)\t\(.kept_as)"' "$1" > "$WORK/.pairs.$$" 2>/dev/null || return 1
  while IFS=$'\t' read -r s d; do
    s="${s%$'\r'}"; d="${d%$'\r'}"
    cmp -s "$s" "$d" || bad=$((bad + 1))
  done < "$WORK/.pairs.$$"
  rm -f "$WORK/.pairs.$$"
  echo "$bad"
}

echo "pack-export e2e — work dir: $WORK"
echo "driver: $DRIVER"
rm -rf "$WORK"; mkdir -p "$WORK"

# ------------------------------------------- A: direction pack, unattended
echo
echo "== A: --direction noncoding-multimodal --yolo runs to an archive =="
build_store "$WORK/home"
A_OUT="$WORK/out-a"
aout="$(HOME="$WORK/home" bash "$DRIVER" --direction noncoding-multimodal --yolo -o "$A_OUT" 2>&1)"; arc=$?
chk "exit status" "$arc" "0"
echo "$aout" > "$WORK/a.log"

has "prints the pack identity" "$aout" "pack: noncoding-multimodal v1.0.0 (direction noncoding-multimodal)"
has "prints the resolved theme list" "$aout" "themes: role-play translation rewriting generation data-analysis multimodal"
has "prints the direction defaults from the pack" "$aout" "min_user_turns=5"
has "prints the per-theme overrides from the pack" "$aout" "overrides role-play: min_user_turns=10 max_tool_ratio=0.05"
has "pre-export count line" "$aout" "this pack qualifies 4 sessions from 7 scanned:"
has "role-play counted via its 10-turn override (s6 excluded)" "$aout" "role-play"
has "zero themes print as zeros" "$aout" "rewriting"
has "report-only theme prints as n/a, not a fabricated zero" "$aout" "multimodal"
has "zero-scan line for multimodal" "$aout" "(report-only)"
has "credential count printed" "$aout" "credentials: 0 qualifying session(s)"
has "yolo skips the confirmation" "$aout" "confirmation skipped (--yolo)"

# per-theme counts printed == manifest's after (acceptance criterion).
# JSON objects are unordered: compare by equality, not by key order.
chk "manifest theme_counts" \
  "$(jq -cn --argjson a "$(manifest_theme_counts "$A_OUT/manifest.json")" \
      --argjson b '{"translation":2,"role-play":1,"generation":1,"rewriting":0,"data-analysis":0,"multimodal":null}' '$a == $b')" \
  "true"
while IFS= read -r t; do
  printed="$(printf '%s\n' "$aout" | sed -n "s/^  $t  *\\([0-9n][0-9a/]*\\)\$/\\1/p" | sed -n 1p)"
  inman="$(jq -r --arg t "$t" '.[0].theme_counts[$t] // "null"' "$A_OUT/manifest.json" 2>/dev/null)"
  [[ "$printed" == "n/a" ]] && want="null" || want="$printed"
  chk "printed count for $t matches manifest" "$want" "$inman"
done <<'THEMES'
translation
role-play
generation
rewriting
data-analysis
THEMES

# the selection: exactly the union of theme survivors, no more
chk "kept sources" "$(sources "$A_OUT/manifest.json")" "s1.jsonl s2.jsonl s3.jsonl s7.jsonl "
hasnt "s6 killed by the role-play 10-turn override" "$(sources "$A_OUT/manifest.json")" "s6"
hasnt "s8 killed by the pack signature floor" "$(sources "$A_OUT/manifest.json")" "s8"
hasnt "s4 (no theme keyword) not exported" "$(sources "$A_OUT/manifest.json")" "s4"

# pack fields merged into every manifest entry (issue #2's mechanism)
chk "pack_id on entries" "$(jq -r '.[0].pack_id' "$A_OUT/manifest.json")" "noncoding-multimodal"
chk "pack_version on entries" "$(jq -r '.[0].pack_version' "$A_OUT/manifest.json")" "1.0.0"
chk "direction on entries" "$(jq -r '.[0].direction' "$A_OUT/manifest.json")" "noncoding-multimodal"
chk "entry themes attributed" "$(jq -c '.[] | .themes' "$A_OUT/manifest.json" | sort -u | tr '\n' ' ')" '["generation"] ["role-play"] ["translation"] '
chk "yolo provenance intact" "$(jq -r '.[0].mode' "$A_OUT/manifest.json")" "yolo"
chk "credential policy recorded" "$(jq -r '.[0].allow_credentials' "$A_OUT/manifest.json")" "false"
chk "theme pack provenance" "$(jq -r '.[0].theme_packs["role-play"]' "$A_OUT/manifest.json")" "theme-role-play@1.0.0"

# byte identity + archive shape (the pipeline's own guarantees, end to end)
chk "copies byte-identical" "$(cmp_bad "$A_OUT/manifest.json")" "0"
A_ARC="$(archive_of "$A_OUT")"
[[ -n "$A_ARC" ]] && ok "archive produced ($(basename "$A_ARC"))" || no "archive produced"
A_N="$(jq 'length' "$A_OUT/manifest.json")"
chk "archive lists manifest + one member per session" \
  "$(list_members "$A_ARC" | awk '$0 !~ /\/$/' | wc -l | tr -d ' ')" "$((A_N + 1))"
has "archive member names carry keep/" "$(list_members "$A_ARC" | tr '\n' ' ')" "keep/"

# ------------------------------------------- B: theme run restricts selection
echo
echo "== B: --theme translation restricts the selection to that theme =="
B_OUT="$WORK/out-b"
bout="$(HOME="$WORK/home" bash "$DRIVER" --theme translation --yolo -o "$B_OUT" 2>&1)"; brc=$?
chk "exit status" "$brc" "0"
echo "$bout" > "$WORK/b.log"
chk "only translation sessions kept" "$(sources "$B_OUT/manifest.json")" "s1.jsonl s7.jsonl "
hasnt "role-play session excluded" "$(sources "$B_OUT/manifest.json")" "s2"
chk "manifest has no direction (theme run)" "$(jq -r '.[0].direction' "$B_OUT/manifest.json")" "null"
chk "manifest pack_id null for theme run" "$(jq -r '.[0].pack_id' "$B_OUT/manifest.json")" "null"
chk "theme run counts" \
  "$(jq -cn --argjson a "$(manifest_theme_counts "$B_OUT/manifest.json")" --argjson b '{"translation":2}' '$a == $b')" \
  "true"
has "theme run prints resolved thresholds" "$bout" "resolved: min_user_turns=5"

# ------------------------------------------- C: usage errors
echo
echo "== C: --direction with --theme is a usage error =="
cout="$(HOME="$WORK/home" bash "$DRIVER" --direction noncoding-multimodal --theme translation -o "$WORK/out-c" 2>&1)"; crc=$?
non0 "exits non-zero" "$crc"
has "prints the usage" "$cout" "Usage: pack-export.sh"
has "names the conflict" "$cout" "usage error"
chk "no directory written" "$([[ -e "$WORK/out-c" ]] && echo present || echo absent)" "absent"

cout2="$(HOME="$WORK/home" bash "$DRIVER" --direction no-such-pack --yolo -o "$WORK/out-c2" 2>&1)"; crc2=$?
non0 "unknown direction exits non-zero" "$crc2"
has "names the missing pack file" "$cout2" "no direction pack 'no-such-pack'"

# ------------------------------------------- D: missing engine
echo
echo "== D: a missing engine refuses with the install command =="
mkdir -p "$WORK/iso" "$WORK/neutral" "$WORK/emptyhome"
cp -R "$REPO/skills/trajectory-packs" "$WORK/iso/trajectory-packs"
dout="$(cd "$WORK/neutral" && HOME="$WORK/emptyhome" bash "$WORK/iso/trajectory-packs/scripts/pack-export.sh" --direction noncoding-multimodal --yolo -o "$WORK/out-d" 2>&1)"; drc=$?
non0 "exits non-zero" "$drc"
has "names the missing engine" "$dout" "trajectory-funnel"
has "prints the npx skills add install command" "$dout" "npx skills add Samuka007/skills"
has "install command names all three skills" "$dout" "--skill agent-session-batch-export"

# ------------------------------------------- E: credential path
echo
echo "== E: credentials refuse unattended, recorded when allowed =="
build_cred_store "$WORK/homecred"
E_OUT="$WORK/out-e"
eout="$(HOME="$WORK/homecred" bash "$DRIVER" --direction noncoding-multimodal --yolo -o "$E_OUT" 2>&1)"; erc=$?
non0 "unattended run with credential hits refuses" "$erc"
has "reports the hit count" "$eout" "credentials: 1 qualifying session(s)"
has "names the escape hatch" "$eout" "--allow-credentials"
chk "nothing written on refusal" "$([[ -e "$E_OUT" ]] && echo present || echo absent)" "absent"

E2_OUT="$WORK/out-e2"
e2out="$(HOME="$WORK/homecred" bash "$DRIVER" --direction noncoding-multimodal --yolo --allow-credentials -o "$E2_OUT" 2>&1)"; e2rc=$?
chk "exit status with --allow-credentials" "$e2rc" "0"
has "warns that flagged sessions ship" "$e2out" "WILL be exported (--allow-credentials)"
chk "hit recorded in manifest" "$(jq -r '.[0].credential_hits' "$E2_OUT/manifest.json")" "1"
chk "flag recorded in manifest" "$(jq -r '.[0].allow_credentials' "$E2_OUT/manifest.json")" "true"
has "flagged session is in the export" "$(sources "$E2_OUT/manifest.json")" "s5.jsonl"
chk "copies still byte-identical" "$(cmp_bad "$E2_OUT/manifest.json")" "0"

# interactive path: flagged rows are not pre-selected (the screen contract the
# picker reads). Drive the confirmation with a piped 'y'; the picker itself is
# the pipeline's own surface (covered by its suites), so stop before it: a
# headless 'y' run reaches the picker, which reports no usable terminal and
# exits — the screen.tsv the picker WOULD read is already on disk.
E3_OUT="$WORK/out-e3"
( cd "$WORK/neutral" && HOME="$WORK/homecred" bash "$DRIVER" --direction noncoding-multimodal -y -o "$E3_OUT" >/dev/null 2>&1 ) || true
s5file="$(printf '%s' "$WORK/homecred/.claude/projects/-demo/s5.jsonl")"
row="$(awk -F'\t' -v f="$s5file" '$7 == f { print }' "$E3_OUT/screen.tsv" 2>/dev/null)"
has "flagged row's reason names the credential pattern" "$row" "credential pattern matched"
chk "flagged row not marked keep (not pre-selected)" "$(printf '%s' "$row" | awk -F'\t' '{ print $(NF-1) }')" ""

printf '\n=====================\n'
if [[ $fail -eq 0 ]]; then echo "PACK-EXPORT E2E: ALL CHECKS PASSED ($pass checks)"; else echo "PACK-EXPORT E2E: FAILURES PRESENT ($fail failed, $pass passed)"; fi
printf '=====================\n'
exit $fail
