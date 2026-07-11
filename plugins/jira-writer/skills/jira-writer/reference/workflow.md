# Jira Writer — Full Workflow

Step-by-step flow for creating or updating tickets. The lean `SKILL.md` covers the
common path (`--desc-file --markdown`); read this file when you need the full
diagram / complex-ADF / update-mode machinery.

## Step 1: Resolve Target Issue

```
IF issue key mentioned in request (e.g., "update PROJ-123"):
    USE that issue
ELSE IF issue already in conversation context (previously fetched/discussed):
    USE that issue
ELSE IF multiple issues in context:
    ASK user which one to target
ELSE:
    ASK user: "Which Jira issue should I update, or should I create a new one?"
```

## Step 2: Gather Content

Content sources (in priority order):
1. **Markdown file provided:** Read file, use as content
2. **Explicit content in request:** Use the text/description provided
3. **Conversation context:** Generate content based on discussion

## Step 3: Scan for Mermaid Blocks

```
SCAN content for pattern: ```mermaid ... ```
IF mermaid blocks found:
    EXTRACT each block
    QUEUE for conversion (Step 4)
ELSE:
    SKIP to Step 5
```

## Step 4: Process Mermaid Diagrams

For each mermaid block (see `reference/mermaid.md` for options and diagram types):

```
4a. CREATE temp file
    TEMP_DIR=$(mktemp -d)
    Write mermaid code to $TEMP_DIR/diagram-N.mmd

4b. VALIDATE syntax
    Run: mmdc -i $TEMP_DIR/diagram-N.mmd -o /dev/null 2>&1
    IF error:
        REPORT: "Diagram N has syntax error: [error message]"
        SKIP this diagram, continue with others

4c. CONVERT to PNG
    Run: mmdc -i $TEMP_DIR/diagram-N.mmd -o $TEMP_DIR/diagram-N.png \
         --backgroundColor white --theme neutral --scale 2
    IF error:
        REPORT conversion error
        SKIP this diagram

4d. UPLOAD attachment (REST API required)
    Use: jira-writer upload_attachment $ISSUE_KEY $TEMP_DIR/diagram-N.png
    Or directly:
    POST to: https://$JIRA_DOMAIN/rest/api/3/issue/$ISSUE_KEY/attachments
    Headers:
        Authorization: Basic $JIRA_API_KEY
        X-Atlassian-Token: no-check
    Body: multipart/form-data with file

    CAPTURE attachment ID and content URL from response
    Content URL format: https://$JIRA_DOMAIN/rest/api/3/attachment/content/<id>
    IF error:
        IF 401/403: STOP, report auth error
        IF 404: STOP, report issue not found
        ELSE: Retry once, then skip with warning

4e. TRACK mapping
    Store: mermaid_block_index -> attachment_id
```

## Step 5: Detect Content Complexity

```
SCAN content for complex elements:

has_checkboxes = content contains `- [ ]` or `- [x]` or `* [ ]` or `* [x]`
has_mermaid = mermaid blocks were found in Step 3
has_images = content contains image references

requires_rest_api = has_checkboxes OR has_mermaid OR has_images

IF requires_rest_api:
    USE REST API only (no MCP fallback for complex content)
    PROCEED to Step 5a (Build full ADF manually)
ELSE:
    TRY REST API first
    IF REST fails: FALL BACK to MCP
    PROCEED to Step 6
```

### Recommended path (avoid hand-building ADF)

For most rich tickets, **don't hand-build ADF**. Pass markdown via `--desc-file`
and let the plugin convert + validate:

```bash
jira-writer create_issue INCORP Story "OAuth support" \
  --desc-file /tmp/oauth-spec.md \
  --parent INCORP-172
```

The wrapper runs `markdown-to-adf.mjs`, validates with `adf-validate.mjs`, and
POSTs to Jira. If validation fails (mark exclusivity, missing localId, etc.),
nothing hits Jira and you get a structured `api:"error"` envelope with the rule
that fired and the path to the offending node.

For inline markdown:

```bash
jira-writer add_comment INCORP-173 "## Update

- [x] Code review complete" --markdown
```

Use the manual ADF path (Step 5a) only when you need a node the converter
doesn't support (mediaSingle for attachments, custom marks, mentions). Even then,
write your ADF to a file and pre-flight it with `validate_adf` before sending.

## Step 5a: Build ADF Document (manual fallback)

See `reference/adf.md` for the full node catalog. In brief:

```
CONVERT markdown content to ADF nodes:
    - Headings -> heading nodes
    - Paragraphs -> paragraph nodes
    - Bullet lists -> bulletList/listItem nodes
    - Numbered lists -> orderedList/listItem nodes
    - Checkboxes -> taskList/taskItem nodes (unique UUID localId each)
    - Code blocks -> codeBlock nodes
    - Tables -> table/tableRow/tableHeader/tableCell nodes
    - Bold/italic -> text with marks
    - Links -> text with link mark

FOR each checkbox pattern:
    `- [ ] text` -> taskItem state "TODO"
    `- [x] text` -> taskItem state "DONE"
    Generate unique localId (UUID) for each taskList and taskItem

FOR each mermaid block position:
    REPLACE with mediaSingle node referencing the uploaded attachment URL
```

The same ADF-build instructions apply to **rich comments**: build the ADF
document, then pass it as the body argument to `add_comment` — the wrapper
auto-detects ADF and passes it through.

## Step 6: Write to Jira

Choose API based on content complexity (determined in Step 5).

### Path A: Simple Content (REST with MCP fallback)

**New issues:**
```bash
jira-writer create_issue PROJECT_KEY "Task" "Summary" "Description"
# If envelope indicates MCP fallback: mcp__atlassian__createJiraIssue with
# projectKey, issueTypeName (default "Task"), summary, description (markdown)
```

Issue type mapping: task/unspecified→"Task", story→"Story", bug→"Bug",
spike→"Spike", epic→"Epic", subtask→"Subtask".

**Existing issues:**
```bash
jira-writer update_issue PROJ-123 '{"summary": "New title"}'
# If MCP fallback: mcp__atlassian__editJiraIssue with description (markdown)

# Rename AND rewrite the body in a single call: the FIELDS_JSON is merged with
# the --desc-file body (file wins on the .description key). No two-call dance.
jira-writer update_issue PROJ-123 '{"summary": "New title"}' --desc-file /tmp/body.md
```

### Path B: Complex Content (REST API only)

Content with checkboxes, images, or mermaid diagrams requires REST API.

**New issues:**
```bash
# Build the ADF document (Step 5a), then pass as the fourth arg. Auto-detected.
jira-writer create_issue PROJECT_KEY "Task" "Summary" '<ADF_DOCUMENT_JSON>'
```

To attach mermaid images, use the two-step flow: create with summary only, upload
diagrams, then `update_issue` with description ADF referencing the attachment URLs.

**Existing issues — update modes:**
```
DEFAULT (append):  fetch current description, parse ADF, append new nodes, PUT
REPLACE ("replace"/"overwrite"):  PUT with new ADF only
INSERT ("after section X"):  fetch, find target section, insert, PUT
PREPEND ("at the top"):  fetch, prepend new nodes, PUT
```

**REST API update format:**
```bash
curl -X PUT \
  -H "Authorization: Basic $(echo -n "$JIRA_API_KEY" | base64)" \
  -H "Content-Type: application/json" \
  -d '{"fields":{"description":{"version":1,"type":"doc","content":[...]}}}' \
  "https://$JIRA_DOMAIN/rest/api/3/issue/$ISSUE_KEY"
```

**Rich comments.** `add_comment` accepts both plain text and pre-built ADF. Strict
detection: a JSON object with `type:"doc"`, numeric `version`, and array `content`
is passed through; anything else is wrapped as a single paragraph. See
`reference/adf.md` for a worked rich-comment example.

**On update failure with uploaded attachments — rollback:**
```
FOR each uploaded attachment_id:
    DELETE via REST API: DELETE /rest/api/3/attachment/{id}
REPORT: "Failed to update description. Cleaned up uploaded attachments."
```

## Step 7: Cleanup

```
REMOVE temp directory:  rm -rf $TEMP_DIR
REPORT success:  "Updated PROJ-123 with [changes]" (+ "Embedded N diagram(s)")
```
