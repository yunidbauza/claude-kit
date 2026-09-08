---
name: work-on
description: >-
  Use when starting work on a Jira ticket — "work on PROJ-123", "start ABC-42",
  "read the ticket and prepare a plan", picking up the next story in an Epic, or
  any new feature/bug work that begins from a Jira ticket rather than an ad-hoc
  request.
---

# Work On (start a ticket)

## Overview

Ticket specs go stale: the codebase moves after the ticket was written (earlier
stories in the Epic, merged PRs, renamed modules). Before planning anything,
reconcile the ticket against the code as it exists TODAY and surface deviations —
otherwise the plan implements against a world that no longer exists. **The codebase
is the source of truth.**

The full lifecycle this skill starts: reconcile → worktree → brainstorm → plan →
implement → **draft** PR → `ship` → `merge-pr`. The PR is opened as a draft so
CI (gated on `draft == false`) stays off during ship's self review; ship marks it
ready-for-review — the single CI trigger — only once the review passes.

**The reconciliation report is the one stop.** The user's go-ahead there authorises
everything after it, through to `ship`'s hand-off to `merge-pr`. Nothing downstream
ends the turn to ask "shall I continue?": brainstorm decisions are asked in one
batch (Step 6), the draft PR opens without a menu (Step 7), and ship is invoked in
the same turn the PR is created. Whether the merge itself waits for a human is
ship's decision, from its auto-merge config — not a question work-on asks.
Measured over a week of tickets, the questions this section removes idled sessions
for one to four hours each, and every answer was the default.

## Steps

**0. Resolve the ticket key.** Take it from the arguments (`PROJ-123` — any Jira
project, pattern `[A-Za-z]+-[0-9]+`, uppercased). No key given → ask the user.

**1. Fetch the ticket** with the `jira-writer:jira-writer` skill (never raw REST/curl; if jira-writer isn't installed, use the Atlassian MCP (Rovo) tools instead — either is fine). Keep
the fetch lean — context bloat starts here:

- Fetch the **full body and all comments** of the target ticket.
- Fetch the Epic's **summary** (title + short description), not its full body.
- List sibling stories as **titles + keys + status**, and read **their comments**
  for anything that amends scope, decisions, or acceptance criteria — pull those in;
  skip their bodies and status-noise/chatter.
- Fetch the **full body and comments** of only the issues **directly linked** to the
  target (blocking/blocked-by/relates). Unlinked siblings stay title + comment-scan
  only.

Comments are where a written spec gets quietly overridden ("skip the migration",
"endpoint moved to /v2", "read-path only, follow-up ticket for writes"). Treat a
comment that amends scope, decisions, or acceptance criteria as **authoritative over
the description**, and carry those amendments — and any description-vs-comment
contradiction — into the reconciliation as candidate deviations.

**2. Reconcile ticket vs codebase (subagents).** Dispatch 1–3 parallel `Explore`
subagents (reading + pattern-matching — a cheaper model is fine). Scope exploration
to the ticket itself and the linked issues from Step 1:

- Does anything the ticket asks for already exist (fully or partially)?
- Do the file paths, module names, schemas, and interfaces the ticket references
  still match reality?
- Did the **linked** prior work change assumptions the ticket relies on?
- Do the ticket's comments (or a linked/sibling ticket's) amend the description — a
  scope cut, a changed approach, a decision — and does the code already reflect it?

Give each subagent the relevant ticket excerpt — the body plus the spec-affecting comments surfaced in Step 1 — and ask for a short verdict plus
concrete `file:line` evidence per mismatch — not full file dumps. If the ticket
spans multiple repos, reconcile against each affected repo.

**3. Report, then STOP — hard gate.** Present a short summary: what the ticket
says, what the code says, and each mismatch with a recommended resolution (follow
ticket / follow code / needs decision). Include whether the ticket description
should be updated. Then END YOUR TURN and wait for the user's go-ahead — even with
zero deviations ("no deviations found, ready to plan — proceed?" is the whole
message in that case). Never continue into Step 4/5 in the same turn as the report.
If a deviation is confirmed, the `spec-deviation` skill propagates it to Jira
and the PR later.

**4. Set up an isolated worktree (default).** Every ticket gets its own git
worktree, not just a topic branch on the shared checkout — concurrent sessions on
one checkout clobber each other's refs.

Run `git fetch origin` first so the remote-tracking ref is current — without it the
worktree can be rooted at a stale base. Then invoke the
**`superpowers:using-git-worktrees`** skill to create the workspace — it owns the
mechanics (detect existing isolation, prefer the native `EnterWorktree` tool, fall
back to `git worktree add`, verify the dir is ignored). Branch fresh from the repo's
default branch (`origin/$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')`
— usually `origin/main`). Choices to feed it:

- **Branch name:** request `feat/<key>-<short-kebab-description>` (lowercased key,
  e.g. `feat/proj-123-add-widget`). Native tooling may sanitize the name into its
  own format — that is fine; the ONE invariant is that the ticket key survives
  somewhere in the branch name (`merge-pr` parses it case-insensitively). After
  creation, confirm `git branch --show-current` contains the key.
- **Baseline:** install dependencies, then run the repo's cheapest static check —
  discover it from `package.json` scripts / `Makefile` / the project's CLAUDE.md
  (type-check or lint). Skip full test suites; the default branch is already green.
- **Multi-repo tickets:** each affected repo gets its own worktree and its own PR.
  A session holds one native worktree at a time — drive each repo from its own
  session, or create additional worktrees with manual `git worktree add`.

**5. Transition the ticket to In Progress** via `jira-writer:jira-writer` when
implementation begins — unless something else (e.g. a user-configured hook) already
moved it; check the current status first.

**6. Plan and implement.** Hand off to the normal superpowers flow:
`superpowers:brainstorming` for design (restate the reconciliation findings from
Step 2 as input there), then `superpowers:writing-plans`, then execute the plan
(choosing inline vs subagents automatically — see below). Step 7 opens the PR.

**Brainstorm questions go out in one batch.** Collect every decision the design
needs before asking any of them, then ask them in a single `AskUserQuestion` call
(it takes up to four questions; a fifth means a second call, never a third). Put
your recommended option first in each. One question per round trip is the shape to
avoid: each answer costs a wait, and a session that asks five questions in sequence
has parked itself five times for the same information one call would have gathered.
Ask a lone follow-up only when an answer genuinely changes what the next question is.

**For tickets with a UI surface:** present the design as a browser-rendered HTML
mockup (ASCII only if the user asks). **One mockup, of the recommended design,**
when the surface follows a pattern the app already has — a settings sub-group, a
chip, a drawer section, another row in an existing table. **Two or three variants**
only when the surface is new to the app, or when the user asks for variants — and
then show them before writing any implementation. Then, the **final implementation
check, before the draft PR is opened, must drive the built UI in a real browser**
(Playwright/e2e specs for the touched surface, or the `verify` skill) to confirm it
renders and behaves as designed — green type-check/unit tests do not prove a UI works.

**Inline is the execution mode.** `superpowers:writing-plans` ends by offering an
execution choice (subagent-driven vs inline). Do NOT ask the user. Run the plan with
`superpowers:executing-plans` — the controller implements in-session, and the plan
already carries the full spec. Subagent-driven development runs an implementer
**and** a reviewer per task, strictly in sequence, each starting cold; measured
across a week of comparable tickets it took four to six times the wall-clock and
five to eight times the cost of an inline run, and most of its per-task reviews found
the same class of nit a single whole-branch review finds once. State the mode in one
line before executing.

**Escalate to `superpowers:subagent-driven-development` only when BOTH hold:**

- The plan spans **two or more subsystems that share no test harness** — a main
  process plus a renderer plus a live conformance suite, a migration plus an API plus
  a UI — so that no single context can hold the whole change and its tests without
  a mid-run compaction. One subsystem, however large, runs inline.
- The change touches a path where a fresh adversarial reviewer per task lowers real
  risk: security, auth, concurrency, money, a wire protocol. A settings page or a
  config block does not qualify on its own.

Task count is not a criterion. A twelve-task plan of edits in one subsystem runs
inline; a four-task plan across three subsystems with a security surface earns
subagents. Two overrides stand: **tightly-coupled tasks** (one cannot be implemented
or reviewed without another in the same edit) force inline regardless; an explicit
**user preference** in the request ("work on … inline" / "… with subagents") wins
over the rule.

If you choose subagent-driven, apply the CWD contract and the loop limits below. If
inline, the controller's own CWD is the worktree, so commits are safe and no
contract is needed.

**Subagent loop limits.** Superpowers' skill sets generous caps; this workflow
tightens them, because the caps are where the hours went:

- **Size every task to twenty minutes of implementer time.** A task an implementer
  cannot finish in that span — "boot, tray and lifecycle" as one task — is two or
  three tasks. Split it in the plan before dispatching, never mid-run.
- **Two fix rounds per task, not five.** After the second scoped re-review still
  leaves findings open, adjudicate them as the skill's breaker does: park with a
  ruling, or rule and carry forward. A loop that has not converged in two rounds is
  not converging.
- **Skip the skill's final whole-branch review.** `ship`'s self code review is this
  PR's whole-branch review: it reads the same diff, on the draft, and its fixes go
  out in one batched push. Running both meant three reviews of one diff inside two
  hours. Hand the ledger's deferred-minor and parked lines to ship's reviewer instead.
- **Never poll a dispatched subagent.** Its result arrives as a task notification
  the moment it stops. A `sleep N; git log` loop in the controller does not see that
  notification until the sleep ends, so every poll overshoots by up to its own
  length — one session lost seventy minutes to it. Between dispatches, do ledger
  work or simply end the tool call and wait.

**Subagent commits must land in the worktree, not the shared checkout.** If you
execute the plan with `superpowers:subagent-driven-development`, mind a CWD gap: a
controller-side `cd` into a git-fallback worktree (superpowers' worktree Step 1b)
does **not** propagate to dispatched subagents — each subagent gets a fresh shell
rooted at the original project root, i.e. the *shared checkout on the base branch*. A
bare `git add`/`git commit` there commits the task onto the base branch in the shared
checkout instead of the feature branch in the worktree — polluting the base branch and
dropping the work from the PR. (Native worktree tools avoid this, but don't rely on
which path created the worktree.) Guard every dispatch:

- Capture the worktree path once in the controller: `WT=$(git rev-parse --show-toplevel)`.
- Give every implementer / fix / task-reviewer subagent that absolute path and require
  it to run **all** git and file commands from there — begin each bash call with
  `cd "$WT"` or use `git -C "$WT" …` — and, before committing, assert
  `[ "$(git rev-parse --show-toplevel)" = "$WT" ]` and that `git branch --show-current`
  is the feature branch. This is the hard version of the template's advisory
  `Work from: [directory]` line; fill that line with the absolute `$WT` path, never a
  bare `.` or the repo name.
- After each task's review comes back clean, verify from the controller that the commit
  actually landed on the feature branch (`git -C "$WT" log --oneline -1`) and that the
  base branch's HEAD in the shared checkout did **not** move. A commit that landed on
  the base branch is a failed task — reset it off the base branch and re-dispatch with
  the CWD contract enforced.

If you cannot guarantee that contract, execute the plan inline
(`superpowers:executing-plans`) from the worktree session instead — the controller's
own CWD is the worktree, so inline commits are always safe.

**7. Open the draft PR and hand off to ship — in the same turn, with no menu.**
Do not invoke `superpowers:finishing-a-development-branch` here. Its job is to ask
"merge locally, push and create a PR, or keep as-is?", and in this workflow the
answer is fixed: the user chose it at the reconciliation gate. Asking again parked
one session for an hour and a half on a question with one answer. Do its
verification yourself, then its Option 2, then continue:

1. **Run the full gate on the exact tree you are about to push**, from the
   worktree: the repo's lint, type-check and unit suite (discover them from its
   CLAUDE.md / `package.json` / `Makefile`); the e2e or browser check when the
   change has a UI surface or crosses files with behaviour. Fix what fails. A red
   gate here is the only thing that stops this step, and it stops it to fix, not
   to ask.
2. `git push -u origin <branch>` from the worktree.
3. **Create the PR as a draft** — `gh pr create --draft`, with a body that
   states what changed and how it was verified. CI is gated to skip draft PRs
   (`if: draft == false`), so ship's self review and its fix pushes run on the
   draft for **zero CI minutes**. Ship marks the PR ready-for-review only after
   the review passes — that single transition is what first triggers CI.
   Opening the PR ready instead burns a full CI run before the review has even
   started.
4. **Invoke the `ship` skill now**, in this same turn, with the repo-qualified
   PR, the worktree path and the ticket key. Do not end the turn on "Draft PR
   #N created" — that sentence was, in every measured session, followed by the
   user typing "ship it" after a wait of forty minutes to three hours. Ship marks
   the PR ready after its self review, moves the ticket to In Review at that
   moment, and decides from its auto-merge config whether the merge waits for a
   human. Leave the worktree in place: ship and merge-pr run from it.

## Red flags

- Writing a plan straight from the ticket text → reconcile first.
- Continuing into worktree setup/planning in the same turn as the reconciliation
  report ("no deviations, so I'll proceed") → the gate applies with zero deviations
  too.
- "The ticket is recent, it can't have drifted" → sibling stories merge daily.
- Reconciling against the ticket description alone while a comment already changed
  the spec → read the comments; one that amends scope/decisions/acceptance criteria
  wins over the body.
- Raw Jira REST/curl instead of jira-writer or the Atlassian MCP.
- Working in the shared checkout instead of an isolated worktree.
- Creating the worktree off the current dirty branch instead of the freshly fetched
  default branch.
- A branch name missing the ticket key → merge-pr can't find the ticket to close.
- Opening the PR ready-for-review instead of a draft → CI runs before ship's self
  review even starts; always `gh pr create --draft` (ship marks it ready).
- Invoking `finishing-a-development-branch` and presenting its menu, or ending the
  turn on "draft PR created" → the go-ahead at the reconciliation gate already
  answered both; push, open the draft, and invoke `ship` in the same turn.
- Asking brainstorm questions one at a time → one `AskUserQuestion` call carries up
  to four; batch them, recommended option first.
- Two or three mockup variants for a surface the app already has a pattern for →
  one mockup of the recommended design; variants are for new surfaces or on request.
- Choosing subagent-driven development for a plan inside one subsystem, or because
  it has many tasks → inline; subagents need two subsystems with no shared harness
  AND a risk surface, both.
- Sleep-polling a dispatched subagent (`sleep N; git log`) → its notification is
  the wake-up; do ledger work or end the call and wait.
- Running the skill's final whole-branch review and then ship's self review on the
  same head → ship's is the whole-branch review; hand it the ledger's parked lines.
- Dispatching subagent-driven-development implementers from a fallback worktree
  without pinning their CWD to `$WT` → their bare `git commit` lands on the base
  branch in the shared checkout, not the feature branch, and the work never reaches
  the PR.
- Presenting UI design options as ASCII art → browser HTML mockups, always.
