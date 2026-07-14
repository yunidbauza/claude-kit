# Workstream

Claude Code plugin covering the full Jira-ticket → PR → merge lifecycle. Five
skills, each independently invocable, that chain end to end:

| Command | Purpose |
|---|---|
| `/workstream:work-on <KEY>` | Fetch the ticket, reconcile spec vs codebase (hard user gate), set up an isolated worktree, hand off to design/plan/implement |
| `/workstream:ship [PR] [--auto-merge]` | PR endgame: CI watch → self code review → findings triage loop → watch-until-approved with base-branch sync → merge |
| `/workstream:review-pr-findings [PR]` | Adversarial triage of all PR feedback with a persistent per-PR ledger; loops until CI is green with no unresolved threads |
| `/workstream:merge-pr [PR]` | Squash merge, worktree/branch teardown, default-branch pull, Jira ticket → Done |
| `/workstream:spec-deviation` | Propagate a mid-work spec change to the PR, the ticket, and affected downstream tickets |

See `docs/TICKET_WORKFLOW.md` for the lifecycle diagram, conventions, and state
files.

## Installation

```bash
/plugin marketplace add yunidbauza/claude-kit
/plugin install workstream
```

## Prerequisites

- **superpowers plugin** — the workflow hands off to its brainstorming,
  writing-plans, using-git-worktrees, test-driven-development, and
  finishing-a-development-branch skills.
- **jira-writer plugin** (this marketplace) — all Jira reads/writes go through
  `jira-writer:jira-writer`. Requires the `JIRA_API_KEY` env var.
- **`gh` CLI** authenticated against your repos.

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

| File | Purpose |
|---|---|
| `ship-config.json` | Per-repo auto-merge default: `{"<owner>/<repo>": {"auto_merge": true}}` |
| `pr-ledgers/<owner>-<repo>-pr<N>.md` | Finding triage ledger per PR; deleted after merge |
