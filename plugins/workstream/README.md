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
- **Node 18+** — used by the `goal-on` verifier under Copilot CLI.

## Harness differences

`goal-on` holds itself to its Outcome with a Stop hook. Copilot CLI supports only
`command`, `http`, and `prompt` (sessionStart) hooks — it has no LLM-prompt hook type
— so the two harnesses enforce the same brief by different means:

| | Claude Code | Copilot CLI |
|---|---|---|
| Declared in | `hooks:` in `skills/goal-on/SKILL.md` frontmatter | `hooks.json` at the plugin root |
| Type | `agent` — an LLM reads the brief and judges it | `command` — `scripts/verify-goal.mjs` |
| Verification | **Semantic**: does the recorded evidence actually support each Outcome item? | **Mechanical**: is every Outcome item ticked `- [x]`, and is `## Verification evidence` non-empty? |
| Registers when | the skill is invoked | the plugin is installed |

Claude Code reads `hooks/hooks.json`, not a root `hooks.json`, so the two never
double-register. Both write `FAILED` once `turn_budget` is spent, both fail open on
any error, and Copilot's own 8-consecutive-block cap coincides with the default
`turn_budget: 8`.

Because Copilot's verifier is mechanical, **ticking a checkbox is what marks an item
done** — don't tick one before its evidence is in the brief.

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
