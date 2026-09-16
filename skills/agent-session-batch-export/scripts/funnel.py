#!/usr/bin/env python3
"""The funnel: deterministic multi-stage filter over agent-session candidates.

Mechanism layer of the session-export skill family. The STAGE ORDER and the
SHAPE of each stage's predicate are fixed here; the PARAMETERS (thresholds,
keywords) come from one of two data sources: a shipped theme JSON via
`--policy` (the direction path -- the purchaser can read exactly what was
bought), or a built-in preset via `--preset` (ad-hoc runs, where no theme
exists; PRESETS below). The agent never parses session JSONL itself -- it
reads the funnel table and the enriched candidates TSV this script prints.

Design rules (do not violate when extending):
  * Python standard library only. No third-party deps. This must run anywhere
    python3 runs, including a scoop-installed Windows python.
  * Streaming: one session file is held in memory at a time, never the corpus.
  * Every stage reports (in, out, killed, skipped, reason) -- the funnel table
    is the agent's only decision surface for re-tuning. A `skip` is NOT a pass:
    it says the judgement did not apply to that format, and it is printed in its
    own column so "the layer passed" and "the layer did not apply" stay apart.
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
                   sessions that end mid-tool-call; SKIPS codex, whose records
                   carry no stop_reason at all (PACK-SPEC § 5), and FAILS a
                   claude_code session whose last assistant record is missing
                   the field -- an empty string read as a pass is how the codex
                   skip went unnoticed in the first place.
  L5 length     -- user-message length distribution. Kills scaffolding-noise
                   sessions (first_prompt is huge, real request is tiny).
  L6 topic      -- keyword/regex match over extracted user prose. The only
                   stage that reads message bodies.
  L7 noncode    -- coding-signal exclusion. "Mainly not code" is a NEGATIVE
                   property, so it is judged by coding signals being absent
                   rather than by a non-coding keyword being present. Runs only
                   when the theme supplies exclude_keywords.
  L8 credential -- credential shapes over the COMPLETE raw JSONL, not merely
                   user prose: a key can sit in tool output or an assistant
                   message. It ANNOTATES and never drops a row, because
                   silently exporting the rest of a batch would hide the
                   finding; --credential-hard-gate turns any surviving hit into
                   a whole-batch refusal (exit 3). This is a determinism and
                   disclosure stage, NOT a security boundary: an agent that
                   rewrites its own artifacts is not stopped by it.
  L9 dedup      -- near-duplicate cluster collapse via 5-gram Jaccard over
                   first user messages. Keeps the longest of each cluster. OFF
                   (its row still printed) when the policy supplies no
                   threshold, which is what --no-dedup does.

The signature stage is OFF unless the theme sets --sig-ratio-min: thresholds are
policy and live in the theme file (PACK-SPEC § 4); the mechanism knows only the
shape.

Usage:
  python3 funnel.py enrich  CANDIDATES.tsv OUT.tsv      # add computed columns
  python3 funnel.py run     CANDIDATES.tsv OUT.tsv --preset report [--min-turns 5 ...]
  python3 funnel.py run     CANDIDATES.tsv OUT.tsv --policy THEME.json
  python3 funnel.py presets                            # list preset parameter sets

The 'run' funnel table goes to stdout; OUT.tsv is the surviving candidates
plus computed columns, shaped for curate-sessions.sh review --ui tsv.
"""

from __future__ import annotations

import argparse
import json
import os
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
    # User-role records that are entirely a tagged context block the client
    # injected (codex's `<environment_context>`, `<user_instructions>`,
    # `<skills_instructions>`). Counted here so the number is visible rather
    # than silently dropped: `user_turns` is real turns, this says how many
    # the raw file appeared to have. Every codex session carries at least one,
    # so without this the turn floor is off by one for codex input.
    injected_user_messages: int = 0
    fmt: str = ""
    # Thinking-signature state (PACK-SPEC § 4). `thinking_blocks` is the number
    # of `type == "thinking"` blocks and always equals present + empty;
    # `redacted_blocks` counts `redacted_thinking` (a safety-redaction block
    # with no signature) and is deliberately NOT a thinking block.
    thinking_blocks: int = 0
    signature_present: int = 0
    signature_empty: int = 0
    redacted_blocks: int = 0
    # Credential shapes found anywhere in the RAW file (L8). `credential_kinds`
    # holds pattern NAMES only, never matched text, so a funnel table or an
    # enriched TSV can be pasted into an issue without leaking the secret it is
    # reporting.
    credential_count: int = 0
    credential_kinds: list[str] = field(default_factory=list)

    @property
    def credential_hit(self) -> int:
        """1 when this file carries at least one credential shape."""
        return 1 if self.credential_count else 0

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


# The blocks a client injects into its own session file as a `user` message.
# Matched structurally — the whole message is one tagged block — never by a
# substring anywhere in the text: a partner discussing `<environment_context>`
# in prose must stay a real user turn.
INJECTED_BLOCK_TAGS = (
    "environment_context",
    "user_instructions",
    "skills_instructions",
)
_BLOCK_RE = re.compile(r"<(?P<tag>[A-Za-z0-9_:-]+)>(?s:.*)</(?P=tag)>\s*\Z")


def is_injected_block(text: str) -> bool:
    """True when `text` is nothing but one tagged context block.

    The tag must be one the client injects (an agent writing `<example>…` by
    hand stays a real turn) and the block must own the whole message, so a
    quoted block inside a longer request is not swallowed.
    """
    m = _BLOCK_RE.match(text.strip())
    return bool(m) and m.group("tag").lower() in INJECTED_BLOCK_TAGS


# Credential shapes, by name (L8). High-signal prefixed forms only: the cost of
# a false positive is a real session withheld, so prose that merely SAYS "my API
# key" must not match. Scanned over the whole raw line, because a key can sit in
# tool output or an assistant message, not only in user prose.
CREDENTIAL_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("anthropic_key", re.compile(r"sk-ant-[A-Za-z0-9_-]{10,}")),
    # `(?!ant-)` keeps this from also matching an `sk-ant-…` key, which would
    # count one secret twice and report it under two vendors. Measured on a
    # fixture: one `sk-ant-…` reported `anthropic_key,openai_key` and a count of
    # 2. An inflated disclosure number is worse than none, because the reader
    # cannot tell it is wrong.
    ("openai_key", re.compile(r"sk-(?!ant-)(?:proj-)?[A-Za-z0-9_-]{16,}")),
    ("aws_access_key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("github_token", re.compile(r"gh[pousr]_[A-Za-z0-9]{16,}")),
    ("github_pat", re.compile(r"github_pat_[A-Za-z0-9_]{16,}")),
    ("google_api_key", re.compile(r"AIza[0-9A-Za-z_-]{30,}")),
    ("slack_token", re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}")),
    ("private_key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
)


def _scan_credentials(v: SessionView, raw: str) -> None:
    """Accumulate credential shapes from one RAW line of the session file.

    Called from inside the parsers' existing single pass rather than as a second
    read: the whole file is the scan surface, and reading it twice would double
    the I/O of the most expensive stage for no gain.
    """
    for name, rx in CREDENTIAL_PATTERNS:
        n = len(rx.findall(raw))
        if n:
            v.credential_count += n
            if name not in v.credential_kinds:
                v.credential_kinds.append(name)


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
    # Separates "not this format" from "this format, zero real user turns".
    # Returning None on an empty user-text list would file a zero-turn session
    # under "unparseable/unknown format" — a different and false claim — and the
    # turn floor is 0 in this family, so L1 must be the thing that judges it.
    saw_record = False
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                # Whole-line scan: a key can sit in tool output or an assistant
                # message, not only in the prose a topic stage reads.
                _scan_credentials(v, line)
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if rec.get("type") not in ("user", "assistant"):
                    continue
                saw_record = True
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
                    # Assigned unconditionally: this is the LAST assistant
                    # record's value, and an absent one there is the finding
                    # the closure stage fails on. Keeping the last non-empty
                    # value instead would let a truncated tail inherit the
                    # closure of an earlier turn and read as a pass.
                    v.last_stop_reason = sr
    except OSError:
        return None
    if not saw_record:
        return None
    v.first_user_msg = v.user_texts[0] if v.user_texts else ""
    v.fmt = "claude_code"
    return v


def parse_codex(path: Path) -> SessionView | None:
    """~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl : response_item lines.

    Codex marks its own injected context as an ordinary `user` message, so a
    filter on `payload.type == "message"` alone counts it as a turn. Measured
    on a one-shot translation rollout: `user_turns` reported 2 for a session
    with exactly one real request, the extra being `<environment_context>`.
    Every codex session carries it, which puts the theme's `min_user_turns`
    floor one turn too low for codex input.
    """
    v = SessionView(path=path)
    # Distinguishes "this is not a codex file" (no message record at all ->
    # not this format, return None) from "this is a codex file whose only user
    # records were injected blocks" (a real session with zero real turns -> let
    # L1 judge it). Without the split, excluding the blocks would file such a
    # file under "unparseable/unknown format", which is a different claim and a
    # false one.
    saw_message = False
    try:
        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                # Whole-line scan, same surface as the claude adapter: tool
                # output and assistant messages carry keys too.
                _scan_credentials(v, line)
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if rec.get("type") != "response_item":
                    continue
                pl = rec.get("payload") or {}
                pt = pl.get("type")
                if pt == "message" and pl.get("role") in ("user", "assistant"):
                    saw_message = True
                    text = "".join(
                        c.get("text", "")
                        for c in (pl.get("content") or [])
                        if isinstance(c, dict)
                    )
                    if pl.get("role") == "user":
                        if is_injected_block(text):
                            # Visible, not dropped: the count is the record of
                            # what the raw file looked like, and a session of
                            # nothing but injected blocks is not a conversation.
                            v.injected_user_messages += 1
                        elif text.strip():
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
    if not saw_message:
        return None
    v.first_user_msg = v.user_texts[0] if v.user_texts else ""
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


def session_path(raw: str) -> Path:
    """Turn a candidates.tsv path into one THIS interpreter can open.

    curate-sessions.sh enumerates sessions with `find`, so under Git Bash the
    paths it writes are MSYS form (`/c/Users/...`). A Windows-native python —
    the scoop install this file's header promises to support — cannot open
    that: `Path('/c/Users/...').exists()` is False, `open()` raises
    FileNotFoundError, the parsers catch OSError and return None, and every
    session is reported as "unparseable/unknown format". Measured on a real
    Windows host: 34 of 34 candidates unparseable via `/c/...`, and the same
    file parsed (user_turns=1) via `C:/...`.

    The count was not lying — the parse genuinely failed — which is why this
    had to be fixed here, at the one boundary where a TSV string becomes a
    Path, rather than by loosening the parsers.

    Left alone when it already opens, so a POSIX path that really is `/c/...`
    on Linux keeps working. Drive-letter rewriting is only attempted when the
    literal path does not exist AND this is a Windows interpreter.
    """
    p = Path(raw)
    if os.name != "nt" or p.exists():
        return p
    # /c/Users/... or /cygdrive/c/Users/... -> C:/Users/...
    m = re.match(r"^/(?:cygdrive/)?([A-Za-z])(/.*)?$", raw)
    if m:
        cand = Path(f"{m.group(1).upper()}:{m.group(2) or '/'}")
        if cand.exists():
            return cand
    return p


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

    The stage only runs when the theme set `sig_ratio_min` (see `Stage.enabled`),
    so the key is read directly: a threshold is policy and lives in the theme
    file, and this stage does not invent one.
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
    """Session closure (PACK-SPEC § 5).

    Codex writes no `stop_reason` on any message record — measured: 0 of 25
    rollouts carry the field — so the layer cannot judge a codex session at
    all, and it SKIPS rather than passing. The distinction is the point: "the
    closure layer passed this batch" and "the closure layer did not apply to
    this batch" are different statements and the manifest must not merge them.

    An absent `stop_reason` on a **claude_code** session is a different thing
    and is a FAIL: that format does have the field, so its absence means the
    last assistant record was truncated or rewritten. Reading the empty string
    as a pass is exactly how the codex skip went unnoticed.
    """
    if not p["require_end_turn"]:
        return "pass", ""
    if v.fmt == "codex":
        return "skip", "no stop_reason in this format"
    if not v.last_stop_reason:
        return "fail", "last stop_reason absent on claude_code"
    if v.last_stop_reason in ("end_turn", "stop"):
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


def stage_noncode(row: dict, v: SessionView, p: dict) -> tuple[StageStatus, str]:
    """Coding-signal exclusion (L7).

    "Mainly not code" is a negative property, so it is judged by coding signals
    being ABSENT rather than by a non-coding keyword being present. Measured
    reason this stage exists: a real session reading `你有图片生成能力吗？`
    carries no translation/writing keyword at all, so a positive-keyword topic
    stage cannot select it and only an LLM's semantic read would — which is
    exactly the judgement this family moves out of the model.

    Reads the same cheap prose surface as the topic stage, not the raw file: an
    exclusion word inside a tool result is the agent's own output, not the
    user's request, and would reject a session for what the assistant did.
    """
    ex = p.get("exclude_keywords") or []
    if not ex:
        return "pass", ""
    hay = norm(" ".join(t[:500] for t in v.user_texts[:3]))
    for kw in ex:
        if norm(kw) in hay:
            return "fail", f"coding signal '{kw}' in user prose"
    return "pass", ""


def stage_credential(row: dict, v: SessionView, p: dict) -> tuple[StageStatus, str]:
    """Credential disclosure (L8) — annotate, never drop.

    A hit does NOT kill the row. Dropping it would export the rest of the batch
    while hiding that the partner's history carries their own keys, and the
    caller could not tell a clean batch from a filtered one. So the stage passes
    and records; `--credential-hard-gate` turns any surviving hit into a
    whole-batch refusal at the end of the run.

    This is determinism and disclosure, not security. An agent that edits its
    own artifacts is not stopped here, and no wording in this file should imply
    it is.
    """
    if v.credential_hit:
        return "pass", f"credential shapes: {','.join(v.credential_kinds)}"
    return "pass", ""


def jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def stage_dedup(
    rows: list[dict], views: dict[str, SessionView], p: dict
) -> tuple[list[dict], list[tuple[str, str]]]:
    """Collapse near-duplicate clusters (same template conversation). Keep the
    longest member of each cluster. Returns (alive_rows, (killed, reason) list).
    This is the one cross-row stage; it runs last so the candidate set is small.

    No threshold supplied means the layer is OFF, and that state is spelled
    `None` — never `0.0`. `jaccard(a, b) >= 0.0` is true of every pair,
    including two empty signatures, so a threshold of zero collapses every
    survivor into one: the exact opposite of no dedup. `None` is the sentinel
    the whole mechanism already reads for "the policy supplied no value"
    (`Stage.enabled`), which is what `--no-dedup` sets (see main).
    """
    thr = p.get("dedup_threshold")
    if thr is None:
        return rows, []
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
    """One stage: its label, its predicate, and the theme key it needs.

    `requires` names the theme parameter without which the stage has no
    threshold to apply, so it cannot run. Stages are the mechanism; which of
    them a theme turns on, and at what threshold, is policy and lives in the
    theme file (DESIGN.md: "a new threshold is a theme-file edit and touches no
    code"). A stage with `requires = None` always runs.

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
    # Needs the threshold, so it is off until the theme supplies one.
    Stage("L3 signature", stage_signature, requires="sig_ratio_min"),
    Stage("L4 end_turn", stage_end_turn),
    Stage("L5 length", stage_length),
    Stage("L6 topic", stage_topic),
    # Off until a theme supplies the word list: an empty exclusion set would
    # otherwise read as "no coding signal found" on every session.
    Stage("L7 noncode", stage_noncode, requires="exclude_keywords"),
    # Always on. It never kills, so it costs no session; what it produces is the
    # disclosure the hard gate and the manifest both read.
    Stage("L8 credential", stage_credential),
]


# The key L9 needs in order to run at all. L9 is the one cross-row stage — it
# consumes the surviving set rather than one row — so it cannot be a STAGES
# entry: the loop judges row by row, and dedup runs last for a reason (smallest
# set). What decides whether it RUNS is still the loop's rule, though: a stage
# whose required key the policy does not supply is OFF, and says so where its
# kill count would sit (`Stage.enabled`; the L9 block in run_funnel).
DEDUP_REQUIRES = "dedup_threshold"


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


# Theme-file key -> the stage parameter it feeds. A theme states buy-side names;
# the stages have their own. Mapping them here in one table is what lets a theme
# file be the single source of a threshold without the stages renaming anything.
POLICY_KEYS: dict[str, str] = {
    "min_user_turns": "min_turns",
    "max_tool_ratio": "max_tool_ratio",
    "sig_ratio_min": "sig_ratio_min",
    "require_end_turn": "require_end_turn",
    "dedup_threshold": "dedup_threshold",
    "min_user_msg_chars": "min_user_msg_chars",
    "max_first_msg_chars": "max_first_msg_chars",
}

# Keys a theme may legitimately carry that NO stage consumes at this engine
# state. Reported once per run rather than applied, because a threshold that
# looks enforced and is not is worse than one openly missing.
POLICY_UNENFORCED: frozenset[str] = frozenset({"min_assistant_turns", "topic_match"})


def load_policy(path: Path) -> dict:
    """Read a theme file into stage parameters.

    Three classes of key, three behaviours:
      * mapped (POLICY_KEYS) -> becomes a stage threshold;
      * known-unenforced (POLICY_UNENFORCED) -> reported on stderr, not applied;
      * anything else -> hard error. A mistyped threshold silently ignored would
        run the funnel at a value nobody chose, which is the failure the whole
        single-source-of-truth layering exists to prevent.
    """
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except OSError as e:
        sys.exit(f"cannot read policy file {path}: {e}")
    except json.JSONDecodeError as e:
        sys.exit(f"policy file {path} is not valid JSON: {e}")
    if not isinstance(doc, dict):
        sys.exit(f"policy file {path} must contain a JSON object")

    pol = doc.get("policy")
    if not isinstance(pol, dict):
        sys.exit(f"policy file {path} has no `policy` object")

    out: dict = {}
    unknown = sorted(set(pol) - set(POLICY_KEYS) - POLICY_UNENFORCED)
    if unknown:
        sys.exit(
            f"policy file {path} carries keys no stage maps: {', '.join(unknown)} "
            "— fix the theme file or teach the funnel; a restated or mistyped "
            "threshold must never pass silently"
        )
    for k, dest in POLICY_KEYS.items():
        if k in pol:
            out[dest] = pol[k]
    ignored = sorted(set(pol) & POLICY_UNENFORCED)
    if ignored:
        print(
            f"note: {path.name} sets {', '.join(ignored)}, which no funnel stage "
            "consumes — NOT enforced by this engine state",
            file=sys.stderr,
        )

    # Word lists live at the top level of a theme, not inside `policy`: they are
    # what the theme IS, while `policy` is how strictly it is applied.
    kws = doc.get("keywords")
    if isinstance(kws, list):
        out["topic_keywords"] = [str(k) for k in kws]
    ex = doc.get("exclude_keywords")
    if isinstance(ex, list) and ex:
        out["exclude_keywords"] = [str(k) for k in ex]
    out["_preset"] = f"theme:{doc.get('theme', path.stem)}"
    return out


@dataclass
class StageRow:
    """One row of the printed funnel table — the agent's decision surface.

    `killed`, `skipped` and `off` are three different things and are kept apart
    on purpose: a stage that ran and passed everything, one the theme gated off,
    and one that skipped the sessions it could not judge must not be readable as
    each other.
    """

    name: str
    survivors: int
    killed: int = 0
    skipped: int = 0
    off: bool = False
    reason: str = ""


def run_funnel(
    rows: list[dict], p: dict
) -> tuple[list[dict], list[tuple[str, str]], dict[str, SessionView]]:
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
                v = parse_session(session_path(f), row.get("agent", ""))
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

    # cross-row stage last: same gate as every stage above — with no threshold
    # supplied the layer is OFF, and its row says so instead of carrying a kill
    # count it did not earn. `--no-dedup` is what produces that state (main).
    if p.get(DEDUP_REQUIRES) is None:
        table.append(
            StageRow(
                "L9 dedup",
                len(alive),
                off=True,
                reason=f"off (this pack sets no {DEDUP_REQUIRES})",
            )
        )
    else:
        alive, dup_killed = stage_dedup(alive, views, p)
        table.append(
            StageRow(
                "L9 dedup",
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
    # The turn counts above are post-correction, so the correction is stated
    # rather than left implicit: an auditor re-running this pack has to be able
    # to see that injected blocks were excluded and by how much (PACK-SPEC § 3
    # buys "user messages, excluding the environment preamble").
    n_inj_files = sum(1 for v in views.values() if v.injected_user_messages)
    if n_inj_files:
        n_inj = sum(v.injected_user_messages for v in views.values())
        print(
            f"{'inject':<14} {fmt_int(n_inj_files):>8}   "
            f"{fmt_int(n_inj)} injected user block(s) excluded from user_turns"
        )
    # Credential disclosure over the SURVIVORS: the hard gate reads the same
    # set, so the number printed here is the number that can refuse the batch.
    # Printed even when zero, because "we scanned and found none" and "we never
    # scanned" must not look alike to an auditor re-running the theme.
    surv_hits = [
        v
        for v in (views.get(r["session_file"]) for r in alive)
        if v is not None and v.credential_hit
    ]
    kinds = sorted({k for v in surv_hits for k in v.credential_kinds})
    print(
        f"{'credential':<14} {fmt_int(len(surv_hits)):>8}   "
        + (
            f"surviving session(s) carry credential shapes: {','.join(kinds)}"
            if surv_hits
            else "no credential shapes in the surviving sessions"
        )
    )
    print()

    return alive, unparseable, views


def main() -> int:
    # Windows python encodes stdout with the legacy ANSI code page (cp1252 on
    # this host), not UTF-8. The funnel table quotes session prose in its stage
    # reasons, and one CJK character in a user's first message then aborts the
    # whole run with UnicodeEncodeError mid-table — observed killing theme
    # `generation` at L6 after 33 sessions had already been judged. The same
    # code page is why the shell's own theme note printed `�`.
    #
    # Reconfigure rather than wrap: this keeps `print` working unchanged
    # everywhere else, and `errors="replace"` means an unmappable glyph
    # degrades to a placeholder instead of destroying the run. A funnel table
    # is a decision surface — printing it slightly lossily beats not printing
    # it at all.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
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
    pr.add_argument(
        "--no-dedup",
        action="store_true",
        help="turn the dedup layer off: no threshold is supplied, so L9 prints "
        "OFF and kills nothing. This is NOT --dedup-threshold 0, which "
        "collapses every survivor into one",
    )
    pr.add_argument(
        "--sig-ratio-min",
        type=float,
        help="thinking-signature ratio floor (PACK-SPEC § 4). No preset sets "
        "one: the layer is OFF unless the theme asks for it, so existing "
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
    pr.add_argument(
        "--policy",
        help="a theme JSON file: its `policy` object supplies every threshold "
        "and its `keywords`/`exclude_keywords` supply the word lists. This is "
        "the direction path's input — thresholds are policy and live in the "
        "theme file, so nothing downstream restates a number. Explicit flags "
        "still win over the file, which is what lets a test pin one value",
    )
    pr.add_argument(
        "--credential-hard-gate",
        action="store_true",
        help="exit 3 when any SURVIVING session carries a credential shape, "
        "before anything is written. The whole batch is refused rather than "
        "quietly filtered: exporting the remainder would hide that the "
        "partner's own keys are in their history. Determinism and disclosure, "
        "not security — an agent that rewrites its own artifacts is not "
        "stopped by this",
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
        # The signature columns are the buy-side `present/empty/absent` state plus
        # the ratio the gate compares against, so a partner can see the
        # distribution before committing to an export (PACK-SPEC § 4, § 6).
        # `injected_user_messages` sits next to `user_turns` for the same
        # reason: the turn floor is read off this TSV, and a raw-block count
        # that was excluded has to be visible or the correction is invisible.
        extra = [
            "user_turns",
            "injected_user_messages",
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
            # Names only, never matched text: an enriched TSV is pasted into
            # issues and chat, and a column that leaked the secret it reports
            # would make the disclosure itself the disclosure.
            "credential_hit",
            "credential_count",
            "credential_kinds",
        ]
        out = []
        for row in rows:
            v = parse_session(session_path(row["session_file"]), row.get("agent", ""))
            vals = (
                (
                    str(v.user_turns),
                    str(v.injected_user_messages),
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
                    str(v.credential_hit),
                    str(v.credential_count),
                    ",".join(v.credential_kinds),
                )
                if v
                else ("",) * len(extra)
            )
            out.append({**row, **dict(zip(extra, vals))})
        full_header = header + extra
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write("\t".join(full_header) + "\n")
            fh.writelines("\t".join(r[h] for h in full_header) + "\n" for r in out)
        print(f"enriched {len(rows)} rows -> {args.out}")
        return 0

    # run
    # A theme file replaces the preset as the base: the direction path's
    # thresholds live in the theme, and a preset silently underneath it would be
    # a second source for the same number. Explicit flags still win over both,
    # which is what lets a test pin one value without editing a shipped theme.
    if args.policy:
        p = load_policy(Path(args.policy))
    else:
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
        # Clears the threshold rather than setting it to zero: the stage tests
        # `jaccard >= thr`, and `>= 0.0` holds for every pair, so a zero
        # threshold collapses every survivor into one — the opposite of what
        # this flag promises. `None` is the mechanism's own "the policy
        # supplied no value" state, which both `Stage.enabled` and
        # `stage_dedup` read as OFF, and which the L9 row prints as such.
        p["dedup_threshold"] = None
    if args.sig_ratio_min is not None:
        p["sig_ratio_min"] = args.sig_ratio_min

    alive, _killed, views = run_funnel(rows, p)

    # Hard gate BEFORE any output is written: a refused batch must leave nothing
    # behind, so the caller cannot mistake a partial write for a delivery.
    if args.credential_hard_gate:
        hits = [
            v
            for v in (views.get(r["session_file"]) for r in alive)
            if v is not None and v.credential_hit
        ]
        if hits:
            kinds = sorted({k for v in hits for k in v.credential_kinds})
            print(
                f"refusing the batch: {len(hits)} surviving session(s) carry "
                f"credential shapes ({','.join(kinds)}).\n"
                "  these are your machine's own history and may hold your keys.\n"
                "  re-run with --allow-credentials to export them anyway "
                "(recorded in the manifest), or run the interactive review.\n"
                "  nothing was written.",
                file=sys.stderr,
            )
            return 3

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
