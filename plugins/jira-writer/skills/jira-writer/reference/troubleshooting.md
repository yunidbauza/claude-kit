# Troubleshooting & Known Issues

## Output Envelope Shapes

Every wrapper invocation returns JSON in one of three shapes:

1. **REST success:** `{"api": "rest", "data": {...}}` — succeeded via REST. `.data` is the Jira response body.
2. **MCP fallback:** `{"api": "mcp_fallback", "operation": "...", "params": {...}, "rest_error": "...", "note": "..."}` — REST failed (no creds, network, or 4xx/5xx). Retry via the corresponding MCP tool with `params`. `.note` warns when pre-built ADF won't render rich through MCP.
3. **Non-recoverable error:** `{"api": "error", "operation": "...", "params": {...}, "rest_error": "..."}` — failed, no MCP fallback. Report to user; no retry path.

**v1.5.0 behavior change:** When the wrapper sends ADF (from markdown or passed in
directly) and Jira REST returns a 4xx, the failure emits `api:"error"` rather than
`api:"mcp_fallback"` — MCP cannot retry rich ADF (checkboxes, tables, marks). The
`api:"error"` envelope includes `rest_error` (the REST `errorMessages`) and a
clarifying `note`. Plain-text input is unchanged — REST failure still emits
`mcp_fallback`. The script header (`jira-api-wrapper.sh:14-27`) is authoritative.

## Graceful Degradation

| Missing | Behavior |
|---------|----------|
| REST API credentials | Fall back to MCP; if MCP unavailable, stop with setup instructions |
| MCP | REST API handles everything (no impact if REST configured) |
| Both REST and MCP | Skill cannot function; stop with setup instructions |
| JIRA_EMAIL + JIRA_API_KEY but no JIRA_DOMAIN | Text ops via MCP; diagrams/checkboxes skipped with warning |
| mmdc | Diagrams skipped with warning; offer installation |

## Error Response Table

| Stage | Error | Action |
|-------|-------|--------|
| Prerequisites | REST unavailable, MCP unavailable | STOP; provide setup instructions |
| Prerequisites | REST auth failed | WARN; try MCP fallback |
| Prerequisites | JIRA_DOMAIN missing | ASK user to provide |
| Prerequisites | mmdc missing | OFFER install; if declined, skip diagrams |
| Mermaid validation | Syntax error | REPORT details; skip diagram, continue others |
| PNG conversion | mmdc fails | REPORT error; skip diagram |
| Attachment upload | 401/403 | STOP; report auth error, check API key |
| Attachment upload | 404 | STOP; issue doesn't exist |
| Attachment upload | Other error | RETRY once; if fails, skip with warning |
| Description update | REST error | TRY MCP fallback (simple content); ROLLBACK attachments; report |
| Section detection | Section not found | ASK user for clarification |
| Wrapper exit 2 | Unknown operation or unknown flag | Suggestion/known-flags list shown; check op/flag name. Data starting with `--word` goes after a lone `--` |

## Rollback Procedure

When a description update fails after attachments were uploaded:
```
FOR each uploaded attachment_id:
    curl -X DELETE \
      -H "Authorization: Basic $(echo -n "$JIRA_EMAIL:$JIRA_API_KEY" | base64 | tr -d '\n')" \
      "https://$JIRA_DOMAIN/rest/api/3/attachment/$attachment_id"
REPORT: "Failed to update the issue description. I've cleaned up the uploaded
         diagram attachments to avoid orphaned files. Error: [details]"
```

## Partial Success (Batch Diagrams)

```
CONTINUE processing remaining diagrams
REPORT at end: "Embedded 2 of 3 diagrams successfully.
                Diagram 2 skipped due to syntax error: [details]"
```

## `jira-writer: command not found` / "scripts missing" / raw "No such file or directory"

Cause depends on the harness.

**Copilot CLI — expected, not a fault.** Copilot does not add a plugin's `bin/` to
the shell `PATH`, and exports no plugin-root variable of any kind. Bare
`jira-writer …` can never work there. Resolve the launcher first (see "How to
invoke" in `SKILL.md`):

```bash
JW=$(command -v jira-writer || { ls -td ~/.copilot/installed-plugins/*/jira-writer/bin/jira-writer 2>/dev/null; \
                                 ls -td ~/.claude/plugins/cache/*/jira-writer/*/bin/jira-writer 2>/dev/null; } | head -1)
"$JW" get_issue PROJ-123
```

**Claude Code — the plugin updated mid-session**, so the cached `PATH` entry points at
a directory that no longer exists. **Restart Claude Code** to refresh it. The resolve
line above also recovers within the session, because `ls -td` sorts newest-first and
skips the dead cache entry.

If `$JW` resolves empty, the plugin is not installed for the current harness — run
`copilot plugin install jira-writer@claude-kit` or `/plugin install jira-writer`.

Do **not** prefix with `$CLAUDE_PLUGIN_ROOT` in either harness: it is exported only to
hook/MCP subprocesses, never to the Bash tool shell, so it expands to empty and fails —
and under Copilot it does not exist at all.

## Known Issues & Gotchas

1. **Credential format** — `JIRA_EMAIL` holds the account email and `JIRA_API_KEY` the
   **raw** token; the scripts join and base64-encode them internally. Wrong:
   `export JIRA_API_KEY=$(echo -n "email:token" | base64)`. Also wrong now:
   `export JIRA_API_KEY="email:token"` — the pre-1.11.0 combined form, still accepted
   but deprecated, and it warns once per run until split. `"$JW" doctor` reports
   the form in effect as `credential_format`: `split` (good), `legacy_combined` (split
   it), `half_migrated` (`JIRA_API_KEY` still carries the `email:` prefix — drop it),
   or `incomplete`.
2. **ADF Media nodes** — use `type: "external"` with the attachment content URL, not
   `type: "file"` with an ID. URL: `https://$JIRA_DOMAIN/rest/api/3/attachment/content/<id>`.
3. **MCP cannot handle complex ADF** — checkboxes become escaped text (not interactive
   taskList); media isn't supported. Use REST for checkboxes/images/diagrams.
4. **MCP cannot update description with raw ADF** — `editJiraIssue` treats input as
   markdown. For ADF with media/checkboxes, PUT via REST directly.
5. **Checkbox ADF requires unique localIds** — UUID per `taskList` and `taskItem`.
6. **Attachment upload requires REST API** — MCP has no file upload; use multipart.
7. **Issue not found (404)** — usually wrong domain or permissions. Verify JIRA_DOMAIN
   and token scope.
8. **REST vs MCP fallback** — REST preferred; MCP fallback is automatic for simple
   content only. Complex content has no MCP fallback.
9. **Issue-link direction** — `link_issues FROM TYPE TO` reads as a sentence:
   `link_issues A Blocks B` ⇒ "A blocks B" (B "is blocked by A"). Under the
   hood the mapping is counterintuitive (verified against live link objects,
   `GET /issueLink/{id}`): in the REST `/issueLink` body the issue that
   PERFORMS the outward verb ("blocks") is the link's **inwardIssue**, and
   the receiving issue is the **outwardIssue** — so the wrapper POSTs
   FROM→inwardIssue, TO→outwardIssue. Never assume outwardIssue carries the
   outward description; that "obvious" reading inverts every link. Reading
   `get_issue` output is unaffected: an `issuelinks` entry containing
   `inwardIssue: X` means "is blocked by X"; `outwardIssue: Y` means
   "blocks Y". After creating a link via the MCP fallback, verify the
   direction with `get_issue` and re-create if reversed.
