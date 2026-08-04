# Examples

> `"$JW"` is the resolved `jira-writer` launcher. Claude Code puts it on `PATH`;
> Copilot CLI does not, so resolve it first — see "How to invoke" in `SKILL.md`:
> `JW=$(command -v jira-writer || { ls -td ~/.copilot/installed-plugins/*/jira-writer/bin/jira-writer 2>/dev/null; ls -td ~/.claude/plugins/cache/*/jira-writer/*/bin/jira-writer 2>/dev/null; } | head -1)`


Common usage patterns. Commands use the bare `jira-writer` launcher.

## 1. Create Ticket with Diagram
> "Create a ticket in PROJECT for the new authentication feature. Include a sequence diagram showing the OAuth flow."

1. Create mermaid sequence diagram for OAuth flow
2. Convert to PNG, upload as attachment (REST API)
3. Build ADF with description and embedded diagram
4. Create issue via REST API (or MCP for summary, then REST for description)

## 2. Update Ticket from Markdown File
> "Update PROJ-123 with the content from feature-spec.md"

1. Read `feature-spec.md`
2. Scan for mermaid blocks (if any)
3. Convert diagrams, upload attachments (REST API)
4. Build ADF from markdown
5. Fetch existing description, append new content
6. Update via REST API (or MCP if no complex content)

## 3. Add Diagram to Existing Ticket
> "Add an ER diagram showing the user tables to the current ticket"

1. Identify current ticket from conversation context
2. Generate ER diagram mermaid code
3. Convert to PNG, upload (REST API)
4. Fetch existing description
5. Append mediaSingle node with diagram
6. Update issue (REST API required)

## 4. Replace Description
> "Replace the description of PROJ-456 with this new spec"

1. Process new content (including any mermaid blocks)
2. Build complete ADF document
3. Update issue with `description` field (full replacement)

## 5. Insert at Specific Location
> "Insert the architecture diagram after the 'Technical Overview' section in PROJ-789"

1. Fetch current description ADF
2. Parse to find "Technical Overview" heading
3. Generate and convert diagram
4. Insert mediaSingle node after that section
5. Update with modified ADF (REST API required)

## 6. Create Ticket with Acceptance Criteria (Checkboxes)
> "Create a ticket for implementing user login with these acceptance criteria:
> - [ ] User can enter email and password
> - [ ] Invalid credentials show error message
> - [x] Remember me checkbox works"

1. Detect checkbox patterns → requires REST API
2. Create issue via REST API (or MCP for summary only)
3. Build ADF with a `taskList` (unique UUID `localId` per item; states TODO/TODO/DONE)
4. Update description via REST API

**Easy path:** write the criteria to a markdown file and pass `--desc-file --markdown` —
the converter builds the taskList for you.

## 7. Simple Text-Only Ticket (REST with MCP Fallback)
> "Create a ticket to refactor the database connection pool"

1. No complex content → REST API with MCP fallback available
2. `"$JW" create_issue PROJECT "Task" "Refactor database connection pool" "Description..."`
3. If REST fails, fall back to `mcp__atlassian__createJiraIssue` (projectKey, issueTypeName "Task", summary, markdown description)

## 8. Fetch Issue Details
> "Show me the details of PROJ-123"

1. `"$JW" get_issue PROJ-123`
2. Present summary, status, assignee, description, etc.

## 9. Search Issues with JQL
> "Find all open bugs assigned to me in PROJECT"

1. Build JQL: `project = PROJECT AND issuetype = Bug AND status != Done AND assignee = currentUser()`
2. `"$JW" search_jql "project = PROJECT AND issuetype = Bug AND status != Done AND assignee = currentUser()"`
3. Present results readably

## 10. List Projects
> "What Jira projects do I have access to?"

1. `"$JW" get_projects`
2. Present project list with keys and names
