# goal-on — design

**Date:** 2026-07-27
**Plugin:** `workstream` (1.3.0 → 1.4.0)
**Status:** approved, ready for implementation planning

## Summary

`/workstream:goal-on <prompt>` turns a vague request into a structured brief, then
drives it to completion across turns without further user input.

It is the ad-hoc counterpart to `work-on`. Same destination — verified work, or a
draft PR handed to `ship` — but the input is a loose human sentence instead of a
Jira ticket, and the run is autonomous instead of gated.

Persistence comes from an **agentic verifier `Stop` hook** declared in the skill's
own frontmatter. The hook blocks the turn from ending until the brief's Outcome is
independently verified, or a stop rule trips.

## Motivation

Claude Code ships a built-in `/goal <condition>` that keeps working across turns
until a condition holds. It has two shortcomings for this use case:

1. **It cannot be invoked programmatically.** `/goal` is a `local-jsx` client-side
   command with `immediate: true` — handled by the terminal before the model runs,
   and it deliberately does not trigger a model turn. No tool can invoke it. Any
   design that routes through `/goal` requires the user to type it by hand.
2. **It takes an already-formed condition.** It has no notion of interrogating a
   vague prompt into a scoped, verifiable objective first.

`goal-on` addresses both: it does the prompt→brief rewrite, and it reproduces the
persistence mechanism in a form a skill can arm on its own.

## Background: how `/goal` works

Established by reading the Claude Code bundle at
`~/.local/share/claude/versions/2.1.220`. These findings are load-bearing; the
design fails without them.

`/goal <condition>` does exactly this:

```js
sessionHooksRegistry.add(sessionId, "Stop", "", {type: "prompt", prompt: condition})
appState.activeGoal = {condition, iterations: 0, setAt, tokensAtStart}
applyMessageOp({append: goal_status attachment {met: false, condition}})
```

It gates on a trusted workspace and on hooks not being restricted
(`disableAllHooks` / `allowManagedHooksOnly`).

Three further facts make a skill-owned copy possible:

- **`hooks` is a valid SKILL.md frontmatter field.** It appears in the parser's
  `declaredFields`, and the loader emits *"Skill declared hooks in frontmatter —
  ignored (MCP-sourced skills cannot register hooks)"* — the exclusion is specific
  to MCP-sourced skills, so plugin skills qualify.
- **Invoking a skill registers its hooks** into the same session registry `/goal`
  writes to: `Vdd(setAppState, sessionId, e.hooks, e.name, skillRoot)`, which fires
  for `type === "prompt"` commands — the category skills belong to.
- **The hook union includes an `agent` type**, documented as *"Agentic verifier hook
  type"*, with `prompt`, `timeout` (60s default), `model` (Haiku default),
  `statusMessage`, and `once`. It is a real subagent with tools, so it can verify
  rather than merely judge text. `/goal` uses the weaker `prompt` type.

Validated hook object shape:

```yaml
hooks:
  <EventName>:
    - matcher: ""        # optional
      hooks:
        - type: agent
          prompt: "..."
          timeout: 180
```

Prompt and agent hooks return a structured verdict: `ok: true` allows the turn to
end; `ok: false` produces `decision: "block"` and feeds the reason back to the model
as its next instruction. A `continueOnBlock` flag adjusts the emitted `continue`
value; its exact `Stop` semantics are unconfirmed and must be settled in the smoke
test.

Two incidental facts:

- **Stop hooks are capped at 8 consecutive blocks** (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`).
  A turn budget above 8 is dead text — the harness abandons the loop first.
- **`/goal clear` will not touch this hook.** The function it uses to find hooks to
  remove skips any whose `skillRoot` is defined. A native `/goal` and `goal-on`
  coexist without interfering.

## Architecture

Two phases, split by the moment the hook arms.

### Phase 1 — Structure (interactive, hook not yet armed)

1. Extract **Task** — the objective, from the raw prompt.
2. Assess **Scope** against the codebase: files affected, migrations, package
   dependencies, and whether sibling repos are implicated.
3. Draft **Constraints** and **Outcome**. Every genuine uncertainty becomes a
   numbered multiple-choice question, asked in one batch via `AskUserQuestion` — not
   drip-fed.
4. Classify the **route**:
   - `artifact` — research, slides, documents, Jira/Confluence updates, throwaway
     scripts. Anything not destined to be merged.
   - `code` — changes intended to merge into a repo.
5. Set **Stop Rules**: turn budget (default 8) and the unresolvable-dependency clause.
6. Present the brief. **User approval here is the only planned gate.** The
   `NEEDS-DECISION` escape hatch in Phase 2 is an exception path, not a routine
   checkpoint — if it fires often, Phase 1 interrogation was too shallow.

Phase 1 is deliberately hook-free. A `Stop` hook prevents the turn from ending, so
questions cannot be asked once it is armed. All interrogation happens first.

### Phase 2 — Execute (hook armed, autonomous)

**`artifact` route:** perform the work to completion, verify it, record the evidence,
write `status: DONE`.

**`code` route:**

1. `git fetch origin`
2. Branch `goal/<slug>` off the repo's default branch (`origin/main`), **in the
   current checkout** — no worktree. If the working tree is dirty, stop and surface
   it during Phase 1 rather than branching over uncommitted work.
3. Implement. Multiple files are expected and fine.
4. Verify: the repo's own checks, plus a real browser check for any UI surface.
5. `gh pr create --draft`
6. Invoke `workstream:ship`.

The goal is met at **draft PR raised + ship handed off**. `ship` owns everything
after that, including CI, findings triage, and the merge checkpoint. `goal-on` does
not wait for the merge.

A `goal/<slug>` branch carries no Jira key by design — `goal-on` is the non-ticket
entry point. `ship` already handles this: it parses the key from the branch name and,
finding none, skips the Jira transitions and notes it. No change to `ship` is needed.

### Brief file

`~/.claude/workstream/goal-on/<session-id>.md`, following the plugin's existing
per-user state convention (`ship-config.json`, `pr-ledgers/`). Session-id keying
means concurrent sessions cannot collide, and nothing is written into the user's
repo.

```
status:      ACTIVE | NEEDS-DECISION | DONE | FAILED | CLEARED
route:       artifact | code
turns_used:  N
turn_budget: 8

Task / Scope / Constraints / Outcome / Stop Rules
```

Field spelled **Constraints**. The brief also accumulates a verification-evidence
section as work proceeds — see the soundness note below.

## The verifier hook

Declared in `SKILL.md` frontmatter; registered session-scoped on invocation.

```yaml
hooks:
  Stop:
    - hooks:
        - type: agent
          timeout: 180
          statusMessage: "verifying goal"
          prompt: |
            $ARGUMENTS carries the hook input JSON; read session_id from it.
            Read ~/.claude/workstream/goal-on/<session_id>.md.
            Apply the decision table.
```

Decision table, evaluated top-down. The first four cases are cheap string reads, so
the common paths cost almost nothing.

| Brief state | Verdict | Effect |
|---|---|---|
| file missing, or `status: CLEARED` | `ok:true` | not a goal-on session — get out of the way |
| `status: DONE` / `FAILED` | `ok:true` | terminal, release |
| `status: NEEDS-DECISION` | `ok:true` | escape hatch — release so the user can be asked |
| `turns_used >= turn_budget` | `ok:true` | stop rule tripped; flip brief to `FAILED` |
| otherwise | verify | see below |

**Verification** independently checks the Outcome items rather than trusting the
model's claim: artifact files exist and have content; `gh pr view --json state,isDraft`
shows the draft PR; recorded check output is present and green; a browser check
actually ran for UI work. Met → `ok:true`. Not met → increment `turns_used`,
`ok:false` with **the specific gap**, which becomes the model's next instruction.

**The verifier owns the turn counter.** It is the only thing that runs exactly once
per turn-end, so the model cannot miscount its own budget.

**Soundness compromise, stated plainly.** A 180s timeout cannot hold a full test
suite, and re-running one at every turn-end would be punitive. So the skill requires
the model to *record* verification output into the brief as it goes, and the verifier
checks that record plus cheap live probes (`gh`, file existence, `git log`). A
sufficiently determined self-deception could fabricate the record. This remains
strictly stronger than `/goal`, which only judges conversation text.

### Clearing

Self-clearing is the normal path, not a user action. Phase 2 writes its own terminal
status: `DONE` on success, `FAILED` when a stop rule trips. `CLEARED` is the
abandon-early state and can be set by the model on request.

`/workstream:goal-on clear` remains supported as a manual override. Because `goal-on`
is a skill rather than a built-in, it is also invocable programmatically —
`Skill(skill: "workstream:goal-on", args: "clear")`.

**Limitation:** the hook cannot be *deregistered*. `/goal clear` calls
`sessionHooksRegistry.remove(...)`, an internal API unavailable to a skill. After a
clean exit the hook stays registered and short-circuits to `ok:true` on the cheap
status read. Residual cost is roughly one Haiku call plus one file read per turn-end
for the remainder of that session; a new session starts with no hook. The `if:` field
cannot gate this away — it is permission-rule syntax matching tool calls, so it is
inert for `Stop`.

## Failure modes

| Condition | Behavior |
|---|---|
| Hooks disabled or workspace untrusted | Detect in Phase 1 (the gates `/goal` checks), warn plainly, degrade to instruction-only persistence. Never silently arm nothing. |
| Skill-frontmatter hooks do not register | The load-bearing risk. Smoke-tested first; fallback is a `command`-type hook variant. |
| Turn budget exhausted | Verifier flips `FAILED` and releases; the model reports what was achieved and the specific remaining gap. Never a silent give-up. |
| Unresolvable dependency conflict | Immediate `FAILED` + report. Do not burn the budget on it. |
| Verifier times out or errors | **Fail open** (`ok:true`). A crashed verifier must never wedge the session. |
| Two goal-on sessions at once | Session-id-keyed brief files; no collision. |
| Session compacted mid-goal | Brief file survives; the verifier's block message re-establishes context. |

## Risk

The design rests on skill-frontmatter hooks registering when a plugin skill is
invoked. The bundle indicates they do, but this was read from minified source, not
observed. **Implementation must begin with a throwaway skill carrying a trivial
`Stop` hook to prove it fires.** If it does not, the design changes shape: the
fallback is a `command`-type hook (deterministic, near-zero cost, but it enforces
only an explicit done-marker rather than real verification), or instructions-only
persistence with no harness enforcement.

The smoke test must also settle `continueOnBlock` semantics for `Stop`.

## Files

| File | Change |
|---|---|
| `plugins/workstream/skills/goal-on/SKILL.md` | new — the skill |
| `plugins/workstream/.claude-plugin/plugin.json` | version → `1.4.0` |
| `.claude-plugin/marketplace.json` | matching version bump |
| `plugins/workstream/README.md` | sixth row in the skills table |
| `plugins/workstream/docs/TICKET_WORKFLOW.md` | `goal-on` as ad-hoc entry point; new `~/.claude/workstream/goal-on/` state row |

## Verification

Workstream skills are pure markdown with no test suite (only `jira-writer` has CI).
Verification is therefore behavioral:

1. **Frontmatter-hook smoke test** — gates the whole design; run first.
2. **`artifact` run** — completes, verifies, writes `DONE`.
3. **`code` run** — branches off `origin/main`, opens a draft PR, hands to `ship`.
4. **Budget-exhaustion run** — proves `FAILED` reports rather than hangs.
