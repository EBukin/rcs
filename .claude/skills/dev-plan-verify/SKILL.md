---
name: dev-plan-verify
description: Verify an implementation plan and make it ready for execution. Uses subagents to check the plan against the code base, dry-run each step, and surface every decision left to the implementer; gives a short ranked report; settles the open decisions with the user in a question session; then updates the plan and has a fresh agent confirm it is ready. Use whenever the user asks to verify, review, check, audit, stress-test or find holes in a plan, asks "is this plan ready?" or "can a fresh agent execute this?", or wants a second opinion on a plan before handing it off, even if they do not say "verify". Not for writing a plan from scratch or for reviewing code that already exists.
---

# Verify a development plan

## Objective

End with a plan that is ready for implementation: correct against the
code base, with every decision made, and structured so it can be
executed efficiently. You find what stands in the way, report it
briefly, settle the open decisions with the user, update the plan and
have it checked once more.

## What a ready plan looks like

Check the plan against both tests. A plan can be right in content and
still fail in execution because of how it is laid out.

Content:

- What it says about the code base is true.
- Its references exist and are current.
- No step leaves a choice to the implementer.
- Executed in full, it delivers its stated goal.

Structure. The plan will be executed by an orchestrator with a 200k
token budget that manages many subagents; the subagents write code,
run it, interpret the results and verify each other's work, each
within 150k tokens. So the plan must make that possible:

- Steps are sized as tasks one modest subagent can finish within its
  budget. A step that needs the whole code base in one head is too
  big; split it.
- Each step is self-contained enough to hand over: what to do, which
  files to read and change, what it depends on, and how to know it
  is done.
- The orchestrator can run the plan from the plan alone, without
  reading the code itself: it dispatches, reads short reports and
  decides.
- Dependencies and order are explicit: which steps can run in
  parallel, which must wait, which write the same file and so must
  not overlap.
- Each step has a concrete check, and the plan says who verifies it:
  an agent other than the one that wrote the code.
- Tests are used where they fit, and test-first (TDD) where the
  behaviour can be specified before the code: the failing test is
  written first, then the code that makes it pass. Where a test does
  not fit, the plan names another check.
- The plan has a status that tracks execution, so an interrupted run
  can be picked up.
- It follows the project's own plan template and rules, if any.

## How the work is divided

You orchestrate and judge; run on the most capable model available
(Fable). Subagents do the checking; spawn them on Opus. A single
reader of a plan tends to follow its logic and agree with it;
independent readers who each go to the code find where the plan and
the code differ. So do not analyse the plan alone and do not run code
yourself.

If you cannot spawn subagents, say so at the top of the report and do
the checks yourself, in the same order.

## Ground rules

- Start only with a named plan. If none is given, ask which one.
- Report in chat. Edit the plan only in stage 6, after the user has
  answered the open decisions. Write any other file only when asked.
- Never implement the plan. Subagents may write small probe snippets
  to learn how the code really behaves, in a temporary directory
  outside the project tree, so the project stays as the plan expects
  to find it.
- A subagent that runs code uses its own session, never the user's,
  and closes it when done. Follow the project's own rules for running
  code and for parallel sessions (see its CLAUDE.md).
- Subagents change nothing in the project: no edits, no commits, no
  writes to project outputs.

## Budgets

Verification should cost far less than the execution it protects.

- Orchestrator: under 200k tokens for the whole verification, the
  question session and the plan update included.
- Each subagent: under 150k tokens.

What keeps you under:

- Read the plan and the documents it references; leave the code to
  subagents. You need their conclusions, not the files.
- Ask each subagent for a short report: findings only, a few lines
  each, no file dumps, no account of how it searched.
- Give each subagent a narrow task that fits its budget. Split a
  component that is too large for one agent.
- Tell each subagent its budget, to search and read excerpts before
  whole files, and to stop and report what it has, naming what it did
  not cover, when it nears the limit.

## Using subagents wisely

Work in rounds of up to 6 subagents in parallel. Use as many as the
round has distinct, useful tasks, not as many as allowed. After each
round, read the results and decide what the next one should check;
early findings often make later checks unnecessary or point to
better ones. Typical order:

1. Claims, references and structure: does what the plan names exist
   and behave as it says, and does the plan meet the structure test?
2. Dry run and open decisions, on the components that survived
   round 1.
3. Runtime probes and confirmation of blockers, only where needed.

Stop when further rounds would only add minor points. A small plan
may need one round.

## What is worth reporting

Subagents return many true but unimportant observations. The user's
attention is the scarce resource, so report a finding only if at
least one holds:

1. Blocks execution: a step cannot be carried out as written.
2. Wrong result: the step gives wrong behaviour, loses data or
   breaks an existing feature.
3. Hidden decision: the implementer must choose something the plan
   has not chosen.
4. Misses the goal: the executed plan does not deliver its stated
   goal, or breaks a project rule.
5. Cannot be executed efficiently: the plan fails the structure test
   in a way that would stall the orchestrator or overrun a budget.

Drop wording, naming taste, equally good alternative designs and
optional extras. Say how many points you dropped, in one line.

## Stages

### 1. Understand

Read the plan, the documents it references and the project
instructions. Tell the user in a few bullets: the goal, the start
state, the end state, and whether the goal is clear and makes sense.
Then continue without waiting; the user can interrupt if you misread
it.

### 2. Split and delegate

Break the plan into components, usually one per step or per group of
steps that touch the same code, and check them in rounds as described
above.

Brief each subagent with the plan path, its component, the files to
start from, the ground rules and its budget. Ask what it finds; do
not hand it your suspicions, because an agent given a hypothesis
tends to confirm it.

Across the rounds, cover:

- Claims: every function, signature, file, field, test and version
  the plan names.
- References: any note, earlier plan, data source or doc that is
  missing, stale or contradicted.
- Structure: the structure test above, step by step.
- Dry run: walk each step as the implementing subagent would. Where
  would it get stuck, guess, overrun its budget or break something
  else? Is the order right?
- Open decisions: every choice left to the implementer: names,
  defaults, error behaviour, edge cases, migration of existing data,
  test design.
- Verification: can each step, and the whole plan, be proven done by
  a concrete test or check?

A subagent's finding must let you judge it without opening the code:
what the plan says, what is true, where the evidence is (file and
line, or probe and output), what it does to execution, and a proposed
fix.

### 3. Judge

- Merge duplicates.
- Confirm the evidence behind every blocker before you report it. A
  false blocker costs the user more than a missed minor point.
- Apply the reporting test.
- For every open decision, form a recommendation and a reason.

### 4. Report

Keep it short; the user will ask about what they want to understand
better. Lead with the verdict (ready, ready after fixes, or needs
rework), then blockers, then decisions to make, then risks, then the
count of dropped points.

Each finding gets one or two lines: what is wrong and what to do.
Hold the evidence and the detail back until asked. Aim for about 10
findings; go over only when there are more real blockers than that.

There is no fixed template. Shape the report to the plan and to how
this user reads: a table when findings compare well, bullets when
they do not, plain sentences for a single serious problem. Notice
what the user asks about and what they skip, and adjust as you go.

### 5. Settle the decisions

After the report, move straight into a question session; do not wait
to be asked. Its purpose is to close every open decision so the plan
can be fixed in one pass.

- One decision per question, most consequential first.
- Each question stands on its own: say in a sentence what is being
  decided and why it matters, without assuming the user remembers the
  finding.
- Offer 2 to 4 concrete answers, your recommended one first and
  marked, each with its consequence in a few words. The user can
  always give their own answer instead.
- Use the question tool when the session has one; otherwise ask in
  chat.
- Skip a question when an earlier answer already settles it.
- Answer the user's own questions as they come, briefly, then return
  to the list.

### 6. Update the plan

When the decisions are settled, edit the plan yourself: apply the
fixes, write in every decision the user made, and restructure steps
that failed the structure test. Keep the plan's goal, numbering and
template; change only what the findings and answers require. State
each decision in the step it affects, as a fact, so the implementer
does not have to trace where it came from.

### 7. Confirm

Spawn one fresh subagent with the updated plan and the "ready plan"
tests above, and nothing else: not your findings, not the user's
answers. It reads the plan as its future orchestrator would and
reports whether every step is clear enough to dispatch, and lists
any decision still left open.

- If it finds nothing material, tell the user the plan is ready, in
  a few lines: what changed and what was decided.
- If it finds something you can fix from what is already decided,
  fix it and say so.
- If it finds a new decision, ask the user that one question, update
  the plan, and stop there; do not start another full round.
