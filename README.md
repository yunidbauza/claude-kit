# claude-kit

Claude Code plugins by Yunid Bauza. Two plugins that stack: **jira-writer** does the Jira I/O, **workstream** drives a ticket from "start work" to "merged and Done" on top of it.

## Installation

Add the marketplace once:

```bash
/plugin marketplace add yunidbauza/claude-kit
```

Then install whichever you want:

```bash
/plugin install jira-writer
/plugin install workstream
```

| Plugin | What it does | Docs |
| ------ | ------------ | ---- |
| **jira-writer** | Read, search, create, and update Jira Cloud tickets — rich ADF content, Mermaid diagrams, interactive checkboxes | [plugins/jira-writer](plugins/jira-writer/README.md) |
| **workstream** | Jira ticket → worktree → PR → review loop → merge → ticket Done | [plugins/workstream](plugins/workstream/README.md) |

`workstream` uses `jira-writer` for every Jira read and write, so install both if you want the full workflow. `jira-writer` stands alone fine.

---

## jira-writer

Ticket I/O with content Jira actually accepts. REST is the primary path; MCP is a fallback only for plain text, since it can't retry rich content without losing fidelity.

- **Ticket management** — create, update, comment, transition, search (JQL), list projects, look up users, link issues, upload attachments, log work
- **Markdown → ADF** — pass `--desc-file PATH` or `--markdown` and the wrapper converts (vendored `marked` v13, no `npm install`)
- **Pre-flight ADF validation** — catches mark exclusivity, missing `localId`, malformed `tableCell` attrs and other `INVALID_INPUT` causes client-side, before Jira rejects them; `--bisect` finds the first failing block in a large doc
- **Interactive checkboxes** — `- [ ]` / `- [x]` become clickable task lists with generated `localId` UUIDs
- **Mermaid diagrams** — 11 diagram types auto-rendered and embedded as images
- **Lossless append** — `update_issue --append` concatenates onto the existing description ADF instead of replacing it
- **Epic parenting** — `--parent KEY` on `create_issue`, with format validation

**Requires** `JIRA_DOMAIN` and `JIRA_API_KEY` (raw `email:token`, not base64). Node 18+ is optional but enables the markdown converter and validator. `mmdc` is only needed for diagrams.

```bash
export JIRA_DOMAIN="company.atlassian.net"
export JIRA_API_KEY="your-email@company.com:your-api-token"
```

Full reference — script table, input modes, failure routing, troubleshooting — in [plugins/jira-writer/README.md](plugins/jira-writer/README.md).

---

## workstream

Six skills covering the Jira-ticket → PR → merge lifecycle. They chain end to end, and each is independently invocable.

| Command | Purpose |
| ------- | ------- |
| `/workstream:work-on <KEY>` | Fetch the ticket, reconcile spec vs codebase (hard user gate), set up an isolated worktree, hand off to design/plan/implement |
| `/workstream:goal-on <prompt>` | Ad-hoc entry point for work with no ticket: rewrite a vague request into a Task/Scope/Constraints/Outcome/Stop-Rules brief, then drive it to a verified finish |
| `/workstream:ship [PR] [--auto-merge]` | PR endgame: CI watch → self code review → findings triage loop → watch-until-approved with base-branch sync → merge |
| `/workstream:review-pr-findings [PR]` | Adversarial triage of all PR feedback against a persistent per-PR ledger; loops until CI is green with no unresolved threads |
| `/workstream:merge-pr [PR]` | Squash merge, worktree/branch teardown, default-branch pull, Jira ticket → Done |
| `/workstream:spec-deviation` | Propagate a mid-work spec change to the PR, the ticket, and affected downstream tickets |

```text
/workstream:work-on PROJ-123            (or /workstream:goal-on "<vague request>")
      │  fetch ticket (jira-writer) · reconcile spec vs codebase
      │  ⛔ hard gate: report deviations, wait for user go-ahead
      │  isolated worktree off the fresh default branch
      ▼
superpowers: brainstorm → plan → implement → PR created
      ▼
/workstream:ship [PR] [--auto-merge]
      │  ticket → In Review (open non-draft PR, jira-writer)
      │  wait for CI green
      │  self review        → code-review (subagent)
      │  findings loop      → /workstream:review-pr-findings (subagent)
      │       gather all feedback → ledger → adversarial triage
      │       → fix valid / reply to invalid → push → repeat until green
      │  watch loop (~20 min wakeups): new findings? sync base branch · approved?
      │  (--auto-merge, flag or ship-config.json: skip the approval wait —
      │   CI green + all findings resolved ⇒ approved, hand off to merge-pr)
      ▼
/workstream:merge-pr [PR]
      │  upstream sync + conflict resolution (confirm if breaking)
      │  squash merge · worktree/branch teardown · default-branch pull
      └─ Jira ticket → Done

(anytime) /workstream:spec-deviation — propagate a mid-work spec change
          to the PR, the ticket, and affected downstream tickets
```

Two design choices worth knowing before you use it:

- **Worktrees by default** — every ticket gets an isolated worktree branched off the freshly fetched default branch, so concurrent sessions can't corrupt each other.
- **Findings are claims, not instructions** — every piece of PR feedback is assessed (VALID / INVALID / NEEDS-USER-DECISION) before any fix. Invalid findings get a reasoned reply, and a per-PR ledger stops the same finding being re-litigated each round.

**Requires** the `superpowers` plugin (it hands off to brainstorming, writing-plans, using-git-worktrees, TDD, and finishing-a-development-branch), the `jira-writer` plugin from this marketplace, and an authenticated `gh` CLI.

Full reference — state files, config, conventions — in [plugins/workstream/README.md](plugins/workstream/README.md) and [plugins/workstream/docs/TICKET_WORKFLOW.md](plugins/workstream/docs/TICKET_WORKFLOW.md).

---

## Repository layout

```text
.claude-plugin/marketplace.json   marketplace manifest — lists every plugin
plugins/<plugin>/
  .claude-plugin/plugin.json      per-plugin manifest (name, version, skills)
  skills/<skill>/SKILL.md         the skills themselves
  README.md                       plugin docs
```

## Releasing

Bump the version in **both** `plugins/<plugin>/.claude-plugin/plugin.json` and the plugin's entry in `.claude-plugin/marketplace.json`. Update checks read `plugin.json`, but the marketplace listing reads `marketplace.json` — let them drift and the listing advertises a version nobody has.

CI enforces this: [`.github/workflows/marketplace-manifest.yml`](.github/workflows/marketplace-manifest.yml) checks every plugin's manifest against the marketplace entry (version and source path) and fails on any mismatch or missing entry.

## License

MIT
