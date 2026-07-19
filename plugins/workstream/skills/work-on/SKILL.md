---
name: work-on
description: >-
  Use when starting work on a Jira ticket — "work on PROJ-123", "start ABC-42",
  "read the ticket and prepare a plan", picking up the next story in an Epic, or
  any new feature/bug work that begins from a Jira ticket rather than an ad-hoc
  request.
---

# Work On (start a ticket)

## Overview

Ticket specs go stale: the codebase moves after the ticket was written (earlier
stories in the Epic, merged PRs, renamed modules). Before planning anything,
reconcile the ticket against the code as it exists TODAY and surface deviations —
otherwise the plan implements against a world that no longer exists. **The codebase
is the source of truth.**

The full lifecycle this skill starts: reconcile → worktree → brainstorm → plan →
implement → **draft** PR → `ship` → `merge-pr`. The PR is opened as a draft so
CI (gated on `draft == false`) stays off during ship's self review; ship marks it
ready-for-review — the single CI trigger — only once the review passes.

## Steps

**0. Resolve the ticket key.** Take it from the arguments (`PROJ-123` — any Jira
project, pattern `[A-Za-z]+-[0-9]+`, uppercased). No key given → ask the user.

**1. Fetch the ticket** with the `jira-writer:jira-writer` skill (never raw REST/curl). Keep
the fetch lean — context bloat starts here:

- Fetch the **full body** of the target ticket only.
- Fetch the Epic's **summary** (title + short description), not its full body.
- List sibling stories as **titles + keys + status only** — do NOT pull their
  bodies.
- Fetch the **full body** of only the issues **directly linked** to the target
  (blocking/blocked-by/relates). Unlinked siblings stay title-only.

**2. Reconcile ticket vs codebase (subagents).** Dispatch 1–3 parallel `Explore`
subagents (reading + pattern-matching — a cheaper model is fine). Scope exploration
to the ticket itself and the linked issues from Step 1:

- Does anything the ticket asks for already exist (fully or partially)?
- Do the file paths, module names, schemas, and interfaces the ticket references
  still match reality?
- Did the **linked** prior work change assumptions the ticket relies on?

Give each subagent the relevant ticket excerpt and ask for a short verdict plus
concrete `file:line` evidence per mismatch — not full file dumps. If the ticket
spans multiple repos, reconcile against each affected repo.

**3. Report, then STOP — hard gate.** Present a short summary: what the ticket
says, what the code says, and each mismatch with a recommended resolution (follow
ticket / follow code / needs decision). Include whether the ticket description
should be updated. Then END YOUR TURN and wait for the user's go-ahead — even with
zero deviations ("no deviations found, ready to plan — proceed?" is the whole
message in that case). Never continue into Step 4/5 in the same turn as the report.
If a deviation is confirmed, the `spec-deviation` skill propagates it to Jira
and the PR later.

**4. Set up an isolated worktree (default).** Every ticket gets its own git
worktree, not just a topic branch on the shared checkout — concurrent sessions on
one checkout clobber each other's refs.

Run `git fetch origin` first so the remote-tracking ref is current — without it the
worktree can be rooted at a stale base. Then invoke the
**`superpowers:using-git-worktrees`** skill to create the workspace — it owns the
mechanics (detect existing isolation, prefer the native `EnterWorktree` tool, fall
back to `git worktree add`, verify the dir is ignored). Branch fresh from the repo's
default branch (`origin/$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')`
— usually `origin/main`). Choices to feed it:

- **Branch name:** request `feat/<key>-<short-kebab-description>` (lowercased key,
  e.g. `feat/proj-123-add-widget`). Native tooling may sanitize the name into its
  own format — that is fine; the ONE invariant is that the ticket key survives
  somewhere in the branch name (`merge-pr` parses it case-insensitively). After
  creation, confirm `git branch --show-current` contains the key.
- **Baseline:** install dependencies, then run the repo's cheapest static check —
  discover it from `package.json` scripts / `Makefile` / the project's CLAUDE.md
  (type-check or lint). Skip full test suites; the default branch is already green.
- **Multi-repo tickets:** each affected repo gets its own worktree and its own PR.
  A session holds one native worktree at a time — drive each repo from its own
  session, or create additional worktrees with manual `git worktree add`.

**5. Transition the ticket to In Progress** via `jira-writer:jira-writer` when
implementation begins — unless something else (e.g. a user-configured hook) already
moved it; check the current status first.

**6. Plan and implement.** Hand off to the normal superpowers flow:
`superpowers:brainstorming` for design (restate the reconciliation findings from
Step 2 as input there), then `superpowers:writing-plans`, then plan execution, then
`superpowers:finishing-a-development-branch` to produce the PR. **For tickets with
a UI surface:** the brainstorm must present design options as browser-rendered HTML
mockups with 2–3 variants (ASCII mockups only if the user asks).

**Create the PR as a draft** — `gh pr create --draft`.
`superpowers:finishing-a-development-branch` is forge-neutral (it pushes the branch
but leaves the `gh pr create` to you), so pass `--draft` explicitly; it will not add
the flag on its own. CI is gated to skip draft PRs (`if: draft == false`), so ship's
self review and its fix pushes run on the draft for **zero CI minutes**. Ship marks
the PR ready-for-review only after the review passes — that single transition is what
first triggers CI. Opening the PR ready instead burns a full CI run before the review
has even started.

Once the (draft) PR exists, continue with the `ship` skill to drive it to merge —
ship marks the PR ready after its self review and moves the ticket to In Review at
that moment.

## Red flags

- Writing a plan straight from the ticket text → reconcile first.
- Continuing into worktree setup/planning in the same turn as the reconciliation
  report ("no deviations, so I'll proceed") → the gate applies with zero deviations
  too.
- "The ticket is recent, it can't have drifted" → sibling stories merge daily.
- Raw Jira REST/curl instead of jira-writer.
- Working in the shared checkout instead of an isolated worktree.
- Creating the worktree off the current dirty branch instead of the freshly fetched
  default branch.
- A branch name missing the ticket key → merge-pr can't find the ticket to close.
- Opening the PR ready-for-review instead of a draft → CI runs before ship's self
  review even starts; always `gh pr create --draft` (ship marks it ready).
- Presenting UI design options as ASCII art → browser HTML mockups, always.
