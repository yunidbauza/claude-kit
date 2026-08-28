# Workstream

Agent plugin covering the full Jira-ticket → PR → merge lifecycle, for **Claude Code**
and **GitHub Copilot CLI**. Six skills, each independently invocable, that chain end
to end:

| Command | Purpose |
|---|---|
| `/workstream:work-on <KEY>` | Fetch the ticket, reconcile spec vs codebase (hard user gate), set up an isolated worktree, hand off to design/plan/implement |
| `/workstream:goal-on <prompt>` | Ad-hoc entry point: rewrite a vague request into a Task/Scope/Constraints/Outcome/Stop-Rules brief, then drive it to a verified finish (artifact) or a draft PR handed to ship (code) |
| `/workstream:ship [PR] [--auto-merge]` | PR endgame: CI watch → self code review → findings triage loop → watch-until-approved with base-branch sync → merge |
| `/workstream:review-pr-findings [PR]` | Adversarial triage of all PR feedback with a persistent per-PR ledger; loops until CI is green with no unresolved threads |
| `/workstream:merge-pr [PR]` | Squash merge, worktree/branch teardown, default-branch pull, Jira ticket → Done |
| `/workstream:spec-deviation` | Propagate a mid-work spec change to the PR, the ticket, and affected downstream tickets |

See `docs/TICKET_WORKFLOW.md` for the lifecycle diagram, conventions, and state
files.

## Installation

**Claude Code**

```bash
/plugin marketplace add yunidbauza/claude-kit
/plugin install workstream
```

**GitHub Copilot CLI**

```bash
copilot plugin marketplace add yunidbauza/claude-kit
copilot plugin install workstream@claude-kit
```

All six skills work in both harnesses. The one behavioral difference is how `goal-on`
enforces its goal — see [Harness differences](#harness-differences) below.

## Prerequisites

- **superpowers plugin** — the workflow hands off to its brainstorming,
  writing-plans, using-git-worktrees, test-driven-development, and
  finishing-a-development-branch skills. Available for both harnesses:
  `/plugin marketplace add obra/superpowers-marketplace` or
  `copilot plugin marketplace add obra/superpowers-marketplace`.
- **jira-writer plugin** (this marketplace) — all Jira reads/writes go through
  `jira-writer:jira-writer`. Requires the `JIRA_API_KEY` env var.
- **`gh` CLI** authenticated against your repos.
- **Node 18+** — runs the `goal-on` Stop verifier under both harnesses.

## Harness differences

`goal-on` holds itself to its Outcome with a Stop hook, and under both harnesses the
thing doing the enforcing is the same Node script — `scripts/verify-goal.mjs`, which
opens the brief with `readFileSync`. Claude Code adds a second, LLM-driven hook on top
of it; Copilot CLI cannot, having no LLM-prompt hook type (only `command`, `http`, and
`prompt` on sessionStart).

| | Claude Code | Copilot CLI |
|---|---|---|
| Floor — enforces the Outcome | `command` hook in `skills/goal-on/SKILL.md` frontmatter | `command` hook in `hooks.json` at the plugin root |
| Ceiling — judges the evidence | `agent` hook in the same frontmatter | none |
| Writes brief state | the floor only | yes |
| Registers when | the skill is invoked | the plugin is installed |

**The floor is not an optimization; it is the whole fix.** An `agent` hook is a
subagent, and a subagent's tools obey the session's permission mode — in a
bypass-permissions session (`--dangerously-skip-permissions`, and every `claude
agents` session) Read and Bash come back denied, because nothing can prompt at turn
end. The hook then fails open, silently, and the goal stops being enforced for the
rest of the session with no way to tell from the outside. A plain Node process reading
the file directly cannot fail that way, so all enforcement and every write to the
brief live there. The LLM hook keeps only the job a script cannot do — judging whether
the recorded evidence supports the items that were ticked — and writes nothing, so its
disappearance costs nothing.

Output shapes differ and are not interchangeable, so the hook command names its
harness (`--harness=claude`) rather than guessing: Claude Code blocks on
`{"decision":"block","reason":…}` and releases on silence, while Copilot's `agentStop`
wants an explicit `{"decision":"allow"|"block"}`. The contract is otherwise identical:
`FAILED` once `turn_budget` is spent, fail open on any error, and Copilot's
8-consecutive-block cap coincides with the default `turn_budget: 8`.

Claude Code auto-loads a plugin's `hooks/hooks.json` (subdirectory) — per its own
plugin docs, *"the standard hooks/hooks.json is loaded automatically, so
manifest.hooks should only reference additional hook files"* — while this plugin ships
`hooks.json` at the **root**, which only Copilot discovers. `plugin.json` declares no
`hooks` key for the same reason, so the verifiers never double-register.

Two deliberate asymmetries with false success, in both directions:

- If a brief has no `## Outcome` checkboxes at all, or the `route: code` PR check
  cannot be run (`gh` missing, offline, no branch recorded), the verifier releases the
  turn but does **not** write `DONE`. Failing open must never mean recording a success
  it could not verify.
- The mechanical verifier cannot tell a real command transcript from a
  plausible-looking one, so **ticking a checkbox is what marks an item done** — don't
  tick one before its evidence is in the brief. What it *can* check without trusting
  anyone is the PR: on `route: code` it runs `gh pr list --head <branch>` and refuses
  `DONE` unless a real open (or merged) PR is there.

Everything else degrades cleanly: worktree isolation uses the native tool in Claude
Code and plain `git worktree` elsewhere, and `AskUserQuestion` falls back to a plain
numbered prose question.

## Behavior highlights

- **Worktrees by default** — every ticket gets an isolated worktree branched from
  the freshly fetched default branch; concurrent sessions can't corrupt each other.
- **Findings are claims, not instructions** — every piece of PR feedback is
  adversarially assessed (VALID / INVALID / NEEDS-USER-DECISION) before any fix;
  invalid findings get a reasoned reply, and a per-PR ledger prevents re-litigating
  across rounds and sessions.
- **One user checkpoint** — the merge confirmation. With `--auto-merge` (flag, or
  per-repo config in `ship-config.json`) ship doesn't wait for a human PR approval
  at all: CI green + every finding resolved is the approval signal, and it hands
  off to merge-pr directly.

## Per-user state (`~/.claude/workstream/`)

This path is deliberately the same under both harnesses — it is plain per-user state,
not Claude Code configuration, so a ticket started in one CLI can be picked up in the
other without migrating anything.

| File | Purpose |
|---|---|
| `ship-config.json` | Per-repo auto-merge default: `{"<owner>/<repo>": {"auto_merge": true}}` |
| `pr-ledgers/<owner>-<repo>-pr<N>.md` | Finding triage ledger per PR; deleted after merge |
| `goal-on/<session-id>.md` | Active goal brief — status, route, turn budget, Outcome checklist, verification evidence |
