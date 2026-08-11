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

## Step 0 — Identify the target: repository, PR number, workspace

A PR number is not an identifier — `#66` exists in every repository you have worked
in, and `gh` resolves which one from the current directory. This skill **pushes
commits and posts comments**, so a wrong target does not merely read the wrong
project, it writes to it.

Resolve all three in one call, before anything else:

```bash
WT=<absolute path to the PR's workspace>    # ship passes this
REPO=$(git -C "$WT" remote get-url origin \
        | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^/]*@##; s#^[^/:]+(:[0-9]+)?[:/]##; s#/+$##; s#\.git$##')
# Empty would be silently accepted by `gh --repo ""`, which then falls back to cwd.
[ -n "$REPO" ] || { echo "ABORT: no origin remote resolvable from $WT"; exit 1; }
echo "target: $REPO#<N> in $WT"
```

**Record the repo, PR number and workspace as literals and substitute them textually
below — do not carry them in shell variables.** Shell state does not survive between
calls, so a `$REPO` set here is empty in the next one, and `gh --repo ""` does not
error: it resolves from cwd, which is exactly what this step exists to distrust.

Scoping differs by command family, because `gh` is not uniform:

| Command | How the repo is carried |
|---|---|
| `gh pr *` | `--repo <owner>/<repo>` |
| `gh api` (REST) | interpolate the slug into the path — there is **no** `--repo` flag |
| `gh api graphql` | neither works: pass query variables, `-F owner=<owner> -F name=<repo>` |
| `git` | `-C <workspace>` |

Confirm the PR's `headRefName` matches the branch checked out in the workspace before
acting — if it does not, stop and report rather than guessing.

### When nothing was passed

`ship` always passes the triple. When something else invoked this skill and did not,
cwd is a **candidate to be verified, never an answer** — and the bar here is the same
as `merge-pr`'s, not lower. It is arguably higher: `merge-pr` performs one
irreversible act, while this skill pushes commits, posts comments and resolves
threads, so a wrong target writes to another project repeatedly, under the user's own
account, before anyone notices.

Announcing the resolved repository is **not** a substitute for verifying it. A report
naming the wrong repo is still a wrong-repo write; it just documents itself.

```bash
CAND=$(git rev-parse --show-toplevel) || { echo "ABORT: cwd is not a git repo"; exit 1; }
CAND_REPO=$(git -C "$CAND" remote get-url origin \
        | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^/]*@##; s#^[^/:]+(:[0-9]+)?[:/]##; s#/+$##; s#\.git$##')
[ -n "$CAND_REPO" ] || { echo "ABORT: no origin remote in $CAND"; exit 1; }

# The PR must exist in THIS repository, and its branch must be checked out HERE.
BRANCH=$(gh pr view <N> --repo "$CAND_REPO" --json headRefName --jq '.headRefName') \
  || { echo "ABORT: $CAND_REPO has no PR <N>"; exit 1; }
[ "$(git -C "$CAND" branch --show-current)" = "$BRANCH" ] \
  || { echo "ABORT: $CAND is on $(git -C "$CAND" branch --show-current), not $BRANCH"; exit 1; }

echo "resolved: $CAND_REPO in $CAND"   # record both as literals
```

With no PR number either, resolve the open PR for the branch checked out in `$CAND`
(`gh pr view "$(git -C "$CAND" branch --show-current)" --repo "$CAND_REPO"`) and run
the same checks against the result. No PR found, or any check above failing → **stop
and ask the user.** Do not fall back to cwd.

## Step 1 — Gather everything in ONE pass

Do not work from only what the user pasted. Fetch the full picture:

```bash
gh pr view <N> --repo <owner>/<repo> --json state,statusCheckRollup,reviews
gh api "repos/<owner>/<repo>/pulls/<N>/comments" --paginate    # inline review comments
gh api "repos/<owner>/<repo>/issues/<N>/comments" --paginate   # top-level comments (bots post here)
gh pr checks <N> --repo <owner>/<repo>
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

- Heredoc-quote comment bodies (`gh pr comment <N> --repo <owner>/<repo> --body-file - <<'EOF'`), never
  backslash-escape backticks.
- Inline replies: `gh api "repos/<owner>/<repo>/pulls/<N>/comments/<id>/replies"`.
  On **HTTP 422** ("Line/Path could not be resolved") fall back to a top-level
  comment quoting `file:line` — do not retry the inline call.
- On **"one pending review per pull request"**: submit or delete the pending review
  first (`gh api "repos/<owner>/<repo>/pulls/<N>/reviews"` to find it).

## Step 6 — Verify, push, loop until green

Discover the repo's verification commands — check `package.json` scripts, `Makefile`
targets, and the project's CLAUDE.md for format/lint, test, type-check, and build
commands. Then, each as its own step:

1. Format/lint scoped to touched paths.
2. Targeted tests for the touched modules.
3. Type-check (if the repo has one).
4. Build (only when the repo's config makes build-only errors likely, e.g. route or
   config changes in a framework with a compile step).
5. **Browser verification — mandatory when the fix touches UI.** If the fix touched
   a component, styles, layout, ARIA/roles, or any visual/interactive surface,
   green lint/tests/type-check/build are NOT sufficient proof — they routinely miss
   render regressions, broken interactions, and accessibility/role changes (exactly
   the class of bug that trips Sonar a11y rules). Drive the affected flow in a real
   browser and observe the actual render + behavior: use the repo's Playwright/e2e
   setup (run only the specs covering the touched surface, never the whole e2e
   suite), or the `verify` skill / a browser-smoke skill if the repo has one. A UI
   finding is not "fixed" until this passes — it is a precondition for the Step 5
   proof-of-fix resolve, not just for CI.
6. Commit ALL of this round's fixes, then push **once**.

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
- Calling a UI fix "verified" on green tests/type-check alone — drive it in a
  browser; those checks miss render/interaction/ARIA regressions.
- Pushing fixes one finding at a time — batch the whole round into a single push.
- Long approval essay → short notes, always.
