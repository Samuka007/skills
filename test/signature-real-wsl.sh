#!/usr/bin/env bash
# Acceptance run, WSL side: the signature layer against a store that HAS real
# signatures. The point is the three states, on real files, not fixtures.
set -uo pipefail
REPO=/home/nixos/workspace/skills
F="$REPO/skills/trajectory-funnel/scripts/funnel.py"
C="$REPO/skills/agent-session-batch-export/scripts/curate-sessions.sh"
W=/tmp/acc-sig-wsl
rm -rf "$W"; mkdir -p "$W"

echo "== scan (WSL stores: ~/.claude/projects, ~/.codex/sessions) =="
bash "$C" scan -o "$W" --agent both --min-lines 3 >/dev/null 2>&1
awk -F'\t' 'NR>1' "$W/candidates.tsv" | wc -l

echo
echo "== enrich: signature state per session, WSL claude store =="
python3 "$F" enrich "$W/candidates.tsv" "$W/enriched.tsv" >/dev/null
awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)h[$i]=i; next}
  $h["agent"]=="claude"{
    printf "%-24s model? state=%-8s pres=%-3s empty=%-3s ratio=%-5s redact=%-2s turns=%s\n",
      substr($h["session_file"], 0), $h["signature_state"], $h["signature_present"], $h["signature_empty"],
      $h["signature_ratio"], $h["redacted_blocks"], $h["user_turns"]
  }' "$W/enriched.tsv" | sed 's#.*/##' | sort

echo
echo "== funnel with the signature gate ON (0.30), everything else permissive =="
python3 "$F" run "$W/candidates.tsv" "$W/out.tsv" \
  --preset report --sig-ratio-min 0.30 --min-turns 1 --no-end-turn \
  --max-tool-ratio 100 --no-dedup --min-user-msg-chars 1 --max-first-msg-chars 1000000 \
  --topic-keywords "__no_such_keyword_so_topic_layer_passes_everything__" > "$W/funnel.txt" 2>&1
sed -n '/^L0/,$p' "$W/funnel.txt"
