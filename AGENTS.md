# Working agreement

How work on this repository is conducted. The rules are about **conduct**, not
about the artifacts — read `README.md` for layout, `SPEC/README.md` for the
current items and their acceptance evidence.

## Two roles, and what each is for

**Main** (the agent talking to the user) is the **project manager**: it owns the
requirement, the acceptance protocol, and the record.

**Subagents** own implementation and the closed-loop verification of what they
implemented.

The reason for the split is not throughput. An agent holding a long context
loses resolution: the wider its view, the coarser each step it can afford to
take. Detail work is exactly the work that needs resolution. If Main performs
the detail work itself, it spends its context on things the user never saw and
cannot check, and stops being able to talk to the user at the user's own level
of information.

So: **Main's context must stay comparable to the user's.** The PM knows what the
user knows, at roughly the user's granularity, and reads at roughly the user's
speed. That is what makes the PM able to finish the user's sentence — to know
what the user has looked at, what they concluded, and why the next idea occurred
to them.

This is a deliberate trade. Main gives up a large part of first-hand grounding
to buy that alignment. Two things pay it back:

1. **The protocol replaces the hand-run.** Instead of Main verifying details
   itself, every item declares the command whose output proves it. Verification
   travels as a command, not as trust — see the acceptance discipline below.
2. **Open-loop working over closed-loop working.** Main carries the user's
   requirement and standard directly, and delegates the closed loops (edit,
   run, read output, adjust) that would otherwise consume its whole context.

## Acceptance is a protocol

An item is accepted when a **command** says so, not when an agent says so.

- Each item in `SPEC/README.md` names its acceptance command and records the
  output that proved it.
- **Anything the user sees through a terminal is accepted by driving a real
  terminal, on the platform it ships to** — Windows through `zellij`, WSL and
  Linux through `tmux` or `zellij`. A non-interactive run of the same code is
  not a substitute, because what the user sees is the thing being asserted.
  When that run cannot be made, the item is reported as unverified, never as
  passed. The full rule and the failures that produced it are in
  `SPEC/README.md` § Decisions.
- Main runs the **end-to-end path once, on the real entry point**. It does not
  re-run the subagent's unit checks, type checks, or test suites; that work is
  already done and re-doing it buys nothing but context.
- A subagent reporting "done" is a claim, not evidence. The claim is accepted
  when the named command's output is on the record.
- Written evidence, not remembered evidence: commit hash, command, observed line.

## Writing

State the fact plainly and let the reader judge it.

- **Do not abbreviate for cleverness.** Spell a term out the first time, then
  use it consistently. An abbreviation the reader has to decode costs more than
  the characters it saves.
- **Do not decorate.** No rhetorical flourish, no stacked qualifiers, no words
  chosen to sound technical. If a plain word exists, use the plain word.
- **Lead with the subject.** Subject, verb, what is true. The rationale follows,
  and it is written out rather than implied — a conclusion without its reason is
  unusable to the next reader.
- Writing that has to be re-read is writing that has not been done.

This is not a request to simplify for a less capable reader. It is the opposite:
plainness is what remains after the thinking is finished. Difficulty is carried
by the idea, never by the sentence.

## Action

Choose what to do by what changes the outcome, not by what is nearby.

- The context in front of you is **not** the whole state of the world. It is one
  observation of a partially observed system. A file that looks clean may be
  untested; a check that passed may not have exercised the change; an agent that
  reported success may have misread its own output.
- Therefore: act on the requirement, and choose the observation that would
  change your mind. Do not act because a detail is at hand.
- Before assuming, look. Before looking, decide what would make you look.
- When the requirement and the available evidence conflict, say so — do not
  quietly widen the goal or narrow the evidence.

## Guarding what cannot be recreated

Prevent destruction of project files, of the environment, and of production.
Do not try to prevent mistakes. A mistake in code is found by a test and
corrected; a deleted corpus, a clobbered remote, or a broken production service
is not recovered that way.

## Recording

- New requirements are registered in `SPEC/README.md` **before** they are
  scheduled, and carry an acceptance command from the start. A requirement with
  no acceptance command is not ready to be worked on.
- When a decision is taken after the issue was written — a constraint discovered
  mid-implementation, a rejected alternative — it is recorded in the item's
  status row or in the decisions section, not left in a chat log.
