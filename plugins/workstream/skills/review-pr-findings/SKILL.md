---
name: review-pr-findings
description: >-
  Use when a PR has review feedback to work through — human reviewer comments, bot
  findings, SonarQube gate failures, or failing CI checks — and the goal is to get
  the PR to green with every thread resolved. Triggers: "check the findings in the
  PR", "assess the feedback", pasted bot/Sonar finding text, "CI is failing", or
  repeated finding rounds ("going in circles").
---

# PR Findings Triage

## Overview

Assess every piece of PR feedback adversarially before touching code. A finding is a
claim, not an instruction: fix it only if it is valid, otherwise reply with a
justification and resolve it. Loop until CI is green and no unresolved threads remain.

**Never blindly apply a finding.** Bots and reviewers are wrong regularly; blindly
"fixing" invalid findings creates new findings and infinite review loops.

Scope boundary: this skill does not announce, watch, or merge — that is `ship`.

## Step 0 — Identify the target PR

If a PR number or URL was passed as an argument, use it. Otherwise use the open PR
for the current branch (`gh pr view`). No PR found → ask the user.

## Step 1 — Gather everything in ONE pass

Do not work from only what the user pasted. Fetch the full picture:

```bash
gh pr view <N> --json state,statusCheckRollup,reviews
gh api repos/{owner}/{repo}/pulls/<N>/comments --paginate   # inline review comments
gh api repos/{owner}/{repo}/issues/<N>/comments --paginate  # top-level comments (bots post here)
gh pr checks <N>
```

Collect: unresolved reviewer comments, bot findings, quality-gate failures, failing
CI checks. Deduplicate against the ledger (Step 2).

Thread resolution state is only visible via GraphQL — `gh api graphql` querying
`pullRequest.reviewThreads { isResolved }`; resolving a thread uses the
`resolveReviewThread` mutation. The REST comment endpoints above don't expose it.

## Step 2 — Persistent triage ledger (survives compaction and sessions)

Maintain `~/.claude/workstream/pr-ledgers/<owner>-<repo>-pr<N>.md` (create the directory
if missing; `<owner>` and `<repo>` come from the GitHub slug — the owner prefix
keeps same-named repos in different orgs from colliding): one row per finding —
`finding → round first seen → verdict → action → resolution`. Before assessing
anything, Read the ledger. If a finding (or a close variant) was already assessed in
a previous round, do NOT re-fix it — reply pointing at the prior resolution. This is
what prevents going in circles. Update the ledger after every verdict and every
push. The ledger is deleted by whoever merges the PR (`ship`/`merge-pr`), not here.

## Step 3 — Adversarial assessment (subagents)

For each NEW finding, dispatch a subagent (inherit the session model — do not
downgrade; verdicts are the judgment-heavy step) whose job is to argue BOTH sides
against the actual code: (a) steelman the finding with a concrete failure scenario,
(b) try to refute it. Verdict: VALID / INVALID / NEEDS-USER-DECISION. Batch small
related findings into one subagent; keep independent subagents parallel.

Anything judgment-heavy (architecture trade-offs, scope questions) → present to the
user with your recommendation before acting. If this skill is itself running inside
a subagent and cannot reach the user, return NEEDS-USER-DECISION findings unresolved
in the final report instead of guessing.

## Step 4 — Act on verdicts

- **VALID** → fix it. Mechanical fixes can go to a cheaper-model subagent; behavior
  changes need a test first (superpowers:test-driven-development) and targeted tests
  after — run only the test paths covering the touched modules, never the bare full
  suite.
- **INVALID** → reply on the thread with a short technical justification and resolve
  it. Do not soften the reply into agreement.

## Step 5 — Post replies safely

- Heredoc-quote comment bodies (`gh pr comment ... --body-file - <<'EOF'`), never
  backslash-escape backticks.
- Inline replies: `gh api repos/{owner}/{repo}/pulls/<N>/comments/<id>/replies`.
  On **HTTP 422** ("Line/Path could not be resolved") fall back to a top-level
  comment quoting `file:line` — do not retry the inline call.
- On **"one pending review per pull request"**: submit or delete the pending review
  first (`gh api .../pulls/<N>/reviews` to find it).

## Step 6 — Verify, push, loop until green

Discover the repo's verification commands — check `package.json` scripts, `Makefile`
targets, and the project's CLAUDE.md for format/lint, test, type-check, and build
commands. Then, each as its own step:

1. Format/lint scoped to touched paths.
2. Targeted tests for the touched modules.
3. Type-check (if the repo has one).
4. Build (only when the repo's config makes build-only errors likely, e.g. route or
   config changes in a framework with a compile step).
5. Commit ALL of this round's fixes, then push **once**.

**One push per round, never per finding.** Fix every VALID finding of the current
round, verify locally, and push a single time. Each push to a ready PR re-triggers
the full CI run, so pushing finding-by-finding multiplies CI minutes for no benefit.

Re-run Step 1. New findings triggered by the push go through the same ledger. When
CI is green and no unresolved threads remain, post ONE short summary comment (2–4
sentences: what was fixed, what was rejected and why), then report completion.

## Red flags

- Fixing a finding without a verdict recorded → stop, assess first.
- The same finding text appearing in the ledger from a prior round → reply, don't re-fix.
- "The bot is probably right" → the bot has been wrong; assess it.
- Running the repo's full test suite instead of targeted paths.
- Pushing fixes one finding at a time — batch the whole round into a single push.
- Long approval essay → short notes, always.
