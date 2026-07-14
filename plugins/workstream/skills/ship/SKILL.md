---
name: ship
description: >-
  Use when a PR is open and should be driven to merge — "ship it", "ship the
  ticket", "merge when green", "run the PR endgame", or after
  superpowers:finishing-a-development-branch produced a PR. Runs the full tail:
  CI watch → self code review → findings triage loop → watch-until-approved
  loop (with main sync) → merge-pr.
---

# Ship (PR endgame)

## Overview

Drives an open PR from "pushed" to "merged" with exactly one user checkpoint (the
merge confirmation — skippable if pre-authorized). Order is fixed: CI green FIRST,
then self review, then the findings loop, then watch, then merge.
Never merge before the review has run and its findings are resolved.

Ship is an orchestrator: the triage/reply mechanics live in `review-pr-findings`,
the merge mechanics in `merge-pr`. Do not duplicate their instructions here.

Arguments: an optional PR number/URL, and optional `--auto-merge` (merge unattended
on approval — treat an explicit user instruction like "ship it without asking" the
same way).

## Step 1 — Preflight

```bash
gh pr view <N> --json number,state,headRefName,statusCheckRollup
```

Confirm the branch is pushed and the PR is open. If CI shows an unfixable blocker
(e.g. a billing/limits message), surface it immediately and stop.

**Stand in the PR's workspace.** Later steps run local verification and `git push`
from wherever this session sits:

- `git branch --show-current` equals the PR's `headRefName` → you're in the right
  place (a `work-on` worktree or a plain checkout; either is fine).
- Otherwise find the branch's worktree with `git worktree list` and enter it
  (`EnterWorktree` with that path, or `cd`). Only fall back to
  `git checkout <headRefName>` on the shared checkout when no worktree exists.

## Step 2 — Wait for CI

Watch checks in a background Bash call (`gh pr checks <N> --watch`). Exit code 8
means checks are still pending — not a failure. Do not start the review until CI is
green.

## Step 3 — Self code review (subagent)

Dispatch a subagent that invokes the `code-review` skill against this PR, so
ship's context stays lean. Apply its valid findings (fix, verify, push) before
asking anyone else to look. A push restarts Step 2.

## Step 4 — Findings loop (subagent)

Dispatch a subagent that invokes the `review-pr-findings` skill for this PR. It owns
the gather → ledger → adversarial triage → fix/reply → verify/push loop and returns
when CI is green with no unresolved threads.

The subagent cannot talk to the user: it returns NEEDS-USER-DECISION findings
unresolved. Present those to the user with your recommendation, then re-dispatch the
subagent with the decisions. Repeat until nothing is unresolved.

## Step 5 — Watch until approved (in-session loop)

Self-schedule a wakeup roughly every 20 minutes (use the session's scheduled-wakeup
/loop mechanism; if unavailable, tell the user to re-run `/workstream:ship` to resume —
the ledger and PR state make resumption idempotent). On each wake:

1. **New feedback?** Gather reviews/comments/checks; if anything new, run Step 4
   again (findings subagent + ledger).
2. **Behind the base branch?** Resolve it once
   (`BASE=$(gh pr view <N> --json baseRefName --jq '.baseRefName')`), then
   `git fetch origin && git rev-list --count HEAD..origin/$BASE` — if behind, merge
   `origin/$BASE` into the branch and push. Conflicts → stop the loop and escalate
   to the user.
3. **Approved?** `gh pr view <N> --json reviewDecision` — on `APPROVED` with green
   CI and no unresolved threads, proceed to Step 6.

## Step 6 — Merge (the ONE user checkpoint)

- Ask the user once: "green + reviewed + approved — merge PR <N>?" Skip the question
  only when pre-authorized (`--auto-merge` or an explicit "ship it without asking").
- On yes: invoke the `merge-pr` skill with the PR number — it owns squash merge,
  worktree/branch cleanup, default-branch pull, and the Jira transition to Done. Do not
  duplicate any of those steps here.
- Post ONE short summary comment on the PR (2–4 sentences: what was fixed, what was
  rejected and why) — unless the findings subagent already posted one this round;
  never double-post.
- Delete the ledger `~/.claude/workstream/pr-ledgers/<owner>-<repo>-pr<N>.md`.
- If this session was inside the worktree merge-pr removed, call
  `ExitWorktree action: keep` to return to the original checkout (a no-op if you
  never entered a worktree).

## Red flags

- Running the review before CI is green, or merging before the review ran.
- Inlining triage/reply mechanics instead of delegating to `review-pr-findings`.
- Guessing a NEEDS-USER-DECISION verdict instead of surfacing it.
- Merging while behind the base branch or with unresolved threads.
