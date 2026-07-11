---
name: jira-writer
description: Read, search, create, and update Jira Cloud tickets — fetch issue details, search with JQL, list projects, look up users, and write rich content with automatic Mermaid diagram embedding
model: claude-sonnet-5
---

# Jira Writer Skill

Read, search, create, and update Jira Cloud tickets. All operations go through one
launcher, `jira-writer`, which prefers the Jira REST API and falls back to the
Atlassian MCP. Rich content (tables, checkboxes, code blocks, Mermaid diagrams) is
handled by passing markdown and letting the plugin convert + validate the ADF.

**Activates when** the user asks to read/view/fetch, search/find, create, update, or
comment on a Jira issue, list projects, look up users, or check issue types — or
provides content (text or markdown) to write to a ticket.

## Prerequisites

Set two environment variables (REST is the primary path):

```bash
export JIRA_DOMAIN="company.atlassian.net"
export JIRA_API_KEY="your-email@domain.com:your_api_token"   # raw email:token, NOT base64
```

- Generate the API token at https://id.atlassian.com/manage-profile/security/api-tokens
- Store the **raw** `email:api_token` string — the scripts base64-encode internally.
- **Fallback:** if REST creds are absent, the wrapper signals the Atlassian MCP
  (`mcp__atlassian__*`). If neither is available, stop and give the setup steps above.
- **Diagrams** additionally need `mmdc` (`npm install -g @mermaid-js/mermaid-cli`),
  checked lazily on first diagram.

REST vs MCP is chosen by content: **checkboxes, images/Mermaid, and attachments
require REST** (MCP can't render them). Everything else tries REST first, then MCP.

## How to invoke

Call the plugin by its **bare command name** — the `bin/jira-writer` launcher is on
the Bash tool's `PATH`, so it resolves from any directory:

```bash
jira-writer get_issue PROJ-123
```

**Do NOT** prefix with `$CLAUDE_PLUGIN_ROOT` or an absolute path — that variable is
exported only to hook/MCP subprocesses, expands to empty in the Bash tool shell, and
fails every time. If you hit `command not found` / "scripts missing", the plugin
updated mid-session — **restart Claude Code** (see `reference/troubleshooting.md`).

## Command cheat-sheet

```bash
# Read / search
jira-writer get_issue PROJ-123 [FIELDS] [--summary-only]
jira-writer search_jql "project = PROJ AND status = Open"
jira-writer get_projects
jira-writer get_issue_types PROJECT_KEY
jira-writer get_transitions PROJ-123
jira-writer lookup_user "alice@example.com"

# Create (‑‑desc-file/‑‑markdown convert markdown → validated ADF automatically)
jira-writer create_issue PROJECT_KEY TYPE SUMMARY [DESC] [--desc-file PATH] [--markdown] [--parent KEY]
jira-writer create_issue INCORP Story "OAuth support" --desc-file /tmp/spec.md --parent INCORP-172

# Update (pass only field values; wrapper wraps with {"fields": ...})
jira-writer update_issue PROJ-123 '{"summary":"New title"}'
jira-writer update_issue PROJ-123 FIELDS_JSON --desc-file PATH --markdown
# FIELDS_JSON + --desc-file merge in ONE call: rename + rewrite body together
jira-writer update_issue PROJ-123 '{"summary":"New title"}' --desc-file /tmp/body.md

# Comment (‑‑markdown / ‑‑desc-file for rich ADF comments)
jira-writer add_comment PROJ-123 "Quick note."
jira-writer add_comment PROJ-123 "## Update\n- [x] Done" --markdown

# Other
jira-writer transition_issue PROJ-123 TRANSITION_ID
jira-writer upload_attachment PROJ-123 /path/to/file.png
jira-writer add_worklog PROJ-123 "2h"
jira-writer validate_adf /tmp/my-adf.json [--bisect]   # local ADF check, no Jira call

# Diagnostics & mermaid
jira-writer doctor              # dependency status (JSON)
jira-writer connection-test     # API connectivity + recommendation
jira-writer mermaid <key> <file_or_code> [filename]
jira-writer mermaid-batch <key> '<json_array_of_diagrams>'
```

**Aliases:** the wrapper accepts verb-only (`issue`, `create`, `comment`, `search`,
`projects`), camelCase (`getIssue`), and `jira_`-prefixed names. Unknown ops exit 2
with a "Did you mean: …" suggestion. Default issue type is `Task`.

## Recommended path: markdown, not hand-built ADF

For almost everything, write markdown and let the plugin convert:

```bash
jira-writer create_issue INCORP Story "OAuth support" --desc-file /tmp/oauth-spec.md --parent INCORP-172
jira-writer add_comment  INCORP-173 "## Update

- [x] Code review complete" --markdown
```

The wrapper runs `markdown-to-adf.mjs`, validates with `adf-validate.mjs`, and only
then POSTs. On a validation failure nothing hits Jira — you get an `api:"error"`
envelope naming the rule that fired and the offending node's path.

## Response envelopes (quick reference)

- `{"api":"rest","data":{...}}` — REST success; `.data` is the Jira response body.
- `{"api":"mcp_fallback",...}` — REST failed on **plain** content; retry via the named MCP tool with `params`.
- `{"api":"error",...}` — failed with no MCP fallback (rich ADF 4xx, or attachment upload). Report it; no retry path.

Full shapes + the v1.5.0 error-vs-fallback nuance: `reference/troubleshooting.md`.

## Deeper reference (read on demand)

Load these only when the task needs them — keep them out of context otherwise:

| File | When to read |
|------|--------------|
| `reference/workflow.md` | Full Step 1–7 flow: mermaid processing, complexity detection, append/replace/insert/prepend update modes, rollback |
| `reference/adf.md` | Hand-building ADF: node catalog, inline marks, media layouts, gotchas (mark exclusivity, localId, tableCell attrs), rich-comment example |
| `reference/mermaid.md` | Supported diagram types, conversion options, filename/validation conventions, upload helpers |
| `reference/troubleshooting.md` | Envelope shapes, graceful degradation, error table, rollback, known issues & gotchas |
| `reference/examples.md` | 10 worked request→execution walkthroughs |
