#!/usr/bin/env bash
# demo.sh — record the pick-sessions.sh review flow end to end (issue #4).
#
# What it does:
#   1. builds a synthetic OUTDIR under /tmp/asbe-demo: 4 fake candidates
#      pointing at tiny synthetic .jsonl fixtures (no real session data is
#      ever read or written),
#   2. drives the real picker (pick-sessions.sh --review-only) inside tmux,
#      showing the fzf pre-selection from the screening, a TAB toggle in both
#      directions, ENTER, and finalize with byte-identity verification,
#   3. records the whole thing with asciinema into demo.cast (asciicast v2)
#      plus a plain-text excerpt (demo-transcript.txt).
#
# Replay for a human:
#   asciinema play demo.cast          # or open on asciinema.org after upload
#
# The README embeds demo.gif, rendered from the cast — GitHub renders images but
# not asciicasts (the player is a <script> embed, which GFM filters out):
#   nix shell nixpkgs#asciinema-agg -c agg --theme github-dark --font-size 14 \
#     --fps-cap 15 --speed 1.5 --last-frame-duration 3 --select 0..4.1 \
#     --text-font-family "JetBrainsMono Nerd Font Mono,DejaVu Sans" \
#     --font-dir ~/.local/share/fonts \
#     --font-dir "$(nix eval --raw nixpkgs#dejavu_fonts.minimal.outPath)/share/fonts/truetype" \
#     demo.cast demo.gif     # 1277x804, 213680 bytes, 10 frames, loops forever
# This command reproduces the committed demo.gif byte for byte (sha256
# 994fd8a9…). The --font-dir flags exist because agg finds no fonts at all on
# NixOS without them: the Nerd Font covers the ⑂ prompt glyph, DejaVu Sans the
# ↳ wrap marker (it is the only local font with U+21B3).
# `--select 0..4.1` drops the last event (tmux exits, asciinema prints
# "[exited]") on agg's post-speed timeline.
#
# Requires: bash, jq (jaq is fine), rg, tmux, asciinema, fzf.
# On NixOS without tmux/asciinema, each is pulled ad hoc via `nix shell`.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PICK_REL="skills/agent-session-batch-export/scripts/pick-sessions.sh"
DEMO_ROOT="${ASBE_DEMO_ROOT:-/tmp/asbe-demo}"        # demo-scoped; wiped below
OUT="$DEMO_ROOT/curated-demo"
SESSIONS="$DEMO_ROOT/sessions"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_CAST="$HERE/demo-raw.cast"                        # asciicast v3, recording-time
CAST="$HERE/demo.cast"                                # asciicast v2, committed
TXT="$HERE/demo-transcript.txt"                       # plain text, committed

# Resolve real binaries ONCE. `nix shell -c tmux` per call costs ~0.3s and,
# inside the asciinema child (which gets a bare PATH), a plain `tmux` is not
# even found. Absolute store paths work everywhere.
TMUX_BIN="$(command -v tmux || nix shell nixpkgs#tmux -c sh -c 'command -v tmux')"
ASCIINEMA_BIN="$(command -v asciinema || nix shell nixpkgs#asciinema -c sh -c 'command -v asciinema')"

# ---------------------------------------------------------------- fixtures
# Four candidates: two substantive (one claude, one codex) and two greeting
# stubs. Paths are synthetic; the TSVs mirror exactly what
# `curate-sessions.sh scan` would emit (7 columns) plus an agent-written
# screen.tsv (candidates + suggested + reason).
rm -rf "$DEMO_ROOT"
mkdir -p "$OUT" "$SESSIONS"

jl() { jq -cn --arg t "$2" "$1" >> "$3"; }   # one JSONL record, jq-built

mk_claude() { # $1=file $2=first_prompt $3=reply $4=n_fill_pairs
  local f="$1" up="$2" ar="$3" n="${4:-0}" i
  : > "$f"
  jl '{type:"user",cwd:"/home/demo/wanwei-cpt",message:{content:$t}}' "$up" "$f"
  jl '{type:"assistant",message:{content:$t}}' "$ar" "$f"
  for ((i = 1; i <= n; i++)); do
    jl '{type:"user",message:{content:$t}}'      "filler detail line $i" "$f"
    jl '{type:"assistant",message:{content:$t}}' "noted detail line $i"  "$f"
  done
}

mk_codex() { # $1=file $2=cwd $3=first_prompt $4=reply $5=n_fill_pairs
  local f="$1" c="$2" up="$3" ar="$4" n="${5:-0}" i
  : > "$f"
  jl '{type:"session_meta",payload:{cwd:$t}}' "$c" "$f"
  jl '{type:"response_item",payload:{type:"message",role:"user",content:[{text:$t}]}}' "$up" "$f"
  jl '{type:"response_item",payload:{type:"message",role:"assistant",content:[{text:$t}]}}' "$ar" "$f"
  for ((i = 1; i <= n; i++)); do
    jl '{type:"response_item",payload:{type:"message",role:"user",content:[{text:$t}]}}'      "filler detail line $i" "$f"
    jl '{type:"response_item",payload:{type:"message",role:"assistant",content:[{text:$t}]}}' "noted detail line $i"  "$f"
  done
}

mk_claude "$SESSIONS/s1.jsonl" \
  "Plan the ClickHouse soft-delete mask purge: which partitions still carry deleted rows, and when can APPLY DELETED MASK run safely" \
  "Two parts still carry masks: 2026-07 and 2026-08. Propose per-partition APPLY at 03:00, idempotent, verify via system.parts afterwards." 10

mk_codex "$SESSIONS/s2.jsonl" "/home/demo/loadrig" \
  "Balance the load-rig plan: open-loop ramp from 5 to 40 rps, watch the edge 503 counters, and decide where the knee actually is" \
  "Start at 5, step by 5, hold 30s per step; the knee is where achieved rps leaves requested rps while 503s stay flat." 8

mk_claude "$SESSIONS/s3.jsonl" \
  "Speed up the embedding backfill: the pgvector writes fall behind after every batch" \
  "The writer is row-by-row INSERT; switch to COPY per 512-row chunk and the backfill should track real time. Re-measure one batch before scaling out." 0
mk_claude "$SESSIONS/s4.jsonl" "test" "Ok." 0

sz()  { wc -c < "$1" | tr -d ' '; }
nl_() { wc -l < "$1" | tr -d ' '; }

# candidates.tsv — the exact shape `scan` writes (deterministic mtimes).
{
  printf 'agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file\n'
  printf 'claude\t/home/demo/wanwei-cpt\t1789067412\t%s\t%s\tPlan the ClickHouse soft-delete mask purge: which partitions still carry deleted rows, and when can APPLY DELETED MASK run safely\t%s\n' \
    "$(sz "$SESSIONS/s1.jsonl")" "$(nl_ "$SESSIONS/s1.jsonl")" "$SESSIONS/s1.jsonl"
  printf 'codex\t/home/demo/loadrig\t1788969944\t%s\t%s\tBalance the load-rig plan: open-loop ramp from 5 to 40 rps, watch the edge 503 counters, and decide where the knee actually is\t%s\n' \
    "$(sz "$SESSIONS/s2.jsonl")" "$(nl_ "$SESSIONS/s2.jsonl")" "$SESSIONS/s2.jsonl"
  printf 'claude\t/home/demo/misc\t1787673123\t%s\t%s\tSpeed up the embedding backfill: the pgvector writes fall behind after every batch\t%s\n' \
    "$(sz "$SESSIONS/s3.jsonl")" "$(nl_ "$SESSIONS/s3.jsonl")" "$SESSIONS/s3.jsonl"
  printf 'claude\t/home/demo/misc\t1787673641\t%s\t%s\ttest\t%s\n' \
    "$(sz "$SESSIONS/s4.jsonl")" "$(nl_ "$SESSIONS/s4.jsonl")" "$SESSIONS/s4.jsonl"
} > "$OUT/candidates.tsv"

# screen.tsv — agent screening: keep the two substantive, drop the stubs.
{
  printf 'agent\tcwd\tmtime\tsize_bytes\tn_lines\tfirst_prompt\tsession_file\tsuggested\treason\n'
  printf 'claude\t/home/demo/wanwei-cpt\t1789067412\t%s\t%s\tPlan the ClickHouse soft-delete mask purge: which partitions still carry deleted rows, and when can APPLY DELETED MASK run safely\t%s\tkeep\tmulti-stage cleanup design with real decisions\n' \
    "$(sz "$SESSIONS/s1.jsonl")" "$(nl_ "$SESSIONS/s1.jsonl")" "$SESSIONS/s1.jsonl"
  printf 'codex\t/home/demo/loadrig\t1788969944\t%s\t%s\tBalance the load-rig plan: open-loop ramp from 5 to 40 rps, watch the edge 503 counters, and decide where the knee actually is\t%s\tkeep\tload-rig ramp methodology, concrete numbers\n' \
    "$(sz "$SESSIONS/s2.jsonl")" "$(nl_ "$SESSIONS/s2.jsonl")" "$SESSIONS/s2.jsonl"
  printf 'claude\t/home/demo/misc\t1787673123\t%s\t%s\tSpeed up the embedding backfill: the pgvector writes fall behind after every batch\t%s\tdrop\tone-shot question, short answer\n' \
    "$(sz "$SESSIONS/s3.jsonl")" "$(nl_ "$SESSIONS/s3.jsonl")" "$SESSIONS/s3.jsonl"
  printf 'claude\t/home/demo/misc\t1787673641\t%s\t%s\ttest\t%s\tdrop\tno-op probe, 2 lines\n' \
    "$(sz "$SESSIONS/s4.jsonl")" "$(nl_ "$SESSIONS/s4.jsonl")" "$SESSIONS/s4.jsonl"
} > "$OUT/screen.tsv"

# ---------------------------------------------------------------- helpers
pane_wait() { # $1=pattern $2=timeout_secs
  local pat="$1" t="${2:-30}" n=0
  until "$TMUX_BIN" capture-pane -t asbe-demo -p 2>/dev/null | grep -q "$pat"; do
    sleep 0.25
    n=$((n + 1))
    if [[ $n -gt $((t * 4)) ]]; then
      echo "timeout waiting for: $pat" >&2
      "$TMUX_BIN" capture-pane -t asbe-demo -p >&2 || true
      return 1
    fi
  done
}

"$TMUX_BIN" kill-session -t asbe-demo 2>/dev/null || true

# ---------------------------------------------------------------- record
# tmux runs INSIDE the asciinema PTY, so every pane redraw is captured; keys
# are injected through the tmux socket (send-keys), which cannot race the
# script's own terminal — the same technique the skill's own test harness uses.
# asciinema's headless child runs with TERM=dumb, which tmux rejects
# ("terminal does not support clear") — hand the tmux command a real TERM.
echo "recording: $CAST"
"$ASCIINEMA_BIN" rec --headless --overwrite --quiet --idle-time-limit 2 \
  --window-size 150x40 \
  --title "agent-session-batch-export: pick -> finalize" \
  -c "TERM=xterm-256color $TMUX_BIN new-session -s asbe-demo -x 150 -y 40" \
  "$RAW_CAST" &
REC_PID=$!

until "$TMUX_BIN" has-session -t asbe-demo 2>/dev/null; do sleep 0.1; done
sleep 1                                            # pane shell ready

# The picker runs from the repo root so the recording shows relative paths.
"$TMUX_BIN" send-keys -t asbe-demo -l "cd $REPO"
"$TMUX_BIN" send-keys -t asbe-demo Enter
pane_wait 'workspace/skills' 10
"$TMUX_BIN" send-keys -t asbe-demo -l \
  "bash $PICK_REL -o $OUT -y --review-only"
"$TMUX_BIN" send-keys -t asbe-demo Enter

pane_wait 'candidates; 2 pre-selected' 30          # fzf header = UI is up
sleep 1.2
# 1 — the picker as the screening left it: keeps on top, pre-selected.
"$TMUX_BIN" capture-pane -t asbe-demo -p > "$HERE/.snap1"

# Story: screening pre-selected s1+s2. The human overrides it both ways —
# drops the codex keep, adds the short pgvector session — keep {s1, s3}.
"$TMUX_BIN" send-keys -t asbe-demo Down;  sleep 0.8
"$TMUX_BIN" send-keys -t asbe-demo Tab;   sleep 0.8      # unselect s2
"$TMUX_BIN" send-keys -t asbe-demo Down;  sleep 0.8
"$TMUX_BIN" send-keys -t asbe-demo Tab;   sleep 0.8      # select s3
# 2 — the override: one pre-selection removed, one row added.
"$TMUX_BIN" capture-pane -t asbe-demo -p > "$HERE/.snap2"
"$TMUX_BIN" send-keys -t asbe-demo Enter

pane_wait 'verified: ' 30                          # finalize verification line
sleep 2                                            # let the summary render
# 3 — picker output after ENTER, then finalize output with the byte check.
"$TMUX_BIN" capture-pane -t asbe-demo -p > "$HERE/.snap3"
"$TMUX_BIN" kill-session -t asbe-demo
wait "$REC_PID"

snap() { # $1=snapshot file — trim trailing blank pane rows
  awk '{ l[NR] = $0 } NF { last = NR } END { for (i = 1; i <= last; i++) print l[i] }' "$1"
}

# ---------------------------------------------------------------- post-process
LC_ALL=C "$ASCIINEMA_BIN" convert --overwrite -f asciicast-v2 "$RAW_CAST" "$CAST"
rm -f "$RAW_CAST"

# ---------------------------------------------------------------- transcript
# asciinema 3.2.1's txt export cannot unroll alt-screen TUI output (it emits a
# 9-byte "[exited]" file), so the readable transcript is assembled from pane
# snapshots captured at each step while the recording ran.
{
  echo "Recorded demo — agent-session-batch-export picker (issue #4)"
  echo "Reproduce: bash demo.sh   ·  Interactive replay: asciinema play demo.cast"
  echo
  echo "================ STEP 1: review — screening pre-selected 2 rows ================"
  snap "$HERE/.snap1"
  echo
  echo "======= STEP 2: TAB override — drop the codex pick, add the pgvector session ======="
  snap "$HERE/.snap2"
  echo
  echo "=============== STEP 3: ENTER — decisions written, finalize + verification ==============="
  snap "$HERE/.snap3"
} > "$TXT"
rm -f "$HERE"/.snap*

# ---------------------------------------------------------------- verify
echo "== recorded artifacts =="
ls -l "$CAST" "$TXT"
echo
echo "== decisions.tsv (what the human ended up choosing) =="
cut -f1,3,4,10 "$OUT/decisions.tsv"
echo
echo "== corpus =="
jq -r '.[] | "\(.kept_as)  \(.sha256[0:16])  <- \(.source)"' "$OUT/manifest.json"
jq -r '.[] | "\(.source)\t\(.kept_as)"' "$OUT/manifest.json" | while IFS=$'\t' read -r s d; do
  cmp -s "$s" "$d" && echo "byte-identical: $(basename "$d")"
done
echo
echo "demo OK — fixtures in $DEMO_ROOT (delete at will), playback: asciinema play $CAST"
