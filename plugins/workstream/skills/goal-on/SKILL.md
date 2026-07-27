---
name: goal-on
description: >-
  Use when a request is vague, broad, or unstructured and should be turned into a
  scoped objective and then carried to completion without further check-ins —
  "figure out X and do it", "sort out this mess", "look into Y and fix whatever's
  wrong", or any ad-hoc task that does not start from a Jira ticket. Rewrites the
  prompt into a Task/Scope/Constraints/Outcome/Stop-Rules brief, then drives it to
  a verified finish. Use work-on instead when a Jira ticket exists.
hooks:
  Stop:
    - hooks:
        - type: agent
          timeout: 180
          statusMessage: "verifying goal"
          prompt: |
            You are the goal-on verifier. $ARGUMENTS holds the Stop hook input JSON.

            1. Read `session_id` from $ARGUMENTS.
            2. Read ~/.claude/workstream/goal-on/<session_id>.md.
               Missing or unreadable -> return ok:true. This is not a goal-on session.
            3. Parse the YAML header: status, route, turns_used, turn_budget.
            4. Return ok:true immediately if status is PENDING-APPROVAL, CLEARED,
               DONE, FAILED, or NEEDS-DECISION. PENDING-APPROVAL means Phase 1 has
               presented the brief and is waiting on the user — the turn MUST be
               allowed to end so they can answer. Never block a brief the user has
               not authorized yet.
            5. If turns_used >= turn_budget: rewrite the header to status: FAILED,
               then return ok:true. The stop rule has tripped.
            6. Otherwise verify the `## Outcome` checklist for real. Do NOT trust
               claims made in the conversation. Check evidence only:
               - Every file or artifact named in Outcome exists and is non-empty.
               - If route is code: run `gh pr view --json number,state,isDraft,headRefName`
                 in cwd. It must show an OPEN DRAFT PR whose headRefName matches the
                 header's `branch`, and `## Verification evidence` must record the
                 ship handoff.
               - `## Verification evidence` contains actual command output for every
                 check named in Outcome, and none of it shows a failure.
            7. Every Outcome item satisfied -> rewrite the header to status: DONE,
               then return ok:true.
            8. Otherwise -> increment turns_used by 1 in the header, then return
               ok:false with a reason naming the SPECIFIC unmet Outcome items and
               the single next concrete action.

            Hard rules:
            - IGNORE `stop_hook_active`. It is normally a loop guard. Here
              `turn_budget` is the guard. Releasing because stop_hook_active is true
              would defeat this skill entirely.
            - Absent evidence is UNMET, never met. Do not infer, do not extrapolate.
            - If you cannot finish verification for any reason — tool error,
              unreadable state, running out of time — return ok:true.
              Failing open is mandatory; a broken verifier must never wedge the
              session.
            - Be terse. Your reason becomes the model's next instruction.
---

# Goal On (structure a vague request, then finish it)

## Overview

A vague prompt cannot be verified, so it cannot be finished — there is no
condition that says "done". `goal-on` fixes that in two moves: it interrogates the
prompt into a brief with a checkable Outcome, then holds itself to that Outcome
across turns using a `Stop` hook that refuses to let the turn end until the
evidence exists.

This is the ad-hoc counterpart to `work-on`. Same destination — verified work, or a
draft PR handed to `ship` — but the input is a loose sentence rather than a Jira
ticket, and the run is autonomous rather than gated at every stage.

**Phase 1 is interactive. Phase 2 is not.** The hook registers the moment this
skill is invoked, and a `Stop` hook prevents the turn from ending — so once Phase 2
starts, questions cannot be asked. Every uncertainty must be resolved in Phase 1.

## The brief

Written to `~/.claude/workstream/goal-on/<session-id>.md`. Session-id keyed, so
concurrent sessions never collide, and nothing lands in the user's repo.

```markdown
---
status: PENDING-APPROVAL   # PENDING-APPROVAL | ACTIVE | NEEDS-DECISION | DONE | FAILED | CLEARED
route: code                # artifact | code
turns_used: 0
turn_budget: 8
created: 2026-07-27T14:30:00Z
branch: goal/widget-cache   # code route only
---

## Task
One sentence. The objective, not the symptom.

## Scope
Files, migrations, dependencies, sibling repos.

## Constraints
Operational boundaries — what must not change, what must be preserved.

## Outcome
- [ ] Checkable item, with the command or artifact that proves it.

## Stop Rules
Stop and report if verification fails after 8 turns, or on an unresolvable
dependency conflict.

## Verification evidence
Command output appended here as work proceeds. The verifier reads this.
```

`turn_budget` is 8 because `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` defaults to 8
consecutive blocks — the harness abandons the loop above that, so a larger number
would never fire. Raise the env var first if a bigger budget is genuinely needed.

## Phase 1 — Structure (interactive)

Do all of this before touching any deliverable.

**1. Check the gates.** The hook needs a trusted workspace and unrestricted hooks.
If `disableAllHooks` or `allowManagedHooksOnly` is set, or the workspace is
untrusted, say so plainly now and continue in degraded mode — the brief is still
worth writing, but nothing will enforce persistence. Never arm silently and let the
user believe the goal is being held.

**2. Extract the Task.** One sentence naming the objective, not the symptom. "Users
see stale prices" is a symptom; "make the price cache invalidate on write" is a
task. If the prompt supports several readings, that is a Phase 1 question, not a
guess.

**3. Assess the Scope against the codebase.** Actually look — do not infer from the
prompt. Establish which files are affected, whether migrations are involved, which
package dependencies are touched, and whether sibling repos are implicated. Record
concrete paths, not categories.

**4. Draft Constraints and Outcome.** Outcome items must be *checkable by someone
else*: each one names the artifact or the command that proves it. "Caching works"
is not an Outcome. "`pnpm test src/cache` passes and the recorded output shows 0
failures" is.

**5. Ask everything now, in one batch.** Every genuine uncertainty in Constraints or
Outcome becomes a numbered multiple-choice question via `AskUserQuestion`. One
batch, not a drip. This is the last chance — after Phase 1 the hook will refuse to
let the turn end, so an unasked question becomes a guess that burns the budget.

**6. Set the route.**

- `artifact` — research, slides, documents, Jira or Confluence updates, throwaway
  scripts. Anything not destined to be merged.
- `code` — changes intended to merge into a repo.

Mixed outcomes take the `code` route; the artifact half rides along as Outcome
items.

**7. Write the brief and present it.** Write
`~/.claude/workstream/goal-on/<session-id>.md` with **`status: PENDING-APPROVAL`**,
then show the five sections to the user and end the turn.

`PENDING-APPROVAL` is load-bearing, not decorative. The hook registered the moment
this skill was invoked, so the verifier runs at the end of *this* turn too. An
`ACTIVE` brief with an unmet Outcome is exactly what "keep working" looks like — so
writing `ACTIVE` here makes the verifier block the turn and shove you into Phase 2
before the user has said a word. `PENDING-APPROVAL` is the only status that lets the
gate exist.

**User approval here is the only planned gate in the skill.** Do not proceed to
Phase 2 without it. If the user amends anything, rewrite the brief (still
`PENDING-APPROVAL`) and re-present.

## Phase 2 — Execute (autonomous)

**First act, before anything else: flip the brief header to `status: ACTIVE`.** That
single edit is what arms the verifier. Until it happens the hook releases every turn
and nothing is being enforced. Do it only once the user has actually approved.

The verifier is then watching. Record evidence as you go: append real command output
to `## Verification evidence` in the brief. The verifier reads that section and
treats absent evidence as unmet — unrecorded work does not count as done.

### Route: artifact

Do the work to completion. Verify it — open the file, run the script, confirm the
Jira issue actually changed. Append the evidence. Write `status: DONE`.

### Route: code

1. `git fetch origin`
2. Confirm the working tree is clean. If it is dirty, this should have surfaced in
   Phase 1 — stop, set `status: NEEDS-DECISION`, and ask. Never branch over
   uncommitted work.
3. Branch off the repo's default branch:

```bash
DEFAULT=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
git checkout -b goal/<slug> "origin/$DEFAULT"
```

Work in the current checkout — no worktree. Record the branch name in the brief
header.

4. Implement. Multiple files are expected and fine.
5. Verify with the repo's own checks — discover them from `CLAUDE.md`,
   `package.json` scripts, or the `Makefile`. **Any UI surface also requires driving
   it in a real browser** (Playwright specs for the touched surface, or the `verify`
   skill). Green type-check and unit tests do not prove a UI renders.
6. Append all of that output to `## Verification evidence`.
7. `gh pr create --draft`
8. Invoke the `workstream:ship` skill with the PR number, and record the handoff in
   the evidence section.
9. Write `status: DONE`.

**The goal is met at draft PR raised plus ship handed off.** `ship` owns CI,
findings triage, approval, and the merge checkpoint. `goal-on` does not wait for the
merge, and must not duplicate any of ship's steps.

A `goal/<slug>` branch carries no Jira key by design — `goal-on` is the non-ticket
entry point. `ship` already parses for a key, finds none, skips the Jira transitions,
and notes it. That is correct behavior; do not work around it.

## Terminal states

Self-clearing is the normal path. Write the terminal status yourself; do not wait to
be asked.

| Status | When | Then |
|---|---|---|
| `PENDING-APPROVAL` | Phase 1 wrote the brief; user has not approved | Verifier releases the turn. Not terminal — flip to `ACTIVE` on approval. |
| `ACTIVE` | Phase 2 running | Verifier enforces the Outcome. |
| `DONE` | Outcome verified | Report what was produced. |
| `FAILED` | Budget spent, or an unresolvable dependency conflict | Report what was achieved and the exact remaining gap. Never fail silently. |
| `NEEDS-DECISION` | An unforeseen decision blocks progress | The verifier releases the turn so the user can be asked. Resolve, set `ACTIVE`, continue. |
| `CLEARED` | User abandons the goal | Set it on request — no command syntax needed. |

`/workstream:goal-on clear` is supported as a manual override and can also be
invoked programmatically as a skill. Note the hook itself cannot be deregistered —
after a terminal status it stays registered and short-circuits on the cheap status
read, costing one small verifier call per turn-end for the rest of the session. A
new session starts clean.

A native `/goal` and this skill do not interfere: `/goal clear` skips hooks that
carry a `skillRoot`, which this one does.

## Red flags

- Writing `status: ACTIVE` before the user approves → the verifier blocks the turn
  and drags you into Phase 2 unapproved, silently destroying the only gate in the
  skill. Phase 1 always writes `PENDING-APPROVAL`.
- Asking a question in Phase 2 → the hook blocks turn-end; ask everything in Phase 1.
- An Outcome item nobody else could check ("works correctly", "is clean") → rewrite
  it as a command or an artifact.
- Claiming done without appending evidence → the verifier reads the evidence
  section, not the conversation, and absent evidence is unmet.
- Re-invoking `goal-on` while a goal is active → each invocation registers another
  verifier, doubling the per-turn cost for no benefit. Amend the brief instead.
- Creating a worktree → `goal-on` works in the current checkout by design.
- Branching off the current branch instead of the freshly fetched default branch.
- Waiting for the merge → `goal-on` ends at draft PR plus ship handoff.
- Marking a UI change verified on green tests alone → drive it in a browser.
- Raising `turn_budget` above 8 without also raising
  `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` → the harness quits first and the extra budget
  never fires.
