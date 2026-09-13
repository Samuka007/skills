#!/usr/bin/env python3
"""trajectory-funnel: deterministic multi-stage filter over agent-session candidates.

Mechanism layer of the trajectory-export skill family. The STAGE ORDER and the
SHAPE of each stage's predicate are fixed here; the PARAMETERS (thresholds,
keywords, presets) come from the CLI, normally transcribed by an agent from a
presets skill. The agent never parses session JSONL itself -- it reads the
funnel table and the enriched candidates TSV this script prints.

Design rules (do not violate when extending):
  * Python standard library only. No third-party deps. This must run anywhere
    python3 runs, including a scoop-installed Windows python.
  * Streaming: one session file is held in memory at a time, never the corpus.
  * Every stage reports (in, out, killed, reason) -- the funnel table is the
    agent's only decision surface for re-tuning.
  * Cheap stages run before expensive ones. Metadata < line scan < JSON parse.
  * Input candidates.tsv comes from curate-sessions.sh scan (header: agent cwd
    mtime size_bytes n_lines first_prompt session_file). Output stays compatible
    with the existing screen.tsv contract (candidates columns + 2).

Stages (fixed order):
  L1 turns      -- user-turn floor. Kills greeting stubs ("hi") in one shot.
  L2 tool_ratio -- assistant tool_use share ceiling. Kills coding-agent runs
                   when the interest is prose (report/roleplay/translation).
  L3 end_turn   -- last assistant stop_reason == end_turn. Kills truncated
                   sessions that end mid-tool-call.
  L4 length     -- user-message length distribution. Kills scaffolding-noise
                   sessions (first_prompt is huge, real request is tiny).
  L5 topic      -- keyword/regex match over extracted user prose. The only
                   stage that reads message bodies.
  L6 dedup      -- near-duplicate cluster collapse via 5-gram Jaccard over
                   first user messages. Keeps the longest of each cluster.

Usage:
  python3 funnel.py enrich  CANDIDATES.tsv OUT.tsv      # add computed columns
  python3 funnel.py run     CANDIDATES.tsv OUT.tsv --preset report [--min-turns 5 ...]
  python3 funnel.py presets                            # list preset parameter sets

The 'run' funnel table goes to stdout; OUT.tsv is the surviving candidates
plus computed columns, shaped for curate-sessions.sh review --ui tsv.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# presets: the default parameter sets an agent picks from. Values here come
# from the noncoding 10-session demo funnel (2026-07-20) and from this repo's
# own coding-export experience. Presets are data, not code: tune via flags.
# ---------------------------------------------------------------------------

PRESETS: dict[str, dict] = {
    "report": {
        "desc": "reports / slides / writing / translation: text-heavy, tool-light, multi-turn",
        "min_turns": 5,
        "max_tool_ratio": 0.15,
        "require_end_turn": True,
        "min_user_msg_chars": 20,
        "max_first_msg_chars": 4000,
        "topic_keywords": ["ppt", "报告", "汇报", "总结", "论文", "润色", "翻译", "改写", "撰写", "方案"],
        "dedup_threshold": 0.6,
    },
    "roleplay": {
        "desc": "roleplay / creative writing: very text-heavy, long conversations, no tools",
        "min_turns": 10,
        "max_tool_ratio": 0.05,
        "require_end_turn": True,
        "min_user_msg_chars": 10,
        "max_first_msg_chars": 20000,
        "topic_keywords": ["角色", "人设", "剧情", "小说", "世界观", "扮演", "故事", "角色卡", "npc", "ooc"],
        "dedup_threshold": 0.6,
    },
    "coding": {
        "desc": "coding sessions: tool-heavy, any length, dedup loose",
        "min_turns": 3,
        "max_tool_ratio": 1.0,
        "require_end_turn": False,
        "min_user_msg_chars": 0,
        "max_first_msg_chars": 0,
        "topic_keywords": [],
        "dedup_threshold": 0.8,
    },
}


# ---------------------------------------------------------------------------
# session file adapters: extract a common view from the raw formats we scan.
# Each returns None if the file is not this format. Keep these tiny and strict;
# unknown formats are SKIPPED and counted, never guessed.
# ---------------------------------------------------------------------------


@dataclass
class SessionView:
    path: Path
    user_turns: int = 0
    assistant_turns: int = 0
    tool_uses: int = 0
    last_stop_reason: str = ""
    user_chars: list[int] = field(default_factory=list)
    first_user_msg: str = ""
    user_texts: list[str] = field(default_factory=list)
    fmt: str = ""


def _content_text(content) -> str:
    """Flatten an Anthropic-style content block list / string to plain text."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                parts.append(b.get("text", ""))
        return "\n".join(parts)
    return ""


def parse_claude_code(path: Path) -> SessionView | None:
    """~/.claude/projects/<munged>/<uuid>.jsonl : one JSON object per line."""
    v = SessionView(path=path)
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if rec.get("type") not in ("user", "assistant"):
                    continue
                msg = rec.get("message") or {}
                role = msg.get("role", rec.get("type"))
                text = _content_text(msg.get("content"))
                if role == "user":
                    if text.strip():
                        v.user_turns += 1
                        v.user_chars.append(len(text))
                        v.user_texts.append(text)
                else:
                    v.assistant_turns += 1
                    content = msg.get("content")
                    if isinstance(content, list):
                        v.tool_uses += sum(
                            1 for b in content if isinstance(b, dict) and b.get("type") == "tool_use"
                        )
                    sr = rec.get("stop_reason") or msg.get("stop_reason") or ""
                    if sr:
                        v.last_stop_reason = sr
    except OSError:
        return None
    if not v.user_texts:
        return None
    v.first_user_msg = v.user_texts[0]
    v.fmt = "claude_code"
    return v


def parse_codex(path: Path) -> SessionView | None:
    """~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl : response_item lines."""
    v = SessionView(path=path)
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if rec.get("type") != "response_item":
                    continue
                pl = rec.get("payload") or {}
                pt = pl.get("type")
                if pt == "message" and pl.get("role") in ("user", "assistant"):
                    text = "".join(
                        c.get("text", "") for c in (pl.get("content") or []) if isinstance(c, dict)
                    )
                    if pl.get("role") == "user":
                        if text.strip():
                            v.user_turns += 1
                            v.user_chars.append(len(text))
                            v.user_texts.append(text)
                    else:
                        v.assistant_turns += 1
                        if pl.get("stop_reason"):
                            v.last_stop_reason = pl["stop_reason"]
                elif pt in ("function_call", "local_shell_call", "custom_tool_call"):
                    v.tool_uses += 1
    except OSError:
        return None
    if not v.user_texts:
        return None
    v.first_user_msg = v.user_texts[0]
    v.fmt = "codex"
    return v


def parse_session(path: Path, hint_agent: str) -> SessionView | None:
    parsers = {
        "claude": (parse_claude_code, parse_codex),
        "codex": (parse_codex, parse_claude_code),
    }
    for fn in parsers.get(hint_agent, (parse_claude_code, parse_codex)):
        v = fn(path)
        if v is not None:
            return v
    return None


# ---------------------------------------------------------------------------
# stages: each takes the enrich row + SessionView, returns (alive, reason).
# Stage order IS the architecture. Add stages at the end of STAGES only after
# cheaper ones; never reorder without re-checking cost assumptions.
# ---------------------------------------------------------------------------


def norm(s: str) -> str:
    return unicodedata.normalize("NFKC", s).lower()


def stage_turns(row: dict, v: SessionView, p: dict) -> tuple[bool, str]:
    if v.user_turns >= p["min_turns"]:
        return True, ""
    return False, f"user_turns {v.user_turns} < {p['min_turns']}"


def stage_tool_ratio(row: dict, v: SessionView, p: dict) -> tuple[bool, str]:
    total = v.assistant_turns or 1
    ratio = v.tool_uses / total
    if ratio <= p["max_tool_ratio"]:
        return True, ""
    return False, f"tool_ratio {ratio:.2f} > {p['max_tool_ratio']}"


def stage_end_turn(row: dict, v: SessionView, p: dict) -> tuple[bool, str]:
    if not p["require_end_turn"]:
        return True, ""
    if v.last_stop_reason in ("", "end_turn", "stop"):
        return True, ""
    return False, f"last stop_reason={v.last_stop_reason!r}"


def stage_length(row: dict, v: SessionView, p: dict) -> tuple[bool, str]:
    floor = p["min_user_msg_chars"]
    cap = p["max_first_msg_chars"]
    if cap and v.first_user_msg and len(v.first_user_msg) > cap:
        return False, f"first user msg {len(v.first_user_msg)} > cap {cap} (scaffold noise)"
    if floor and v.user_chars:
        real = [c for c in v.user_chars[1:] or v.user_chars]  # skip msg#1 (rules/preamble)
        if real and max(real) < floor:
            return False, f"longest later user msg {max(real)} < {floor}"
    return True, ""


def stage_topic(row: dict, v: SessionView, p: dict) -> tuple[bool, str]:
    kws = p.get("topic_keywords") or []
    if not kws:
        return True, ""
    # read the cheapest prose surface first: first 3 user messages, truncated.
    hay = norm(" ".join(t[:500] for t in v.user_texts[:3]))
    for kw in kws:
        if norm(kw) in hay:
            return True, f"matched '{kw}'"
    return False, "no topic keyword in first user messages"


def ngrams(s: str, n: int = 5) -> set[str]:
    s = re.sub(r"\s+", "", norm(s))
    return {s[i : i + n] for i in range(0, max(1, len(s) - n + 1))}


def jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def stage_dedup(rows: list[dict], views: dict[str, SessionView], p: dict) -> tuple[list[dict], list[tuple[str, str]]]:
    """Collapse near-duplicate clusters (same template conversation). Keep the
    longest member of each cluster. Returns (alive_rows, (killed, reason) list).
    This is the one cross-row stage; it runs last so the candidate set is small."""
    thr = p["dedup_threshold"]
    alive: list[dict] = []
    killed: list[tuple[str, str]] = []
    kept_sigs: list[tuple[set[str], str]] = []  # (ngram set, session_file)
    for row in rows:
        f = row["session_file"]
        v = views.get(f)
        sig = ngrams(v.first_user_msg[:2000]) if v else set()
        dup_of = next((kf for ks, kf in kept_sigs if jaccard(sig, ks) >= thr), None)
        if dup_of:
            killed.append((f, f"near-duplicate of {Path(dup_of).name} (jaccard>={thr})"))
            continue
        kept_sigs.append((sig, f))
        alive.append(row)
    return alive, killed


STAGES = [
    ("L1 turns", stage_turns),
    ("L2 tool_ratio", stage_tool_ratio),
    ("L3 end_turn", stage_end_turn),
    ("L4 length", stage_length),
    ("L5 topic", stage_topic),
]


# ---------------------------------------------------------------------------
# enrich + run
# ---------------------------------------------------------------------------


def read_candidates(path: Path) -> list[dict]:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines:
        sys.exit("candidates file is empty")
    header = lines[0].split("\t")
    need = {"agent", "session_file"}
    if not need.issubset(header):
        sys.exit(f"candidates header missing {need}: {header}")
    rows = []
    for ln in lines[1:]:
        if not ln.strip():
            continue
        parts = ln.split("\t")
        row = dict(zip(header, parts))
        row["_header"] = header
        rows.append(row)
    return rows


def fmt_int(n: int) -> str:
    return f"{n:,}"


def run_funnel(rows: list[dict], p: dict) -> tuple[list[dict], list[tuple[str, str]]]:
    views: dict[str, SessionView] = {}
    skipped: list[tuple[str, str]] = []
    alive = rows

    table: list[tuple[str, int, int, str]] = []
    total_in = len(rows)
    table.append(("L0 scan", total_in, total_in, "candidates.tsv from curate scan"))

    for name, fn in STAGES:
        nxt = []
        killed = 0
        reasons: dict[str, int] = {}
        for row in alive:
            f = row["session_file"]
            v = views.get(f)
            if v is None:
                v = parse_session(Path(f), row.get("agent", ""))
                if v is None:
                    skipped.append((f, "unparseable/unknown format"))
                    continue
                views[f] = v
            ok, why = fn(row, v, p)
            if ok:
                nxt.append(row)
            else:
                killed += 1
                key = why.split("(")[0][:60]
                reasons[key] = reasons.get(key, 0) + 1
        alive = nxt
        top = "; ".join(f"{k} x{c}" for k, c in sorted(reasons.items(), key=lambda kv: -kv[1])[:2])
        table.append((name, len(alive), killed, top or "-"))

    # cross-row stage last
    alive, dup_killed = stage_dedup(alive, views, p)
    table.append((f"L6 dedup", len(alive), len(dup_killed), "; ".join(f"{k} x1" for _, k in dup_killed[:2]) or "-"))

    # print funnel table: the agent's decision surface
    print("=" * 78)
    print(f"preset: {p.get('_preset', 'custom')}   surviving {len(alive)} / {total_in}")
    print("=" * 78)
    for name, inn, killed, reason in table:
        pass
    prev = total_in
    for name, inn, killed, reason in table:
        if name.startswith("L0"):
            print(f"{name:<14} {fmt_int(inn):>8}   {reason}")
            continue
        pct = f"({killed / prev * 100:.0f}% of prev)" if prev else ""
        print(f"{name:<14} {fmt_int(inn):>8}   killed {killed:<5} {pct:<10} {reason[:70]}")
        prev = inn
    if skipped:
        print(f"{'skipped':<14} {fmt_int(len(skipped)):>8}   unparseable/unknown format")
    print()

    all_killed = [(f, r) for f, r in skipped]
    return alive, all_killed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    pe = sub.add_parser("enrich", help="add computed columns (turns/tools/stop/chars) to candidates.tsv")
    pe.add_argument("candidates")
    pe.add_argument("out")

    pr = sub.add_parser("run", help="execute the funnel and write surviving candidates")
    pr.add_argument("candidates")
    pr.add_argument("out")
    pr.add_argument("--preset", default="report", choices=sorted(PRESETS))
    pr.add_argument("--min-turns", type=int)
    pr.add_argument("--max-tool-ratio", type=float)
    pr.add_argument("--no-end-turn", action="store_true")
    pr.add_argument("--min-user-msg-chars", type=int)
    pr.add_argument("--max-first-msg-chars", type=int)
    pr.add_argument("--topic-keywords", help="comma-separated; overrides preset")
    pr.add_argument("--dedup-threshold", type=float)
    pr.add_argument("--no-dedup", action="store_true")

    sub.add_parser("presets", help="list preset parameter sets")

    args = ap.parse_args()

    if args.cmd == "presets":
        for name, cfg in PRESETS.items():
            print(f"{name}: {cfg['desc']}")
            for k in ("min_turns", "max_tool_ratio", "require_end_turn", "topic_keywords", "dedup_threshold"):
                print(f"  {k}: {cfg[k]}")
            print()
        return 0

    rows = read_candidates(Path(args.candidates))

    if args.cmd == "enrich":
        extra = ["user_turns", "assistant_turns", "tool_uses", "last_stop", "first_msg_chars"]
        out = []
        for row in rows:
            v = parse_session(Path(row["session_file"]), row.get("agent", ""))
            vals = (
                (str(v.user_turns), str(v.assistant_turns), str(v.tool_uses), v.last_stop_reason,
                 str(len(v.first_user_msg)))
                if v else ("", "", "", "", "")
            )
            out.append({**row, **dict(zip(extra, vals))})
        header = rows[0]["_header"] + extra
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write("\t".join(header) + "\n")
            for r in out:
                fh.write("\t".join(r[h] for h in header) + "\n")
        print(f"enriched {len(rows)} rows -> {args.out}")
        return 0

    # run
    p = dict(PRESETS[args.preset])
    p["_preset"] = args.preset
    if args.min_turns is not None:
        p["min_turns"] = args.min_turns
    if args.max_tool_ratio is not None:
        p["max_tool_ratio"] = args.max_tool_ratio
    if args.no_end_turn:
        p["require_end_turn"] = False
    if args.min_user_msg_chars is not None:
        p["min_user_msg_chars"] = args.min_user_msg_chars
    if args.max_first_msg_chars is not None:
        p["max_first_msg_chars"] = args.max_first_msg_chars
    if args.topic_keywords is not None:
        p["topic_keywords"] = [k for k in args.topic_keywords.split(",") if k]
    if args.dedup_threshold is not None:
        p["dedup_threshold"] = args.dedup_threshold
    if args.no_dedup:
        p["dedup_threshold"] = 0.0

    alive, killed = run_funnel(rows, p)

    # output: surviving candidates, same shape as input (compatible with screen.tsv flow)
    header = rows[0]["_header"]
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\t".join(header) + "\n")
        for r in alive:
            fh.write("\t".join(r[h] for h in header) + "\n")
    print(f"surviving {len(alive)} / {len(rows)} -> {args.out}")
    print("next: curate-sessions.sh scan already produced screen.tsv scaffold;")
    print("      run review --ui tsv on this OUT after folding survivors, or re-tune and re-run.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
