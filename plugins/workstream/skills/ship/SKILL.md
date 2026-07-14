---
name: ship
description: >-
  Use when a PR is open and should be driven to merge — "ship it", "ship the
  ticket", "merge when green", "run the PR endgame", or after
  superpowers:finishing-a-development-branch produced a PR. Runs the full tail:
  CI watch → self code review → findings triage loop → Slack announcement →
  watch-until-approved loop (with main sync) → merge-pr.
---

# Ship (PR endgame)

## Overview

Drives an open PR from "pushed" to "merged" with exactly one user checkpoint (the
merge confirmation — skippable if pre-authorized). Order is fixed: CI green FIRST,
then self review, then the findings loop, then announce, then watch, then merge.
Never merge before the review has run and its findings are resolved.

Ship is an orchestrator: the triage/reply mechanics live in `review-pr-findings`,
the merge mechanics in `merge-pr`. Do not duplicate their instructions here.

Arguments: an optional PR number/URL, optional `--auto-merge` (merge unattended on
approval — treat an explicit user instruction like "ship it without asking" the
same way), and optional `--no-msg` (skip the Slack announcement and all Slack
thread replies for this PR).

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

## Step 5 — Slack announcement (at most ONCE per PR)

Skip this step entirely when `--no-msg` was passed.

The announcement goes out exactly once, when the PR first becomes ready for review —
never again on later loop rounds or resumed runs. Before posting, check the PR's
ledger (`~/.claude/workstream/pr-ledgers/<owner>-<repo>-pr<N>.md`) for a recorded
announcement permalink: if one exists, the announcement was already sent — do not
post another. After posting, record the message permalink/timestamp in the ledger;
Step 6 uses it as the thread to reply into.

Announce the PR is ready for review. Channel resolution is per-user and per-repo via
`~/.claude/workstream/ship-config.json`:

```json
{ "<owner>/<repo>": { "channels": ["#team-reviews"], "last_used": "#team-reviews" } }
```

- No entry for this repo → ask the user which channel to use, then create the entry
  (create the file/directory if missing).
- One saved channel → use it, telling the user which.
- Multiple saved channels → present the list (default: `last_used`), let the user
  pick, update `last_used`. A new channel answer gets appended to `channels`.

Post via the Slack MCP tools: a short message — PR title, link, one-line summary,
"ready for review". Slack MCP not connected, or the user declines → note it and
continue; the announcement is optional, never a blocker.

## Step 6 — Watch until approved (in-session loop)

Self-schedule a wakeup roughly every 20 minutes (use the session's scheduled-wakeup
/loop mechanism; if unavailable, tell the user to re-run `/workstream:ship` to resume —
the ledger and PR state make resumption idempotent). On each wake:

1. **New feedback?** Gather reviews/comments/checks; if anything new, run Step 4
   again (findings subagent + ledger). Then decide whether to reply in the Slack
   announcement thread (permalink recorded in the ledger by Step 5):
   - **Human reviewer** → post a short reply in the thread (e.g. "addressing
     <reviewer>'s feedback, will push shortly" — and a follow-up when pushed).
   - **Bot author** (GitHub `user.type == "Bot"` or login ending in `[bot]`, e.g.
     `gitstream-cm[bot]`, `github-actions[bot]`) → handle the findings silently;
     never post to Slack for bot feedback.
   - No thread replies at all when `--no-msg` was passed or no announcement was
     posted.
2. **Behind the base branch?** Resolve it once
   (`BASE=$(gh pr view <N> --json baseRefName --jq '.baseRefName')`), then
   `git fetch origin && git rev-list --count HEAD..origin/$BASE` — if behind, merge
   `origin/$BASE` into the branch and push. Conflicts → stop the loop and escalate
   to the user.
3. **Approved?** `gh pr view <N> --json reviewDecision` — on `APPROVED` with green
   CI and no unresolved threads, proceed to Step 7.

## Step 7 — Merge (the ONE user checkpoint)

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
- Posting to Slack without a channel confirmed for this repo.
- Re-posting the announcement on a later round or resumed run — it goes out once;
  everything after is a reply in its thread.
- Slack replies about bot findings — Slack hears about human feedback only.
- Merging while behind the base branch or with unresolved threads.
