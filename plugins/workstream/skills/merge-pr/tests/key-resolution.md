# Step 5 ticket-key resolution tests

Representative cases for checking that `merge-pr` Step 5 transitions the right Jira
ticket — or, more often, correctly refuses to transition any. Re-run these by hand
after editing Step 0, Step 5, or the red flags. No runner executes these;
the check is reading the skill against each row and confirming it lands on the stated
action.

`Supplied key` means a key from the invocation arguments — typed by the user, or
passed down by `ship` from its own confirmed Step 3. It is the only load-bearing
confirmation. The branch name, PR title, and PR body never confirm a key.

## Cases

| # | Branch name | Supplied key | Expected action | Rule |
|---|---|---|---|---|
| 1 | `fix/SEC-1-hotfix-rollup-BILLING-9001` | — | Transition nothing. Report both `SEC-1` and `BILLING-9001`. | P5 |
| 2 | `feat/proj-1316-merge-pr-guard` | — | Transition nothing. Report `PROJ-1316` as an unconfirmed candidate. | P4 |
| 3 | `feat/proj-1316-merge-pr-guard` | `PROJ-1316` | Transition `PROJ-1316` to Done. | P1 |
| 4 | `feat/proj-1316-merge-pr-guard` | `PROJ-1400` | Transition nothing. Report both — the supplied key contradicts the branch. | P2 |
| 5 | `goal/ship-injection-hardening` | — | Skip. Note that no ticket reference was found. | P3 |
| 6 | `goal/ship-injection-hardening` | `PROJ-1316` | Transition `PROJ-1316` to Done — the branch has no key to contradict it. | P1 |
| 7 | `goal/ship-injection-hardening`, PR body says "Closes PROJ-1316" | — | Skip. The body is written by the PR author and never confirms. | P3 |
| 8 | `revert-proj-1300-proj-1316` | — | Transition nothing. Report both `PROJ-1300` and `PROJ-1316`. | P5 |
| 9 | `revert-proj-1300-proj-1316` | `PROJ-1316` | Transition `PROJ-1316` to Done — a trusted source resolves the ambiguity. | P1 |
| 10 | `feat/PROJ-1316-guard` | `proj-1316` | Transition `PROJ-1316` to Done — matching is case-insensitive. | P1 |
| 11 | `revert-proj-1300-proj-1316` | `PROJ-9999` | Transition nothing. Report `PROJ-9999` and both branch keys — the supplied key matches neither. | P2 |
| 12 | `feat/proj-1316-merge-pr-guard`, invoked as `merge-pr https://github.com/…/pull/58#issuecomment-1234567890` | — | No supplied key. `issuecomment-1234567890` is a substring of the PR argument, not a whole token, so it is not a key. Falls through to the branch candidate. | P4 |
| 13 | `goal/ship-injection-hardening` | `PROJ-1300 PROJ-1316` | Transition nothing. Report both. With no branch key nothing contradicts either one, so P1 alone would pick arbitrarily. | P0 |
| 14 | `revert-proj-1300-proj-1316` | `PROJ-1300 PROJ-1316` | Transition nothing. Both match branch keys, so P1 fires twice — supplying both does not resolve P5's ambiguity. | P0 |
| 15 | `feat/proj-1316-merge-pr-guard`, invoked as `merge-pr owner/repo#142 <workspace> PROJ-1316` | `PROJ-1316` | Transition `PROJ-1316` to Done. The three-argument form is what `ship` passes; consuming the PR target and the workspace leaves exactly one token, and the `/` in the first two is not a reason to stop before matching it. | P1 |
| 16 | `feat/proj-1316-merge-pr-guard`, Step 0's `arguments:` line reads literally `$ARGUMENTS` | — (harness did not interpolate) | Treat as no arguments: take the cwd bootstrap and fall through to the branch candidate. Do **not** parse the token as a target. | P4 |
| 15 | `feat/proj-1316-merge-pr-guard` | `PROJ-1316 proj-1316` | Transition `PROJ-1316`. One distinct key after uppercasing and de-duplication. | P1 |
| 16 | `feat/proj-1316-merge-pr-guard`, PR already `MERGED` | `PROJ-1316` | Step 0 skips Steps 1–3, runs teardown and Step 5, transitions `PROJ-1316`, and reports that this run did not perform the merge. | P1 |
| 17 | `feat/proj-1316-merge-pr-guard`, PR `CLOSED` with null `mergedAt` | `PROJ-1316` | Stop at Step 0. Transition nothing — unmerged work never closes a ticket, even with a trusted key. | — |

## Invariants that hold across every case

- **The merge itself always completes.** Steps 1–4 (CI check, upstream sync, squash
  merge, worktree/branch teardown, default-branch pull) are never blocked by an
  unconfirmed key. Only Step 5 is skipped.
- **Every non-transitioning case is reported, never silent.** The report names the
  candidate keys it found, so the user can re-run with the right one or move the
  ticket by hand.
- **No case is resolved by branch-name ordering.** Case 1 is the regression this file
  exists for: the old `head -1` picked `SEC-1` purely because it came first.
- **The rules are total.** Every combination of branch-key count (0 / 1 / 2+) against
  supplied-key state (absent / one matching / one matching none / 2+ supplied) lands on
  exactly one rule, with P0 checked before P1–P5. Two cells once fell through:
  - Case 11 — with P2 scoped to a single branch key, a supplied key matching neither of
    two branch keys matched no rule at all, and the nearest attractor was P1, silently
    transitioning a ticket the branch never named.
  - Cases 13–14 — multiple supplied keys. Note that a *mixed* multi-key input (one key
    matching a branch key, one not) was already safe, because it fires both P1 and P2
    and the "matches two rules → transition nothing" backstop catches it. The unsafe
    inputs were the ones with **no** double match to detect: zero branch keys (nothing
    contradicts either key) and two branch keys with both supplied (both match). P0
    closes all of them by refusing before the table is consulted.

**Cases 16–17 exercise Step 0's already-merged fast path, and the gate matters more
than the path.** The fast path may be entered *only* on GitHub reporting
`state: MERGED` with a non-null `mergedAt`. It must never be inferred from a local
symptom — a missing worktree, a failed `git checkout`, or a non-zero `gh pr merge` are
all equally produced by branch protection, a missing approval, or a red required check,
and reading those as "already merged" would skip the CI gate on an unmerged PR and
write a terminal Done on work that never landed. Case 17 is the counterpart: a trusted
supplied key does **not** license closing a ticket whose PR was abandoned.

**Reading the skill is not enough to catch a `$BRANCH` that never got set.** Step 5
re-derives the branch from `gh pr view --json headRefName` for exactly that reason: an
empty branch name makes every row behave as "no branch keys", which turns off the P2
contradiction check and lets a wrong supplied key through P1. When checking these
cases, confirm the derivation is present, not just that the table is right.

## Case 2 is the common one

The everyday `work-on` branch with a single key and no supplied key does **not**
transition on its own. That is intended, not a bug: without `ship` passing its
confirmed key, nothing available to a forked subagent distinguishes "the ticket this
PR is for" from "a ticket named in the branch". The remote-link check is tried and
returns nothing in our Jira (the GitHub development panel is a separate source the
MCP does not expose). Confirming costs the user one word.
