---
name: merge-pr
description: >-
  Use when the user asks to "merge the PR", "squash and merge", "complete the
  merge", "finish the PR", or an orchestrating skill (ship) hands off a PR that is
  approved and green. Runs the full merge checklist — verify CI, re-check every
  merge blocker at the instant of merging, squash merge, tear down the worktree or
  local branch, pull main, and move the linked Jira ticket to Done. Pass the repo-qualified PR and a ticket key
  (`merge-pr owner/repo#123 PROJ-456`, or `merge-pr owner/repo#123 <workspace>
  PROJ-456`) to close it; a key found only in the branch name is reported, not
  transitioned.
context: fork
agent: general-purpose
---

# PR Merge Workflow

Execute the full merge checklist for an open, ready pull request. Always follow all
steps in order.

This skill runs in a forked subagent with no conversation history, so it cannot
infer which PR is meant from earlier chat — resolve the target explicitly first.

## Step 0: Identify the target — repository, PR number, workspace, and the supplied ticket key

### The invocation arguments

**Everything the caller passed arrives here, and nowhere else:**

```text
arguments: $ARGUMENTS
```

This block is not a convenience — it is the **only** channel. This skill runs in a
forked subagent with no conversation history, so there is no user message to re-read
and no earlier turn to consult: an argument that is not interpolated above did not
reach this run at all. Read that line *before* forming any belief about what the
caller supplied.

An **empty** value after `arguments:` means the skill genuinely was invoked with
none — take the bootstrap row of the table below. A **non-empty** value is the token
list that §"The supplied ticket key" parses, and the repo-qualified target that the
rest of this step resolves from.

**There is a third state, and it is not "non-empty".** If the line still reads
literally `arguments: $ARGUMENTS`, with the token undisturbed, then this harness does
not interpolate skill bodies at all — **treat it exactly as empty and take the
bootstrap row.** Never try to parse the token itself as a target: it matches none of
the four accepted PR forms, and reading it as a supplied argument would deny this run
the cwd bootstrap it should have fallen back to. Claude Code interpolates; other
harnesses this plugin supports may not.

Two consequences worth stating, because both have already cost a run:

- **Never report "no arguments were supplied" without quoting that line.** It is
  cheap to check and it is the difference between a correct cwd bootstrap and one
  that silently ignored a target the caller named.
- **An unbraced positional token anywhere in this file is rewritten with the
  caller's arguments before this agent ever sees it.** Substitution is 0-indexed:
  the unbraced token — spelled `${0}` throughout this paragraph so that it survives
  to be read — resolves to the *first* argument, `${1}` to the second. Out-of-range
  tokens are left as literal text, so the damage depends on how many arguments were
  passed.
  Backticks do not protect it; a code span is rewritten exactly like prose. That is
  why no shell snippet below uses `awk`, whose field references are spelled the same
  way: a three-argument invocation would splice the PR target into the middle of an
  awk program. **When editing this file, write positional tokens braced** — the
  braced form is passed through untouched, which is why the ones in this paragraph
  survive to be read. Keep the snippets free of them either way.

**A PR number is not an identifier.** `#123` exists in every repository you have ever
worked in, and `gh` decides which one it means from the **current working
directory** — which this skill does not control. A forked subagent inherits neither
the conversation nor the caller's directory, so the cwd it starts in may belong to an
entirely different project. A bare `gh pr merge 123` there merges *that* project's PR
123, and the merge is irreversible.

This is not a hypothetical failure mode. It is the default one whenever the session
was launched from a different repo than the work lives in — normal for cross-repo
tickets, and for anything `goal-on` moved into a worktree. Watch for the shape of the
mistake, because it is easy to make while believing you have avoided it: warning that
the PR *number* cannot be inferred from context, and then resolving the *repository*
by exactly the mechanism you just rejected.

The ledger path already spells identity correctly — `<owner>-<repo>-pr<N>`. Every
command below uses those same parts, plus the workspace.

**Start by asking what the caller gave you. The order of everything else follows from
that answer, and getting it backwards strands the recovery path this skill documents.**

| The invocation supplied | Resolve in this order |
|---|---|
| A repo-qualified target — `<owner>/<repo>#<N>` or a GitHub PR URL | **A.** Repository + number from the argument → **B.** PR state (the already-merged check) → **C.** workspace, *only if* the PR is open or teardown is still pending |
| A bare number, or nothing | **A.** Workspace, via the cwd bootstrap → **B.** repository, from the workspace's `origin` → **C.** PR state |

A repo-qualified argument already carries the repository, so nothing about resolving
it needs a workspace — and on a merged PR there may not be one left to find. That is
not a corner case: it is exactly the state Step 5's documented recovery re-runs from,
after teardown has put cwd on the default branch and deleted the topic branch.
Demanding a workspace first aborts there every time.

A bare number carries no repository, so the bootstrap is the only way to get one.

### Resolving the repository and workspace

When the workspace is known — ship passes it, or the bootstrap below produced it —
derive the repository **from it**, in one bash call:

```bash
# The workspace: where the PR's branch is checked out and was verified.
WT=<absolute path>

# The repository — resolved FROM THE WORKSPACE, never from cwd.
# Handles scp-style, https, ssh:// and scheme+port remotes alike, and refuses
# to continue on an empty answer (see "Empty is not safe" below).
REPO=$(git -C "$WT" remote get-url origin \
        | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^/]*@##; s#^[^/:]+(:[0-9]+)?[:/]##; s#/+$##; s#\.git$##')
[ -n "$REPO" ] || { echo "ABORT: no origin remote resolvable from $WT"; exit 1; }

echo "repo: $REPO  workspace: $WT"
```

When the argument was repo-qualified, this block **verifies** rather than discovers:
the slug it produces must match the one the caller named, and a disagreement is a
stop. It is skipped entirely on the already-merged path, where there is no workspace.

**Record `<owner>/<repo>`, the PR number, and the workspace path as literals, and
substitute them textually into every command below. Do not carry them in shell
variables** — shell state does not survive between calls, so a `$REPO` set here is
**empty** by Step 3, and an empty value is the one thing that must never reach `gh`
(see "Empty is not safe"). The variables above are scratch names inside a single
call; the values are what you carry forward. This is the same rule that already
governs the PR number, and for the same reason Step 5 re-derives the branch instead
of reusing Step 4's.

From here on **every command carries its target explicitly**: `gh` commands take
`--repo <owner>/<repo>`, `git` commands take `-C <workspace>`. A bare `gh pr` or
`git` command anywhere below this line is a bug.

### Resolving the PR number

- **Two argument forms are repo-qualified, and both are binding:**
  `<owner>/<repo>#<N>`, and a GitHub PR URL — `https://github.com/<owner>/<repo>/pull/<N>`
  names its repository just as explicitly. Parse the slug **and** the number out of
  either, and in both cases, when the slug disagrees with the repository resolved
  from the workspace, **stop**: the caller and the workspace are describing different
  targets.

  Treating a URL as merely a source for the number is a live hole, not a nicety.
  `merge-pr https://github.com/B/repo/pull/60 <workspace in A>` would derive repo A
  from the workspace and silently discard the `B` the caller actually named — and if
  A also has a PR 60, the run proceeds confidently against the wrong one. That is the
  precise failure this step exists to prevent, arriving through the argument that
  looks *most* explicit.
- A bare number supplies no repository; it takes the one resolved from the workspace.
- Otherwise, resolve the PR for the branch checked out in the workspace, before
  anything else runs:

  ```bash
  # gh pr view takes a number, URL, OR branch name as its positional argument.
  # Naming the branch is what keeps this from resolving against cwd's HEAD.
  gh pr view "$(git -C <workspace> branch --show-current)" --repo <owner>/<repo> \
    --json number,headRefName --jq '"\(.number) \(.headRefName)"'
  ```

  Step 4 checks out the default branch, so from Step 5 onward a *bare* `gh pr`
  command resolves against `$DEFAULT`, not this PR — it either exits non-zero with
  "no pull requests found for branch main", which trips Step 5's empty-`BRANCH` stop
  and strands the ticket, or, in a repo with an open PR whose head *is* the default
  branch, silently returns the **wrong** PR: a non-empty branch name that clears the
  guard while disabling the P2 contradiction check.

  No PR found → **stop here** and report; there is no target.

### The guard that actually holds

`--repo` is only ever as correct as whatever resolved it, and resolution is the step
that fails. So do not rely on it alone. Before the merge in Step 3, assert that the
commit GitHub is about to merge is the exact commit this workspace verified:

```bash
PR_HEAD=$(gh pr view <N> --repo <owner>/<repo> --json headRefOid --jq '.headRefOid')
LOCAL_HEAD=$(git -C <workspace> rev-parse HEAD)

# Empty is not a match — see below. Check it before the comparison, not after.
if [ -z "$PR_HEAD" ] || [ -z "$LOCAL_HEAD" ]; then
  echo "ABORT: could not read both heads (PR_HEAD='$PR_HEAD' LOCAL_HEAD='$LOCAL_HEAD')"
  exit 1
fi

if [ "$PR_HEAD" != "$LOCAL_HEAD" ]; then
  echo "ABORT: PR head $PR_HEAD is not the workspace head $LOCAL_HEAD"
  exit 1
fi
```

A mismatch means one of exactly two things, and both are stop conditions:

1. **The target is the wrong repository.** Two unrelated repos cannot share a head
   SHA, so once both values are known to be non-empty this fails closed however badly
   the target was resolved — the property `--repo` alone cannot give you.
2. **The branch moved after it was verified.** Someone pushed while the gates were
   running, so merging now lands code no review and no CI has seen. This is the more
   likely failure on a repo you *are* standing in, and it matters most under ship's
   `--auto-merge`, where nothing else is watching.

This comparison is not run on its own before the merge. **Step 3's gate performs it**,
in the same call that reads the review threads and the checks, so all of them describe
one instant. Run it standalone here only as pre-flight — to fail fast on a wrong target
before Steps 1 and 2 do any work. A pre-flight pass is never what authorises the merge;
only the gate's own reading is.

**Scope of the assertion — it gates Step 3, not the whole run.** On the already-merged
fast path below there is no merge to gate, and the workspace may legitimately be gone
or back on the default branch, so a head comparison there would abort exactly the
bookkeeping re-run that path exists to allow. What protects Step 4 instead is its own
check that the workspace holds `$BRANCH` (`git worktree list` / `branch --show-current`)
— never delete a branch in a workspace that does not have it checked out.

#### Empty is not safe

The emptiness check above is not defensive padding; without it the guard fails
**open** on the one input most likely to be wrong.

Neither tool errors on an empty argument — both silently fall back to the current
directory, which is the exact thing this whole step exists to distrust:

```text
git -C "" rev-parse HEAD          -> prints cwd's HEAD, exit 0
gh pr view <N> --repo "" --json … -> resolves via cwd, exit 0
```

So an unsubstituted placeholder or a failed `git remote get-url` does not announce
itself. It produces two values quietly derived from cwd — and if both lookups fail
outright, `[ "" != "" ]` is **false**, the guard does not fire, and execution walks
into `gh pr merge` with `--repo ""`, which resolves from cwd as well. Rejecting empty
is what turns that path back into a stop. **This is also why the target is carried as
literals rather than shell variables**: a variable that did not survive the call
boundary is indistinguishable from one that resolved to the wrong thing, and both
land as `--repo ""`.

### Finding the workspace, when the caller passed none

**When the argument was repo-qualified, ask GitHub for the PR's state before you go
looking for a workspace at all.** The repository is already known, so the
already-merged check below can run immediately — and on a merged PR there is nothing
left that *needs* a workspace: Steps 1–3 are skipped, and Step 4 only tears down a
workspace if one still holds the branch.

Ordering this the other way breaks the recovery path this skill documents. Step 5
tells the user to re-run `merge-pr <owner>/<repo>#<N> <KEY>` after a normal merge —
but by then teardown has put cwd on the default branch and deleted the topic branch,
so a bootstrap that *first* demands "cwd must have the PR branch checked out" aborts
every time, and the `MERGED` fast path is never reached. The documented recovery
would never work.

So: repo-qualified input → resolve state first, and require a verified workspace only
for an **open** PR, or when teardown is still pending. Bare-number input → you have
no repository yet, so the bootstrap below is the only way to get one.

The bootstrap cannot use the workspace or the repository, because neither exists yet.
Start from cwd **as a candidate to be verified, never as an answer**:

```bash
CAND=$(git rev-parse --show-toplevel) || { echo "ABORT: cwd is not a git repo"; exit 1; }
CAND_REPO=$(git -C "$CAND" remote get-url origin \
        | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^/]*@##; s#^[^/:]+(:[0-9]+)?[:/]##; s#/+$##; s#\.git$##')
[ -n "$CAND_REPO" ] || { echo "ABORT: no origin remote in $CAND"; exit 1; }

# Does this repository actually have the PR, and is its branch checked out here?
BRANCH=$(gh pr view <N> --repo "$CAND_REPO" --json headRefName --jq '.headRefName') \
  || { echo "ABORT: $CAND_REPO has no PR <N>"; exit 1; }
[ "$(git -C "$CAND" branch --show-current)" = "$BRANCH" ] \
  || { echo "ABORT: $CAND is on $(git -C "$CAND" branch --show-current), not $BRANCH"; exit 1; }

echo "resolved: $CAND_REPO in $CAND"   # record both as literals
```

Every branch of that is a stop, and deliberately so: the whole point of this step is
that a plausible-looking wrong answer is available at every turn. Cwd is allowed to
*suggest* a target; it is never allowed to *be* one.

### The already-merged check

- **Is it already merged?** Before Step 1, ask GitHub — never infer this from a local
  failure:

  ```bash
  gh pr view <N> --repo <owner>/<repo> --json state,mergedAt --jq '"\(.state) \(.mergedAt)"'
  ```

  - `MERGED` with a non-null `mergedAt` → **skip Steps 1–3**, then run Step 4
    (teardown may still be pending if the merge happened in the web UI) and Step 5.
    State in the report that this run did not perform the merge, and name the merge time.
  - `OPEN` → run every step normally.
  - `CLOSED` with a null `mergedAt` → **stop. Transition nothing.** The PR was
    abandoned; closing its ticket would mark work Done that never landed.
  - Anything else, or the command fails → no fast path. Run Steps 1–4 normally.

  **This is the only permitted way to skip Steps 1–3.** A missing worktree, a failed
  `git checkout`, or a non-zero `gh pr merge` are **not** evidence of a merge —
  branch protection, a missing approval, and a red required check all produce exactly
  those symptoms, and reading them as "already merged" would skip the CI gate on an
  unmerged PR and write a terminal **Done** on work that never landed. Step 5's
  P0–P5 rules apply unchanged on the fast path.

### The supplied ticket key

**A Jira issue key among the arguments** — `merge-pr owner/repo#123 PROJ-456`, or
`merge-pr owner/repo#123 <workspace> PROJ-456` as `ship` passes it — is the
**supplied key**: the trusted ticket for Step 5. It reaches this run only through the
`arguments:` line above; if that line is empty, no key was passed, whatever the
caller intended. `ship` passes the key it confirmed
in its own Step 3 this way. Record it now; Step 5 is its only consumer.

**Parse it with this algorithm, in this order.** Do not eyeball the argument line and
judge it as a whole; run the steps.

1. **Take the `arguments:` line from §"The invocation arguments" above and split it
   into whitespace-separated tokens.** That line is the input to this parse — not a
   memory of what the caller typed, which a forked subagent does not have. Everything
   below works token by token; nothing below ever inspects the line as a single
   string.
2. **Consume the PR target token** — whichever one form the caller used: a bare `<N>`,
   `#<N>`, `<owner>/<repo>#<N>`, or a `https://github.com/<owner>/<repo>/pull/<N>`
   URL. Remove that **one** token from the list.
3. **Consume the workspace path token**, if one was passed — the path resolved above.
   Remove that **one** token from the list.
4. **Anchor-match each token that remains**, individually, against
   `^[A-Za-z]+-[0-9]+$` (case-insensitive). Every token matching *in full* is a
   supplied key. Only an empty result here means no key was supplied.

Worked example — the exact shape `ship` hands down:

```text
merge-pr acme/widgets#142 /Users/me/wt/feat-hive-113 HIVE-113
  tokens:    ["acme/widgets#142", "/Users/me/wt/feat-hive-113", "HIVE-113"]
  step 2 →   consume "acme/widgets#142"           (the PR target)
  step 3 →   consume "/Users/me/wt/feat-hive-113" (the workspace)
  remaining: ["HIVE-113"]
  step 4 →   "HIVE-113" matches in full  →  supplied key = HIVE-113   (Step 5 → P1)
```

**A `/` anywhere in the invocation says nothing about the other tokens.** Steps 2 and
3 remove the PR target and the workspace path *before* any matching happens, so what
those two contain cannot change step 4's answer. The anchoring is belt-and-braces for
exactly those two consumed forms and no others: were one of them somehow left in the
list, the `/` inside it means it still could not match a whole token. **Concluding
"no key was supplied" because the PR target contains a `/` is the specific bug this
algorithm exists to prevent.** A slash is never a reason to skip step 4.

Anchoring also earns its keep for a second, independent reason: matching as a
substring rather than as a whole token lets a pasted comment permalink supply a key
of its own — `…/pull/58#issuecomment-1234567890` contains `issuecomment-1234567890`,
which matches the bare pattern and would be recorded as the trusted ticket. **Never
match a key as a substring of a token.**

**Exactly one.** Collect every whole-token match, uppercase, and de-duplicate. Two
or more **distinct** keys is not a supplied key — it is a contradiction (**P0**
below): transition nothing, report every supplied key alongside every branch key,
and say the invocation must name exactly one. Do **not** resolve it by picking the
one that happens to match the branch name — with no branch key nothing contradicts
either, and with two branch keys both match, so P1 alone would pick arbitrarily and
re-open the ambiguity P5 exists to close. The merge still completes; only the Jira
write is skipped.

**Carry the parse forward as a literal**, alongside the repository, the number and
the workspace, in one of exactly these two forms:

```text
supplied key: HIVE-113
supplied key: none (tokens left after consuming target and workspace: [])
```

The "none" form must name what step 4 actually looked at. Step 5 echoes this line
into the report, so a parse that dropped a key is visible in the output rather than
arriving there as a bare "none" that reads like a correct result.

No remaining token matches → **there is no supplied key.** Do not substitute one
from the branch name, the PR title, or the PR body; Step 5 handles that case
explicitly.

## Step 1: Verify CI status (pre-flight)

This reading fails fast on a PR that is nowhere near mergeable. It does **not**
authorise the merge — Step 3's gate re-reads all of it at merge time, because
everything below can change while Step 2 runs.

```bash
gh pr checks <N> --repo <owner>/<repo>
```

- All checks pass → proceed.
- Checks still running → wait and re-check before proceeding.
- Any check failed → **stop**. Surface the failure. Do not merge.
- **Zero checks reported** → this is not "green". It means either the repo has no CI,
  or you are looking at the wrong PR. "No checks failed" and "no checks ran" read
  identically. Confirm which before proceeding; a repo with no workflows is
  legitimate and common, but it has to be established rather than assumed, and Step
  0's head-SHA assertion is what distinguishes it from a wrong target.

## Step 2: Sync with upstream — detect drift and conflicts

The base branch may have moved since this PR was last synced. Detect both cases
BEFORE merging:

```bash
BASE=$(gh pr view <N> --repo <owner>/<repo> --json baseRefName --jq '.baseRefName')
[ -n "$BASE" ] || { echo "ABORT: base branch not resolved"; exit 1; }
git -C "<workspace>" fetch origin
gh pr view <N> --repo <owner>/<repo> --json mergeable,mergeStateStatus
git -C "<workspace>" rev-list --count "HEAD..origin/$BASE"   # commits that landed upstream since divergence
```

**`BASE` does not survive to the next call, and must never be inlined as bare text.**
Carried across a call boundary it is empty, degrading `origin/$BASE` to `origin/` —
not a valid ref, so synchronization stalls. Inlined as text it is a ref name that may
contain shell metacharacters, the same hazard Step 4 documents for `BRANCH`.

So **every block below opens by re-reading it.** This line is part of each one, not a
preamble to remember:

```bash
BASE=$(gh pr view <N> --repo <owner>/<repo> --json baseRefName --jq '.baseRefName')
[ -n "$BASE" ] || { echo "ABORT: base branch not resolved"; exit 1; }
```

Syncing and conflict resolution happen in the PR's working tree — that is the
workspace Step 0 already resolved. Do not go looking for it again with a bare
`git worktree list`; that asks whichever repository cwd happens to be in.

- **Up to date and MERGEABLE** → proceed to Step 3.
- **Behind, no conflicts** → assess what landed before absorbing it:

  ```bash
  BASE=$(gh pr view <N> --repo <owner>/<repo> --json baseRefName --jq '.baseRefName')
  [ -n "$BASE" ] || { echo "ABORT: base branch not resolved"; exit 1; }
  git -C "<workspace>" log --oneline "HEAD..origin/$BASE"
  git -C "<workspace>" diff "HEAD...origin/$BASE" --stat
  ```

  Compare against the PR's own diff — did upstream touch files, interfaces, or
  behavior this PR modifies or relies on? No overlap → absorb it with the merge block
  below, push, wait for CI green, proceed. Overlap → same merge block, then run the
  repo's targeted verification on the affected paths, and treat any behavioral
  interaction as a conflict for the purposes of the confirmation rule below.

  ```bash
  BASE=$(gh pr view <N> --repo <owner>/<repo> --json baseRefName --jq '.baseRefName')
  [ -n "$BASE" ] || { echo "ABORT: base branch not resolved"; exit 1; }
  git -C "<workspace>" merge "origin/$BASE"
  ```
- **CONFLICTING** → first read the upstream commits that introduced the conflicting
  hunks:

  ```bash
  BASE=$(gh pr view <N> --repo <owner>/<repo> --json baseRefName --jq '.baseRefName')
  [ -n "$BASE" ] || { echo "ABORT: base branch not resolved"; exit 1; }
  git -C "<workspace>" log -p "origin/$BASE" -- "<file>"
  ```

  so you understand BOTH intents. Then merge and resolve, preserving both — never by
  blanket `--ours`/`--theirs`:

  ```bash
  BASE=$(gh pr view <N> --repo <owner>/<repo> --json baseRefName --jq '.baseRefName')
  [ -n "$BASE" ] || { echo "ABORT: base branch not resolved"; exit 1; }
  git -C "<workspace>" merge "origin/$BASE"
  ```

  After resolving: run the repo's targeted verification, commit the merge, push, and
  wait for CI green before proceeding.

**The merge itself is a command, not a description.** Every block above repeats the
re-read because each one is its own call — including the merges. A merge written only
as prose (*"merge `origin/$BASE` into the branch"*) is the case that keeps slipping
through: it reads like narration, gets run in a fresh shell where `$BASE` is empty,
and `git merge origin/` fails. If you find yourself about to type a `git` command that
touches the base branch, it needs its own re-read and guard.
- **Confirmation hard stop:** if a resolution (or absorbing upstream changes)
  would break or drastically change functionality that a previously merged PR
  introduced — or materially change what THIS PR was reviewed as doing — do NOT
  merge and do NOT push a guess. This skill runs in a forked subagent that cannot
  ask questions interactively: abort the merge and report back with the
  conflicting files, both sides' intent, and your proposed resolution, so the
  user can confirm before merge-pr is re-run.

Anything pushed here moves both the PR head and the workspace head — and restarts CI,
and can wake a review agent. Step 3's gate is what catches all of that; a push here is
one more reason its reading must be taken *after* this step, never before it.

## Step 3: The merge gate, then the squash merge

Everything above this line is **pre-flight**. It establishes that the PR *was*
mergeable. It does not establish that it *is*. Between any earlier check and this
moment a reviewer can submit findings, a review agent that was still running can
finish and post them, a teammate can push, and CI can start over — none of which
announces itself.

That is the failure this step exists for, and it is not a missing check: it is the
**right check run at the wrong time**. A reading taken before the instruction to merge
arrived — before the user said "merge it", before ship's watch loop woke — describes
the moment it was taken and nothing since. A merge gate is only a gate if it is
evaluated **at the instant of merging**. Minutes-old is stale; "I checked that
already" is the answer of someone who is about to merge past a finding.

So the gate below is not a step you pass and carry forward. It is a reading with a
lifetime of exactly one call.

### The gate — one call, immediately before the merge

Every merge-blocking fact in a single GraphQL reading, so no two of them are separated
in time, plus the workspace head, reduced to one verdict:

```bash
GATE=$(gh api graphql -f query='
query($owner:String!, $repo:String!, $n:Int!) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$n) {
      headRefOid state mergeable reviewDecision
      reviewRequests(first:50){ nodes { requestedReviewer {
        __typename ... on User { login } ... on Bot { login } } } }
      latestReviews(first:50){ nodes { author { login } state } }
      reviewThreads(first:100){ pageInfo { hasNextPage } nodes { isResolved isOutdated } }
      commits(last:1){ nodes { commit { statusCheckRollup { state contexts(first:100){
        pageInfo { hasNextPage }
        nodes { __typename ... on CheckRun { name status conclusion }
                ... on StatusContext { context state } } } } } } }
    }
  }
}' -F owner=<owner> -F repo=<repo> -F n=<N>)
LOCAL_HEAD=$(git -C "<workspace>" rev-parse HEAD)
[ -n "$GATE" ] && [ -n "$LOCAL_HEAD" ] || { echo "GATE: HOLD — empty reading"; exit 1; }
printf '%s' "$GATE" | jq -r --arg local "$LOCAL_HEAD" '
  .data.repository.pullRequest as $p
  | ($p.reviewThreads.nodes | map(select(.isResolved | not))) as $open
  | ($p.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // []) as $ctx
  | ($ctx | map(select(
      (.__typename=="CheckRun"      and (.status != "COMPLETED")) or
      (.__typename=="StatusContext" and (.state=="PENDING" or .state=="EXPECTED"))))) as $running
  | ($ctx | map(select(
      (.__typename=="CheckRun"      and ([.conclusion] | inside(["FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE","STALE"]))) or
      (.__typename=="StatusContext" and (.state=="FAILURE" or .state=="ERROR"))))) as $failed
  | ($p.reviewRequests.nodes | map("\(.requestedReviewer.login // "?") [\(.requestedReviewer.__typename)]")) as $pending
  | ($p.latestReviews.nodes | map(select(.state=="CHANGES_REQUESTED") | .author.login)) as $cr
  | [ (if $p.headRefOid != $local then "head moved: PR \($p.headRefOid) != workspace \($local)" else empty end),
      (if $p.state != "OPEN" then "PR state is \($p.state)" else empty end),
      (if ($open|length) > 0 then "\($open|length) unresolved review thread(s), \(($open|map(select(.isOutdated))|length)) of them outdated" else empty end),
      (if $p.reviewThreads.pageInfo.hasNextPage then "more than 100 review threads — paginate before trusting the count" else empty end),
      (if ($running|length) > 0 then "checks still running: \($running|map(.name // .context)|join(", "))" else empty end),
      (if ($ctx|length) == 0 then "zero checks reported — establish whether this repo has CI" else empty end),
      (if $p.commits.nodes[0].commit.statusCheckRollup.contexts.pageInfo.hasNextPage then "more than 100 checks — paginate" else empty end),
      (if ($failed|length) > 0 then "checks failed: \($failed|map(.name // .context)|join(", "))" else empty end),
      (if ($pending|length) > 0 then "review still requested from: \($pending|join(", ")) — reviewDecision=\($p.reviewDecision // "none")" else empty end),
      (if ($cr|length) > 0 then "CHANGES_REQUESTED standing from: \($cr|join(", "))" else empty end),
      (if $p.mergeable == "CONFLICTING" then "mergeable=CONFLICTING" else empty end),
      (if $p.mergeable == "UNKNOWN" then "mergeable=UNKNOWN — re-query" else empty end)
    ] as $blocks
  | if ($blocks|length) == 0
    then "GATE: CLEAR — merge \($p.headRefOid) in the very next call"
    else "GATE: HOLD\n" + ($blocks | map("  - " + .) | join("\n")) end'
```

`<owner>`, `<repo>`, `<N>` and `<workspace>` are the literals Step 0 resolved — the
same rule as everywhere else in this skill: no shell variable survives to the next
call, and `--repo ""` / `-C ""` fall back to cwd without erroring, which is why the
block refuses an empty reading before it compares anything.

The head comparison inside the gate **is** Step 0's assertion, folded in so that the
SHA and the review state come from one instant rather than two. That is the point of
one call: a green-checks reading from 14:02 and a threads reading from 14:05 describe
two different pull requests, and neither describes the one you are about to merge.

### What a HOLD means

| Verdict line | What actually happened | Action |
|---|---|---|
| `unresolved review thread(s)` | Someone left findings and nobody answered them — including findings that landed **after** the last time anything looked. Outdated threads count: GitHub does not resolve them for you, and a thread going stale is not a thread being addressed. | **Stop.** Hand back to `review-pr-findings`. Never resolve a thread to clear the gate. |
| `checks still running` | CI is not finished. Some review agents (Copilot review among them) surface as a check run while they work. | Wait, then re-run **the whole gate**, not the one line that was red. |
| `review still requested from … [Bot]` | A review agent was asked and has not submitted. This is precisely the "still thinking" state, and its findings arrive as new threads the moment it finishes. | Wait for it to submit, then re-run the whole gate — the new threads show up in the same reading. |
| `review still requested from … [User]`, `reviewDecision=APPROVED` | A human request that someone else's approval already satisfied. Unlike a bot, it can sit unanswered for days, so waiting it out is not a plan. | **Stop and report it** — name the reviewer and say the PR is otherwise clear. Removing someone's review request is the caller's call, not this skill's. |
| `review still requested from … [User]`, not approved | A human was asked and has not answered. | **Stop and report.** Nothing here approves on their behalf. |
| `CHANGES_REQUESTED standing from …` | A reviewer's blocking review has not been superseded. | **Stop.** Only a new review from that reviewer clears it; your own assessment does not. |
| `head moved` | Either the wrong repository or a push landed mid-run. Both are stop conditions — see Step 0. | **Stop.** |
| `zero checks reported` | "No checks failed" and "no checks ran" read identically. | Establish which, as in Step 1. |
| `PR state is …` | `MERGED` → Step 0's fast path. `CLOSED` → stop, nothing merges. | Per Step 0. |
| `mergeable=CONFLICTING` / `UNKNOWN` | Step 2's territory, or GitHub is still computing it. | Return to Step 2, or re-query. |
| `more than 100 …` | The reading is truncated, so the count cannot be trusted. | Paginate before deciding. Truncated is never CLEAR. |
| `empty reading` | A lookup failed, or a placeholder was never substituted. | **Stop.** Empty is not a pass. |

**Waiting is a real outcome, not a failure.** A review agent that has not finished is
the most common HOLD here and the one that caused this step to exist: the merge went
in while the agent was still working, and its findings arrived minutes later against a
merged PR. Wait with whatever the harness provides (a monitor/wait mechanism, or a
short sleep), re-run the gate, and repeat — but bound it. If it has not settled after
roughly ten minutes of polling, stop and report what is still pending: this skill runs
in a forked subagent and cannot ask the user whether to keep waiting.

### The freshness rule

A `CLEAR` is valid for exactly **one** call: the `gh pr merge` below, issued next,
with nothing in between. Anything at all in between voids it — a push, a comment, a
thread reply, a wait, another poll, a user turn, any other tool call. Void means
**re-run the gate block verbatim**, not re-read its output.

Three shapes of this mistake, all of which look like diligence:

- Running the gate, reporting "green, no unresolved threads" to the user, waiting for
  them to say "merge it", and then merging on that report. The instruction to merge
  **starts** the gate; it does not confirm one.
- Running the gate, hitting a HOLD, waiting for the checks, and then merging because
  the checks are now done — without re-reading the threads. The wait is exactly when
  new findings land.
- Treating ship's Step 6 approval loop, or `review-pr-findings` returning "all
  resolved", as the gate. Those are upstream evidence that this PR was ready; this
  gate is the only reading contemporaneous with the merge.

### The merge

Carry the SHA the gate cleared into the merge, so GitHub itself refuses if the head
moved between the two calls:

```bash
gh pr merge <N> --repo <owner>/<repo> --squash --match-head-commit <the SHA the gate printed>
```

The SHA is a literal copied from the `GATE: CLEAR` line — the one value that may cross
a call boundary as text, because it is hex and because carrying it is the check. If
you cannot point at a `GATE: CLEAR` line from the immediately preceding call, you do
not have a SHA to paste, and that is the gate working.

Do **not** pass `--delete-branch`. merge-pr usually runs from inside the PR's
worktree (the default for `work-on` tickets), and `--delete-branch` makes gh
switch the current checkout to the default branch so it can delete the local
branch — but the default branch is already checked out in the main working tree,
so git aborts with `fatal: '<default>' is already used by worktree …`. The remote
merge still succeeds, but gh exits non-zero on that error and leaves local cleanup
half done. Step 4 owns all branch teardown — the worktree, the local branch, AND
the remote branch — deterministically from the main working tree, so gh never
touches the local checkout.

If the user wants to review or edit the squash commit message first, open
`gh pr view <N> --repo <owner>/<repo> --web` and let them complete the merge manually
(still without `--delete-branch`). Run the gate first anyway: a merge done by hand
needs the same reading, and a HOLD is a reason not to open the page at all.

Confirm the merge landed on the PR you targeted before cleaning anything up:

```bash
gh pr view <N> --repo <owner>/<repo> --json state,mergedAt,mergeCommit \
  --jq '{state, mergedAt, mergeCommit: .mergeCommit.oid}'
```

## Step 4: Clean up the local workspace

Work started with `work-on` lives in a **git worktree**, not just a branch on the
shared checkout. Resolve the head branch and detect which case applies:

```bash
BRANCH=$(gh pr view <N> --repo <owner>/<repo> --json headRefName --jq '.headRefName')   # <N> = the number recorded in Step 0 — always present by now, never drop it
DEFAULT=$(gh repo view <owner>/<repo> --json defaultBranchRef --jq '.defaultBranchRef.name')
[ -n "$BRANCH" ] && [ -n "$DEFAULT" ] || { echo "ABORT: branch/default not resolved"; exit 1; }

# Which checkout holds the branch, and which one is the main working tree?
# Parsed with a shell loop, not awk: awk's unbraced field references are rewritten
# with the caller's arguments before the agent reads this file (see Step 0,
# "The invocation arguments"). Do not reintroduce awk here.
WT_LIST=$(git -C "<workspace>" worktree list --porcelain)
MAIN_WT=""; WT_PATH=""; cur=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*)                cur=${line#worktree }
                                 [ -n "$MAIN_WT" ] || MAIN_WT=$cur ;;   # first entry is the main working tree
    "branch refs/heads/$BRANCH") WT_PATH=$cur ;;
  esac
done <<< "$WT_LIST"
[ -n "$MAIN_WT" ] || { echo "ABORT: main working tree not resolved"; exit 1; }

if   [ -z "$WT_PATH" ];              then echo "NEITHER   (no checkout here holds $BRANCH)"
elif [ "$WT_PATH" = "$MAIN_WT" ];    then echo "BRANCH    (main working tree $MAIN_WT)"
else                                      echo "WORKTREE  ($WT_PATH, main is $MAIN_WT)"
fi
```

**Holding the branch is not the same as being a worktree to remove**, and conflating
them is the failure this block is written to avoid. `git worktree list` **always
lists the main working tree first**, as an ordinary entry with its own `branch` line —
so a plain topic branch checked out in the shared clone matches a bare
`grep "branch refs/heads/$BRANCH"` exactly as a linked worktree does. Detecting on
that match alone sends every non-worktree PR into Case A, where
`git worktree remove` refuses on the main working tree (`fatal: … is a main working
tree`) and teardown stops there: branch never deleted, remote branch never deleted,
default branch never pulled — after a merge that succeeded. Loud enough to notice,
quiet enough to look like a post-merge hiccup rather than a skipped step.

Comparing `$WT_PATH` against `$MAIN_WT` is what separates the two, and it collapses
all three outcomes into one reading: no path (nothing here holds the branch), the main
path (Case B), or some other path (Case A).

**Re-derive `BRANCH` and `DEFAULT` at the top of every block below, and always
expand them quoted — `"$BRANCH"`, `"$DEFAULT"`.** This is the one place the
literal-substitution rule does **not** apply, and the exception is load-bearing in
both directions:

- Crossing a call boundary is still forbidden. A `$BRANCH` set here is empty in Case
  A, and every consequence is quiet: `git branch -D ""` and `git checkout ""` fail,
  and the loop matches `branch refs/heads/` against nothing, so `WT_PATH` comes back
  empty and teardown half-completes while the merge itself looks fine.
- But **the branch name is attacker-controlled**, and pasting it in as bare text is
  worse than the bug that would fix. `git check-ref-format` permits `;`, `$`,
  `` ` ``, `&`, `(`, `)` and `|` in a ref — `foo;whoami` and `foo$(id)` are both
  **valid branch names**. Substituted textually into `git branch -D <branch>` they
  execute during cleanup, with the PR author choosing the command.

Re-reading inside each block satisfies both constraints at once: the value never
crosses a call, and it never appears as bare text. Quote every expansion, including
`<workspace>` paths.

**Nothing here deletes a branch the workspace does not hold.** This check is what
guards teardown, in place of Step 0's head-SHA assertion — which cannot run on the
already-merged fast path, where the workspace may already be back on the default
branch. On `NEITHER` the workspace is not this PR's: skip teardown, say so, and go to
Step 5.

### Case A — the branch has its own **linked** worktree (default for `work-on` tickets)

Tear the worktree down with **git**, not `ExitWorktree` — this skill runs in a
forked subagent, and `ExitWorktree` only acts on worktrees the same session created.
Operate from the main working tree (you cannot remove the worktree you stand in):

```bash
# Re-read inside this call — never carried from the block above, never inlined as text.
BRANCH=$(gh pr view <N> --repo <owner>/<repo> --json headRefName --jq '.headRefName')
DEFAULT=$(gh repo view <owner>/<repo> --json defaultBranchRef --jq '.defaultBranchRef.name')
[ -n "$BRANCH" ] && [ -n "$DEFAULT" ] || { echo "ABORT: branch/default not resolved"; exit 1; }

WT_LIST=$(git -C "<workspace>" worktree list --porcelain)
MAIN_WT=""; WT_PATH=""; cur=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*)                cur=${line#worktree }
                                 [ -n "$MAIN_WT" ] || MAIN_WT=$cur ;;
    "branch refs/heads/$BRANCH") WT_PATH=$cur ;;
  esac
done <<< "$WT_LIST"
[ -n "$MAIN_WT" ] && [ -n "$WT_PATH" ] || { echo "ABORT: worktree not resolved"; exit 1; }
# The detection above already established these differ. Re-assert it: this block is
# its own call, and `worktree remove` on the main working tree cannot succeed.
[ "$WT_PATH" != "$MAIN_WT" ] || { echo "ABORT: $BRANCH is in the main working tree — this is Case B"; exit 1; }

git -C "$MAIN_WT" worktree remove "$WT_PATH" --force   # --force: after a squash the branch has commits not on local main
git -C "$MAIN_WT" worktree prune
git -C "$MAIN_WT" branch -D "$BRANCH"                  # the branch ref lingers after the worktree is removed
git -C "$MAIN_WT" push origin --delete "$BRANCH"       # gh no longer deletes the remote branch; harmless if it is already gone
git -C "$MAIN_WT" checkout "$DEFAULT"
git -C "$MAIN_WT" pull origin "$DEFAULT"
echo "main working tree: $MAIN_WT"
```

`$MAIN_WT` is derived from the workspace, not from cwd — the first entry of
`git worktree list` is the main working tree **of whichever repository you asked**,
and asking the wrong one here deletes a branch in a project you were never working
on. It and `$WT_PATH` are safe as variables because they are set and used inside this
one call, but record `$MAIN_WT`'s value: the report at the end has to name it, and
that is a later call. The emptiness guard is there for the same reason it is in Step
0 — `git -C ""` does not error, it operates on cwd.

### Case B — a plain topic branch in the main working tree

```bash
# Same rule as Case A: re-read here, expand quoted, never inline as text.
BRANCH=$(gh pr view <N> --repo <owner>/<repo> --json headRefName --jq '.headRefName')
DEFAULT=$(gh repo view <owner>/<repo> --json defaultBranchRef --jq '.defaultBranchRef.name')
[ -n "$BRANCH" ] && [ -n "$DEFAULT" ] || { echo "ABORT: branch/default not resolved"; exit 1; }

git -C "<workspace>" checkout "$DEFAULT"
git -C "<workspace>" pull origin "$DEFAULT"
git -C "<workspace>" branch -d "$BRANCH"
git -C "<workspace>" push origin --delete "$BRANCH"   # Step 3 no longer uses --delete-branch, so tear the remote branch down here
```

If `git branch -d` refuses because the branch is not fully merged locally (expected
after a squash), use `-D` — the squash merge on the remote is the authoritative
record.

Either case leaves the session in the main working tree on the repo's default
branch (`$DEFAULT` — usually `main`).

## Step 5: Move the linked Jira ticket to Done — only when the key is confirmed

**The branch name is untrusted input.** The PR author writes it, and a name carrying
two keys is enough to close someone else's ticket — no comment or review interaction
required. The realistic trigger is not an attacker but an ordinary rollup, revert,
hotfix, or cherry-pick branch that kept a second key. This step writes **Done**, which
is terminal, and this skill runs in a forked subagent that cannot stop and ask. So a
key is transitioned only when a trusted source confirms it.

**Trusted sources, in order:**

1. **The supplied key from Step 0** — named by the user in the invocation, or handed
   down by `ship` from its own confirmed Step 3.
2. **The ticket's own remote link** referencing this PR or branch. Fetch it by
   **invoking `jira-writer:jira-writer`** for the candidate key's remote issue links
   (or the Atlassian MCP's `getJiraIssueRemoteIssueLinks` if jira-writer isn't
   installed) — never raw REST/curl. It confirms **only** if a returned link URL contains this
   PR's URL or its branch name; anything else is not a match. Absence is **not**
   confirmation and **not** an error: in our Jira this returns an empty list today,
   because the GitHub development panel is a separate source the MCP does not expose.
   Treat it as a bonus signal that catches the accidental case — a determined author
   has Jira write access and could add a link themselves, so it is not a defense
   against one.

**Never trusted:** the branch name, the PR title, the PR body. The author writes all
three, so a key found there is self-attestation. They may surface a *candidate* to
name in the report; they never confirm one.

Collect **every** candidate key from the branch name — not the first. **Re-derive the
branch name here**; do not rely on a `$BRANCH` set in Step 4. Shell state does not
survive between calls, and by this point Step 4 has deleted the branch locally and
remotely, so only GitHub still knows it (`headRefName` outlives the branch):

```bash
BRANCH=$(gh pr view <N> --repo <owner>/<repo> --json headRefName --jq '.headRefName')
KEYS=$(printf '%s' "$BRANCH" | grep -oiE '[a-z]+-[0-9]+' | tr '[:lower:]' '[:upper:]' | sort -u)
```

An empty `$BRANCH` here is a **bug, not a "no keys found"** result: it silently makes
every rule below behave as if the branch carried no key, which turns the contradiction
check (P2) off and lets a wrong supplied key through P1. If `BRANCH` comes back empty,
stop and report rather than transitioning anything.

Then apply exactly one rule. Uppercase before comparing — matching is case-insensitive.

| | Branch keys | Supplied key | Action |
|---|---|---|---|
| **P0** | any | **2+ distinct keys supplied** | **Transition nothing.** Report every supplied key and every branch key. Exactly one key may be supplied — see Step 0. |
| **P1** | any | present (exactly one), and either matches one of them or the branch has none | **Transition it.** A trusted source named it, which resolves any ambiguity in the branch name. |
| **P2** | 1+ | present, and matches **none** of them | **Transition nothing.** Report the supplied key and every branch key. Someone is confused about which PR is being merged — do not silently pick a side. |
| **P3** | 0 | absent | Skip. Note it in the final report. |
| **P4** | 1 | absent | Try the remote-link check on that key. Confirmed → transition. Unconfirmed → **transition nothing** and report the candidate. |
| **P5** | 2+ | absent | **Transition nothing.** Report every key found so the user can re-run naming the right one. |

P0 is checked first, then P1–P5. Together they cover every combination of branch-key
count (0 / 1 / 2+) against supplied-key state (absent / one matching / one matching
none / 2+ supplied). If an input appears to match no rule, or two, **transition
nothing and report** — never improvise toward P1.

**Name the rule that fired, before acting on it.** Emit this line as part of Step 5's
output, and again in the final report:

```text
step 5: rule <P#> — supplied key: <KEY|none>, branch keys: [<K1>, <K2>, …|none], action: <transitioned <KEY> to Done | transitioned nothing>
```

The `supplied key:` field is the literal Step 0 recorded; do not re-derive it here,
and do not summarise "none" without the tokens Step 0 listed alongside it. A wrong
classification is otherwise **silent**: P3's skip and P4's unconfirmed path both end
a run that merged cleanly and moved no ticket, and in a report that says only "no
ticket was transitioned" they are indistinguishable from P1 doing its job. Naming
the rule and the two inputs that selected it is what makes a dropped supplied key
visible to the caller.

**If that line reads `supplied key: none` while the invocation did contain a key
token, Step 0's parse is wrong.** Go back and re-run Step 0's four steps against the
actual argument tokens; do not report a P3/P4 outcome as correct. Never write "no
ticket key was supplied" — or any sentence like it — unless step 4 of that parse ran
over the remaining tokens and matched none.

To transition: **invoke the `jira-writer:jira-writer` skill** (never raw Jira
REST/curl — jira-writer handles credentials; if jira-writer isn't installed, use the
Atlassian MCP (Rovo) tools directly) and move the ticket to **Done**.

**An unconfirmed key never blocks the merge.** Steps 1–4 have already completed and
are correct; only this step is skipped. Say so plainly in the final report: name the
candidate keys, state that no ticket was transitioned, and give the two ways to finish
it — **re-run `merge-pr <owner>/<repo>#<N> <KEY>` with exactly one key**, where Step 0
detects the PR is already merged and goes straight to teardown and the Jira write, or
move the ticket in Jira by hand. Without Step 0's already-merged check a bare re-run
is not a recovery path at all: it re-enters Step 2 with no branch to check out and a
`mergeStateStatus` of `UNKNOWN`, then hard-stops at Step 3, since `gh pr merge` cannot
squash a merged PR.

## Report back

Name the target you acted on, in full, so the caller can tell a correct merge from a
confident wrong one. A report that says only "merged PR 58" is unfalsifiable:

```text
merged <owner>/<repo>#<N> — squash <sha>, branch <branch> torn down, <KEY> → Done
gate: CLEAR at <head SHA> (threads 0 unresolved, checks green, no reviewer pending)
step 5: rule <P#> — supplied key: <KEY|none>, branch keys: [<K1>, …|none], action: <…>
main working tree: <path>
```

The gate line is part of the report for the same reason the target is: it is the
difference between "it was fine when I looked" and "it was fine when I merged". If a
run waited on a review agent or re-ran the gate, say how many times and on what.

The step 5 line is there for the same reason again: "no ticket was transitioned" is
an outcome that a correct run and a mis-parsed one produce identically. Printing the
rule alongside the two inputs that selected it — including Step 0's literal
`supplied key:` — is what lets the caller see that a key it passed was dropped. It is
required on every run, including the ones that did transition a ticket.

The main working tree is reported because the caller may be standing inside the
worktree this skill just deleted, and a process whose cwd no longer exists cannot run
`git` to find its way out. Naming the path is what lets ship return somewhere real
instead of asking a bare `git worktree list` from a directory that is gone.

## Error handling

| Situation | Action |
|---|---|
| Step 3's gate says `HOLD` | **Stop or wait**, per the reason. Never merge on an earlier `CLEAR`, and never on a summary of one. |
| The gate said `CLEAR`, but anything happened before the merge call | The `CLEAR` is void. Re-run the gate block verbatim — a reading is good for exactly one call. |
| Unresolved review threads at merge time | **Stop.** Hand back to `review-pr-findings`. Resolving threads to clear the gate is falsifying the gate. |
| A reviewer (human or review agent) has been requested and not submitted | Wait and re-run the whole gate; its findings become threads when it lands. Bound the wait (~10 min), then stop and report — this skill cannot ask. |
| `gh pr merge` rejects the `--match-head-commit` SHA | The head moved between gate and merge. Do **not** re-run without the flag. Re-run the gate; the new reading is the answer. |
| Head SHA mismatch (Step 0) | **Stop.** Report both SHAs and the resolved repo/workspace. Never merge past this. |
| Either head reads empty (Step 0) | **Stop.** An empty `--repo`/`-C` silently falls back to cwd; empty is never a match. Fix the resolution, do not retry past it. |
| The repository resolves empty | **Stop.** The workspace has no `origin`, or the workspace path is wrong. Do not continue with an empty `--repo`. |
| A repo-qualified argument disagrees with the workspace's `origin` | **Stop.** The caller and the workspace name different targets; resolve which is right before acting. Applies to a PR **URL** exactly as to `<owner>/<repo>#<N>`. |
| Branch/base name contains `;`, `$(`, `` ` ``, `&`, `\|` | These are **valid** git refs and the author chose them. Never inline a ref as bare text; re-read it in-call and expand it quoted. |
| Repo-qualified re-run on a merged PR, no workspace passed | Resolve state from the supplied repo **first**. Do not demand a branch workspace — teardown already removed it, and requiring it would break the documented recovery. |
| No workspace passed, cwd's repo lacks the branch | **Stop and report.** Do not fall back to cwd. |
| `gh pr checks` reports zero checks | Not green. Confirm the repo genuinely has no CI (Step 0's assertion rules out a wrong PR). |
| Step 4 detection returns `NEITHER` | Skip teardown entirely and report it. Never delete a branch from a workspace that does not hold it. |
| Step 4 detection returns `BRANCH` because `$WT_PATH` equals `$MAIN_WT` | Case B. The branch is checked out in the shared clone, not a linked worktree — there is no worktree to remove. |
| `git worktree remove` says `is a main working tree` | The detection sent a Case B teardown into Case A. Do not force it; re-run the detection and take Case B. |
| CI failing | Stop. Report the failing check. Do not merge. |
| CI not yet run | Wait for checks to complete. Do not skip. |
| Merge conflict | Resolve via Step 2 (understand both intents, verify, push), then **re-run Step 0's assertion** — the push moved both heads. Abort and report for confirmation if the resolution breaks/changes previously merged functionality. |
| Remote branch already deleted (auto-delete-on-merge, or a prior run) | `git push origin --delete` prints "remote ref does not exist" — treat as success and proceed. |
| `git branch -d` refused | Use `-D` after confirming the squash succeeded remotely. |
| `gh pr merge` aborts with "already used by worktree" | Only if `--delete-branch` was passed (Step 3 omits it). The remote merge already succeeded — ignore the error and let Step 4 own cleanup. |
| `git worktree remove` refused (dirty) | Add `--force`; the remote squash is authoritative. |
| Worktree already gone | Skip removal; run `git -C "$MAIN_WT" worktree prune` + branch delete, proceed. |
| Jira ticket not found | Skip Step 5. Note it to the user. |
| Step 5 logs `supplied key: none`, but the invocation contained a key token | Step 0's parse is wrong, not the P-table. Re-run Step 0's four steps over the argument tokens; the PR target's `/` is not a reason to skip step 4. Do not report the P3/P4 outcome as correct. |
| Tempted to report "no ticket key was supplied" | Only ever say this when step 4 of Step 0's parse ran over the remaining tokens and matched none — and print those tokens with it. Said on a dropped key, it makes the failure read as correct behaviour. |
| Branch carries 2+ keys, none supplied | P5 — transition nothing, report every key. The merge itself stands. |
| Supplied key matches none of the branch's keys | P2 — transition nothing, report the supplied key and every branch key. Do not guess which is right. |
| 2+ distinct keys supplied | P0 — transition nothing, report all of them. The invocation must name exactly one. |
| Remote-link check returns nothing | Not an error — it returns nothing in our Jira by default. Fall through to P4's unconfirmed path. |
| `BRANCH` came back empty in Step 5 | A bug, not "no keys". Transition nothing and report — an empty branch name disables the P2 contradiction check. |
| Step 0 finds no PR for the current branch | Stop before Step 1. There is no target PR; report and let the user name one. |
| PR already merged (a re-run, or merged in the web UI) | Step 0's check sees `state: MERGED` → skip Steps 1–3, run Step 4 (teardown may still be pending) and Step 5. Report that this run did not perform the merge. |
| PR is CLOSED but not merged | Stop. Transition nothing — unmerged work never closes a ticket. |
| `mergeable`/`mergeStateStatus` come back `UNKNOWN` | Not one of Step 2's three cases. If the PR is merged, Step 0's check should already have skipped Step 2; otherwise re-query. Never read a `HEAD..origin/$BASE` count of 0 taken from the default branch as "up to date" for the PR. |
| `git branch -D` says the branch does not exist | Already cleaned up by a prior run. Proceed. |

## Workflow context

- Merges always use the **squash strategy** — one clean commit on the default
  branch per PR.
- Each PR touches exactly one repo; a ticket may have produced several PRs — run
  this workflow once per PR.
- Never merge directly to the default branch without a PR.
- If a `~/.claude/workstream/pr-ledgers/<owner>-<repo>-pr<N>.md` ledger exists for this PR, delete
  it after the merge succeeds (ship also deletes it when orchestrating; deleting
  twice is harmless).

## Red flags

- **Running any `gh` command without `--repo`, or any `git` command without `-C`** →
  the default target is cwd, and cwd is the thing this skill cannot trust. `<N>`
  exists in every repository you have ever worked in.
- **Expecting any shell variable to survive to the next call** → it does not. The
  target arrives as `--repo ""`, which resolves from cwd; `$BRANCH`, `$DEFAULT` and
  `$BASE` arrive empty, so `git branch -D ""` and `git checkout ""` fail and teardown
  half-completes while the merge looks fine. Carry literals; use variables only
  within the single call that sets them.
- **Inlining a ref name as bare text to satisfy that rule** → refs are
  attacker-controlled and `foo;whoami` is a valid branch name, so this turns a quiet
  bug into arbitrary command execution as the PR author. Refs are the exception:
  re-read them in-call and expand them quoted. Both rules hold together — never
  across a call, never as bare text.
- **Reading a PR URL as just a number** → it names its repository as bindingly as
  `<owner>/<repo>#<N>`. Discarding that is how the caller's explicit target loses to
  a workspace that disagrees with it.
- **Merging without the head-SHA assertion against current values** → `--repo` is only
  as good as whatever resolved it. The assertion is the only check that fails closed
  on a wrong repository, and the only one that catches a push landing mid-run.
- **Merging on a reading taken before the instruction to merge arrived** → "I checked
  the threads a few minutes ago" is a statement about a PR that no longer exists. The
  instruction to merge *starts* Step 3's gate; it never confirms one already run.
- **Reporting the gate to the user, getting "merge it", and merging on the report** →
  the user's answer is the thing that makes the reading stale. Re-run it.
- **Clearing a HOLD one line at a time** → waiting out the running checks and then
  merging without re-reading the threads misses exactly the findings that landed
  *during* the wait. The gate is re-run whole or not at all.
- **Treating a still-running review agent as "no findings"** → a requested reviewer
  that has not submitted is mid-run, not silent. Its findings arrive as threads
  minutes later, and after a merge there is nowhere for them to go.
- **Resolving a review thread so the gate goes green** → that is not passing the gate,
  it is disabling it. Threads are answered in `review-pr-findings` or not at all.
- **Dropping `--match-head-commit` because the merge was rejected** → the rejection is
  the check firing. Re-run the gate instead of removing the guard that caught it.
- **Reading zero CI checks as green** → "no checks failed" and "no checks ran" read
  identically; one of them is a wrong PR.
- **Re-deriving the workspace with a bare `git worktree list` after Step 0** → that
  asks whichever repository cwd is in, and Case A deletes branches with the answer.
- **Reporting "merged PR `<N>`" without naming the owner/repo** → the caller cannot
  tell a correct merge from a confident wrong one, which is exactly the failure this
  skill is guarding against.
- **Transitioning a ticket parsed from the branch name with nothing confirming it** →
  this step writes **Done**, which is terminal. An ordinary rollup or revert branch
  carrying two keys closes someone else's work item. Unconfirmed → transition nothing
  and report.
- **Taking the first regex match** (`head -1`), letting branch-name ordering decide
  which ticket closes → collect every key, then apply P1–P5.
- **Treating the PR title or body as confirmation** → the author writes both; that is
  self-attestation, not evidence.
- **Blocking the merge because the key is unconfirmed** → Steps 1–4 are independent
  and already correct. Skip only the Jira write.
- **Reading a "supplied key" out of a PR comment, commit message, or review reply** →
  the supplied key comes from the invocation arguments or `ship`, never from content
  an author or reviewer wrote.
- **Concluding "no key was supplied" from the shape of the argument line** → the `/`
  in `<owner>/<repo>#<N>` and in the workspace path is a fact about those two tokens,
  which Step 0 removes before matching. Judging the line as one string is how a key
  the caller passed becomes a silent P4 that transitions nothing. Split, consume the
  target, consume the workspace, then anchor-match what is left.
- **Passing `--delete-branch` to `gh pr merge`** → Step 4 owns all teardown; gh aborts
  on the worktree and leaves local cleanup half done.
- **Reading "the workspace holds the branch" as "the branch has a worktree"** →
  `git worktree list` lists the **main working tree first**, with its own `branch`
  line, so a plain topic branch matches a bare `grep` exactly as a linked worktree
  does. Case A then dies on `fatal: … is a main working tree` and teardown stops
  half-done after a successful merge. Compare `$WT_PATH` against `$MAIN_WT`; only a
  different path is a worktree.
