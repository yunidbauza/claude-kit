# Ticket-to-Merge Workflow

Six skills cover the full lifecycle of a Jira ticket, from intake to squash merge.
Each is independently invocable; together they chain end to end:

```
/workstream:work-on PROJ-123
   │  fetch + reconcile ticket vs codebase (hard gate: user go-ahead)
   │  isolated worktree off the default branch (fetched fresh)
   ▼
superpowers: brainstorming → writing-plans → implementation → PR
   ▼
/workstream:ship [PR] [--auto-merge]
   │  ticket → In Review (open non-draft PR, jira-writer)
   │  CI green → self review (code-review, subagent)
   │  findings loop (review-pr-findings, subagent)
   │  watch loop: new findings / sync base branch / approval (~20 min wakeups)
   │  (--auto-merge: skip the wait — findings resolved + CI green ⇒ approved,
   │   hand off to merge-pr)
   ▼
/workstream:merge-pr [PR]
      upstream sync + conflict resolution (confirm if breaking) →
      squash merge → worktree/branch cleanup → default-branch pull → Jira ticket Done
```

Standalone entry points:

| Command | Use it when |
|---|---|
| `/workstream:work-on <KEY>` | Starting a ticket from scratch. |
| `/workstream:goal-on <prompt>` | Starting ad-hoc work from a vague request rather than a ticket. |
| `/workstream:ship [PR]` | A PR exists and should be driven to merge. |
| `/workstream:review-pr-findings [PR]` | A PR has feedback to triage, outside the ship flow. |
| `/workstream:merge-pr [PR]` | The PR is approved and green; just merge + clean up. |
| `/workstream:spec-deviation` | Implementation diverged from the ticket spec. |

## Prerequisites

- **superpowers plugin** installed (brainstorming, writing-plans,
  using-git-worktrees, test-driven-development, finishing-a-development-branch).
- **`gh` CLI** authenticated against the repo.
- **jira-writer plugin** installed and configured — `JIRA_API_KEY` env var (see the jira-writer skill), or
  the Atlassian MCP connected as fallback.

## Conventions

- **One repo per PR.** A ticket may produce several PRs (e.g. backend + frontend);
  each gets its own work-on worktree, ship run, and merge.
- **Squash merge only** — one clean commit on the default branch per PR.
- **Worktrees by default** — work-on isolates every ticket in its own worktree so
  concurrent sessions can't corrupt each other's refs.
- **Branch names carry the ticket key** (`feat/proj-123-slug` or the sanitized
  worktree variant) — merge-pr parses the key to close the ticket.

## Per-user state (`~/.claude/workstream/`)

| File | Owner | Purpose |
|---|---|---|
| `ship-config.json` | ship | Per-repo auto-merge default: `{"<owner>/<repo>": {"auto_merge": true}}` — when active, CI green + all findings resolved replaces the human-approval wait. |
| `pr-ledgers/<owner>-<repo>-pr<N>.md` | review-pr-findings | Finding triage ledger per PR; survives sessions/compaction; deleted after merge. |
| `goal-on/<session-id>.md` | goal-on | Active goal brief; the verifier Stop hook reads it at every turn-end. Session-id keyed so concurrent sessions cannot collide. |

The path is identical under Claude Code and Copilot CLI — it is per-user state rather
than harness configuration, so a ticket can move between the two CLIs untouched.

The verifier behind `goal-on/<session-id>.md` differs by harness: Claude Code runs an
`agent`-type Stop hook that judges the evidence semantically, while Copilot CLI —
which has no LLM-prompt hook type — runs `scripts/verify-goal.mjs` via a `command`
hook, checking mechanically that every Outcome item is ticked and that evidence was
recorded. Both fail open and both write `FAILED` at `turn_budget`. See
[../README.md#harness-differences](../README.md#harness-differences).
