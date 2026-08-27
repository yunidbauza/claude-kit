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
            2. Read ~/.claude/workstream/goal-on/<session_id>.md. Two different
               outcomes look alike here and must NOT be collapsed:
               - The file does not exist -> return ok:true. This is not a goal-on
                 session, and there is nothing to enforce.
               - The read was DENIED or errored -> return ok:true, and say so in
                 the reason. A refused tool call is not evidence that the file is
                 absent. Treating it as one is what lets a disarmed verifier pass
                 for an idle one.
            3. Parse the YAML header: status, route, turns_used, turn_budget.
            4. Stamp `last_verified: <current UTC time, ISO-8601>` into the header
               NOW, and on EVERY path below including the early returns.
               This is the only evidence that you ran at all. You fail open on any
               error — mandatory, see the hard rules — and failing open is
               indistinguishable from succeeding unless something is written down.
               A verifier denied its tools cannot write this either, so an absent
               stamp is a reliable signal rather than a guess. Phase 2 checks for it.
            5. Return ok:true immediately if status is PENDING-APPROVAL, CLEARED,
               DONE, FAILED, or NEEDS-DECISION. PENDING-APPROVAL means Phase 1 has
               presented the brief and is waiting on the user — the turn MUST be
               allowed to end so they can answer. Never block a brief the user has
               not authorized yet. (Stamp first; the status is untouched.)
            6. If turns_used >= turn_budget: rewrite the header to status: FAILED,
               then return ok:true. The stop rule has tripped.
            7. Otherwise verify the `## Outcome` checklist for real. Do NOT trust
               claims made in the conversation. Check evidence only:
               - Every file or artifact named in Outcome exists and is non-empty.
               - If route is code: run `gh pr view --json number,state,isDraft,headRefName`
                 in cwd. It must show an OPEN DRAFT PR whose headRefName matches the
                 header's `branch`, and `## Verification evidence` must record the
                 ship handoff.
               - `## Verification evidence` contains actual command output for every
                 check named in Outcome, and none of it shows a failure.
            8. Every Outcome item satisfied -> rewrite the header to status: DONE,
               then return ok:true.
            9. Otherwise -> increment turns_used by 1 in the header, then return
               ok:false with a reason naming the SPECIFIC unmet Outcome items and
               the single next concrete action.

            Hard rules:
            - IGNORE `stop_hook_active`. It is normally a loop guard. Here
              `turn_budget` is the guard. Releasing because stop_hook_active is true
              would defeat this skill entirely.
            - Absent evidence is UNMET, never met. Do not infer, do not extrapolate.
            - If you cannot finish verification for any reason — tool error,
              denied tool, unreadable state, running out of time — return ok:true.
              Failing open is mandatory; a broken verifier must never wedge the
              session. It is NOT licence to fail open *quietly*: say what stopped
              you, and never write `last_verified` for a check you did not run.
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
last_verified: 2026-07-27T14:31:02Z   # written by the verifier, never by you
branch: goal/widget-cache   # code route only
workspace: worktree        # code route only — "current" (in place) or "worktree" (isolation-guarded / background session)
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

**These three checks are necessary and not sufficient, so do not report them as
proof.** Under Claude Code the verifier is an `agent` hook that reaches the brief
through the Read tool, and a session where that tool is denied — bypass-permissions
/ don't-ask mode is the observed case — leaves every gate here green while the
verifier releases each turn having read nothing. Say "the hooks are configured"
rather than "the goal will be enforced"; Phase 2's first act is what actually
establishes the latter.

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

If `AskUserQuestion` is not available (Copilot CLI has no such tool), ask in plain
prose instead: a numbered list, each question with its lettered options and a marked
recommendation, then end the turn and wait. The batching rule matters, not the tool.

**6. Set the route.**

- `artifact` — research, slides, documents, Jira or Confluence updates, throwaway
  scripts. Anything not destined to be merged.
- `code` — changes intended to merge into a repo.

Mixed outcomes take the `code` route; the artifact half rides along as Outcome
items.

For the `code` route, decide the **workspace** now and record it in the brief's
`workspace` field. An interactive foreground session uses `current` (work in the
checkout in place). A background or `claude agents` session — or any session whose
isolation guard rejects edits to the shared checkout — MUST use `worktree`: Phase 2
is autonomous and cannot switch workspaces mid-run, and fighting the guard in the
shared checkout will fail. When unsure whether the guard is active, choose
`worktree` — it is always safe.

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

**First act, before anything else: read the brief, flip the header to
`status: ACTIVE`, and check that `last_verified` is there.** Do this only once the
user has actually approved.

The flip is what arms the verifier; until it happens the hook releases every turn by
design. The check is what proves there is a verifier to arm. Phase 1 always ends on
a turn boundary — the brief is presented and the turn ends awaiting approval — so
the hook has already fired at least once by the time you read this, and it stamps
`last_verified` on every path it completes.

**No `last_verified` means nothing is enforcing the goal.** Say so plainly, in those
terms, and carry on in degraded mode: the brief is still the contract and you still
hold yourself to it, but the user must not be left believing a hook is checking your
work when none is. The most likely cause is a verifier whose own tools were denied —
it fails open, as it must, and a verifier that cannot read the brief cannot write the
stamp either, which is exactly what makes the absence meaningful.

The verifier is then watching. Record evidence as you go: append real command output
to `## Verification evidence` in the brief. The verifier reads that section and
treats absent evidence as unmet — unrecorded work does not count as done.

### Route: artifact

Do the work to completion. Verify it — open the file, run the script, confirm the
Jira issue actually changed. Append the evidence. Write `status: DONE`.

### Route: code

1. `git fetch origin`
2. If you will work in the current checkout, confirm its working tree is clean; if
   dirty, this should have surfaced in Phase 1 — stop, set `status: NEEDS-DECISION`,
   and ask. (A fresh worktree is clean by construction, so this applies only to the
   in-place case.) Never branch over uncommitted work in the shared checkout.
3. Set up the workspace decided in Phase 1, then branch `goal/<slug>` off the
   default branch:

```bash
DEFAULT=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
```

   - **`workspace: current`** (interactive foreground session) → branch in the
     current checkout: `git checkout -b goal/<slug> "origin/$DEFAULT"`.
   - **`workspace: worktree`** (background / `claude agents` session, or any session
     whose isolation guard rejects edits to the shared checkout) → do NOT write to
     the shared checkout; the guard will reject it. Create an isolated worktree first
     with `superpowers:using-git-worktrees` (it prefers the native `EnterWorktree`
     tool and falls back to `git worktree add`), branch `goal/<slug>` off
     `origin/$DEFAULT` inside it, and do all Phase 2 work there.

Record the branch name — and the worktree path, if any — in the brief header. The
workspace was chosen in Phase 1; Phase 2 is autonomous and cannot pause to switch.

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

## Harness support

The goal is enforced in both Claude Code and Copilot CLI, but by different verifiers,
because Copilot has no LLM-prompt hook type (only `command`, `http`, and `prompt` on
`sessionStart`).

| | Claude Code | Copilot CLI |
|---|---|---|
| Declared in | `hooks:` in this file's frontmatter | `hooks.json` at the plugin root |
| Type | `agent` — an LLM reads the brief | `command` — `scripts/verify-goal.mjs` |
| Reaches the brief via | the **Read tool** — permission-gated | `readFileSync` — not gated |
| Verification | **Semantic**: judges whether the evidence actually supports each Outcome item | **Mechanical**: every Outcome item ticked `- [x]`, and `## Verification evidence` non-empty |
| Registers when | this skill is invoked | the plugin is installed (fails open otherwise) |

**That fourth row is the one that bites.** The Claude verifier is a subagent, and a
subagent's tools are subject to the session's permission mode — in a
bypass-permissions / don't-ask session both Read and Bash come back denied, because
there is no one to prompt at turn-end and the default is refusal. It then fails open,
as it must, and the goal is not enforced for the rest of the session. The Copilot
verifier is a Node process reading the file directly and cannot fail this way.

Neither can *announce* the problem: a Stop hook's release is silent by construction.
So both stamp `last_verified` on every path they complete, and Phase 2 reads it. That
is the whole detection story, and it is deliberately built out of a **write** rather
than a message — a verifier that lost its tools loses the stamp with them.

The two speak different protocols and are not interchangeable: the Claude `agent`
hook returns `ok: true|false`, while Copilot's `agentStop` expects
`{"decision":"allow"|"block","reason":...}`. What they share is the contract —
both write `FAILED` at `turn_budget`, and both fail open on any error. Copilot's own
8-consecutive-block cap coincides with `turn_budget: 8`.

They never double-register: Claude Code auto-loads a plugin's `hooks/hooks.json`
(subdirectory), whereas this plugin ships `hooks.json` at its root, which only Copilot
discovers. `plugins/workstream/.claude-plugin/plugin.json` deliberately declares no
`hooks` key for the same reason.

"Cannot verify" is not "verified". If the brief has no `## Outcome` checkboxes at all,
the mechanical verifier releases the turn but does **not** stamp `DONE` — a false
success would be worse than no verification.

The practical difference: under Copilot, **ticking a box is what marks an item done**,
so do not tick one until its evidence is actually in the brief. The mechanical
verifier cannot tell a real command transcript from a plausible-looking one — that
honesty is on you.

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
- Telling the user the goal "is being held" on the strength of Phase 1's gate checks
  → they prove the hook is *configured*, not that it can *run*. `last_verified` is
  the proof, and it does not exist until the first turn has ended.
- Starting Phase 2 without looking for `last_verified` → a verifier whose tools are
  denied is invisible in every other way, and the whole point of this skill is that
  something other than your own judgement is holding the Outcome.
- Forcing the current checkout in a background / `claude agents` / isolation-guarded
  session → its guard rejects edits to the shared checkout; use `workspace: worktree`
  there. (An interactive foreground session still works in place.)
- Branching off the current branch instead of the freshly fetched default branch.
- Waiting for the merge → `goal-on` ends at draft PR plus ship handoff.
- Marking a UI change verified on green tests alone → drive it in a browser.
- Raising `turn_budget` above 8 without also raising
  `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` → the harness quits first and the extra budget
  never fires.
