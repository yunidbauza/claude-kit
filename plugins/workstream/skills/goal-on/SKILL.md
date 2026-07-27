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
            4. Return ok:true immediately if status is CLEARED, DONE, FAILED, or
               NEEDS-DECISION.
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
status: ACTIVE          # ACTIVE | NEEDS-DECISION | DONE | FAILED | CLEARED
route: code             # artifact | code
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
