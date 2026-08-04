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

**Resolve the launcher first, then call it through `$JW`.** This one line works in
every harness — Claude Code, Copilot CLI, and a plain shell:

```bash
JW=$(command -v jira-writer || { ls -td ~/.copilot/installed-plugins/*/jira-writer/bin/jira-writer 2>/dev/null; \
                                 ls -td ~/.claude/plugins/cache/*/jira-writer/*/bin/jira-writer 2>/dev/null; } | head -1)
"$JW" get_issue PROJ-123
```

Why the resolve step: Claude Code auto-adds each plugin's `bin/` to the Bash tool's
`PATH`, so `command -v` succeeds there. **Copilot CLI does neither — it adds no
plugin `bin/` to `PATH` and exports no plugin-root variable at all** — so the glob
fallback is what finds the launcher.

Three details in that line are load-bearing, so do not "simplify" it:

- The two `ls` calls are **sequential inside `{ … }`**, not one `ls` with two globs.
  A single `ls` sorts all matches together, and `.claude` sorts before `.copilot` —
  which would make Copilot resolve to a Claude cache copy.
- `ls -td` sorts **newest first**, so a stale cached version never wins. With a plain
  `-d`, `1.8.0` sorts before `1.9.0` and you get the older build.
- Order matters: Copilot's path is probed first, Claude's second.

**Tool shells do not persist environment between calls.** `JW=` must therefore be set
in the *same* Bash call that uses it. Include the resolve line in every call that
invokes the plugin; the cheat-sheet below writes `$JW` as shorthand for the resolved
launcher.

Never hard-code an absolute path and never use `$CLAUDE_PLUGIN_ROOT` — it is exported
only to hook/MCP subprocesses, expands to empty in the Bash tool shell, and does not
exist in Copilot. If `$JW` comes back empty the plugin is not installed, or it updated
mid-session and the cache path moved — reinstall or restart the CLI (see
`reference/troubleshooting.md`).

> Optional convenience: `ln -s "$JW" /usr/local/bin/jira-writer` once puts the
> launcher on your real `PATH`, after which bare `jira-writer …` works everywhere.

## Command cheat-sheet

```bash
# Read / search
"$JW" get_issue PROJ-123 [FIELDS] [--summary-only]
"$JW" search_jql "project = PROJ AND status = Open"
"$JW" get_projects
"$JW" get_issue_types PROJECT_KEY
"$JW" get_transitions PROJ-123
"$JW" get_remote_links PROJ-123   # remote/web links attached to an issue
"$JW" lookup_user "alice@example.com"

# Create (‑‑desc-file/‑‑markdown convert markdown → validated ADF automatically)
"$JW" create_issue PROJECT_KEY TYPE SUMMARY [DESC] [--desc-file PATH] [--markdown] [--parent KEY]
"$JW" create_issue INCORP Story "OAuth support" --desc-file /tmp/spec.md --parent INCORP-172

# Update (pass only field values; wrapper wraps with {"fields": ...})
"$JW" update_issue PROJ-123 '{"summary":"New title"}'
"$JW" update_issue PROJ-123 FIELDS_JSON --desc-file PATH --markdown
# FIELDS_JSON + --desc-file merge in ONE call: rename + rewrite body together
"$JW" update_issue PROJ-123 '{"summary":"New title"}' --desc-file /tmp/body.md
# ⚠ --desc-file/--markdown REPLACE the whole description. To ADD to an existing
# rich description (tables/checkboxes/images survive untouched), use --append:
# it fetches the current ADF and concatenates the new content onto it.
"$JW" update_issue PROJ-123 '{}' --desc-file /tmp/extra.md --append

# Comment (‑‑markdown / ‑‑desc-file for rich ADF comments)
"$JW" add_comment PROJ-123 "Quick note."
"$JW" add_comment PROJ-123 "## Update

- [x] Done" --markdown

# Link issues — DIRECTION: reads as a sentence, the FIRST key performs the verb.
# "PROJ-1 Blocks PROJ-2" ⇒ PROJ-1 blocks PROJ-2 (PROJ-2 is blocked by PROJ-1).
"$JW" link_issues PROJ-1 Blocks PROJ-2
"$JW" get_link_types              # valid type names + inward/outward wording

# Other
"$JW" transition_issue PROJ-123 TRANSITION_ID
"$JW" upload_attachment PROJ-123 /path/to/file.png
"$JW" add_worklog PROJ-123 "2h"
"$JW" validate_adf /tmp/my-adf.json   # local ADF check, no Jira call

# Diagnostics & mermaid
"$JW" doctor              # dependency status (JSON)
"$JW" connection-test     # API connectivity + recommendation
"$JW" test_connection     # REST auth check (returns {rest_api: {...}, recommended: ...})
"$JW" mermaid <key> <file_or_code> [filename]
"$JW" mermaid-batch <key> '<json_array_of_diagrams>'
```

**Aliases:** the wrapper accepts verb-only (`issue`, `create`, `comment`, `search`,
`projects`), camelCase (`getIssue`), and `jira_`-prefixed names. Unknown ops exit 2
with a "Did you mean: …" suggestion. Default issue type is `Task`.

## Recommended path: markdown, not hand-built ADF

For almost everything, write markdown and let the plugin convert:

```bash
"$JW" create_issue INCORP Story "OAuth support" --desc-file /tmp/oauth-spec.md --parent INCORP-172
"$JW" add_comment  INCORP-173 "## Update

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
