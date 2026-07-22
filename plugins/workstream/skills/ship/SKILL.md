---
name: ship
description: >-
  Use when a PR is open and should be driven to merge — "ship it", "ship the
  ticket", "merge when green", "run the PR endgame", or after
  superpowers:finishing-a-development-branch produced a PR. Runs the full tail:
  draft self-review → mark ready (the CI trigger) → CI watch → findings triage
  loop → watch-until-approved loop (with main sync) → merge-pr.
---

# Ship (PR endgame)

## Overview

Drives an open PR from "pushed" to "merged" with exactly one user checkpoint (the
merge confirmation — skippable if pre-authorized).

**CI minutes are the scarce resource.** Every push to a ready PR re-triggers the
full CI run (build + a Postgres-backed boot smoke). So ship does all of its own
work while the PR is a **draft** — where CI is gated off (`if: draft == false`) and
pushes cost zero minutes — and only marks the PR **ready-for-review** once the self
review is applied and local verification passes. Marking ready IS the moment CI
first runs, and by then it runs on already-verified code, so it runs about once.

Fixed order: preflight (ensure draft) → self review on the draft → local verify +
**one batched push** + mark ready → CI green → findings loop → watch → merge. Never
merge before the review has run and its findings are resolved.

Ship is an orchestrator: the triage/reply mechanics live in `review-pr-findings`,
the merge mechanics in `merge-pr`. Do not duplicate their instructions here.

Arguments: an optional PR number/URL, and optional `--auto-merge`. Auto-merge
changes what counts as the approval signal: instead of waiting for a human PR
approval, **CI green + every finding resolved** (self review applied, findings loop
finished with no unresolved threads) IS the approval — ship skips the
watch-for-approval loop and the merge confirmation and hands off to `merge-pr`
directly. Treat an explicit user instruction like "ship it without asking" the same
way.

Auto-merge can also be enabled per repo without passing the flag, via
`~/.claude/workstream/ship-config.json`:

```json
{ "<owner>/<repo>": { "auto_merge": true } }
```

Resolution order: explicit `--auto-merge` flag or user instruction → config entry →
default (off). When the user says to always auto-merge a repo, create/update the
entry (create the file/directory if missing).

## Batch-push rule (applies to every step)

CI re-runs on each push to a ready PR. Within any fix phase — the self review and
each findings round — make ALL the commits for that phase locally, verify once, then
**push a single time**. Never commit-push-commit-push finding by finding; that
multiplies CI runs. On a draft the push is free regardless, which is exactly why the
self-review fixes go in before the PR is marked ready.

## Step 1 — Preflight

```bash
gh pr view <N> --json number,state,isDraft,headRefName,statusCheckRollup
```

Confirm the branch is pushed and the PR is open. If CI shows an unfixable blocker
(e.g. a billing/limits message), surface it immediately and stop.

**Ensure the PR is a draft before doing any work.** The self review and its fixes
must land while CI is gated off:

- Already a draft → good. (Ideally the PR was created with `gh pr create --draft`,
  so even the `opened` event costs nothing.)
- Marked ready → convert it back to draft now: `gh pr ready <N> --undo`. Everything
  ship does next is a draft-phase activity.

**Do NOT transition the Jira ticket yet.** In Review is for a ready PR — ship moves
the ticket to In Review in Step 3, at the same moment it marks the PR ready. (work-on
owns In Progress; merge-pr owns Done.)

**Stand in the PR's workspace.** Later steps run local verification and `git push`
from wherever this session sits:

- `git branch --show-current` equals the PR's `headRefName` → you're in the right
  place (a `work-on` worktree or a plain checkout; either is fine).
- Otherwise find the branch's worktree with `git worktree list` and enter it
  (`EnterWorktree` with that path, or `cd`). Only fall back to
  `git checkout <headRefName>` on the shared checkout when no worktree exists.

## Step 2 — Self code review on the draft (subagent)

Dispatch a subagent that invokes the `code-review` skill against this PR, so ship's
context stays lean. Apply its valid findings locally. No CI is needed for this — the
review reads the diff, not a CI run — which is why it happens on the draft before any
minutes are spent. Batch all fixes per the batch-push rule; do not push per finding.

**This step is a gate on Step 3.** Step 2 is complete only when the self review has
returned AND every valid finding it raised is fixed and applied locally. Do not
advance to Step 3 — and therefore do not mark the PR ready — while the review is
still running or any valid finding is unfixed. A finding that needs a user decision
blocks the gate: surface it with your recommendation and wait; never mark the PR
ready with a valid or undecided self-review finding still open.

## Step 3 — Local verify, batch push, mark ready

**Precondition:** Step 2 is fully complete — the self review returned and every valid
finding is fixed and applied locally (nothing open, nothing awaiting a user
decision). If that is not true, go back to Step 2; do not mark the PR ready.

Before spending the first CI run, reproduce the CI gates locally so the run passes
first try. Discover the repo's commands (its CLAUDE.md / `package.json` scripts /
`Makefile`) and run them each as its own step — typically format/lint, type-check,
unit tests, build; add migration/emoji-compile checks if the repo's CI has them.
Fix anything they surface (still on the draft, still batched).

**When the self review's fixes touch UI** (components, styles, layout, ARIA/roles,
any visual/interactive surface), verification also includes driving the affected
flow in a real browser — the repo's Playwright/e2e specs for the touched surface,
or the `verify`/browser-smoke skill. Green lint/tests/type-check/build do not prove
a UI renders or behaves correctly; they miss render and interaction regressions.
This runs on the draft too, so it costs zero CI minutes.

Then, in order:

1. **One batched push** of every self-review + verification fix.
2. `gh pr ready <N>` — this marks the PR ready-for-review and is the single event
   that first triggers CI (and the bot/Sonar reviewers).
3. **Now** transition the linked Jira ticket to **In Review** (this is the step
   nothing else performs): parse the ticket key from the PR's `headRefName`
   (`[A-Za-z]+-[0-9]+`, case-insensitive, uppercased; fall back to title/body) and
   transition via `jira-writer:jira-writer` — unless the ticket is already In Review
   or later; never move a ticket backward. No key found → skip and note it.

## Step 4 — Wait for CI

Watch checks in a background Bash call (`gh pr checks <N> --watch`). Exit code 8
means checks are still pending — not a failure. Do not start the findings loop until
CI is green. Because Step 3 verified locally first, this run should be green with no
further pushes.

## Step 5 — Findings loop (subagent)

Dispatch a subagent that invokes the `review-pr-findings` skill for this PR. It owns
the gather → ledger → adversarial triage → fix/reply → verify/push loop and returns
when CI is green with no unresolved threads. Each of its fix rounds is one batched
push (a legitimate CI re-run only when a real finding needed a code change).

The subagent cannot talk to the user: it returns NEEDS-USER-DECISION findings
unresolved. Present those to the user with your recommendation, then re-dispatch the
subagent with the decisions. Repeat until nothing is unresolved.

## Step 6 — Watch until approved (in-session loop)

**Auto-merge bypass — of the approval WAIT only, never of the gates:** when
auto-merge is active (flag, user instruction, or config), skip this loop. What is
bypassed is waiting for a human `APPROVED` review — nothing else. Steps 2–5 are
non-negotiable prerequisites in every mode: do NOT enter Step 7 unless CI is green,
the self code review (Step 2) ran and its valid findings were applied, and the
findings loop (Step 5) finished with every finding — yours and anyone else's —
resolved and no unresolved threads. If any of that is not true, there is no
approval signal and nothing merges. When it is all true, run the base-branch sync
check (item 2) once, then proceed to Step 7 — which, as always, hands off to the
`merge-pr` skill; ship never performs the merge itself.

Self-schedule a wakeup roughly every 20 minutes (use the session's scheduled-wakeup
/loop mechanism; if unavailable, tell the user to re-run `/workstream:ship` to resume —
the ledger and PR state make resumption idempotent). On each wake:

1. **New feedback?** Gather reviews/comments/checks; if anything new, run Step 5
   again (findings subagent + ledger).
2. **Behind the base branch?** Resolve it once
   (`BASE=$(gh pr view <N> --json baseRefName --jq '.baseRefName')`), then
   `git fetch origin && git rev-list --count HEAD..origin/$BASE` — if behind, merge
   `origin/$BASE` into the branch and push. Conflicts → stop the loop and escalate
   to the user.
3. **Approved?** `gh pr view <N> --json reviewDecision` — on `APPROVED` with green
   CI and no unresolved threads, proceed to Step 7.

## Step 7 — Merge (the ONE user checkpoint)

- Ask the user once: "green + reviewed + approved — merge PR <N>?" Skip the question
  when auto-merge is active (flag, explicit "ship it without asking", or the
  per-repo config entry).
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

- Marking a PR ready (or leaving it ready) before the self review has run, while it
  is still running, or with any valid/undecided self-review finding still open — mark
  ready only once Step 2 is complete and every fix is applied and pushed. The self
  review belongs on the draft, where its fix pushes cost no CI minutes.
- Pushing self-review or findings fixes one commit at a time — batch each phase into
  a single push; every extra push to a ready PR is another full CI run.
- Transitioning the ticket to In Review while the PR is still a draft — In Review
  pairs with marking the PR ready in Step 3.
- Running the findings loop or watching before CI is green, or merging before the
  review ran.
- Inlining triage/reply mechanics instead of delegating to `review-pr-findings`.
- Guessing a NEEDS-USER-DECISION verdict instead of surfacing it.
- Marking a UI change ready or "verified" on green lint/tests/type-check alone —
  drive it in a browser first; those checks miss render/interaction/ARIA regressions.
- Merging while behind the base branch or with unresolved threads.
- Waiting for a human PR approval while auto-merge is active — there, CI green +
  all findings resolved IS the approval signal.
- Treating auto-merge as permission to skip Steps 2–5 — it only skips the approval
  wait; merging with failing CI, an un-run self review, or any unresolved finding
  is never allowed, in any mode.
- Auto-merging without checking `ship-config.json` when no flag was passed — the
  per-repo config is part of the resolution order.
