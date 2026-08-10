---
name: merge-pr
description: >-
  Use when the user asks to "merge the PR", "squash and merge", "complete the
  merge", "finish the PR", or an orchestrating skill (ship) hands off a PR that is
  approved and green. Runs the full merge checklist — verify CI, squash merge,
  tear down the worktree or local branch, pull main, and move the linked Jira
  ticket to Done.
context: fork
agent: general-purpose
---

# PR Merge Workflow

Execute the full merge checklist for an open, ready pull request. Always follow all
steps in order.

This skill runs in a forked subagent with no conversation history, so it cannot
infer which PR is meant from earlier chat — resolve the target explicitly first.

## Step 0: Identify the target — repository, PR number, and workspace

**A PR number is not an identifier.** `#66` exists in every repository you have
ever worked in, and `gh` decides which one it means from the **current working
directory** — which this skill does not control. A forked subagent inherits
neither the conversation nor the caller's directory, so the cwd it starts in may
belong to an entirely different project. A bare `gh pr merge 66` there merges
*that* project's PR 66, and the merge is irreversible.

This is not a hypothetical failure mode. It is the default one whenever the
session was launched from a different repo than the work lives in — which is
normal for cross-repo tickets and for anything `goal-on` moved into a worktree.

The rest of this file already spells identity correctly in one place — the ledger
path, `<owner>-<repo>-pr<N>`. Every command below uses those same three parts.

Resolve all three before touching anything:

```bash
# 1. The workspace: where the PR's branch is checked out and was verified.
#    ship passes this; otherwise see "Finding the workspace" below.
WT=<absolute path>

# 2. The repository — resolved FROM THE WORKSPACE, never from cwd.
REPO=$(git -C "$WT" remote get-url origin \
        | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')

# 3. The PR number, from the caller's argument.
PR=<number>

echo "target: $REPO#$PR in $WT"
```

From here on **every command carries its target explicitly**: `gh` commands take
`--repo "$REPO"`, `git` commands take `-C "$WT"`. A bare `gh pr` or `git` command
anywhere below this line is a bug.

### The guard that actually holds

`--repo` is only ever as correct as whatever resolved it, and resolution is the
step that fails. So do not rely on it alone. Before **any** mutating command,
assert that the commit GitHub is about to merge is the exact commit this workspace
verified:

```bash
PR_HEAD=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq '.headRefOid')
LOCAL_HEAD=$(git -C "$WT" rev-parse HEAD)

if [ "$PR_HEAD" != "$LOCAL_HEAD" ]; then
  echo "ABORT: $REPO#$PR is at $PR_HEAD but $WT is at $LOCAL_HEAD"
  exit 1
fi
```

A mismatch means one of exactly two things, and both are stop conditions:

1. **The target is the wrong repository.** Two unrelated repos cannot share a head
   SHA, so this check fails closed however badly the target was resolved — which
   is the property `--repo` alone cannot give you.
2. **The branch moved after it was verified.** Someone pushed while the gates were
   running, so merging now lands code that no review and no CI has seen. This is
   the more likely failure on a repo you *are* standing in, and it matters most
   under ship's `--auto-merge`, where nothing else is watching.

Re-run the assertion immediately before Step 3 if Step 2 pushed a sync merge: both
values move together, and the check is only worth anything against current ones.

### Finding the workspace, when the caller passed none

`git worktree list` is itself cwd-resolved, so it can only be trusted once you
already know you are in the right repository. Establish that first:

```bash
BRANCH=$(gh pr view "$PR" --repo "$REPO" --json headRefName --jq '.headRefName')
git -C "$WT" rev-parse --verify "refs/heads/$BRANCH"
```

If no workspace was passed **and** the current directory's repository does not
contain the PR's branch, **stop and report**. Do not fall back to cwd and do not
guess: the whole point of this step is that a plausible-looking wrong answer is
available at every turn.

## Step 1: Verify CI status

```bash
gh pr checks "$PR" --repo "$REPO"
```

- All checks pass → proceed.
- Checks still running → wait and re-check before proceeding.
- Any check failed → **stop**. Surface the failure. Do not merge.
- **Zero checks reported** → this is not "green". It means either the repo has no
  CI, or you are looking at the wrong PR. Confirm which before proceeding; the
  head-SHA assertion in Step 0 distinguishes them.

## Step 2: Sync with upstream — detect drift and conflicts

The base branch may have moved since this PR was last synced. Detect both cases
BEFORE merging:

```bash
BASE=$(gh pr view "$PR" --repo "$REPO" --json baseRefName --jq '.baseRefName')
git -C "$WT" fetch origin
gh pr view "$PR" --repo "$REPO" --json mergeable,mergeStateStatus
git -C "$WT" rev-list --count "HEAD..origin/$BASE"   # commits that landed upstream since divergence
```

Syncing and conflict resolution happen in the PR's working tree — that is `$WT`,
which Step 0 already resolved.

- **Up to date and MERGEABLE** → proceed to Step 3.
- **Behind, no conflicts** → assess what landed before absorbing it:
  `git -C "$WT" log --oneline HEAD..origin/$BASE` and
  `git -C "$WT" diff HEAD...origin/$BASE --stat`.
  Compare against the PR's own diff — did upstream touch files, interfaces, or
  behavior this PR modifies or relies on? No overlap → merge `origin/$BASE` into
  the branch, push, wait for CI green, proceed. Overlap → merge, run the repo's
  targeted verification on the affected paths, and treat any behavioral
  interaction as a conflict for the purposes of the confirmation rule below.
- **CONFLICTING** → merge `origin/$BASE` into the branch and resolve each conflict
  deliberately: first read the upstream commits that introduced the conflicting
  hunks (`git -C "$WT" log -p origin/$BASE -- <file>`) so you understand BOTH
  intents, then resolve preserving both. Never resolve by blanket
  `--ours`/`--theirs`. After resolving: run the repo's targeted verification,
  commit the merge, push, and wait for CI green before proceeding.
- **Confirmation hard stop:** if a resolution (or absorbing upstream changes)
  would break or drastically change functionality that a previously merged PR
  introduced — or materially change what THIS PR was reviewed as doing — do NOT
  merge and do NOT push a guess. This skill runs in a forked subagent that cannot
  ask questions interactively: abort the merge and report back with the
  conflicting files, both sides' intent, and your proposed resolution, so the
  user can confirm before merge-pr is re-run.

Anything pushed here moves both `PR_HEAD` and `LOCAL_HEAD`. Re-run Step 0's
assertion before Step 3.

## Step 3: Squash merge

```bash
gh pr merge "$PR" --repo "$REPO" --squash
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
`gh pr view "$PR" --repo "$REPO" --web` and let them complete the merge manually
(still without `--delete-branch`).

Confirm the merge landed on the PR you targeted before cleaning anything up:

```bash
gh pr view "$PR" --repo "$REPO" --json state,mergedAt,mergeCommit \
  --jq '{state, mergedAt, mergeCommit: .mergeCommit.oid}'
```

## Step 4: Clean up the local workspace

Work started with `work-on` lives in a **git worktree**, not just a branch on the
shared checkout. Resolve the head branch and detect which case applies:

```bash
BRANCH=$(gh pr view "$PR" --repo "$REPO" --json headRefName --jq '.headRefName')
DEFAULT=$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')
git -C "$WT" worktree list --porcelain | grep -qxF "branch refs/heads/$BRANCH" \
  && echo WORKTREE || echo BRANCH
```

### Case A — the branch has a worktree (default for `work-on` tickets)

Tear the worktree down with **git**, not `ExitWorktree` — this skill runs in a
forked subagent, and `ExitWorktree` only acts on worktrees the same session created.
Operate from the main working tree (you cannot remove the worktree you stand in):

```bash
MAIN_WT=$(git -C "$WT" worktree list --porcelain \
          | awk '/^worktree /{sub(/^worktree /,""); print; exit}')
WT_PATH=$(git -C "$WT" worktree list --porcelain \
          | awk -v b="branch refs/heads/$BRANCH" '/^worktree /{p=$0; sub(/^worktree /,"",p)} $0==b{print p; exit}')

git -C "$MAIN_WT" worktree remove "$WT_PATH" --force   # --force: after a squash the branch has commits not on local main
git -C "$MAIN_WT" worktree prune
git -C "$MAIN_WT" branch -D "$BRANCH"                  # the branch ref lingers after the worktree is removed
git -C "$MAIN_WT" push origin --delete "$BRANCH"       # gh no longer deletes the remote branch; harmless if it is already gone
git -C "$MAIN_WT" checkout "$DEFAULT"
git -C "$MAIN_WT" pull origin "$DEFAULT"
```

`$MAIN_WT` is derived from `$WT`, not from cwd — the first entry of
`git worktree list` is the main working tree **of whichever repository you asked**,
and asking the wrong one here would delete a branch in a project you were never
working on.

### Case B — a plain topic branch

```bash
git -C "$WT" checkout "$DEFAULT"
git -C "$WT" pull origin "$DEFAULT"
git -C "$WT" branch -d "$BRANCH"
git -C "$WT" push origin --delete "$BRANCH"   # Step 3 no longer uses --delete-branch, so tear the remote branch down here
```

If `git branch -d` refuses because the branch is not fully merged locally (expected
after a squash), use `-D` — the squash merge on the remote is the authoritative
record.

Either case leaves the session in the main working tree on the repo's default
branch (`$DEFAULT` — usually `main`).

## Step 5: Move the linked Jira ticket to Done

1. Parse a ticket key from the branch name, case-insensitively — worktree branches
   and plain branches both keep the key somewhere in the name:

   ```bash
   KEY=$(printf '%s' "$BRANCH" | grep -oiE '[a-z]+-[0-9]+' | head -1 | tr '[:lower:]' '[:upper:]')
   ```
2. If nothing matches, check the PR title and body:
   `gh pr view "$PR" --repo "$REPO" --json title,body`.

If a key is found: **invoke the `jira-writer:jira-writer` skill** (never raw Jira REST/curl —
jira-writer handles credentials; if jira-writer isn't installed, use the
Atlassian MCP (Rovo) tools directly) and transition the
ticket to **Done**. If no ticket reference exists anywhere, skip this step and note
it in the final report.

## Report back

Name the target you acted on, in full, so the caller can tell a correct merge from
a confident wrong one:

```text
merged <owner>/<repo>#<N> — squash <sha>, branch <branch> torn down, <KEY> → Done
```

## Error handling

| Situation | Action |
|---|---|
| Head SHA mismatch (Step 0) | **Stop.** Report both SHAs and the resolved `$REPO`/`$WT`. Never merge past this. |
| No workspace passed, cwd's repo lacks the branch | **Stop and report.** Do not fall back to cwd. |
| `gh pr checks` reports zero checks | Not green. Confirm the repo genuinely has no CI (the Step 0 assertion rules out wrong-PR). |
| CI failing | Stop. Report the failing check. Do not merge. |
| CI not yet run | Wait for checks to complete. Do not skip. |
| Merge conflict | Resolve via Step 2 (understand both intents, verify, push), then re-run the Step 0 assertion. Abort and report for confirmation if the resolution breaks/changes previously merged functionality. |
| Remote branch already deleted (auto-delete-on-merge, or a prior run) | `git push origin --delete` prints "remote ref does not exist" — treat as success and proceed. |
| `git branch -d` refused | Use `-D` after confirming the squash succeeded remotely. |
| `gh pr merge` aborts with "already used by worktree" | Only if `--delete-branch` was passed (Step 3 omits it). The remote merge already succeeded — ignore the error and let Step 4 own cleanup. |
| `git worktree remove` refused (dirty) | Add `--force`; the remote squash is authoritative. |
| Worktree already gone | Skip removal; run `git worktree prune` + branch delete, proceed. |
| Jira ticket not found | Skip Step 5. Note it to the user. |

## Workflow context

- Merges always use the **squash strategy** — one clean commit on the default
  branch per PR.
- Each PR touches exactly one repo; a ticket may have produced several PRs — run
  this workflow once per PR.
- Never merge directly to the default branch without a PR.
- If a `~/.claude/workstream/pr-ledgers/<owner>-<repo>-pr<N>.md` ledger exists for this PR, delete
  it after the merge succeeds (ship also deletes it when orchestrating; deleting
  twice is harmless).
