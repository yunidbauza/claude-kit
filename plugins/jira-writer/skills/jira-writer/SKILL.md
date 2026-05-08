---
name: jira-writer
description: Read, search, create, and update Jira Cloud tickets — fetch issue details, search with JQL, list projects, look up users, and write rich content with automatic Mermaid diagram embedding
model: claude-sonnet-4-6
---

# Jira Writer Skill

## Overview

This skill enables reading, searching, creating, and modifying Jira Cloud tickets. You can fetch issue details, search with JQL queries, list projects and issue types, look up users, and view issue transitions. When writing content that includes Mermaid diagram code blocks, diagrams are automatically converted to PNG images and embedded in the ticket description.

### Capabilities

#### Read & Search
- Fetch issue details by key (summary, description, status, assignee, etc.)
- Search issues using JQL queries
- List visible Jira projects
- Get available issue types for a project
- Get available status transitions for an issue
- Look up Jira users by name or email
- Get remote/linked issues for a ticket

#### Create & Update
- Create new Jira tickets with structured content
- Update existing ticket descriptions (append, replace, or insert at location)
- Add comments to existing tickets
- Transition issue status
- Parse markdown files and convert to Jira-compatible ADF
- Automatically detect and convert Mermaid diagrams to embedded images
- Batch processing for multiple diagrams in a single request

### Trigger Conditions

This skill activates contextually when:

- User asks to **read, view, fetch, or get** a Jira issue (e.g., "show me PROJ-123", "what's the status of PROJ-456")
- User asks to **search or find** Jira issues (e.g., "find open bugs in PROJECT", "search Jira for...")
- User asks to **list projects**, **look up users**, or **check issue types**
- User asks to **create** a Jira ticket
- User asks to **update/modify** a Jira ticket description
- User provides content (text or markdown file) to write to a Jira ticket
- Content contains ` ```mermaid ``` ` code blocks that need embedding

### Issue Resolution

- If a Jira issue is already in the conversation (fetched, discussed), use it automatically
- If multiple issues are in context, ask which one to target
- If no issue in context, ask the user to specify or offer to create new

## Prerequisites

Before executing Jira operations, verify these dependencies:

### API Selection: REST API Primary, MCP Fallback

This skill uses a **hybrid approach** with REST API as the primary method:

| Priority | Method | When Used |
|----------|--------|-----------|
| **1st** | REST API | Always tried first (requires `JIRA_DOMAIN` + `JIRA_API_KEY`) |
| **2nd** | Atlassian MCP | Fallback when REST fails or isn't configured |

**Decision logic:**
```
IF JIRA_DOMAIN and JIRA_API_KEY configured:
    TRY REST API first
    IF REST fails:
        FALL BACK to MCP (if available)
ELSE:
    USE MCP directly (if available)
    IF MCP unavailable:
        REPORT error with setup instructions
```

### Required for REST API (Primary): JIRA_API_KEY

REST API is the recommended primary method for all operations.

**Check:** Verify environment variable `JIRA_API_KEY` exists.

**Format:** `email:api_token` (plain text, NOT base64 encoded)
- Generate API token at: https://id.atlassian.com/manage-profile/security/api-tokens
- Set as: `export JIRA_API_KEY="your-email@domain.com:your_api_token"`

**IMPORTANT:** Store the raw `email:api_token` string. The upload scripts handle base64 encoding internally.

### Required for REST API (Primary): JIRA_DOMAIN

**Check:** Verify environment variable `JIRA_DOMAIN` exists (e.g., `company.atlassian.net`).

**If missing:** Ask user to provide their Jira domain.

### Optional Fallback: Atlassian MCP

The Atlassian MCP provides Jira API access as a fallback when REST API is unavailable.

**Check:** Attempt to use any `mcp__atlassian__*` tool.

**If unavailable and REST also unavailable:**
```
Neither REST API nor Atlassian MCP is configured.

For REST API (recommended):
1. Generate an API token at https://id.atlassian.com/manage-profile/security/api-tokens
2. Set environment variables:
   export JIRA_DOMAIN="company.atlassian.net"
   export JIRA_API_KEY="your-email@domain.com:your_api_token"

For MCP fallback:
1. Install the MCP from the Atlassian marketplace
2. Configure authentication in your Claude Code MCP settings
3. Restart Claude Code
```

### Content Type and API Selection

Use a **content-based approach** for API selection:

| Content Type | API to Use | Reason |
|--------------|------------|--------|
| Headings, paragraphs, text | REST or MCP | Both work |
| Bullet lists, numbered lists | REST or MCP | Both work |
| Tables | REST or MCP | Both work |
| Code blocks | REST or MCP | Both work |
| Bold, italic, links | REST or MCP | Both work |
| **Checkboxes** (`- [ ]`, `- [x]`) | **REST API** | MCP converts to escaped text, not interactive taskList |
| **Images/Mermaid diagrams** | **REST API** | MCP cannot handle mediaSingle nodes |
| **External media** | **REST API** | MCP cannot embed media |
| **Attachments** | **REST API only** | MCP cannot upload files |

**Decision logic:**
```
SCAN content for:
  - Checkbox patterns: `- [ ]` or `- [x]` or `* [ ]` or `* [x]`
  - Mermaid blocks: ```mermaid
  - Image references or embedded media
  - Attachments to upload

IF any complex content found:
    USE REST API (required, no fallback)
ELSE:
    USE REST API first
    IF REST fails: FALL BACK to MCP
```

### Required for Diagrams: mermaid-cli

The `mmdc` command converts Mermaid syntax to PNG.

**Check (deferred until first diagram):**
```bash
which mmdc
```

**If missing:**
```
Mermaid CLI (mmdc) not found. Install it?

Run: npm install -g @mermaid-js/mermaid-cli

[If user declines, skip diagram processing with warning]
```

**Cache result:** After first check, remember mmdc availability for session.

### Graceful Degradation

| Missing | Behavior |
|---------|----------|
| REST API credentials | Fall back to MCP; if MCP unavailable, stop with setup instructions |
| MCP | REST API handles everything (no impact if REST configured) |
| Both REST and MCP | Skill cannot function; stop with setup instructions |
| JIRA_API_KEY only | Text operations via MCP; diagrams/checkboxes skipped with warning |
| mmdc | Diagrams skipped with warning; offer installation |

### Helper Scripts

The following scripts automate operations (located in `scripts/` directory):

#### Script Selection Guide

All operations go through `jira-api-wrapper.sh`. The low-level functions in `jira-rest-api.sh` are sourced by the wrapper and are not invoked directly.

#### Primary Scripts

**jira-api-wrapper.sh** (USE THIS)
```bash
# Create issue - accepts positional args
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" create_issue PROJECT_KEY TYPE "Summary" "Description"
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" create_issue PROJ Task "Fix login bug" "Users cannot login"

# Update issue
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" update_issue PROJ-123 '{"fields":{"summary":"New title"}}'

# Get issue
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" get_issue PROJ-123

# Search with JQL
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" search_jql "project = PROJ AND status = Open"

# Get projects and issue types
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" get_projects
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" get_issue_types PROJECT_KEY

# Add comment
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" add_comment PROJ-123 "This is a comment"

# Add worklog
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" add_worklog PROJ-123 "2h"

# Transitions
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" get_transitions PROJ-123
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" transition_issue PROJ-123 TRANSITION_ID

# Upload attachment
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" upload_attachment PROJ-123 /path/to/file.png
```

**Aliases:** The wrapper accepts the canonical op names listed above plus common variants — verb-only forms (`issue`, `create`, `comment`, `search`, `projects`), camelCase (`getIssue`), and `jira_`-prefixed names (`jira_get_issue`). Unknown ops exit 2 with a "Did you mean: …" suggestion.

#### Diagnostic Scripts

**test-jira-connection.sh**
```bash
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/test-jira-connection.sh"
# Tests API connectivity and returns recommendation
```

**check-prerequisites.sh**
```bash
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/check-prerequisites.sh"
# Returns JSON with status of all dependencies
```

#### Mermaid Diagram Scripts

**jira-mermaid-upload.sh**
```bash
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-mermaid-upload.sh" <issue_key> <mermaid_file_or_code> [filename]
# Converts mermaid to PNG and uploads to Jira
# Returns: { "attachment_id": "...", "content_url": "...", "filename": "..." }
```

**jira-mermaid-batch-upload.sh**
```bash
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-mermaid-batch-upload.sh" <issue_key> '<json_array_of_diagrams>'
# Processes multiple diagrams in one call
```

### Default Issue Type

When creating new issues:
- **Default:** Task (if no type specified)
- **User-specified:** Use whatever type the user indicates (Story, Bug, Spike, Epic, Subtask, etc.)

Check available issue types for a project:
```bash
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" get_issue_types PROJECT_KEY
# Or via MCP: mcp__atlassian__getJiraProjectIssueTypesMetadata with projectIdOrKey
```

## Workflow

Follow these steps when creating or updating Jira tickets:

### Step 1: Resolve Target Issue

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

### Step 2: Gather Content

Content sources (in priority order):
1. **Markdown file provided:** Read file, use as content
2. **Explicit content in request:** Use the text/description provided
3. **Conversation context:** Generate content based on discussion

### Step 3: Scan for Mermaid Blocks

```
SCAN content for pattern: ```mermaid ... ```
IF mermaid blocks found:
    EXTRACT each block
    QUEUE for conversion (Step 4)
ELSE:
    SKIP to Step 5
```

### Step 4: Process Mermaid Diagrams

For each mermaid block:

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
    Use: "$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" upload_attachment $ISSUE_KEY $TEMP_DIR/diagram-N.png
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

### Step 5: Detect Content Complexity

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

### Step 5a: Build ADF Document (for complex content)

```
CONVERT markdown content to ADF nodes:
    - Headings -> heading nodes
    - Paragraphs -> paragraph nodes
    - Bullet lists -> bulletList/listItem nodes
    - Numbered lists -> orderedList/listItem nodes
    - Checkboxes -> taskList/taskItem nodes (see below)
    - Code blocks -> codeBlock nodes
    - Tables -> table/tableRow/tableHeader/tableCell nodes
    - Bold/italic -> text with marks
    - Links -> text with link mark

FOR each checkbox pattern:
    CONVERT to taskItem:
    - `- [ ] text` -> state: "TODO"
    - `- [x] text` -> state: "DONE"
    - Generate unique localId (UUID) for each taskList and taskItem

FOR each mermaid block position:
    REPLACE with mediaSingle node:
    {
        "type": "mediaSingle",
        "attrs": { "layout": "center" },
        "content": [{
            "type": "media",
            "attrs": {
                "type": "external",
                "url": "https://$JIRA_DOMAIN/rest/api/3/attachment/content/<attachment_id>"
            }
        }]
    }
```

### Step 6: Write to Jira

Choose API based on content complexity (determined in Step 5):

#### Path A: Simple Content (REST with MCP fallback)

**For new issues:**
```bash
# Try REST API first
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" create_issue PROJECT_KEY "Task" "Summary" "Description"

# If response indicates MCP fallback needed:
# Use mcp__atlassian__createJiraIssue with:
#     - projectKey
#     - issueTypeName (default: "Task" if not specified by user)
#     - summary
#     - description (markdown - MCP converts to ADF)
```

Issue type mapping:
- "task" or unspecified -> "Task"
- "story" or "user story" -> "Story"
- "bug" or "defect" -> "Bug"
- "spike" -> "Spike"
- "epic" -> "Epic"
- "subtask" or "sub-task" -> "Subtask"

**For existing issues:**
```bash
# Try REST API first
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" update_issue PROJ-123 '{"description": "..."}'

# If response indicates MCP fallback needed:
# Use mcp__atlassian__editJiraIssue with:
#     - description (markdown - MCP converts to ADF)
```

#### Path B: Complex Content (REST API only)

Content with checkboxes, images, or mermaid diagrams requires REST API.

**For new issues:**
```
1. CREATE issue via REST API (or MCP if REST unavailable) with summary only:
   "$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" create_issue PROJECT_KEY "Task" "Summary"

2. UPDATE description via REST API:
   curl -X PUT \
     -H "Authorization: Basic $(echo -n $JIRA_API_KEY | base64)" \
     -H "Content-Type: application/json" \
     -d '{"fields":{"description": <ADF_DOCUMENT>}}' \
     "https://$JIRA_DOMAIN/rest/api/3/issue/<key>"
```

**For existing issues:**
```
DETERMINE update mode from user request:

DEFAULT (append):
    FETCH current description via REST API or MCP
    PARSE existing ADF content
    APPEND new ADF nodes to existing content array
    UPDATE via REST API (PUT /rest/api/3/issue/<key>)

REPLACE (user says "replace", "overwrite"):
    UPDATE via REST API with new ADF only

INSERT (user specifies location like "after section X"):
    FETCH current description
    PARSE ADF to find target section
    INSERT new content at specified position
    UPDATE via REST API

PREPEND (user says "at the beginning", "at the top"):
    FETCH current description
    PREPEND new ADF nodes before existing
    UPDATE via REST API
```

**REST API update format:**
```bash
curl -X PUT \
  -H "Authorization: Basic $(echo -n "$JIRA_API_KEY" | base64)" \
  -H "Content-Type: application/json" \
  -d '{
    "fields": {
      "description": {
        "version": 1,
        "type": "doc",
        "content": [...]
      }
    }
  }' \
  "https://$JIRA_DOMAIN/rest/api/3/issue/$ISSUE_KEY"
```

**On update failure with uploaded attachments:**
```
ROLLBACK:
    FOR each uploaded attachment_id:
        DELETE via REST API: DELETE /rest/api/3/attachment/{id}
    REPORT: "Failed to update description. Cleaned up uploaded attachments."
```

### Step 7: Cleanup

```
REMOVE temp directory and files:
    rm -rf $TEMP_DIR

REPORT success:
    "Updated PROJ-123 with [description of changes]"
    IF diagrams embedded:
        "Embedded N diagram(s)"
```

## ADF Reference

Quick reference for Atlassian Document Format nodes.

### Document Structure

```json
{
  "version": 1,
  "type": "doc",
  "content": [ /* array of block nodes */ ]
}
```

### Block Nodes

**Heading:**
```json
{
  "type": "heading",
  "attrs": { "level": 2 },
  "content": [{ "type": "text", "text": "Heading Text" }]
}
```

**Paragraph:**
```json
{
  "type": "paragraph",
  "content": [{ "type": "text", "text": "Paragraph text" }]
}
```

**Bullet List:**
```json
{
  "type": "bulletList",
  "content": [{
    "type": "listItem",
    "content": [{
      "type": "paragraph",
      "content": [{ "type": "text", "text": "Item text" }]
    }]
  }]
}
```

**Ordered List:**
```json
{
  "type": "orderedList",
  "content": [{ "type": "listItem", "content": [...] }]
}
```

**Task List (Checkboxes):**
```json
{
  "type": "taskList",
  "attrs": { "localId": "unique-uuid-1" },
  "content": [
    {
      "type": "taskItem",
      "attrs": { "localId": "unique-uuid-2", "state": "TODO" },
      "content": [{ "type": "text", "text": "Unchecked item" }]
    },
    {
      "type": "taskItem",
      "attrs": { "localId": "unique-uuid-3", "state": "DONE" },
      "content": [{ "type": "text", "text": "Checked item" }]
    }
  ]
}
```

**Task List states:**
- `"state": "TODO"` - Unchecked checkbox (markdown: `- [ ]`)
- `"state": "DONE"` - Checked checkbox (markdown: `- [x]`)

**IMPORTANT:** Each `taskList` and `taskItem` requires a unique `localId` (UUID format). Generate with `uuidgen` or similar.

**Code Block:**
```json
{
  "type": "codeBlock",
  "attrs": { "language": "python" },
  "content": [{ "type": "text", "text": "code here" }]
}
```

**Media (embedded image from attachment):**
```json
{
  "type": "mediaSingle",
  "attrs": { "layout": "center" },
  "content": [{
    "type": "media",
    "attrs": {
      "type": "external",
      "url": "https://your-domain.atlassian.net/rest/api/3/attachment/content/ATTACHMENT_ID"
    }
  }]
}
```

**Table:**
```json
{
  "type": "table",
  "attrs": { "isNumberColumnEnabled": false, "layout": "default" },
  "content": [
    {
      "type": "tableRow",
      "content": [
        {
          "type": "tableHeader",
          "attrs": {},
          "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Header 1" }] }]
        },
        {
          "type": "tableHeader",
          "attrs": {},
          "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Header 2" }] }]
        }
      ]
    },
    {
      "type": "tableRow",
      "content": [
        {
          "type": "tableCell",
          "attrs": {},
          "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Cell 1" }] }]
        },
        {
          "type": "tableCell",
          "attrs": {},
          "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Cell 2" }] }]
        }
      ]
    }
  ]
}
```

**Table node types:**
- `table` - Container for the entire table
- `tableRow` - A row in the table
- `tableHeader` - Header cell (first row typically)
- `tableCell` - Regular data cell

### Inline Marks

**Bold:**
```json
{ "type": "text", "text": "bold", "marks": [{ "type": "strong" }] }
```

**Italic:**
```json
{ "type": "text", "text": "italic", "marks": [{ "type": "em" }] }
```

**Code:**
```json
{ "type": "text", "text": "code", "marks": [{ "type": "code" }] }
```

**Link:**
```json
{ "type": "text", "text": "link text", "marks": [{ "type": "link", "attrs": { "href": "https://..." } }] }
```

### Media Layout Options

| Layout | Behavior |
|--------|----------|
| `center` | Centered, original size (recommended) |
| `wide` | Wider than text column |
| `full-width` | Full page width |
| `align-start` | Left-aligned |
| `align-end` | Right-aligned |

## Mermaid Reference

Reference for Mermaid diagram generation.

### Supported Diagram Types

| Type | Syntax Start | Use Case |
|------|--------------|----------|
| Flowchart | `graph TD` or `graph LR` | Process flows, decision trees |
| Sequence | `sequenceDiagram` | API calls, interactions |
| Class | `classDiagram` | Object models, relationships |
| State | `stateDiagram-v2` | State machines, lifecycles |
| ER | `erDiagram` | Database schemas |
| Gantt | `gantt` | Project timelines |
| Pie | `pie` | Proportions, distributions |
| Git | `gitGraph` | Branch strategies |
| Mindmap | `mindmap` | Concept organization |
| Timeline | `timeline` | Chronological events |

### Conversion Command

```bash
mmdc -i input.mmd -o output.png \
  --backgroundColor white \
  --theme neutral \
  --scale 2
```

### Options

| Option | Value | Rationale |
|--------|-------|-----------|
| `--backgroundColor` | `white` | Matches Jira's white background |
| `--theme` | `neutral` | Clean, professional look |
| `--scale` | `2` | High resolution for retina |

Alternative themes: `default`, `forest`, `dark`

### Filename Convention

Generate descriptive filenames based on:
1. Nearby heading context: `auth-flow-diagram.png`
2. Diagram type: `sequence-diagram.png`
3. Fallback sequential: `diagram-1.png`, `diagram-2.png`

### Syntax Validation

Before conversion, validate syntax:
```bash
mmdc -i input.mmd -o /dev/null 2>&1
```

If exit code non-zero, report the error and skip the diagram.

## Error Handling

How to handle errors at each stage.

### Error Response Table

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
| Description update | REST error | TRY MCP fallback (for simple content); ROLLBACK attachments; report error |
| Section detection | Section not found | ASK user for clarification |
| Wrapper exit 2 | Unknown operation | Suggestion shown; check op name or run with no args |

### Rollback Procedure

When description update fails after attachments were uploaded:

```
FOR each uploaded attachment_id:
    curl -X DELETE \
      -H "Authorization: Basic $(echo -n "$JIRA_API_KEY" | base64)" \
      "https://$JIRA_DOMAIN/rest/api/3/attachment/$attachment_id"

REPORT to user:
    "Failed to update the issue description. I've cleaned up the uploaded
    diagram attachments to avoid orphaned files. Error: [details]"
```

### Partial Success (Batch Diagrams)

When processing multiple diagrams and some fail:

```
CONTINUE processing remaining diagrams
REPORT at end:
    "Embedded 2 of 3 diagrams successfully.
    Diagram 2 skipped due to syntax error: [error details]"
```

### User Communication

Always provide actionable information:
- What went wrong
- Why it happened (if known)
- What the user can do to fix it
- What was successfully completed (partial success)

### Known Issues & Gotchas

**1. JIRA_API_KEY format**
- Store as plain `email:api_token` in env var
- Scripts handle base64 encoding internally
- Wrong: `export JIRA_API_KEY=$(echo -n "email:token" | base64)`
- Correct: `export JIRA_API_KEY="email:token"`

**2. ADF Media nodes for attachments**
- Use `type: "external"` with the attachment content URL
- Do NOT use `type: "file"` with attachment ID (requires Media API UUID)
- Correct URL format: `https://$JIRA_DOMAIN/rest/api/3/attachment/content/<attachment_id>`

**3. MCP cannot handle complex ADF content**
- The MCP's markdown-to-ADF conversion is limited
- **Checkboxes:** MCP converts `- [ ]` to escaped text in bulletList, NOT interactive taskList
- **Images/Media:** MCP cannot create mediaSingle nodes
- **Solution:** Use REST API directly for content with checkboxes, images, or diagrams

**4. MCP cannot update description with raw ADF**
- The MCP's editJiraIssue tries to convert input as markdown
- For ADF with embedded media or checkboxes, use REST API directly:
  ```bash
  curl -X PUT -H "Authorization: Basic <encoded>" \
    -H "Content-Type: application/json" \
    -d '{"fields":{"description":<adf_document>}}' \
    "https://$JIRA_DOMAIN/rest/api/3/issue/<key>"
  ```

**5. Checkbox ADF requires unique localIds**
- Each `taskList` and `taskItem` node requires a unique `localId` attribute
- Use UUID format (e.g., `"localId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"`)
- Generate with `uuidgen` command or equivalent

**6. Attachment upload requires REST API**
- MCP does not support file uploads
- Must use REST API with multipart/form-data
- The `jira-mermaid-upload.sh` script handles this

**7. Issue not found errors**
- 404 from REST API often means wrong domain or permissions
- Verify JIRA_DOMAIN matches your instance exactly
- Verify API token has correct permissions

**8. REST API vs MCP fallback**
- REST API is preferred (faster, more reliable, full feature support)
- MCP fallback is automatic for simple content when REST is unavailable
- Complex content (checkboxes, diagrams, attachments) has no MCP fallback

## Examples

Common usage patterns for this skill.

### Example 1: Create Ticket with Diagram

**User request:**
> "Create a ticket in PROJECT for the new authentication feature. Include a sequence diagram showing the OAuth flow."

**Skill execution:**
1. Create mermaid sequence diagram for OAuth flow
2. Convert to PNG, upload as attachment (REST API)
3. Build ADF with description and embedded diagram
4. Create issue via REST API (or MCP for summary, then REST for description)

---

### Example 2: Update Ticket from Markdown File

**User request:**
> "Update PROJ-123 with the content from feature-spec.md"

**Skill execution:**
1. Read `feature-spec.md`
2. Scan for mermaid blocks (if any)
3. Convert diagrams, upload attachments (REST API)
4. Build ADF from markdown
5. Fetch existing description, append new content
6. Update via REST API (or MCP if no complex content)

---

### Example 3: Add Diagram to Existing Ticket

**User request:**
> "Add an ER diagram showing the user tables to the current ticket"

**Skill execution:**
1. Identify current ticket from conversation context
2. Generate ER diagram mermaid code
3. Convert to PNG, upload (REST API)
4. Fetch existing description
5. Append mediaSingle node with diagram
6. Update issue (REST API required)

---

### Example 4: Replace Description

**User request:**
> "Replace the description of PROJ-456 with this new spec"

**Skill execution:**
1. Process new content (including any mermaid blocks)
2. Build complete ADF document
3. Update issue with `description` field (full replacement)

---

### Example 5: Insert at Specific Location

**User request:**
> "Insert the architecture diagram after the 'Technical Overview' section in PROJ-789"

**Skill execution:**
1. Fetch current description ADF
2. Parse to find "Technical Overview" heading
3. Generate and convert diagram
4. Insert mediaSingle node after that section
5. Update with modified ADF (REST API required)

---

### Example 6: Create Ticket with Acceptance Criteria (Checkboxes)

**User request:**
> "Create a ticket for implementing user login with these acceptance criteria:
> - [ ] User can enter email and password
> - [ ] Invalid credentials show error message
> - [x] Remember me checkbox works"

**Skill execution:**
1. Detect checkbox patterns (`- [ ]`, `- [x]`) -> requires REST API
2. Create issue via REST API (or MCP for summary only)
3. Build ADF with taskList:
   ```json
   {
     "type": "taskList",
     "attrs": { "localId": "<uuid>" },
     "content": [
       { "type": "taskItem", "attrs": { "localId": "<uuid>", "state": "TODO" }, "content": [...] },
       { "type": "taskItem", "attrs": { "localId": "<uuid>", "state": "TODO" }, "content": [...] },
       { "type": "taskItem", "attrs": { "localId": "<uuid>", "state": "DONE" }, "content": [...] }
     ]
   }
   ```
4. Update description via REST API

---

### Example 7: Simple Text-Only Ticket (REST with MCP Fallback)

**User request:**
> "Create a ticket to refactor the database connection pool"

**Skill execution:**
1. No complex content detected -> REST API with MCP fallback available
2. Try REST API first:
   ```bash
   "$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" create_issue PROJECT "Task" "Refactor database connection pool" "Description..."
   ```
3. If REST fails, fall back to `mcp__atlassian__createJiraIssue` with:
   - projectKey
   - issueTypeName: "Task"
   - summary: "Refactor database connection pool"
   - description: (markdown text - MCP handles conversion)

---

### Example 8: Fetch Issue Details

**User request:**
> "Show me the details of PROJ-123"

**Skill execution:**
1. Run: `"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" get_issue PROJ-123`
2. Parse response and present summary, status, assignee, description, etc.

---

### Example 9: Search Issues with JQL

**User request:**
> "Find all open bugs assigned to me in PROJECT"

**Skill execution:**
1. Build JQL: `project = PROJECT AND issuetype = Bug AND status != Done AND assignee = currentUser()`
2. Run: `"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" search_jql "project = PROJECT AND issuetype = Bug AND status != Done AND assignee = currentUser()"`
3. Present results in a readable format

---

### Example 10: List Projects

**User request:**
> "What Jira projects do I have access to?"

**Skill execution:**
1. Run: `"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" get_projects`
2. Present project list with keys and names
