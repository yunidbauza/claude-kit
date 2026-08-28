# Step 3 merge-gate tests

Representative cases for checking that `merge-pr` Step 3 refuses to merge on anything
except a reading taken **in the call immediately before the merge**. Re-run these by
hand after editing Step 1, Step 2, Step 3, the error-handling table, or the red flags.
No runner executes these; the check is reading the skill against each row and
confirming it lands on the stated action.

The failure this guards against was a real one, and it did not come from a missing
check. The right check — review *threads*, not comment counts — was run, and then the
user said "merge it", and a reading that was minutes old was treated as current. In
those minutes a review agent that was still working finished and posted findings.
**A merge gate is only a gate if it is evaluated at the instant of merging.**

Throughout: **the gate** is Step 3's single `gh api graphql` + `git rev-parse` call
and its `GATE: CLEAR` / `GATE: HOLD` verdict; **CLEAR** is valid for exactly one
following call.

## Cases

| # | Situation | Expected action | Why |
|---|---|---|---|
| 1 | Gate returns `CLEAR`; `gh pr merge … --match-head-commit <that SHA>` is the very next call | Merge. | The normal path — one reading, one merge, nothing between them. |
| 2 | Gate ran, reported "green, no unresolved threads" to the user, user replied "merge it" | **Re-run the gate.** The reply is what made the reading stale. | The exact failure this step exists for. The instruction to merge starts the gate; it never confirms one. |
| 3 | Gate HOLDs on `checks still running`; after the wait the checks are green | **Re-run the whole gate**, not just the checks. | New review threads land *during* the wait. Clearing a HOLD one line at a time re-creates the bug in slow motion. |
| 4 | `review still requested from: copilot-… [Bot]`, everything else green | **HOLD.** Wait for it to submit, re-run the whole gate. | A requested reviewer that has not submitted is mid-run, not silent. Its findings arrive as threads. This is the case that caused the original merge-past-findings. |
| 5 | Same as 4, still pending after ~10 minutes of polling | **Stop and report** what is pending. | merge-pr is a forked subagent and cannot ask whether to keep waiting. Fail closed, hand the decision back. |
| 5a | `review still requested from: alice [User] — reviewDecision=APPROVED`, everything else green | **Stop and report**, naming alice. Do not wait it out, and do not remove her request. | A human request someone else's approval already satisfied can sit for days, so polling is not a plan — but dropping another person's review request is the caller's decision, not this skill's. |
| 6 | Two unresolved threads, both `isOutdated: true` | **HOLD.** | GitHub does not resolve outdated threads; a thread going stale is not a thread being addressed. |
| 7 | Unresolved threads, and resolving them would make the gate green | **Never resolve to clear the gate.** Hand back to `review-pr-findings`. | Resolving to pass is disabling the gate, not passing it. |
| 8 | `reviewThreads.pageInfo.hasNextPage` is true | **HOLD.** Paginate before deciding. | A truncated reading cannot support "zero unresolved". Truncated is never CLEAR. |
| 9 | A bot's `CHANGES_REQUESTED` review stands, every thread resolved | **HOLD.** Only a new review from that reviewer clears it. | Self-assessment is not a review. GitHub blocks the merge anyway; the gate should say why first. |
| 10 | `statusCheckRollup` is `null` / zero contexts | **HOLD** until it is established that the repo has no CI. | "No checks failed" and "no checks ran" read identically — Step 1's rule, applied at merge time. |
| 11 | Gate `CLEAR`, then a PR comment is posted, then the merge | **Re-run the gate.** | Any intervening call voids the reading. The list is not "risky calls" — it is *any* call. |
| 12 | Step 2 absorbed upstream and pushed; Step 3 runs | The gate's own reading covers it — the push moved the head, restarted CI, and may have woken a review agent. | The gate is taken after Step 2 by construction; a reading from before it describes a different head. |
| 13 | Gate `CLEAR` at `abc123`; someone pushes; the merge call carries `--match-head-commit abc123` | GitHub **rejects** the merge. Re-run the gate; do not retry without the flag. | The rejection is the check firing. Dropping the flag to get past it removes the only server-side enforcement of freshness. |
| 14 | The gate block is run with `<workspace>` unsubstituted, or `gh` returns nothing | **HOLD — empty reading.** | `-C ""` and `--repo ""` both fall back to cwd without erroring. Empty is never a pass — the same rule as Step 0. |
| 15 | ship's Step 6 loop saw `APPROVED` + green + no threads one wake ago, and passes that to merge-pr as "already verified" | merge-pr runs the gate regardless. | Upstream evidence says the PR *was* ready. Only the gate is contemporaneous with the merge. |
| 16 | `review-pr-findings` returned "CI green, all threads resolved" | Same as 15 — evidence, not authorisation. | It returned before the handoff; the handoff itself takes time. |
| 17 | The user asks to merge by hand in the web UI | Run the gate first anyway. | A hand merge needs the same reading, and a HOLD is a reason not to open the page. |
| 18 | Gate `CLEAR`; the run reports "merged" without naming the gate SHA | **Defect.** The report names `gate: CLEAR at <sha>`. | Without it the report cannot distinguish "fine when I looked" from "fine when I merged" — the same unfalsifiability problem as an unqualified `merged PR 58`. |
| 19 | PR state comes back `MERGED` in the gate | Step 0's fast path — skip to teardown. | The gate is not the place to discover this, but it must not read `MERGED` as mergeable either. |
| 20 | `mergeable: UNKNOWN` | **HOLD**, re-query. | GitHub is still computing it; unknown is not mergeable. |

## Invariants that hold across every case

- **The gate is one call.** Every merge-blocking fact comes from a single GraphQL
  reading plus the workspace head, so no two of them are separated in time. A
  checks reading from 14:02 and a threads reading from 14:05 describe two different
  pull requests, and neither describes the one being merged.
- **A `CLEAR` has a lifetime of one call.** Not one step, not one turn, not "until
  something changes" — one call. Void means re-run the block, never re-read its output.
- **Waiting is an outcome.** Running checks and unsubmitted reviewers are HOLDs that
  resolve by waiting and re-reading, bounded, then reported.
- **Every HOLD leaves the PR unmerged.** No case here resolves a HOLD by judging the
  finding to be unimportant; that judgement belongs to `review-pr-findings`.
- **The gate subsumes Step 0's head-SHA assertion** rather than repeating it — same
  comparison, same two meanings on a mismatch (wrong repository, or a push landed
  mid-run), now taken at the moment that matters. Step 0's standalone run is
  pre-flight only.
- **`--match-head-commit` carries the gate's verdict into the merge**, so the freshness
  rule has a server-side backstop and not only a prose one.
