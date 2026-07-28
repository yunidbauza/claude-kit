---
name: spec-deviation
description: >-
  Use when an implementation has deviated from what its Jira ticket specifies — a
  design decision changed mid-work, the plan diverged from the ticket, or the user
  says "update the ticket with the deviation", "add UPDATED SPECS", or "update the
  downstream/Epic tickets affected by this change".
---

# Spec Deviation Propagation

## Overview

When implementation diverges from the ticket spec, the deviation must land in three
places — the PR, the ticket, and the downstream tickets that inherit the changed
assumption. Missing the third is the common failure: sibling stories then get built
on the old spec.

All Jira writes go through the `jira-writer:jira-writer` skill (never raw REST/curl); if jira-writer isn't installed, use the Atlassian MCP (Rovo) tools instead.

This skill is workspace-agnostic: every write targets the PR (`gh api`) or Jira,
both of which work identically from a `work-on` worktree or a plain checkout. No
branch/worktree setup or teardown here — that belongs to `work-on` and `merge-pr`.

## Steps

**1. Write the deviation statement once.** 2–5 sentences: what the ticket said,
what was actually done, why. This exact text is reused in every step below — do not
re-draft per destination.

**2. PR description.** Add/refresh a `## Deviation from spec` section with the
statement. `gh pr edit` can fail on such bodies — use
`gh api repos/{owner}/{repo}/pulls/<N> -X PATCH -f body=...` (or `--input` with a
payload file written via the Write tool).

**3. Current ticket.** Append a section titled `UPDATED SPECS` to the ticket
description (do not rewrite the original spec — the history matters). Include the
statement, the date, and the PR link.

**4. Downstream tickets.** Fetch the Epic's remaining (not-Done) stories and any
tickets linked to this one. Remember the link-direction gotcha: in Jira's API,
`inwardIssue` is the BLOCKER side and `outwardIssue` is the BLOCKED side — opposite
of natural reading; verify direction against the rendered ticket, not the raw field
names. Dispatch a subagent (a cheaper model is fine — this is reading work) to read
the candidate tickets and flag which ones rely on the changed assumption. Present
the list of affected tickets and proposed edits to the user for confirmation BEFORE
writing — then apply the same `UPDATED SPECS` treatment to each confirmed ticket.

**5. Report.** One short summary: deviation statement + which tickets/PR were
updated, with links.

## Formatting

- Jira content goes through jira-writer, which writes ADF. Known ADF gotchas: the
  `code` mark is exclusive (no other marks on the same text), and bare code fences
  without a language are rejected — always tag fences with a language.
- For `gh` bodies use `--body-file - <<'EOF'` heredocs; backticks stay plain, never
  backslash-escaped.

## Red flags

- Updating only the current ticket → downstream stories inherit stale specs; always
  run Step 4.
- Rewriting the ticket's original description instead of appending `UPDATED SPECS`.
- Editing downstream tickets without user confirmation of the affected list.
- Trusting `inwardIssue`/`outwardIssue` to mean what they sound like.
