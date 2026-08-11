---
name: merge-pr
description: >-
  Use when the user asks to "merge the PR", "squash and merge", "complete the
  merge", "finish the PR", or an orchestrating skill (ship) hands off a PR that is
  approved and green. Runs the full merge checklist — verify CI, squash merge,
  tear down the worktree or local branch, pull main, and move the linked Jira
  ticket to Done. Pass the repo-qualified PR and a ticket key
  (`merge-pr owner/repo#123 PROJ-456`) to close it; a key found only in the
  branch name is reported, not transitioned.
context: fork
agent: general-purpose
---

# PR Merge Workflow

Execute the full merge checklist for an open, ready pull request. Always follow all
steps in order.

This skill runs in a forked subagent with no conversation history, so it cannot
infer which PR is meant from earlier chat — resolve the target explicitly first.

## Step 0: Identify the target — repository, PR number, workspace, and the supplied ticket key

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

Re-run the assertion immediately before Step 3 if Step 2 pushed a sync merge: both
values move together, and the check is only worth anything against current ones.

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

- **A Jira issue key among the arguments** — e.g.
  `merge-pr owner/repo#123 PROJ-456` — is the **supplied key**: the trusted
  ticket for Step 5. `ship` passes the key it confirmed in its own Step 3 this way.
  Record it now; Step 5 is its only consumer.

  Match it against a **whole argument token**, anchored (`^[A-Za-z]+-[0-9]+$`,
  case-insensitive), after setting aside the arguments already consumed above — the
  PR number/URL/`<owner>/<repo>#<N>` and the workspace path — never as a substring of
  the argument string. Unanchored, a pasted comment permalink supplies a key of its
  own: `…/pull/58#issuecomment-1234567890` contains `issuecomment-1234567890`, which
  matches the bare pattern and would be recorded as the trusted ticket. The anchoring
  is also what keeps the two new argument forms out of the count: both contain `/`,
  so neither can match a whole token.

  **Exactly one.** Collect every whole-token match, uppercase, and de-duplicate. Two
  or more **distinct** keys is not a supplied key — it is a contradiction (**P0**
  below): transition nothing, report every supplied key alongside every branch key,
  and say the invocation must name exactly one. Do **not** resolve it by picking the
  one that happens to match the branch name — with no branch key nothing contradicts
  either, and with two branch keys both match, so P1 alone would pick arbitrarily and
  re-open the ambiguity P5 exists to close. The merge still completes; only the Jira
  write is skipped.
- No key among the arguments → **there is no supplied key.** Do not substitute one
  from the branch name, the PR title, or the PR body; Step 5 handles that case
  explicitly.

## Step 1: Verify CI status

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

Anything pushed here moves both the PR head and the workspace head. **Re-run Step 0's
assertion before Step 3.**

## Step 3: Squash merge

Step 0's head-SHA assertion must have passed against **current** values immediately
before this command. It is the only check that fails closed on a wrong repository.

```bash
gh pr merge <N> --repo <owner>/<repo> --squash
```

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
(still without `--delete-branch`).

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
git -C <workspace> worktree list --porcelain | grep -qxF "branch refs/heads/$BRANCH" \
  && echo WORKTREE || echo BRANCH
```

**Re-derive `BRANCH` and `DEFAULT` at the top of every block below, and always
expand them quoted — `"$BRANCH"`, `"$DEFAULT"`.** This is the one place the
literal-substitution rule does **not** apply, and the exception is load-bearing in
both directions:

- Crossing a call boundary is still forbidden. A `$BRANCH` set here is empty in Case
  A, and every consequence is quiet: `git branch -D ""` and `git checkout ""` fail,
  and the `awk` matches `branch refs/heads/` against nothing, so `WT_PATH` comes back
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
branch. If neither case below matches, the workspace is not this PR's: skip teardown,
say so, and go to Step 5.

### Case A — the branch has a worktree (default for `work-on` tickets)

Tear the worktree down with **git**, not `ExitWorktree` — this skill runs in a
forked subagent, and `ExitWorktree` only acts on worktrees the same session created.
Operate from the main working tree (you cannot remove the worktree you stand in):

```bash
# Re-read inside this call — never carried from the block above, never inlined as text.
BRANCH=$(gh pr view <N> --repo <owner>/<repo> --json headRefName --jq '.headRefName')
DEFAULT=$(gh repo view <owner>/<repo> --json defaultBranchRef --jq '.defaultBranchRef.name')
[ -n "$BRANCH" ] && [ -n "$DEFAULT" ] || { echo "ABORT: branch/default not resolved"; exit 1; }

MAIN_WT=$(git -C "<workspace>" worktree list --porcelain \
          | awk '/^worktree /{sub(/^worktree /,""); print; exit}')
WT_PATH=$(git -C "<workspace>" worktree list --porcelain \
          | awk -v b="branch refs/heads/$BRANCH" '/^worktree /{p=$0; sub(/^worktree /,"",p)} $0==b{print p; exit}')
[ -n "$MAIN_WT" ] && [ -n "$WT_PATH" ] || { echo "ABORT: worktree not resolved"; exit 1; }

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

### Case B — a plain topic branch

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
main working tree: <path>
```

The main working tree is reported because the caller may be standing inside the
worktree this skill just deleted, and a process whose cwd no longer exists cannot run
`git` to find its way out. Naming the path is what lets ship return somewhere real
instead of asking a bare `git worktree list` from a directory that is gone.

## Error handling

| Situation | Action |
|---|---|
| Head SHA mismatch (Step 0) | **Stop.** Report both SHAs and the resolved repo/workspace. Never merge past this. |
| Either head reads empty (Step 0) | **Stop.** An empty `--repo`/`-C` silently falls back to cwd; empty is never a match. Fix the resolution, do not retry past it. |
| The repository resolves empty | **Stop.** The workspace has no `origin`, or the workspace path is wrong. Do not continue with an empty `--repo`. |
| A repo-qualified argument disagrees with the workspace's `origin` | **Stop.** The caller and the workspace name different targets; resolve which is right before acting. Applies to a PR **URL** exactly as to `<owner>/<repo>#<N>`. |
| Branch/base name contains `;`, `$(`, `` ` ``, `&`, `\|` | These are **valid** git refs and the author chose them. Never inline a ref as bare text; re-read it in-call and expand it quoted. |
| Repo-qualified re-run on a merged PR, no workspace passed | Resolve state from the supplied repo **first**. Do not demand a branch workspace — teardown already removed it, and requiring it would break the documented recovery. |
| No workspace passed, cwd's repo lacks the branch | **Stop and report.** Do not fall back to cwd. |
| `gh pr checks` reports zero checks | Not green. Confirm the repo genuinely has no CI (Step 0's assertion rules out a wrong PR). |
| Step 4 finds the workspace on neither the branch nor its worktree | Skip teardown entirely and report it. Never delete a branch from a workspace that does not hold it. |
| CI failing | Stop. Report the failing check. Do not merge. |
| CI not yet run | Wait for checks to complete. Do not skip. |
| Merge conflict | Resolve via Step 2 (understand both intents, verify, push), then **re-run Step 0's assertion** — the push moved both heads. Abort and report for confirmation if the resolution breaks/changes previously merged functionality. |
| Remote branch already deleted (auto-delete-on-merge, or a prior run) | `git push origin --delete` prints "remote ref does not exist" — treat as success and proceed. |
| `git branch -d` refused | Use `-D` after confirming the squash succeeded remotely. |
| `gh pr merge` aborts with "already used by worktree" | Only if `--delete-branch` was passed (Step 3 omits it). The remote merge already succeeded — ignore the error and let Step 4 own cleanup. |
| `git worktree remove` refused (dirty) | Add `--force`; the remote squash is authoritative. |
| Worktree already gone | Skip removal; run `git -C "$MAIN_WT" worktree prune` + branch delete, proceed. |
| Jira ticket not found | Skip Step 5. Note it to the user. |
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
- **Passing `--delete-branch` to `gh pr merge`** → Step 4 owns all teardown; gh aborts
  on the worktree and leaves local cleanup half done.
