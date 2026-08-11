# Step 0 target-resolution tests

Representative cases for checking that `merge-pr` Step 0 resolves the right
**repository, PR number and workspace** — or refuses to act. Re-run these by hand
after editing Step 0, Step 3, Step 4, or the red flags. No runner executes these; the
check is reading the skill against each row and confirming it lands on the stated
action.

The failure this guards against is not exotic. `#66` exists in every repository the
session has ever touched, `gh` resolves it from the current working directory, and
`merge-pr` runs `context: fork` — so it starts in whatever directory the harness gave
it, with no conversation to correct from. The merge is irreversible.

Throughout: **workspace** is the checkout the PR's branch lives in, **resolved repo**
is `git -C <workspace> remote get-url origin` reduced to `<owner>/<repo>`, and cwd is
whatever directory the subagent happened to start in.

## Cases

| # | Situation | Expected action | Why |
|---|---|---|---|
| 1 | `merge-pr owner/repo#58 <wt> PROJ-1316`, workspace `origin` is `owner/repo` | Proceed. Every `gh` carries `--repo owner/repo`, every `git` carries `-C <wt>`. | The normal path. |
| 2 | Same, but cwd is a different repo entirely | Proceed, identically. | The repo comes from the workspace, never cwd — the whole point of Step 0. |
| 3 | `merge-pr 58` with no workspace, cwd is a repo whose branch matches PR 58's `headRefName` | Proceed, after the bootstrap verifies **both** that cwd's repo has PR 58 and that its branch is checked out there. | Cwd may *suggest* a target; the bootstrap is what promotes it to an answer. |
| 4 | `merge-pr 58` with no workspace, cwd's repo has a PR 58 but on a different branch | **Stop.** Report the branch mismatch. | A same-numbered PR in the wrong project is the exact collision this exists for. |
| 5 | `merge-pr 58` with no workspace, cwd is not a git repo | **Stop.** No candidate to verify. | Nothing to derive a repo from. |
| 6 | `merge-pr other/repo#58 <wt>` where `<wt>`'s `origin` is `owner/repo` | **Stop.** The argument and the workspace name different targets. | Neither is authoritative over the other; guessing picks a coin flip on an irreversible merge. |
| 7 | Workspace path has no `origin` remote (or the path is wrong) | **Stop** at the `[ -n "$REPO" ]` guard. | `gh --repo ""` does not error — it resolves from cwd, silently restoring the bug. |
| 8 | PR head SHA is `612ed9c`, workspace `HEAD` is `a15e473` | **Stop** before Step 3. Report both SHAs and the resolved repo/workspace. | Either the wrong repository (two repos cannot share a head SHA) or a push landed mid-run. Both are stop conditions. |
| 9 | `gh pr view --json headRefOid` returns empty and `git rev-parse HEAD` returns empty | **Stop.** Empty is never a match. | `[ "" != "" ]` is false — without the emptiness check the guard fails *open* on exactly the input most likely to be wrong. |
| 10 | Step 2 merges `origin/main` and pushes, then Step 3 | Re-run the assertion first. | The push moved both heads; a stale comparison proves nothing. |
| 11 | PR is `MERGED` with a non-null `mergedAt`, workspace already back on `main` | Skip Steps 1–3, **do not** run the head-SHA assertion, run teardown and Step 5. | The assertion gates Step 3 only. Applying it here would abort the bookkeeping re-run this path exists to allow. |
| 12 | Same as 11, but the workspace holds neither the branch nor its worktree | Skip teardown entirely and say so. Still run Step 5. | Step 4's own branch check is what guards teardown in place of the assertion. Never delete a branch from a workspace that does not hold it. |
| 13 | `gh pr checks 58 --repo <owner>/<repo>` returns zero checks | **Not green.** Establish whether the repo has any workflows before proceeding. | "No checks failed" and "no checks ran" read identically; one of them is a wrong PR. |
| 14 | A repository with no workflows at all reports zero checks | Proceed, having confirmed there are none. | Case 13's legitimate half — it has to be established, not assumed. |
| 15 | Step 4 Case A cleanup | `MAIN_WT` comes from `git -C <workspace> worktree list`, not a bare one | A bare call answers for cwd's repository, and this branch deletes refs with the answer. |
| 16 | Step 5 re-derives the branch after teardown | `gh pr view <N> --repo <owner>/<repo> --json headRefName` | GitHub still knows `headRefName` after the branch is deleted both ends — but only if asked about the right repo. |
| 17 | Report says "merged PR 58" with no owner/repo | **Defect.** The report must name `<owner>/<repo>#<N>` and the main working tree path. | An unqualified report is unfalsifiable: a wrong-target merge reports success just as confidently as a right one. |
| 18 | Step 4's Case A block runs as its own call, having only `BRANCH=`/`DEFAULT=` from the detection block above it | **Defect.** Both are empty; `git branch -D ""` and `git checkout ""` fail and `WT_PATH` resolves empty, so teardown half-completes while the merge looks fine. Re-read both inside the block. | Same class as case 7 — a value that did not survive a call boundary is indistinguishable from one that resolved wrong, and both fail quietly. |
| 19 | PR head branch is `foo;whoami` or `foo$(id)` — both **valid** git refs (`git check-ref-format` exits 0) | The ref must be re-read in-call and expanded **quoted**. Inlining it as bare text into `git branch -D <branch>` executes the author's command during cleanup. | Fixing case 18 by textual substitution converts a quiet bug into arbitrary code execution. Both constraints hold at once: never across a call, never as bare text. |
| 20 | `merge-pr https://github.com/B/repo/pull/60 <workspace in A>` | **Stop.** A PR URL is repo-qualified; its slug must be parsed and checked against the workspace's `origin` exactly like `<owner>/<repo>#<N>`. | Otherwise the caller's explicit target is silently discarded in favour of the workspace — and if A also has a PR 60, the run proceeds against the wrong one. |
| 21 | `merge-pr <owner>/<repo>#<N> <KEY>` re-run after a normal merge, no workspace passed, cwd on the default branch, topic branch deleted | Resolve PR state from the supplied repo **first** → `MERGED` → skip Steps 1–3, skip teardown (nothing holds the branch), run Step 5. | This is the recovery path Step 5 documents. A bootstrap that demands a branch workspace before checking state aborts here every time, so the documented recovery never works. |
| 22 | ship Step 1 pass one, session in repo A, PR in repo B | Resolve repo + `headRefName` from the argument first; then, finding no route from A to a worktree of B, **require the workspace argument**. | `git worktree list` only enumerates the current repository's worktrees, so there is no search path across repos. That is a missing input, not a reason to fall back to cwd. |

## Invariants that hold across every case

- **The repository is derived from the workspace, never from cwd.** Cwd is a
  candidate to be verified (case 3) or nothing at all.
- **Empty is never a pass.** An empty repo slug, an empty head SHA, or an
  unsubstituted placeholder is a stop — because `--repo ""` and `-C ""` both fall back
  to cwd without erroring.
- **The target is carried as literals, not shell variables.** Shell state does not
  survive between calls in this harness, so a `$REPO` set in Step 0 arrives at Step 3
  as `--repo ""` — indistinguishable from a value that resolved to the wrong thing,
  and with the same consequence.
- **The head-SHA assertion gates Step 3 only** (cases 8–11). Teardown is gated by
  Step 4's own branch check instead (case 12).
- **Every stop leaves the PR unmerged and the ticket untouched.** No case in this
  file resolves ambiguity by picking a side.
- **Step 5's P0–P5 key rules are unaffected** by any of this — see
  `key-resolution.md`. Target resolution decides *which PR*; those rules decide
  *which ticket*.
