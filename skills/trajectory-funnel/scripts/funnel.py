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
  L3 signature  -- thinking-signature ratio floor (PACK-SPEC § 4). Kills a
                   session whose thinking blocks carry no signature (a relay
                   or client stripped it); SKIPS a session with no thinking
                   block at all (codex has no signature field) and records the
                   skip in the reason, so it cannot be read as a pass.
  L4 end_turn   -- last assistant stop_reason == end_turn. Kills truncated
                   sessions that end mid-tool-call.
  L5 length     -- user-message length distribution. Kills scaffolding-noise
                   sessions (first_prompt is huge, real request is tiny).
  L6 topic      -- keyword/regex match over extracted user prose. The only
                   stage that reads message bodies.
  L7 dedup      -- near-duplicate cluster collapse via 5-gram Jaccard over
                   first user messages. Keeps the longest of each cluster.

The signature stage is OFF unless the pack sets --sig-ratio-min: thresholds are
policy and live in the pack (PACK-SPEC § 4), the mechanism only knows the shape.

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
import textwrap
import unicodedata
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

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
        "topic_keywords": [
            "ppt",
            "报告",
            "汇报",
            "总结",
            "论文",
            "润色",
            "翻译",
            "改写",
            "撰写",
            "方案",
        ],
        "dedup_threshold": 0.6,
    },
    "roleplay": {
        "desc": "roleplay / creative writing: very text-heavy, long conversations, no tools",
        "min_turns": 10,
        "max_tool_ratio": 0.05,
        "require_end_turn": True,
        "min_user_msg_chars": 10,
        "max_first_msg_chars": 20000,
        "topic_keywords": [
            "角色",
            "人设",
            "剧情",
            "小说",
            "世界观",
            "扮演",
            "故事",
            "角色卡",
            "npc",
            "ooc",
        ],
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
    # Thinking-signature state (PACK-SPEC § 4). `thinking_blocks` is the number
    # of `type == "thinking"` blocks and always equals present + empty;
    # `redacted_blocks` counts `redacted_thinking` (a safety-redaction block
    # with no signature) and is deliberately NOT a thinking block.
    thinking_blocks: int = 0
    signature_present: int = 0
    signature_empty: int = 0
    redacted_blocks: int = 0

    @property
    def signature_ratio(self) -> float:
        """present / (present + empty), 0.0 when there are no thinking blocks."""
        n = self.signature_present + self.signature_empty
        return self.signature_present / n if n else 0.0

    @property
    def signature_state(self) -> str:
        """The three states PACK-SPEC § 4 records per session.

        `present` covers a mixed session too: the states name what can be
        measured, and where any signature exists the ratio is what decides.
        """
        if not self.thinking_blocks:
            return "absent"
        return "present" if self.signature_present else "empty"


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


def _count_blocks(v: SessionView, content) -> None:
    """Accumulate thinking-signature state from one `message.content[]`.

    Three block types, three behaviours (PACK-SPEC § 4):
      * `thinking` with a non-empty `signature` -> signed;
      * `thinking` with `""` -> unsigned. Anthropic documents that `signature`
        is returned regardless of the `display` setting, so an empty one means
        something in the path stripped it, not that the model produced none;
      * `redacted_thinking` -> a safety-redaction block carrying `data` and no
        signature. It is NOT a thinking block for this purpose and counts
        toward neither numerator nor denominator, but is counted separately so
        a redacted-only session stays distinguishable from a plain one.
    """
    if not isinstance(content, list):
        return
    for b in content:
        if not isinstance(b, dict):
            continue
        t = b.get("type")
        if t == "thinking":
            v.thinking_blocks += 1
            sig = b.get("signature")
            if isinstance(sig, str) and sig:
                v.signature_present += 1
            else:
                v.signature_empty += 1
        elif t == "redacted_thinking":
            v.redacted_blocks += 1


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
                content = msg.get("content")
                _count_blocks(v, content)
                text = _content_text(content)
                if role == "user":
                    if text.strip():
                        v.user_turns += 1
                        v.user_chars.append(len(text))
                        v.user_texts.append(text)
                else:
                    v.assistant_turns += 1
                    if isinstance(content, list):
                        v.tool_uses += sum(
                            1
                            for b in content
                            if isinstance(b, dict) and b.get("type") == "tool_use"
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
                        c.get("text", "")
                        for c in (pl.get("content") or [])
                        if isinstance(c, dict)
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
# stages: each takes the enrich row + SessionView, returns (verdict, reason)
# where verdict is "pass" | "fail" | "skip". Stage order IS the architecture.
# Add stages at the end of STAGES only after cheaper ones; never reorder without
# re-checking cost assumptions.
# ---------------------------------------------------------------------------


# A stage verdict. "skip" exists because one judgement genuinely does not apply
# to one format: codex has no signature field at all, so failing it would be
# judging the format rather than the data (PACK-SPEC § 4). A skipped session
# stays alive and its reason is recorded; it is NOT a pass, and the funnel table
# prints it under "skipped", never in the pass column.
StageStatus = Literal["pass", "fail", "skip"]


def norm(s: str) -> str:
    return unicodedata.normalize("NFKC", s).lower()


def stage_turns(row: dict, v: SessionView, p: dict) -> tuple[StageStatus, str]:
    if v.user_turns >= p["min_turns"]:
        return "pass", ""
    return "fail", f"user_turns {v.user_turns} < {p['min_turns']}"


def stage_tool_ratio(row: dict, v: SessionView, p: dict) -> tuple[StageStatus, str]:
    total = v.assistant_turns or 1
    ratio = v.tool_uses / total
    if ratio <= p["max_tool_ratio"]:
        return "pass", ""
    return "fail", f"tool_ratio {ratio:.2f} > {p['max_tool_ratio']}"


def stage_signature(row: dict, v: SessionView, p: dict) -> tuple[StageStatus, str]:
    """Thinking-signature ratio floor (PACK-SPEC § 4).

    Three outcomes, and the middle one is the load-bearing decision recorded in
    PACK-SPEC § 4: codex has no `signature` field at all, and judging it as a
    ratio of zero would exclude every codex session from a purchase that
    explicitly covers both formats. So the gate applies where the field exists.

      * zero thinking blocks -> SKIP, with the skip in the reason string;
      * thinking blocks exist -> the ratio decides.

    `redacted_thinking` is deliberately not counted here: it is a safety
    redaction with no signature, so a redacted-only session reports `absent`
    (skipped) rather than `empty` (failed) — the two mean different things.

    The stage only runs when the pack set `sig_ratio_min` (see `stage_gate`), so
    the key is read directly: a threshold is policy and lives in the pack, and
    this stage does not invent one.
    """
    floor = p["sig_ratio_min"]
    if not v.thinking_blocks:
        return "skip", f"no thinking block ({v.fmt}, signature state absent)"
    if v.signature_ratio < floor:
        return "fail", (
            f"signature_ratio {v.signature_ratio:.2f} < {floor:.2f} "
            f"({v.signature_empty} of {v.thinking_blocks} thinking blocks "
            f"unsigned)"
        )
    return "pass", ""


def stage_end_turn(row: dict, v: SessionView, p: dict) -> tuple[StageStatus, str]:
    if not p["require_end_turn"]:
        return "pass", ""
    if v.last_stop_reason in ("", "end_turn", "stop"):
        return "pass", ""
    return "fail", f"last stop_reason={v.last_stop_reason!r}"


def stage_length(row: dict, v: SessionView, p: dict) -> tuple[StageStatus, str]:
    floor = p["min_user_msg_chars"]
    cap = p["max_first_msg_chars"]
    if cap and v.first_user_msg and len(v.first_user_msg) > cap:
        return (
            "fail",
            f"first user msg {len(v.first_user_msg)} > cap {cap} (scaffold noise)",
        )
    if floor and v.user_chars:
        real = [
            c for c in v.user_chars[1:] or v.user_chars
        ]  # skip msg#1 (rules/preamble)
        if real and max(real) < floor:
            return "fail", f"longest later user msg {max(real)} < {floor}"
    return "pass", ""


def stage_topic(row: dict, v: SessionView, p: dict) -> tuple[StageStatus, str]:
    kws = p.get("topic_keywords") or []
    if not kws:
        return "pass", ""
    # read the cheapest prose surface first: first 3 user messages, truncated.
    hay = norm(" ".join(t[:500] for t in v.user_texts[:3]))
    for kw in kws:
        if norm(kw) in hay:
            return "pass", f"matched '{kw}'"
    return "fail", "no topic keyword in first user messages"


def ngrams(s: str, n: int = 5) -> set[str]:
    s = re.sub(r"\s+", "", norm(s))
    return {s[i : i + n] for i in range(max(1, len(s) - n + 1))}


def jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def stage_dedup(
    rows: list[dict], views: dict[str, SessionView], p: dict
) -> tuple[list[dict], list[tuple[str, str]]]:
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
            killed.append(
                (f, f"near-duplicate of {Path(dup_of).name} (jaccard>={thr})")
            )
            continue
        kept_sigs.append((sig, f))
        alive.append(row)
    return alive, killed


@dataclass(frozen=True)
class Stage:
    """One stage: its label, its predicate, and the pack key it needs.

    `requires` names the pack parameter without which the stage has no threshold
    to apply, so it cannot run. Stages are the mechanism; which of them a pack
    turns on, and at what threshold, is policy and lives in the pack
    (DESIGN.md: "a new threshold is a pack edit and touches no code"). A stage
    with `requires = None` always runs.

    A gated-off stage KEEPS ITS ROW and prints OFF where its kill count would
    sit. Dropping the row would make "this layer never ran" and "this layer ran
    and passed everything" print identically, which is the confusion an auditor
    re-running a pack over a delivered batch cannot afford.
    """

    name: str
    fn: Callable[..., tuple[StageStatus, str]]
    requires: str | None = None

    def enabled(self, p: dict) -> bool:
        # `is not None`, not a truthiness test: --sig-ratio-min 0 is a deliberate
        # floor of zero, not an unset flag.
        return self.requires is None or p.get(self.requires) is not None


STAGES: list[Stage] = [
    Stage("L1 turns", stage_turns),
    Stage("L2 tool_ratio", stage_tool_ratio),
    # Needs the threshold, so it is off until the pack supplies one.
    Stage("L3 signature", stage_signature, requires="sig_ratio_min"),
    Stage("L4 end_turn", stage_end_turn),
    Stage("L5 length", stage_length),
    Stage("L6 topic", stage_topic),
]


# ---------------------------------------------------------------------------
# enrich + run
# ---------------------------------------------------------------------------


def read_candidates(path: Path) -> tuple[list[str], list[dict]]:
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
        rows.append(row)
    return header, rows


def fmt_int(n: int) -> str:
    return f"{n:,}"


@dataclass
class StageRow:
    """One row of the printed funnel table — the agent's decision surface.

    `killed`, `skipped` and `off` are three different things and are kept apart
    on purpose: a stage that ran and passed everything, one the pack gated off,
    and one that skipped the sessions it could not judge must not be readable as
    each other.
    """

    name: str
    survivors: int
    killed: int = 0
    skipped: int = 0
    off: bool = False
    reason: str = ""


def run_funnel(rows: list[dict], p: dict) -> tuple[list[dict], list[tuple[str, str]]]:
    views: dict[str, SessionView] = {}
    unparseable: list[tuple[str, str]] = []
    alive = rows

    total_in = len(rows)
    table: list[StageRow] = [
        StageRow("L0 scan", total_in, reason="candidates.tsv from curate scan")
    ]

    for st in STAGES:
        if not st.enabled(p):
            table.append(
                StageRow(
                    st.name,
                    len(alive),
                    off=True,
                    reason=f"off (this pack sets no {st.requires})",
                )
            )
            continue
        name, fn = st.name, st.fn
        nxt = []
        killed = 0
        n_skip = 0
        fails: dict[str, int] = {}
        skips: dict[str, int] = {}
        for row in alive:
            f = row["session_file"]
            v = views.get(f)
            if v is None:
                v = parse_session(Path(f), row.get("agent", ""))
                if v is None:
                    unparseable.append((f, "unparseable/unknown format"))
                    continue
                views[f] = v
            verdict, why = fn(row, v, p)
            if verdict == "fail":
                killed += 1
                key = why.split("(")[0][:50]
                fails[key] = fails.get(key, 0) + 1
            else:
                if verdict == "skip":
                    n_skip += 1
                    key = why.split("(")[0][:50]
                    skips[key] = skips.get(key, 0) + 1
                nxt.append(row)
        alive = nxt
        # Fail and skip reasons are both shown, each carrying its class: a reader
        # must be able to tell "we rejected these" from "we could not judge these"
        # without opening the manifest.
        bits = [f"{k} x{c}" for k, c in sorted(fails.items(), key=lambda kv: -kv[1])]
        bits += [
            f"skip: {k} x{c}" for k, c in sorted(skips.items(), key=lambda kv: -kv[1])
        ]
        table.append(
            StageRow(name, len(alive), killed, n_skip, reason="; ".join(bits[:3]))
        )

    # cross-row stage last
    alive, dup_killed = stage_dedup(alive, views, p)
    table.append(
        StageRow(
            "L7 dedup",
            len(alive),
            killed=len(dup_killed),
            reason="; ".join(f"{k} x1" for _, k in dup_killed[:2]),
        )
    )

    # print funnel table: the agent's decision surface
    width = 100
    print("=" * width)
    print(f"preset: {p.get('_preset', 'custom')}   surviving {len(alive)} / {total_in}")
    print("=" * width)
    prev = total_in
    # Column where a reason starts; continuation lines hang under it.
    col = 62
    for r in table:
        if r.name.startswith("L0"):
            print(f"{r.name:<14} {fmt_int(r.survivors):>8}   {r.reason}")
            continue
        if r.off:
            # A gated-off stage is marked by the literal OFF where a kill count
            # would sit: "ran and passed everything" and "never ran" must not
            # look alike.
            print(f"{r.name:<14} {fmt_int(r.survivors):>8}   {'OFF':<9} {r.reason}")
            prev = r.survivors
            continue
        pct = f"({r.killed / prev * 100:.0f}% of prev)" if prev else ""
        # The skip column and the skip reasons are both always present. A stage
        # that skipped sessions must not read as one that passed them, which is
        # the whole reason the skip is printed rather than folded into `out`.
        head = (
            f"{r.name:<14} {fmt_int(r.survivors):>8}   killed {r.killed:<5} "
            f"skipped {r.skipped:<5}{pct}"
        )
        # Reasons are never truncated: a clipped "skip: no thinking block…"
        # would hide exactly the distinction this column exists to show.
        lines = textwrap.wrap(r.reason, width - col) if r.reason else [""]
        for i, ln in enumerate(lines):
            print((f"{head:<{col}} {ln}" if i == 0 else " " * col + " " + ln).rstrip())
        prev = r.survivors
    if unparseable:
        print(
            f"{'unparseable':<14} {fmt_int(len(unparseable)):>8}   "
            "unknown format, not judged"
        )
    print()

    return alive, unparseable


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    pe = sub.add_parser(
        "enrich",
        help="add computed columns (turns/tools/stop/chars/signature) to candidates.tsv",
    )
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
    pr.add_argument(
        "--sig-ratio-min",
        type=float,
        help="thinking-signature ratio floor (PACK-SPEC § 4). No preset sets "
        "one: the layer is OFF unless the pack asks for it, so existing "
        "presets behave exactly as before. Sessions with no thinking block "
        "are skipped, not failed — codex has no signature field",
    )
    pr.add_argument(
        "--in-place",
        action="store_true",
        help="write survivors back as CANDIDATES and rebuild the "
        "screen.tsv scaffold next to it (the integration "
        "contract with pick-sessions --review-only); CANDIDATES "
        "is archived as candidates.full.tsv",
    )

    sub.add_parser("presets", help="list preset parameter sets")

    args = ap.parse_args()

    if args.cmd == "presets":
        for name, cfg in PRESETS.items():
            print(f"{name}: {cfg['desc']}")
            for k in (
                "min_turns",
                "max_tool_ratio",
                "require_end_turn",
                "topic_keywords",
                "dedup_threshold",
            ):
                print(f"  {k}: {cfg[k]}")
            print()
        return 0

    header, rows = read_candidates(Path(args.candidates))

    if args.cmd == "enrich":
        # The signature columns are the pack's `present/empty/absent` state plus
        # the ratio the gate compares against, so a partner can see the
        # distribution before committing to an export (PACK-SPEC § 4, § 6).
        extra = [
            "user_turns",
            "assistant_turns",
            "tool_uses",
            "last_stop",
            "first_msg_chars",
            "thinking_blocks",
            "signature_present",
            "signature_empty",
            "signature_ratio",
            "signature_state",
            "redacted_blocks",
        ]
        out = []
        for row in rows:
            v = parse_session(Path(row["session_file"]), row.get("agent", ""))
            vals = (
                (
                    str(v.user_turns),
                    str(v.assistant_turns),
                    str(v.tool_uses),
                    v.last_stop_reason,
                    str(len(v.first_user_msg)),
                    str(v.thinking_blocks),
                    str(v.signature_present),
                    str(v.signature_empty),
                    f"{v.signature_ratio:.2f}",
                    v.signature_state,
                    str(v.redacted_blocks),
                )
                if v
                else ("", "", "", "", "", "", "", "", "", "", "")
            )
            out.append({**row, **dict(zip(extra, vals))})
        full_header = header + extra
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write("\t".join(full_header) + "\n")
            fh.writelines("\t".join(r[h] for h in full_header) + "\n" for r in out)
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
    if args.sig_ratio_min is not None:
        p["sig_ratio_min"] = args.sig_ratio_min

    alive, _killed = run_funnel(rows, p)

    if args.in_place:
        # Integration contract with curate-sessions/pick-sessions: the picker's
        # fzf input IS OUTDIR/candidates.tsv, so survivors must REPLACE it — a
        # side-file filter silently does nothing to the interactive flow.
        # E2E-provided failure modes baked in here:
        #   1. the full candidate set is archived, never lost;
        #   2. the screen.tsv scaffold is rebuilt FROM SURVIVORS with the
        #      header row carrying suggested/reason (an awk that skips the
        #      header row drops it, the join then fails with "screen.tsv has
        #      no `suggested` column" and fzf renders 0/0);
        #   3. writes are atomic (tmp + rename) so a crash never leaves a
        #      half-replaced candidates.tsv.
        cand = Path(args.candidates).resolve()
        outdir = cand.parent
        full = outdir / "candidates.full.tsv"
        if not full.exists():
            cand.rename(full)
        else:
            cand.unlink()  # re-tune rerun: archive already holds the full set
        cand_tmp = outdir / ".candidates.tsv.tmp"
        with open(cand_tmp, "w", encoding="utf-8") as fh:
            fh.write("\t".join(header) + "\n")
            fh.writelines("\t".join(r[h] for h in header) + "\n" for r in alive)
        cand_tmp.rename(cand)
        # Survivor rows verbatim + two empty suggestion columns — the shape
        # scan's scaffold emits (`print $0, "", ""`). The join keys on
        # session_file, so a row of all-empty cells would match nothing.
        # An awk that also skips the header row drops suggested/reason and the
        # join aborts with "screen.tsv has no `suggested` column" (fzf 0/0).
        screen = outdir / "screen.tsv"
        tmp = outdir / ".screen.tsv.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write("\t".join(header + ["suggested", "reason"]) + "\n")
            fh.writelines("\t".join(r[h] for h in header) + "\t\t\n" for r in alive)
        tmp.rename(screen)
        print(f"surviving {len(alive)} / {len(rows)}")
        print(f"candidates.tsv replaced in place (full set archived: {full.name})")
        print(f"screen.tsv scaffold rebuilt for survivors: {screen}")
        print(f"next: pick-sessions.sh -o {outdir} -y --review-only  (interactive)")
        print("      or fill screen.tsv suggested/reason, then:")
        print(
            f"      curate-sessions.sh review --ui tsv -o {outdir} && curate-sessions.sh finalize -o {outdir}"
        )
        return 0

    # default: write survivors to the requested output path, leave inputs alone
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("\t".join(header) + "\n")
        fh.writelines("\t".join(r[h] for h in header) + "\n" for r in alive)
    print(f"surviving {len(alive)} / {len(rows)} -> {args.out}")
    print("tip: --in-place replaces OUTDIR/candidates.tsv + rebuilds screen.tsv,")
    print("     which is what pick-sessions --review-only actually reads.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
