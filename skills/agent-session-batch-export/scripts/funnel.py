#!/usr/bin/env python3
"""The funnel: deterministic multi-stage filter over agent-session candidates.

Mechanism layer of the session-export skill family. The STAGE ORDER and the
SHAPE of each stage's predicate are fixed here; the PARAMETERS (thresholds,
keywords) come from three explicit layers, merged per key with the later
layer winning:
  1. scripts/policy.json  the global standard every run starts from. Resolved
                          next to THIS FILE, so a missing file is a broken
                          installation and is a hard error -- silently
                          substituting defaults would run a standard nobody
                          chose.
  2. themes/<name>.json   a theme's delta over that standard (`override`),
                          plus the topic word list that is what the theme IS.
                          Selected with `--theme NAME`.
  3. --override-file      one run's explicit delta; the direction driver
                          composes the direction's root override and the
                          theme entry's own into this one file.
Command-line flags sit on top of all three. A layer may also CLEAR a key
(`null`, or an empty word list), which turns the stage OFF.
The agent never parses session JSONL itself -- it reads the funnel table and
the enriched candidates TSV this script prints.

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
                   stage that reads message bodies. OFF unless the merged
                   policy supplies a topic word list.
  L7 noncode    -- coding-signal exclusion. "Mainly not code" is a NEGATIVE
                   property, so it is judged by coding signals being absent
                   rather than by a non-coding keyword being present. Runs only
                   when the merged policy supplies exclude_keywords.
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

Thresholds are policy and live in the policy/theme/override layers, never in
this file (PACK-SPEC § 4); the mechanism knows only the shape.

Usage:
  python3 funnel.py enrich  CANDIDATES.tsv OUT.tsv      # add computed columns:
                            #   turns/tools/stop/chars/signature, plus the
                            #   item-27 annotation columns (tool pairing,
                            #   repeats, error streaks, verification calls,
                            #   refusal/wrapper proxies, single-shot,
                            #   modalities, capabilities, replay blockers)
  python3 funnel.py run     CANDIDATES.tsv OUT.tsv                    # global policy only
  python3 funnel.py run     CANDIDATES.tsv OUT.tsv --theme translation
  python3 funnel.py run     CANDIDATES.tsv OUT.tsv --theme translation \
                            --override-file RUN.json [--min-turns 5 ...]
  python3 funnel.py collect CANDIDATES.tsv OUTDIR [--theme NAME]      # collection
                            # posture: no thresholds, policy.json not read;
                            # drops only unparseable rows and exact
                            # duplicates, keeps the rest with every
                            # annotation column (pool.tsv) and one row card
                            # per row (row-cards.jsonl)

The 'run' funnel table goes to stdout; OUT.tsv is the surviving candidates
plus computed columns, shaped for curate-sessions.sh review --ui tsv.
"""

from __future__ import annotations

import argparse
import hashlib
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
# Parameter sources are DATA files, never code: scripts/policy.json (the
# global standard), themes/<name>.json (a topic's delta + word list), and the
# --override-file a direction driver composes. See the module docstring for
# the merge order. The former built-in PRESETS dict lived here; every value
# it carried moved into those files (the coding preset is now themes/coding).
# ---------------------------------------------------------------------------


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
    # --- collection annotations (SPEC item 27). Pure additions: every field
    # below defaults to a no-value and no existing column or stage verdict
    # reads them. All are mechanical derivations from the same single pass
    # the parsers already run; none applies a threshold.
    # First assistant message text — the refusal proxy's only surface.
    first_assistant_msg: str = ""
    # Tool pairing, by call id: results missing for calls, and orphans the
    # other way. A call the file lost the answer to is a replay blocker.
    tool_call_ids: set[str] = field(default_factory=set)
    tool_result_ids: set[str] = field(default_factory=set)
    # Repeat counts keyed by (tool name, arguments digest); the max is the
    # loop signature a row card wants.
    tool_repeat_counts: dict[tuple[str, str], int] = field(default_factory=dict)
    # Consecutive failed tool results (claude `is_error`, codex explicit
    # failure markers), current streak plus the max it reached.
    tool_error_streak: int = 0
    tool_error_streak_max: int = 0
    # Tool calls whose command text hit a verification pattern.
    verification_commands: int = 0
    # Modality facets observed in message content (MODALITY_ORDER fixes the
    # emission order).
    modalities: set[str] = field(default_factory=set)
    # Distinct capability ids seen (static TOOL_CAPABILITIES map) and the
    # distinct tool names the map does not know.
    capability_calls: set[str] = field(default_factory=set)
    unmapped_tool_names: set[str] = field(default_factory=set)
    # An explicit truncated-output marker in a tool output (codex writes one);
    # and whether any call went to a live network service.
    has_truncation_marker: bool = False
    has_network_call: bool = False

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

    @property
    def tool_calls_missing_results(self) -> int:
        """Calls with no paired result in the file."""
        return len(self.tool_call_ids - self.tool_result_ids)

    @property
    def tool_results_orphan(self) -> int:
        """Results with no paired call in the file."""
        return len(self.tool_result_ids - self.tool_call_ids)

    @property
    def tool_repeat_max(self) -> int:
        """Most repeats of one (tool name, arguments digest)."""
        return max(self.tool_repeat_counts.values(), default=0)

    @property
    def single_shot(self) -> int:
        """1 when the session is exactly one real user turn."""
        return 1 if self.user_turns == 1 else 0

    @property
    def input_modalities(self) -> str:
        """Comma list of observed modality facets, canonical order."""
        return ",".join(m for m in MODALITY_ORDER if m in self.modalities)

    @property
    def capabilities(self) -> str:
        """Comma list of distinct mapped capability ids, sorted."""
        return ",".join(sorted(self.capability_calls))

    @property
    def tools_unmapped(self) -> int:
        """Distinct tool names the static capability map does not know."""
        return len(self.unmapped_tool_names)

    @property
    def refusal_proxy(self) -> int:
        """1 when the first assistant message opens refusal-shaped."""
        if not self.first_assistant_msg:
            return 0
        text = norm(self.first_assistant_msg)
        return 1 if any(p in text for p in REFUSAL_PATTERNS) else 0

    @property
    def synthetic_wrapper(self) -> int:
        """1 when the first real user message starts with a wrapper prefix."""
        if not self.first_user_msg:
            return 0
        text = norm(self.first_user_msg).lstrip()
        return 1 if any(text.startswith(p) for p in SYNTHETIC_WRAPPER_PREFIXES) else 0

    @property
    def replay_blockers(self) -> str:
        """Why a faithful replay of this session would diverge, comma list.

        Three mechanical findings, each its own proxy:
          * missing_tool_results — a call's answer is not in the file;
          * truncated_output — an explicit truncation marker in a tool output
            (codex writes `Warning: truncated output`), or a claude session
            whose last assistant record carries no stop_reason at all (the
            exact signal the L4 closure stage fails on: the tail was cut or
            rewritten). Codex records no stop_reason, so the second proxy
            never fires there and the marker is its only signal;
          * external_service — a call to a live network capability, whose
            response no replay can reproduce.
        """
        out: list[str] = []
        if self.tool_calls_missing_results:
            out.append("missing_tool_results")
        if self.has_truncation_marker or (
            self.fmt == "claude_code"
            and self.assistant_turns > 0
            and not self.last_stop_reason
        ):
            out.append("truncated_output")
        if self.has_network_call:
            out.append("external_service")
        return ",".join(out)


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


# ---------------------------------------------------------------------------
# collection annotations (SPEC item 27). Mechanically derivable from the raw
# JSONL parse — zero model tokens, no thresholds, never a kill: `collect`
# ships them as pool columns and row cards, `enrich` as columns, and neither
# gains a drop because of them. Every pattern table is centralized here so a
# change to any proxy is one data edit and both parsers read the same table.
# ---------------------------------------------------------------------------

# Command surfaces that look like a test/verification run. Matched against a
# tool call's command text only — never user prose, and never a Write call's
# file content: authoring a test is not running one.
VERIFICATION_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"\bpytest\b", re.IGNORECASE),
    re.compile(r"\bcargo\s+test\b", re.IGNORECASE),
    re.compile(r"\bnpm\s+(?:run\s+)?test\b", re.IGNORECASE),
    re.compile(r"\bnpx\s+(?:jest|vitest|mocha|playwright)\b", re.IGNORECASE),
    re.compile(r"\bgo\s+test\b", re.IGNORECASE),
    re.compile(r"\bmake\b", re.IGNORECASE),
    re.compile(r"\btsc\b", re.IGNORECASE),
    re.compile(r"lint\b", re.IGNORECASE),
    re.compile(r"\bruff\b", re.IGNORECASE),
    re.compile(r"\bmypy\b", re.IGNORECASE),
    re.compile(r"\bflake8\b", re.IGNORECASE),
)

# Refusal phrasing, matched against the normalized (NFKC, lowercased) first
# assistant message. A proxy, like every column here: it annotates a session
# that opens with a refusal-shaped reply, it does not judge the session.
REFUSAL_PATTERNS: tuple[str, ...] = (
    "我不能",
    "我无法",
    "无法协助",
    "无法帮助",
    "i cannot",
    "i can't",
    "i'm unable",
    "i am unable",
    "i won't be able",
    "i'm not able",
    "i am not able",
)

# Packaging prefixes a wrapped/transplanted history starts its first real user
# message with. Matched as a prefix of the normalized first user message.
SYNTHETIC_WRAPPER_PREFIXES: tuple[str, ...] = (
    "the following is the codex agent history",
    "treat the transcript",
)

# Canonical emission order of the input-modality facets.
MODALITY_ORDER: tuple[str, ...] = ("text", "code", "image", "document")


def _note_text_modality(v: SessionView, text: str) -> None:
    """Record the modality facets one message text carries.

    Any non-blank text is `text`; a fenced code block inside it is also `code`.
    Image and document facets come from content blocks, not from prose, so
    they are recorded by the parsers' block loops instead of here.
    """
    if not text.strip():
        return
    v.modalities.add("text")
    if "```" in text:
        v.modalities.add("code")


def _note_tool_error(v: SessionView, failed: bool) -> None:
    """Advance the consecutive-error streak over tool results, in file order."""
    if failed:
        v.tool_error_streak += 1
        v.tool_error_streak_max = max(v.tool_error_streak_max, v.tool_error_streak)
    else:
        v.tool_error_streak = 0


def _note_tool_call(v: SessionView, name: str, digest: str, surface: str) -> None:
    """Accumulate the per-call annotations: repeat key, capability, verifier.

    `digest` is the stable per-format summary of the call's arguments (the
    repeat key's second half); `surface` is the call's command text, or ""
    when the format carries none. An unmapped tool name is counted, never
    guessed at: the unmapped counter is how a new tool surfaces.
    """
    if name:
        cap = TOOL_CAPABILITIES.get(name.lower())
        if cap is not None:
            v.capability_calls.add(cap)
            if cap in NETWORK_CAPABILITIES:
                v.has_network_call = True
        else:
            v.unmapped_tool_names.add(name)
    key = (name, digest)
    v.tool_repeat_counts[key] = v.tool_repeat_counts.get(key, 0) + 1
    if surface and any(rx.search(surface) for rx in VERIFICATION_PATTERNS):
        v.verification_commands += 1


# Input keys a call's command text may ride in. The list is deliberately
# short: matching against arbitrary input fields would count a Write call
# whose file content mentions pytest as a verification run.
COMMAND_FIELDS: tuple[str, ...] = ("command", "cmd", "script")


def _command_surface_from_object(obj: object) -> str:
    """Join a call payload's command-like fields into one match surface."""
    if not isinstance(obj, dict):
        return ""
    parts = []
    for k in COMMAND_FIELDS:
        val = obj.get(k)
        if isinstance(val, str):
            parts.append(val)
        elif isinstance(val, list):
            parts.append(" ".join(str(x) for x in val))
    return " ".join(parts)


def _note_claude_tool_call(v: SessionView, block: dict) -> None:
    """Annotations for one claude `tool_use` block."""
    name = str(block.get("name") or "")
    call_id = block.get("id")
    if isinstance(call_id, str) and call_id:
        v.tool_call_ids.add(call_id)
    payload = block.get("input")
    digest = json.dumps(payload, sort_keys=True, ensure_ascii=False, default=str)
    # claude inputs are structured: command fields only, no raw fallback —
    # a Write call's content naming a test runner must not read as one.
    _note_tool_call(v, name, digest, _command_surface_from_object(payload))


def _note_claude_tool_result(v: SessionView, block: dict) -> None:
    """Pairing + error state for one claude `tool_result` block."""
    call_id = block.get("tool_use_id")
    if isinstance(call_id, str) and call_id:
        v.tool_result_ids.add(call_id)
    _note_tool_error(v, bool(block.get("is_error")))
    content = block.get("content")
    if isinstance(content, list):
        for c in content:
            if isinstance(c, dict) and c.get("type") == "image":
                v.modalities.add("image")


def _note_codex_tool_call(v: SessionView, pl: dict) -> None:
    """Annotations for one codex call record (the three call shapes)."""
    pt = pl.get("type")
    if pt == "local_shell_call":
        name = "local_shell"
        action = pl.get("action")
        digest = json.dumps(action, sort_keys=True, ensure_ascii=False, default=str)
        surface = _command_surface_from_object(action)
    elif pt == "custom_tool_call":
        # The JS bridge source embeds the command by construction
        # (`tools.exec_command({cmd: …})`), so the raw input IS the surface.
        name = str(pl.get("name") or "")
        raw = pl.get("input")
        if not isinstance(raw, str):
            raw = json.dumps(raw, ensure_ascii=False, default=str)
        digest = raw
        surface = raw
    else:  # function_call
        name = str(pl.get("name") or "")
        raw = pl.get("arguments")
        if not isinstance(raw, str):
            raw = json.dumps(raw, ensure_ascii=False, default=str)
        digest = raw
        try:
            parsed: object = json.loads(raw)
        except ValueError:
            parsed = None
        # Structured fields when the arguments parse; the raw string only
        # when they do not (a malformed record is where the text fallback
        # cannot misread a file payload as a command).
        surface = (
            _command_surface_from_object(parsed)
            if isinstance(parsed, dict)
            else raw
        )
    call_id = pl.get("call_id") or pl.get("id")
    if isinstance(call_id, str) and call_id:
        v.tool_call_ids.add(call_id)
    _note_tool_call(v, name, digest, surface)


def _flatten_codex_output(out: object) -> str:
    """Flatten one codex tool output (string or content-item list) to text."""
    if isinstance(out, str):
        return out
    if isinstance(out, list):
        return "\n".join(
            c.get("text", "") for c in out if isinstance(c, dict)
        )
    return ""


def _codex_output_failed(flat: str) -> bool:
    """The explicit failure markers a codex tool output carries.

    Two shapes, both machine-readable: an output that OPENS with `error`
    (measured: the exec bridge reports fetch failures exactly so), or a JSON
    envelope whose `metadata.exit_code` is a nonzero integer.
    """
    if flat.lstrip().lower().startswith("error"):
        return True
    try:
        doc: object = json.loads(flat)
    except ValueError:
        return False
    if isinstance(doc, dict) and isinstance(doc.get("metadata"), dict):
        code = doc["metadata"].get("exit_code")
        return isinstance(code, int) and not isinstance(code, bool) and code != 0
    return False


def _note_codex_tool_output(v: SessionView, pl: dict) -> None:
    """Pairing + error/truncation state for one codex `*_output` record."""
    call_id = pl.get("call_id")
    if isinstance(call_id, str) and call_id:
        v.tool_result_ids.add(call_id)
    flat = _flatten_codex_output(pl.get("output"))
    if "warning: truncated output" in flat.lower():
        v.has_truncation_marker = True
    _note_tool_error(v, _codex_output_failed(flat))


# Static tool-name -> capability map. Keys are lowercased tool names across
# both formats; an unmapped name is counted in `tools_unmapped`, never
# guessed. Network capabilities are the ones a faithful replay cannot
# reproduce (live services), which is what the `external_service` replay
# blocker reports.
_CAP_CODE = "capability.code_execution"
_CAP_FS_READ = "capability.filesystem_read"
_CAP_FS_WRITE = "capability.filesystem_write"
_CAP_SEARCH = "capability.search"
_CAP_WEB_SEARCH = "capability.web_search"
_CAP_WEB_FETCH = "capability.web_fetch"
_CAP_DELEGATION = "capability.delegation"
_CAP_PLANNING = "capability.planning"

NETWORK_CAPABILITIES: frozenset[str] = frozenset({_CAP_WEB_SEARCH, _CAP_WEB_FETCH})

TOOL_CAPABILITIES: dict[str, str] = {
    # code execution
    "bash": _CAP_CODE,
    "bashoutput": _CAP_CODE,
    "killshell": _CAP_CODE,
    "local_shell": _CAP_CODE,
    "shell": _CAP_CODE,
    "exec": _CAP_CODE,
    "exec_command": _CAP_CODE,
    "container.exec": _CAP_CODE,
    # filesystem read
    "read": _CAP_FS_READ,
    "read_file": _CAP_FS_READ,
    "view": _CAP_FS_READ,
    "view_image": _CAP_FS_READ,
    # filesystem write
    "edit": _CAP_FS_WRITE,
    "write": _CAP_FS_WRITE,
    "write_file": _CAP_FS_WRITE,
    "multiedit": _CAP_FS_WRITE,
    "notebookedit": _CAP_FS_WRITE,
    "apply_patch": _CAP_FS_WRITE,
    # search
    "glob": _CAP_SEARCH,
    "grep": _CAP_SEARCH,
    "search": _CAP_SEARCH,
    "codebase_search": _CAP_SEARCH,
    "list_dir": _CAP_SEARCH,
    "ls": _CAP_SEARCH,
    # web
    "websearch": _CAP_WEB_SEARCH,
    "web_search": _CAP_WEB_SEARCH,
    "webfetch": _CAP_WEB_FETCH,
    "web_fetch": _CAP_WEB_FETCH,
    "fetch": _CAP_WEB_FETCH,
    # delegation
    "task": _CAP_DELEGATION,
    "agent": _CAP_DELEGATION,
    # planning
    "todowrite": _CAP_PLANNING,
    "update_plan": _CAP_PLANNING,
    "enterplanmode": _CAP_PLANNING,
    "exitplanmode": _CAP_PLANNING,
}


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
                    if isinstance(content, list):
                        for b in content:
                            if not isinstance(b, dict):
                                continue
                            bt = b.get("type")
                            if bt == "tool_result":
                                _note_claude_tool_result(v, b)
                            elif bt == "image":
                                v.modalities.add("image")
                            elif bt == "document":
                                v.modalities.add("document")
                    if text.strip():
                        v.user_turns += 1
                        v.user_chars.append(len(text))
                        v.user_texts.append(text)
                        _note_text_modality(v, text)
                else:
                    v.assistant_turns += 1
                    if isinstance(content, list):
                        for b in content:
                            if not isinstance(b, dict):
                                continue
                            bt = b.get("type")
                            # Counted exactly as the old sum() counted it;
                            # the annotation work rides the same iteration.
                            if bt == "tool_use":
                                v.tool_uses += 1
                                _note_claude_tool_call(v, b)
                            elif bt == "image":
                                v.modalities.add("image")
                            elif bt == "document":
                                v.modalities.add("document")
                    if text.strip():
                        if not v.first_assistant_msg:
                            v.first_assistant_msg = text
                        _note_text_modality(v, text)
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
                    for c in pl.get("content") or []:
                        if isinstance(c, dict) and "image" in str(c.get("type") or ""):
                            v.modalities.add("image")
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
                            _note_text_modality(v, text)
                    else:
                        v.assistant_turns += 1
                        if pl.get("stop_reason"):
                            v.last_stop_reason = pl["stop_reason"]
                        if text.strip():
                            if not v.first_assistant_msg:
                                v.first_assistant_msg = text
                            _note_text_modality(v, text)
                elif pt in ("function_call", "local_shell_call", "custom_tool_call"):
                    v.tool_uses += 1
                    _note_codex_tool_call(v, pl)
                elif isinstance(pt, str) and pt.endswith("_output"):
                    _note_codex_tool_output(v, pl)
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

    The stage only runs when the merged policy supplies `sig_ratio_min` (see
    `Stage.enabled`), so the key is read directly: a threshold is policy and
    lives in the data layers, and this stage does not invent one.
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

    No empty-list branch lives here on purpose: an empty word list is not a
    threshold of zero, and a pass-all branch would silently wave every session
    through if the merge layer ever failed to canonicalize. The merge layer
    DROPS empty lists (see `_canonicalize_lists`), so by the time a stage runs
    a supplied list is non-empty and an absent one means the stage is OFF —
    loud, visible, and impossible to confuse with a pass.
    """
    ex = p.get("exclude_keywords") or []
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
    """One stage: its label, its predicate, and the policy key it needs.

    `requires` names the policy parameter without which the stage has no
    threshold to apply, so it cannot run. Stages are the mechanism; which of
    them a run turns on, and at what threshold, is policy and lives in the
    policy/theme/override layers (DESIGN.md: "a new threshold is a data-file
    edit and touches no code"). A stage with `requires = None` always runs.

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
        # floor of zero, not an unset flag. Absence is produced uniformly by
        # the merge chain — `null` in an override clears a key, and empty word
        # lists are dropped there too (see `_canonicalize_lists`). The choice
        # was canonicalize-at-merge rather than teach every stage to also test
        # for emptiness: this predicate stays the single OFF rule, and the OFF
        # row's printed reason ("this pack sets no X") stays truthful.
        return self.requires is None or p.get(self.requires) is not None


STAGES: list[Stage] = [
    Stage("L1 turns", stage_turns),
    Stage("L2 tool_ratio", stage_tool_ratio),
    # Needs the threshold, so it is off until the merged policy supplies one
    # (the global policy sets one; --no-signature or a `null` override clears
    # it).
    Stage("L3 signature", stage_signature, requires="sig_ratio_min"),
    Stage("L4 end_turn", stage_end_turn),
    Stage("L5 length", stage_length),
    # Off until a word list is supplied: with no list the stage never ran, and
    # a pass-all reading of that state is the confusion the OFF row prevents.
    Stage("L6 topic", stage_topic, requires="topic_keywords"),
    # Off until the direction/policy layers supply the exclusion word list: an
    # empty exclusion set would otherwise read as "no coding signal found" on
    # every session.
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


def _sha256_file(path: Path) -> str:
    """Hash a session file's raw bytes (the exact-duplicate key's body)."""
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _theme_hits(v: SessionView, keywords: list[str] | None) -> list[str]:
    """Theme keywords hit over the same prose surface the L6 stage reads."""
    if not keywords:
        return []
    hay = norm(" ".join(t[:500] for t in v.user_texts[:3]))
    return [kw for kw in keywords if norm(kw) in hay]


def run_collect(args: argparse.Namespace, header: list[str], rows: list[dict]) -> int:
    """The collection posture (DESIGN.md § Collection and labeling).

    Recall first, zero model tokens, no thresholds: the only drops are the two
    unambiguous junk classes — structurally dead rows (both parsers refuse the
    file) and exact duplicates (same agent + sha256 of the file's bytes). The
    global policy is never read: `policy.json` is a delivery-posture standard,
    and a collection run applies no quality gate at all. Everything else lands
    in the pool with every annotation column, and once more as a row card.
    """
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    theme_keywords: list[str] | None = None
    if args.theme:
        theme_path = (
            Path(__file__).resolve().parent.parent / "themes" / f"{args.theme}.json"
        )
        if not theme_path.is_file():
            available = ", ".join(
                sorted(q.stem for q in theme_path.parent.glob("*.json"))
            )
            sys.exit(
                f"no such theme: {args.theme} (looked for {theme_path})\n"
                f"  available themes: {available or '(none)'}"
            )
        theme_keywords = load_theme(theme_path).get("topic_keywords") or []

    pool: list[tuple[dict, SessionView]] = []
    dropped: list[dict] = []
    seen: dict[tuple[str, str], str] = {}  # (agent, sha256) -> kept session_file
    for row in rows:
        agent = row.get("agent", "")
        raw = row["session_file"]
        path = session_path(raw)
        v = parse_session(path, agent)
        if v is None:
            dropped.append(
                {"agent": agent, "session_file": raw, "reason": "unparseable", "detail": ""}
            )
            continue
        digest = _sha256_file(path)
        prior = seen.get((agent, digest))
        if prior is not None:
            dropped.append(
                {
                    "agent": agent,
                    "session_file": raw,
                    "reason": "exact_duplicate",
                    "detail": prior,
                }
            )
            continue
        seen[(agent, digest)] = raw
        pool.append((row, v))

    columns = ENRICH_COLUMNS + ANNOTATION_COLUMNS
    pool_path = outdir / "pool.tsv"
    with pool_path.open("w", encoding="utf-8") as fh:
        fh.write("\t".join(header + columns) + "\n")
        for row, v in pool:
            fh.write(
                "\t".join(row.get(h, "") for h in header)
                + "\t"
                + "\t".join(_enrich_values(v))
                + "\n"
            )

    cap = max(0, int(args.max_first_prompt_chars))
    cards_path = outdir / "row-cards.jsonl"
    with cards_path.open("w", encoding="utf-8") as fh:
        for row, v in pool:
            card = {
                "source": row.get("session_file", ""),
                "agent": row.get("agent", ""),
                "first_prompt": v.first_user_msg[:cap],
                "user_turns": v.user_turns,
                "assistant_turns": v.assistant_turns,
                "tool_uses": v.tool_uses,
                "capabilities": v.capabilities,
                "input_modalities": v.input_modalities,
                "single_shot": v.single_shot,
                "refusal_proxy": v.refusal_proxy,
                "synthetic_wrapper": v.synthetic_wrapper,
                "tool_calls_missing_results": v.tool_calls_missing_results,
                "tool_error_streak_max": v.tool_error_streak_max,
                "verification_commands": v.verification_commands,
                "theme_hits": _theme_hits(v, theme_keywords),
            }
            fh.write(json.dumps(card, ensure_ascii=False) + "\n")

    dropped_path = outdir / "dropped.tsv"
    with dropped_path.open("w", encoding="utf-8") as fh:
        fh.write("agent\tsession_file\treason\tdetail\n")
        for d in dropped:
            fh.write(
                f"{d['agent']}\t{d['session_file']}\t{d['reason']}\t{d['detail']}\n"
            )

    by_reason: dict[str, int] = {}
    for d in dropped:
        by_reason[d["reason"]] = by_reason.get(d["reason"], 0) + 1
    detail = ", ".join(f"{k} {n}" for k, n in sorted(by_reason.items())) or "none"
    print(
        f"collected {len(pool)} / {len(rows)} rows -> {pool_path}\n"
        f"row cards: {len(pool)} -> {cards_path}\n"
        f"dropped {len(dropped)} ({detail}) -> {dropped_path}\n"
        "collection applies no thresholds and reads no policy.json: the only "
        "drops are unparseable rows and exact duplicates"
    )
    return 0


# ---------------------------------------------------------------------------
# enrich + run
# ---------------------------------------------------------------------------


def read_candidates(path: Path) -> tuple[list[str], list[dict]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError as e:
        # Fail loud with the cause, not a bare traceback. The historical source
        # of these bytes is curate-sessions.sh truncating the first_prompt
        # preview with `cut -c`, which is byte-based and splits CJK characters
        # at the byte boundary. Old candidates.tsv files are regenerable — the
        # fix is to re-run the scan with the current scripts, so say that.
        sys.exit(
            f"candidates file is not valid UTF-8 ({e}). It was almost certainly "
            "written by an old curate-sessions.sh that byte-truncated the "
            "first_prompt preview; re-run the scan with the current scripts to "
            "regenerate it."
        )
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


ENRICH_COLUMNS: list[str] = [
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

# SPEC item 27: annotation-grade columns, appended after the enrich columns.
# Every value is mechanically derivable from the parse; none is a threshold
# and none of them kills a row anywhere in the engine.
ANNOTATION_COLUMNS: list[str] = [
    "tool_calls_missing_results",
    "tool_results_orphan",
    "tool_repeat_max",
    "tool_error_streak_max",
    "verification_commands",
    "refusal_proxy",
    "synthetic_wrapper",
    "single_shot",
    "input_modalities",
    "capabilities",
    "tools_unmapped",
    "replay_blockers",
]


def _enrich_values(v: SessionView | None) -> tuple[str, ...]:
    """Stringify one view into the enrich + annotation column order."""
    if v is None:
        return ("",) * (len(ENRICH_COLUMNS) + len(ANNOTATION_COLUMNS))
    return (
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
        str(v.tool_calls_missing_results),
        str(v.tool_results_orphan),
        str(v.tool_repeat_max),
        str(v.tool_error_streak_max),
        str(v.verification_commands),
        str(v.refusal_proxy),
        str(v.synthetic_wrapper),
        str(v.single_shot),
        v.input_modalities,
        v.capabilities,
        str(v.tools_unmapped),
        v.replay_blockers,
    )


def fmt_int(n: int) -> str:
    return f"{n:,}"


# Policy-file key -> the stage parameter it feeds. The policy layers state
# buy-side names; the stages have their own. Mapping them here in one table is
# what lets a data file be the single source of a threshold without the stages
# renaming anything.
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


VALID_OVERRIDE_KEYS: frozenset[str] = (
    frozenset(POLICY_KEYS) | POLICY_UNENFORCED | {"exclude_keywords"}
)

# Keys a `null` may clear: exactly those whose stage HAS an off state (L3, L9,
# L6, L7). The always-on stages (L1/L2/L4/L5) have no OFF row to print, so a
# cleared key there would be a KeyError at best and a silently unjudged stage
# at worst — refused here, loudly, instead.
CLEARABLE_KEYS: frozenset[str] = frozenset(
    {"sig_ratio_min", "dedup_threshold", "topic_keywords", "exclude_keywords"}
)

def _load_json_object(path: Path, what: str) -> dict:
    """Read `path` as a JSON object or die naming the file and the layer."""
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except OSError as e:
        sys.exit(f"cannot read {what} {path}: {e}")
    except json.JSONDecodeError as e:
        sys.exit(f"{what} {path} is not valid JSON: {e}")
    if not isinstance(doc, dict):
        sys.exit(f"{what} {path} must contain a JSON object")
    return doc


def _mapped_params(path: Path, pol: dict) -> dict:
    """Translate one `policy` object into stage parameters.

    Three classes of key, three behaviours:
      * mapped (POLICY_KEYS) -> becomes a stage threshold;
      * known-unenforced (POLICY_UNENFORCED) -> reported on stderr, not applied;
      * anything else -> hard error. A mistyped threshold silently ignored would
        run the funnel at a value nobody chose, which is the failure the whole
        single-source-of-truth layering exists to prevent.
    """
    unknown = sorted(set(pol) - VALID_OVERRIDE_KEYS)
    if unknown:
        sys.exit(
            f"policy file {path} carries keys no stage maps: {', '.join(unknown)} "
            "— fix the file or teach the funnel; a restated or mistyped "
            "threshold must never pass silently"
        )

    out: dict = {}
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
    return out


def _override_layer(path: Path, layer: dict) -> dict:
    """Translate one override delta (theme.override or --override-file) into
    stage parameters.

    Same three key classes as `_mapped_params`, plus `exclude_keywords`: the
    exclusion word list is policy too (it is what turns L7 on), it just is a
    list rather than a threshold. A value of `null` CLEARS the key — the stage
    prints OFF — which is how a run turns a layer's setting off without
    restating every other value. A list replaces wholesale, never appends.
    Clearing is only meaningful where an OFF state exists; see CLEARABLE_KEYS.
    """
    unknown = sorted(set(layer) - VALID_OVERRIDE_KEYS)
    if unknown:
        sys.exit(
            f"{path} carries override keys no stage maps: {', '.join(unknown)} "
            "— legal keys are "
            f"{', '.join(sorted(VALID_OVERRIDE_KEYS))}; a restated or mistyped "
            "threshold must never pass silently"
        )
    out: dict = {}
    for k, v in layer.items():
        if v is None:
            dest = "topic_keywords" if k == "topic_keywords" else (
                "exclude_keywords" if k == "exclude_keywords" else POLICY_KEYS.get(k)
            )
            if dest not in CLEARABLE_KEYS:
                sys.exit(
                    f"{path}: `null` cannot clear {k}: that stage has no off "
                    "state, so a cleared key could not be judged or reported — "
                    "set an explicit value instead"
                )
            out[dest] = None
            continue
        if k == "exclude_keywords":
            out[k] = v
        elif k in POLICY_KEYS:
            out[POLICY_KEYS[k]] = v
        else:  # known-unenforced: reported, never applied — same as the baseline
            print(
                f"note: {path} sets {k}, which no funnel stage consumes — "
                "NOT enforced by this engine state",
                file=sys.stderr,
            )
    return out


def _canonicalize_lists(p: dict) -> dict:
    """Drop empty word lists so "supplied but empty" reads as "not supplied".

    An empty topic/exclusion list is not a threshold of zero: with it present,
    L6/L7 would either pass everything (a stage that never ran, reading as one
    that did) or fail everything (matching nothing is not a judgement). Both
    print differently from OFF, and OFF is the only honest rendering of "no
    words to match". Dropped here — ONCE, after the whole merge chain — so
    `Stage.enabled` stays the single `is not None` rule and every layer (theme
    override, override file, flags) gets the same empty-means-clear semantics
    for free. `--exclude-keywords ""` and `{"exclude_keywords": []}` are
    therefore both an explicit "turn this layer off".
    """
    for key in ("topic_keywords", "exclude_keywords"):
        if key in p and not p[key]:
            del p[key]
    return p


def load_global_policy() -> tuple[dict, str]:
    """Layer 1: the global standard, resolved next to THIS FILE.

    Engine-relative on purpose: the policy travels with the script it governs,
    so a copy installed anywhere carries its own standard and no CWD or
    environment variable can silently substitute another. A missing file is a
    broken installation and a hard error — guessing defaults here would run a
    standard nobody chose.
    """
    path = Path(__file__).resolve().parent / "policy.json"
    if not path.is_file():
        sys.exit(
            f"the global policy file is missing: {path}\n"
            "  the funnel resolves it next to this script; reinstall the skill\n"
            "  or restore the file — there is no built-in fallback"
        )
    doc = _load_json_object(path, "policy file")
    pol = doc.get("policy")
    if not isinstance(pol, dict):
        sys.exit(f"policy file {path} has no `policy` object")
    return _mapped_params(path, pol), str(doc.get("name", path.stem))


def load_theme(path: Path) -> dict:
    """Layer 2: one theme's contribution — its word list plus its override.

    `keywords` is what the theme IS (the topic stage's positive list), so it
    stays a top-level theme key; `override` is how far the theme deviates from
    the global policy. Legacy theme shapes are rejected loudly rather than
    half-read: a `policy` block or a top-level `exclude_keywords` means a
    pre-decoupling file, and silently ignoring either would run the theme
    without the words or thresholds its author wrote.
    """
    doc = _load_json_object(path, "theme file")
    if "policy" in doc:
        sys.exit(
            f"theme file {path} carries a `policy` block: thresholds moved to\n"
            "  scripts/policy.json and per-theme `override` deltas (SPEC item 25).\n"
            "  This file predates the split; re-shipping it is the only fix."
        )
    if "exclude_keywords" in doc:
        sys.exit(
            f"theme file {path} carries top-level `exclude_keywords`: the coding\n"
            "  exclusion list moved to the direction layer (SPEC item 25), which\n"
            "  passes it to every run via --override-file. This file predates the\n"
            "  split; re-shipping it is the only fix."
        )
    out: dict = {}
    kws = doc.get("keywords")
    if isinstance(kws, list):
        out["topic_keywords"] = [str(k) for k in kws]
    override = doc.get("override", {})
    if not isinstance(override, dict):
        sys.exit(f"theme file {path} has a non-object `override`")
    out.update(_override_layer(path, override))
    return out


def load_override_file(path: Path) -> dict:
    """Layer 3: one run's explicit delta, as a flat JSON object of policy keys.

    The direction driver composes the direction's root override with the theme
    entry's own into this one file (entry wins), so the funnel sees a single
    object and stays ignorant of direction structure.
    """
    doc = _load_json_object(path, "override file")
    return _override_layer(path, doc)

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
    # One line, three provenance fields: which standard ran, under which
    # theme, and the headline count. A reader copying the table into an issue
    # must not have to guess where the numbers came from.
    print(
        f"policy: {p.get('_policy', 'standard')}   "
        f"theme: {p.get('_theme', 'none')}   surviving {len(alive)} / {total_in}"
    )
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
            # ty's stubs type the mixed stdout/stderr union as `object`; the
            # method exists at runtime on TextIOWrapper (guarded above).
            stream.reconfigure(encoding="utf-8", errors="replace")  # ty: ignore[call-non-callable]
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
    pr.add_argument(
        "--theme",
        help="name of a shipped theme in themes/<name>.json: its word list "
        "becomes the topic stage's positive list and its `override` deltas "
        "the run's thresholds. The global policy is always the base layer",
    )
    pr.add_argument(
        "--override-file",
        help="a flat JSON object of policy keys applied over the theme (if "
        "any): the direction driver composes the direction's root override "
        "and the theme entry's own into this one file. `null` clears a key "
        "(the stage prints OFF); lists replace, never append",
    )
    pr.add_argument("--min-turns", type=int)
    pr.add_argument("--max-tool-ratio", type=float)
    pr.add_argument("--no-end-turn", action="store_true")
    pr.add_argument("--min-user-msg-chars", type=int)
    pr.add_argument("--max-first-msg-chars", type=int)
    pr.add_argument(
        "--topic-keywords",
        help="comma-separated topic word list, replacing whatever the theme "
        "supplied; an empty value clears the list and L6 prints OFF",
    )
    pr.add_argument(
        "--exclude-keywords",
        help="comma-separated coding-signal exclusion list for L7, replacing "
        "whatever the layers below supplied; an empty value clears the list "
        "and L7 prints OFF",
    )
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
        help="thinking-signature ratio floor (PACK-SPEC § 4), restated for "
        "one run over whatever the policy layers set. Sessions with no "
        "thinking block are skipped, not failed — codex has no signature "
        "field",
    )
    pr.add_argument(
        "--no-signature",
        action="store_true",
        help="turn the signature layer off: the policy's floor is cleared, "
        "so L3 prints OFF and kills nothing. This is NOT --sig-ratio-min 0, "
        "which would fail every unsigned thinking block",
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
        "--credential-hard-gate",
        action="store_true",
        help="exit 3 when any SURVIVING session carries a credential shape, "
        "before anything is written. The whole batch is refused rather than "
        "quietly filtered: exporting the remainder would hide that the "
        "partner's own keys are in their history. Determinism and disclosure, "
        "not security — an agent that rewrites its own artifacts is not "
        "stopped by this",
    )

    pc = sub.add_parser(
        "collect",
        help="collection posture: keep everything alive, annotate, emit "
        "pool.tsv + row-cards.jsonl (no thresholds, policy.json not read)",
    )
    pc.add_argument("candidates")
    pc.add_argument("outdir", help="directory for pool.tsv, row-cards.jsonl, dropped.tsv")
    pc.add_argument(
        "--theme",
        help="name of a shipped theme: its keyword list becomes the row "
        "cards' theme_hits (hits over the first 3 user messages). No "
        "threshold from the theme is applied — collection has none",
    )
    pc.add_argument(
        "--max-first-prompt-chars",
        type=int,
        default=2000,
        help="row-card first_prompt truncation length (default 2000)",
    )

    args = ap.parse_args()
    header, rows = read_candidates(Path(args.candidates))

    if args.cmd == "enrich":
        # The signature columns are the buy-side `present/empty/absent` state plus
        # the ratio the gate compares against, so a partner can see the
        # distribution before committing to an export (PACK-SPEC § 4, § 6).
        # `injected_user_messages` sits next to `user_turns` for the same
        # reason: the turn floor is read off this TSV, and a raw-block count
        # that was excluded has to be visible or the correction is invisible.
        # The annotation columns (SPEC item 27) ride the same output shape;
        # `collect` writes exactly these too.
        extra = ENRICH_COLUMNS + ANNOTATION_COLUMNS
        out = []
        for row in rows:
            v = parse_session(session_path(row["session_file"]), row.get("agent", ""))
            vals = _enrich_values(v)
            out.append({**row, **dict(zip(extra, vals))})
        full_header = header + extra
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write("\t".join(full_header) + "\n")
            fh.writelines("\t".join(r[h] for h in full_header) + "\n" for r in out)
        print(f"enriched {len(rows)} rows -> {args.out}")
        return 0

    if args.cmd == "collect":
        return run_collect(args, header, rows)

    # run
    # Four layers, merged per key, later wins: global policy -> theme override
    # -> override file -> flags. Each layer only restates what it owns, so no
    # number has two sources; a layer may also CLEAR a key (`null`, an empty
    # word list, or a --no-* flag), which is the OFF state every stage reads.
    # Provenance tags ride along so the table's header can name what ran.
    p, policy_name = load_global_policy()
    p["_policy"] = policy_name
    if args.theme:
        theme_path = Path(__file__).resolve().parent.parent / "themes" / f"{args.theme}.json"
        if not theme_path.is_file():
            themes_dir = theme_path.parent
            available = ", ".join(sorted(q.stem for q in themes_dir.glob("*.json")))
            sys.exit(
                f"no such theme: {args.theme} (looked for {theme_path})\n"
                f"  available themes: {available or '(none)'}"
            )
        p.update(load_theme(theme_path))
        p["_theme"] = args.theme
    if args.override_file:
        p.update(load_override_file(Path(args.override_file)))
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
    if args.exclude_keywords is not None:
        # Same comma semantics as --topic-keywords: an empty value is an empty
        # list, which _canonicalize_lists turns into the OFF state below.
        p["exclude_keywords"] = [k for k in args.exclude_keywords.split(",") if k]
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
    if args.no_signature:
        # Same shape as --no-dedup: clears the key rather than stating a zero
        # floor, because 0.0 would fail every unsigned thinking block — the
        # opposite of what this flag promises.
        p["sig_ratio_min"] = None
    if args.sig_ratio_min is not None:
        p["sig_ratio_min"] = args.sig_ratio_min
    p = _canonicalize_lists(p)

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
