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
        # THE FLOOR. A plain Node process: it opens the brief with readFileSync, so
        # nothing can deny it the way the agent hook below gets denied. It is the only
        # hook that writes brief state — last_verified, turns_used, DONE, FAILED.
        # NB: `${CLAUDE_PLUGIN_ROOT}` is NOT string-interpolated in skill-frontmatter
        # hooks (verified against Claude Code 2.1.250); it is exported into the hook's
        # environment instead, so the shell expands it here.
        - type: command
          timeout: 30
          statusMessage: "verifying goal"
          command: node "$CLAUDE_PLUGIN_ROOT/scripts/verify-goal.mjs" --harness=claude
        # THE CEILING. Judges meaning, writes nothing. Silently loses its tools in a
        # bypass-permissions session, which is precisely why it may not own state.
        - type: agent
          timeout: 180
          statusMessage: "judging goal evidence"
          prompt: |
            You are the goal-on semantic verifier. $ARGUMENTS holds the Stop hook
            input JSON.

            You are the CEILING, not the floor. A command hook
            (`scripts/verify-goal.mjs`) has already run for this same turn. It owns
            the brief's state: it stamped `last_verified`, spent turn budget, and
            settled DONE/FAILED. It checks FORM — every Outcome box ticked, evidence
            present, a real PR on the branch. You check MEANING, and you write
            NOTHING. Never edit the brief. Never stamp anything. A second writer
            would double-spend the turn budget.

            1. Read `session_id` from $ARGUMENTS.
            2. Read ~/.claude/workstream/goal-on/<session_id>.md. If it is missing,
               or the read is DENIED or errors, return ok:true and say which in the
               reason. A refused tool call is not evidence that the file is absent —
               but it is no longer your problem to compensate for: the floor has the
               session covered either way. (A brief written under a drifted filename
               also lands here; the command hook resolves those by header identity.)
            3. Return ok:true unless `status` is ACTIVE or DONE. Every other status
               is settled or waiting on the user. DONE is in that list for one
               reason: the two hooks run concurrently, and on the decisive turn —
               the one where the last box gets ticked — the floor writes DONE while
               you are reading. Skipping DONE would mean skipping the only turn you
               exist for, at random.
            4. Read `## Outcome` and `## Verification evidence`. For each TICKED item,
               ask the one question a script cannot: does the recorded evidence
               actually support it?
               - Evidence showing a failure, a skipped check, or the output of a
                 different command than the item names -> unsupported.
               - An item ticked with no evidence naming it -> unsupported.
               - Do NOT re-judge unticked items. The floor already blocks on those.
               - Judge the brief, not the conversation. Claims made in chat are not
                 evidence.
            5. Every ticked item genuinely supported -> ok:true.
            6. Otherwise -> ok:false, naming the SPECIFIC items whose evidence does
               not hold and the single next concrete action. **If the brief already
               says DONE, your reason MUST also instruct the model to set
               `status: ACTIVE` before continuing** — you cannot write it yourself,
               and until it is ACTIVE again the floor sees a terminal status and
               enforces nothing.

            Hard rules:
            - IGNORE `stop_hook_active`. `turn_budget` is the loop guard, and the
              command hook owns it.
            - Absent evidence is UNMET, never met. Do not infer, do not extrapolate.
            - If you cannot finish for any reason — tool error, denied tool,
              unreadable state, running out of time — return ok:true and say what
              stopped you. Failing open is mandatory, and it now costs nothing: the
              floor is still standing.
            - Write nothing, ever.
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

Name the file **exactly** `<session-id>.md`, and repeat the id in the header's
`session:` field. The verifier tries the filename first and falls back to the header,
because a brief it cannot find is indistinguishable from no goal at all — it releases
every turn and the skill silently stops working. The header is what survives a name
that drifted.

```markdown
---
status: PENDING-APPROVAL   # PENDING-APPROVAL | ACTIVE | NEEDS-DECISION | DONE | FAILED | CLEARED
route: code                # artifact | code
turns_used: 0
turn_budget: 8
created: 2026-07-27T14:30:00Z
session: 3f9c1e04-...        # this session's id — the brief's identity if the file is ever renamed
last_verified: 2026-07-27T14:31:02Z   # written by the verifier, never by you
branch: goal/widget-cache   # code route only
workspace: worktree        # code route only — "current" (in place) or "worktree" (isolation-guarded / background session)
repo: /abs/path/to/repo    # code route — REQUIRED when the work is not in the session's own cwd
worktree: /abs/path/to/wt  # code route — the worktree path, when workspace is "worktree"
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
proof.** They establish that hooks are *permitted to run*, never that one did.
Enforcement rests on a `command` hook whose access to the brief cannot be denied —
but a plugin that failed to load, a `node` that is not on PATH, or a brief written
under a name the verifier cannot resolve all leave every gate here green with nothing
enforcing anything. Say "the hooks are configured" rather than "the goal will be
enforced"; Phase 2's first act is what actually establishes the latter.

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
work when none is. The stamp is written by the `command` hook, which cannot be denied
its tools, so its absence points at something blunter than a permission refusal — the
plugin is not installed in this harness, `node` is missing, hooks are disabled, or the
brief is sitting under a filename the verifier could not resolve. Check the last one
first: it is the only one you can fix from here, by renaming the brief to
`<session-id>.md`.

The verifier is then watching. Record evidence as you go: append real command output
to `## Verification evidence` in the brief. The verifier reads that section and
treats absent evidence as unmet — unrecorded work does not count as done.

### Route: artifact

Do the work to completion. Verify it — open the file, run the script, confirm the
Jira issue actually changed. Append the evidence and tick the Outcome items. The
verifier writes `status: DONE`; you do not (see the code route's step 9).

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

Record the branch name in the header's `branch:`, and the absolute path of the
checkout you are working in as `repo:` (plus `worktree:` when you made one). Those
keys are not decoration: the verifier's PR check runs `gh` from that directory, and
`gh` resolves the repository from wherever it is standing. A cross-repo goal whose
brief omits them sends the check into the session's own repo, where it finds no PR.
Absolute paths only — a bare repo name resolves against cwd and is ignored.

The workspace was chosen in Phase 1; Phase 2 is autonomous and cannot pause to
switch.

4. Implement. Multiple files are expected and fine.
5. Verify with the repo's own checks — discover them from `CLAUDE.md`,
   `package.json` scripts, or the `Makefile`. **Any UI surface also requires driving
   it in a real browser** (Playwright specs for the touched surface, or the `verify`
   skill). Green type-check and unit tests do not prove a UI renders.
6. Append all of that output to `## Verification evidence`.
7. `gh pr create --draft`
8. Invoke the `workstream:ship` skill with the PR number, and record the handoff in
   the evidence section.
9. Tick the Outcome items whose evidence is now recorded — and **do not write
   `status: DONE` yourself.** The verifier writes it, once it has confirmed the boxes,
   the evidence, and (on this route) a real PR on the branch. Writing it yourself
   makes the brief terminal, and the next verifier run stops at the status and never
   reaches those checks — you would be marking your own homework and skipping the one
   check that needs no trust.

**The goal is met at draft PR raised plus ship handed off.** `ship` owns CI,
findings triage, approval, and the merge checkpoint. `goal-on` does not wait for the
merge, and must not duplicate any of ship's steps.

A `goal/<slug>` branch carries no Jira key by design — `goal-on` is the non-ticket
entry point. `ship` already parses for a key, finds none, skips the Jira transitions,
and notes it. That is correct behavior; do not work around it.

## Harness support

The goal is enforced by the **same Node script under both harnesses** —
`scripts/verify-goal.mjs`, a plain process that opens the brief with `readFileSync`.
Under Claude Code a second, LLM-driven hook rides on top of it.

| | Claude Code | Copilot CLI |
|---|---|---|
| Floor — enforces the Outcome | `command` hook in this file's frontmatter, `--harness=claude` | `command` hook in `hooks.json` at the plugin root |
| Ceiling — judges the evidence | `agent` hook in this file's frontmatter | none (Copilot has no LLM-prompt hook type) |
| Reaches the brief via | `readFileSync` (floor) / the **Read tool** (ceiling) | `readFileSync` |
| Writes brief state | floor only | yes |
| Registers when | this skill is invoked | the plugin is installed (fails open otherwise) |
| Stop contract | `{"decision":"block","reason":…}`; silence releases | `{"decision":"allow"\|"block","reason":…}` |

**Why the floor exists at all.** The ceiling is a subagent, and a subagent's tools are
subject to the session's permission mode: in a bypass-permissions / don't-ask session
both Read and Bash come back denied, because there is no one left to prompt at turn
end and the default is refusal. It then fails open, as it must — and a Stop hook's
release is silent by construction, so for the rest of that session the goal is not
enforced and nothing says so. Every session launched with
`--dangerously-skip-permissions`, and every `claude agents` session, is that session.
A Node process cannot be denied a file it opens directly, so enforcement lives there.

**The two hooks divide along writes.** The floor owns every mutation of the brief —
`last_verified`, `turns_used`, `DONE`, `FAILED` — and the ceiling owns none. Two
writers would double-spend the turn budget, and a ceiling that vanishes mid-session
would take an unpredictable share of the budget with it. A hook that writes nothing
can disappear without consequence, which is exactly what the disarmed one does.

**Verification splits the same way.** The floor checks form: every Outcome item ticked
`- [x]`, `## Verification evidence` non-empty, and — on `route: code` — a real PR on
the header's `branch`, looked up with `gh pr list --head`. That last check is the one
piece of the Outcome that needs no trust: it holds even when nothing else can be
believed. The ceiling checks meaning: whether the recorded evidence actually supports
the items that were ticked. The floor cannot tell a real command transcript from a
plausible-looking one, so under Copilot — and under any Claude session whose ceiling
lost its tools — **ticking a box is what marks an item done**. Do not tick one until
its evidence is in the brief. That honesty is on you.

Both fail open on every error, and both refuse to record a false success: "cannot
verify" releases the turn but never stamps `DONE`. If the brief has no `## Outcome`
checkboxes at all, or the PR check could not be run, the turn is released and the
status is left untouched — a false success would be worse than no verification.

The floor stamps `last_verified` on every path it completes. That is how Phase 2 knows
it ran at all, and it is deliberately built out of a **write** rather than a message:
a hook that never ran cannot leave one behind.

They never double-register: Claude Code auto-loads a plugin's `hooks/hooks.json`
(subdirectory), whereas this plugin ships `hooks.json` at its root, which only Copilot
discovers, and the Claude-side hooks are declared in this skill's frontmatter so they
register only when the skill is invoked.
`plugins/workstream/.claude-plugin/plugin.json` deliberately declares no `hooks` key
for the same reason.

One wiring detail, verified against Claude Code 2.1.250 rather than assumed:
`${CLAUDE_PLUGIN_ROOT}` is **not** string-interpolated inside skill-frontmatter hook
commands. It is exported into the hook process's environment instead, so the command
spells it `"$CLAUDE_PLUGIN_ROOT/scripts/verify-goal.mjs"` and lets the shell expand it.
`CLAUDE_SKILL_DIR` is not set at all.

## Terminal states

Self-clearing is the normal path. `FAILED`, `NEEDS-DECISION` and `CLEARED` you write
yourself; do not wait to be asked. **`DONE` is the exception — the verifier writes
it**, so that a completed goal is a thing something else confirmed rather than a thing
you declared. The one case where you write it is degraded mode: if Phase 2's first act
found no `last_verified`, no verifier is running, and you must set the terminal status
yourself and say plainly that you did.

| Status | When | Then |
|---|---|---|
| `PENDING-APPROVAL` | Phase 1 wrote the brief; user has not approved | Verifier releases the turn. Not terminal — flip to `ACTIVE` on approval. |
| `ACTIVE` | Phase 2 running | Verifier enforces the Outcome. |
| `DONE` | Outcome verified — **written by the verifier**, not by you | Report what was produced. |
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
- Starting Phase 2 without looking for `last_verified` → a verifier that never ran is
  invisible in every other way, and the whole point of this skill is that something
  other than your own judgement is holding the Outcome.
- Writing `status: DONE` yourself → the status is terminal, so the next verifier run
  returns at it and never checks the boxes, the evidence, or the PR. Tick the boxes,
  record the evidence, and let the verifier settle it.
- Omitting `repo:` from a code-route brief whose work is not in the session's cwd →
  the PR check runs `gh` in the wrong repository, finds nothing, and blocks every turn
  until the budget is spent.
- Writing the brief anywhere but `<session-id>.md`, or omitting the `session:` header
  → a brief the verifier cannot resolve reads as "no goal here", and it releases every
  turn without a word.
- Forcing the current checkout in a background / `claude agents` / isolation-guarded
  session → its guard rejects edits to the shared checkout; use `workspace: worktree`
  there. (An interactive foreground session still works in place.)
- Branching off the current branch instead of the freshly fetched default branch.
- Waiting for the merge → `goal-on` ends at draft PR plus ship handoff.
- Marking a UI change verified on green tests alone → drive it in a browser.
- Raising `turn_budget` above 8 without also raising
  `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` → the harness quits first and the extra budget
  never fires.
