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

## Step 2: Squash merge

```bash
gh pr merge --squash --delete-branch
```

If the user wants to review or edit the squash commit message first, open
`gh pr view --web` and let them complete the merge manually.

## Step 3: Clean up the local workspace

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
git checkout "$DEFAULT"
git pull origin "$DEFAULT"
```

### Case B — a plain topic branch

```bash
git checkout "$DEFAULT"
git pull origin "$DEFAULT"
git branch -d "$BRANCH"
```

If `git branch -d` refuses because the branch is not fully merged locally (expected
after a squash), use `-D` — the squash merge on the remote is the authoritative
record.

Either case leaves the session in the main working tree on the repo's default
branch (`$DEFAULT` — usually `main`).

## Step 4: Move the linked Jira ticket to Done

1. Parse a ticket key from the branch name, case-insensitively — worktree branches
   and plain branches both keep the key somewhere in the name:

   ```bash
   KEY=$(printf '%s' "$BRANCH" | grep -oiE '[a-z]+-[0-9]+' | head -1 | tr '[:lower:]' '[:upper:]')
   ```
2. If nothing matches, check the PR title and body: `gh pr view --json title,body`.

If a key is found: **invoke the `jira-writer:jira-writer` skill** (never raw Jira REST/curl —
jira-writer handles credentials) and transition the
ticket to **Done**. If no ticket reference exists anywhere, skip this step and note
it in the final report.

## Error handling

| Situation | Action |
|---|---|
| CI failing | Stop. Report the failing check. Do not merge. |
| CI not yet run | Wait for checks to complete. Do not skip. |
| Merge conflict | Stop. Surface the conflict. Resolve before merging. |
| Remote branch already deleted | Proceed — the PR was already merged elsewhere. |
| `git branch -d` refused | Use `-D` after confirming the squash succeeded remotely. |
| Local branch already deleted (gh removed it during merge) | Proceed — nothing to clean up. |
| `git worktree remove` refused (dirty) | Add `--force`; the remote squash is authoritative. |
| Worktree already gone | Skip removal; run `git worktree prune` + branch delete, proceed. |
| Jira ticket not found | Skip Step 4. Note it to the user. |

## Workflow context

- Merges always use the **squash strategy** — one clean commit on the default
  branch per PR.
- Each PR touches exactly one repo; a ticket may have produced several PRs — run
  this workflow once per PR.
- Never merge directly to the default branch without a PR.
- If a `~/.claude/workstream/pr-ledgers/<owner>-<repo>-pr<N>.md` ledger exists for this PR, delete
  it after the merge succeeds (ship also deletes it when orchestrating; deleting
  twice is harmless).
