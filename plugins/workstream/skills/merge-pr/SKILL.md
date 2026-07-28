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
infer which PR is meant from earlier chat — resolve the target PR explicitly first.

## Step 0: Identify the target PR

- If a PR number or URL was passed as an argument, operate on that PR — pass it to
  every `gh pr` command below.
- Otherwise, operate on the open PR for the **current branch** (the default behavior
  of the `gh pr` commands as written).

## Step 1: Verify CI status

```bash
gh pr checks
```

- All checks pass → proceed.
- Checks still running → wait and re-check before proceeding.
- Any check failed → **stop**. Surface the failure. Do not merge.

## Step 2: Sync with upstream — detect drift and conflicts

The base branch may have moved since this PR was last synced. Detect both cases
BEFORE merging:

```bash
BASE=$(gh pr view <N> --json baseRefName --jq '.baseRefName')
git fetch origin
gh pr view <N> --json mergeable,mergeStateStatus
git rev-list --count HEAD..origin/$BASE   # run from the PR's workspace — commits that landed upstream since divergence
```

Syncing and conflict resolution happen in the PR's working tree: find the branch's
worktree with `git worktree list` and operate there, or check the branch out if no
worktree exists.

- **Up to date and MERGEABLE** → proceed to Step 3.
- **Behind, no conflicts** → assess what landed before absorbing it:
  `git log --oneline HEAD..origin/$BASE` and `git diff HEAD...origin/$BASE --stat`.
  Compare against the PR's own diff — did upstream touch files, interfaces, or
  behavior this PR modifies or relies on? No overlap → merge `origin/$BASE` into
  the branch, push, wait for CI green, proceed. Overlap → merge, run the repo's
  targeted verification on the affected paths, and treat any behavioral
  interaction as a conflict for the purposes of the confirmation rule below.
- **CONFLICTING** → merge `origin/$BASE` into the branch and resolve each conflict
  deliberately: first read the upstream commits that introduced the conflicting
  hunks (`git log -p origin/$BASE -- <file>`) so you understand BOTH intents, then
  resolve preserving both. Never resolve by blanket `--ours`/`--theirs`. After
  resolving: run the repo's targeted verification, commit the merge, push, and
  wait for CI green before proceeding.
- **Confirmation hard stop:** if a resolution (or absorbing upstream changes)
  would break or drastically change functionality that a previously merged PR
  introduced — or materially change what THIS PR was reviewed as doing — do NOT
  merge and do NOT push a guess. This skill runs in a forked subagent that cannot
  ask questions interactively: abort the merge and report back with the
  conflicting files, both sides' intent, and your proposed resolution, so the
  user can confirm before merge-pr is re-run.

## Step 3: Squash merge

```bash
gh pr merge <N> --squash
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
`gh pr view --web` and let them complete the merge manually (still without
`--delete-branch`).

## Step 4: Clean up the local workspace

Work started with `work-on` lives in a **git worktree**, not just a branch on the
shared checkout. Resolve the head branch and detect which case applies:

```bash
BRANCH=$(gh pr view <N> --json headRefName --jq '.headRefName')   # <N> = the PR from Step 0; drop it only when operating on the current branch's PR
DEFAULT=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
git worktree list --porcelain | grep -qxF "branch refs/heads/$BRANCH" && echo WORKTREE || echo BRANCH
```

### Case A — the branch has a worktree (default for `work-on` tickets)

Tear the worktree down with **git**, not `ExitWorktree` — this skill runs in a
forked subagent, and `ExitWorktree` only acts on worktrees the same session created.
Operate from the main working tree (you cannot remove the worktree you stand in):

```bash
MAIN_WT=$(git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /,""); print; exit}')
WT_PATH=$(git worktree list --porcelain | awk -v b="branch refs/heads/$BRANCH" '/^worktree /{p=$0; sub(/^worktree /,"",p)} $0==b{print p; exit}')
cd "$MAIN_WT"
git worktree remove "$WT_PATH" --force   # --force: after a squash the branch has commits not on local main
git worktree prune
git branch -D "$BRANCH"                  # the branch ref lingers after the worktree is removed
git push origin --delete "$BRANCH"       # gh no longer deletes the remote branch; harmless if it is already gone
git checkout "$DEFAULT"
git pull origin "$DEFAULT"
```

### Case B — a plain topic branch

```bash
git checkout "$DEFAULT"
git pull origin "$DEFAULT"
git branch -d "$BRANCH"
git push origin --delete "$BRANCH"   # Step 3 no longer uses --delete-branch, so tear the remote branch down here
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
2. If nothing matches, check the PR title and body: `gh pr view --json title,body`.

If a key is found: **invoke the `jira-writer:jira-writer` skill** (never raw Jira REST/curl —
jira-writer handles credentials; if jira-writer isn't installed, use the
Atlassian MCP (Rovo) tools directly) and transition the
ticket to **Done**. If no ticket reference exists anywhere, skip this step and note
it in the final report.

## Error handling

| Situation | Action |
|---|---|
| CI failing | Stop. Report the failing check. Do not merge. |
| CI not yet run | Wait for checks to complete. Do not skip. |
| Merge conflict | Resolve via Step 2 (understand both intents, verify, push). Abort and report for confirmation if the resolution breaks/changes previously merged functionality. |
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
