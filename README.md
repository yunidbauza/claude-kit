# Jira Writer

Claude Code plugin for creating and updating Jira Cloud tickets with rich content, including automatic Mermaid diagram embedding and interactive checkboxes.

## Installation

### From GitHub

First, add the repository as a marketplace:

```bash
/plugin marketplace add yunidbauza/claude-kit
```

Then install the plugin:

```bash
/plugin install jira-writer
```

### Manual Installation

```bash
git clone https://github.com/yunidbauza/claude-kit.git /tmp/claude-kit
cp -r /tmp/claude-kit/plugins/jira-writer ~/.claude/plugins/
chmod +x ~/.claude/plugins/jira-writer/skills/jira-writer/scripts/*.sh
rm -rf /tmp/claude-kit
```

## Prerequisites

| Dependency | Purpose | Required |
| ---------- | ------- | -------- |
| `JIRA_DOMAIN` | Your Jira Cloud domain | Yes |
| `JIRA_API_KEY` | REST API auth (`email:token`) | Yes |
| Atlassian MCP | Fallback when REST fails | No (optional) |
| `mmdc` | Mermaid CLI for diagrams | For diagrams only |

**jira-writer** also benefits from Node 18+ when present — enables the markdown-to-ADF converter and ADF validator. Without Node, plain-text and pre-built-ADF paths still work.

## Environment Setup

```bash
# Required for REST API (primary method)
export JIRA_DOMAIN="company.atlassian.net"
export JIRA_API_KEY="your-email@company.com:your-api-token"

# Optional: for Mermaid diagrams
npm install -g @mermaid-js/mermaid-cli
```

### Getting Your API Token

1. Go to <https://id.atlassian.com/manage-profile/security/api-tokens>
2. Click "Create API token"
3. Give it a label and copy the token
4. Set `JIRA_API_KEY` as `your-email@company.com:your-token`

**Important:** Store the raw `email:token` format. The scripts handle base64 encoding internally.

### Verify Setup

```bash
# Test connection
~/.claude/plugins/jira-writer/skills/jira-writer/scripts/test-jira-connection.sh

# Check all prerequisites
~/.claude/plugins/jira-writer/skills/jira-writer/scripts/check-prerequisites.sh
```

## Features

- **Ticket Management** - Create, update, comment, transition, and search Jira issues
- **Rich Formatting** - Headings, bold, italic, links, code blocks, tables
- **Interactive Checkboxes** - `- [ ]` and `- [x]` as clickable task lists with auto-generated `localId` UUIDs
- **Mermaid Diagrams** - Auto-convert and embed as images
- **Markdown -> ADF Conversion** - Pass `--desc-file PATH` or `--markdown` and the wrapper converts (vendored `marked` v13, no npm install)
- **Pre-flight ADF Validation** - Catches mark exclusivity, missing `localId`, malformed `tableCell` attrs, and other `INVALID_INPUT` causes client-side before they hit Jira
- **Epic Parenting** - `--parent KEY` on `create_issue` with format validation
- **Smart Failure Routing** - Plain-text REST failures fall back to MCP; ADF/markdown failures hard-error (MCP can't retry rich content)

### Supported Diagram Types (11)

| Type | Syntax | Type | Syntax |
| ------ | -------- | ------ | -------- |
| Flowchart | `graph TD` | Sequence | `sequenceDiagram` |
| Class | `classDiagram` | State | `stateDiagram-v2` |
| ER | `erDiagram` | Gantt | `gantt` |
| Pie | `pie` | Mindmap | `mindmap` |
| User Journey | `journey` | Timeline | `timeline` |
| Quadrant | `quadrantChart` | | |

## Usage

The skill activates contextually when you:

- Ask to create or update a Jira ticket
- Provide content with Mermaid diagrams
- Reference a markdown file for ticket content

### Examples

```text
"Create a ticket for the authentication feature"
"Update PROJ-123 with this description"
"Add a sequence diagram showing the auth flow to PROJ-456"
"Create a ticket with acceptance criteria:
 - [ ] User can login
 - [x] Remember me works"
"Create a story from /tmp/oauth-spec.md and attach it to epic PROJ-100"
"Validate this ADF file before I send it"
```

## How It Works

The plugin uses **REST API as the primary method**. MCP is a fallback only for plain-text inputs (the only path MCP can actually retry without losing fidelity).

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                          Jira Writer Skill                                │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   ┌──────────────────────────────────────────────────────────────────┐   │
│   │                      jira-api-wrapper.sh                          │   │
│   │   resolves input mode -> validates ADF -> dispatches REST call    │   │
│   └──────────────────────────────────────────────────────────────────┘   │
│         │                       │                          │             │
│         ▼                       ▼                          ▼             │
│   ┌───────────┐         ┌────────────────┐        ┌────────────────┐    │
│   │  REST     │         │ markdown-to-   │        │ adf-validate   │    │
│   │  (always  │         │ adf.mjs        │        │ .mjs           │    │
│   │  primary) │         │ (Node 18+)     │        │ (Node 18+)     │    │
│   └───────────┘         └────────────────┘        └────────────────┘    │
│         │                                                                │
│         ▼ on 4xx                                                         │
│   plain text -> api:"mcp_fallback" (MCP can retry)                       │
│   ADF/markdown -> api:"error" (MCP cannot retry rich content)            │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Input Modes & Failure Routing

| Input mode                                  | REST 4xx envelope    | Notes                                                  |
| ------------------------------------------- | -------------------- | ------------------------------------------------------ |
| Plain text (positional `DESC`)              | `api:"mcp_fallback"` | MCP retry is viable; unchanged from v1.4              |
| Markdown via `--desc-file PATH`             | `api:"error"`        | Converted to ADF, then validated client-side          |
| Markdown via `--markdown`                   | `api:"error"`        | Same as above, with inline string                     |
| Pre-built ADF (raw JSON in positional arg)  | `api:"error"`        | Passthrough + pre-flight validation                   |
| Mermaid diagrams / attachments              | `api:"error"`        | Always REST-only; no MCP fallback                     |

## Scripts

| Script | Purpose |
| ------ | ------- |
| `test-jira-connection.sh` | Test API connectivity and auth |
| `check-prerequisites.sh` | Verify all dependencies (incl. Node 18+) |
| `jira-api-wrapper.sh` | Unified interface (flag parsing, ADF routing, failure envelopes) |
| `jira-rest-api.sh` | Core REST API functions |
| `markdown-to-adf.mjs` | Node helper: markdown -> ADF (uses vendored `marked` v13) |
| `adf-validate.mjs` | Node helper: lightweight ADF rule checks + `--bisect` mode |
| `jira-mermaid-upload.sh` | Upload single diagram |
| `jira-mermaid-batch-upload.sh` | Upload multiple diagrams |
| `vendor/marked/` | Vendored `marked@13.0.3` ESM bundle (no npm install needed) |

### Script Usage Examples

```bash
# Test your connection
./scripts/test-jira-connection.sh

# Check prerequisites (also reports Node availability)
./scripts/check-prerequisites.sh

# Get an issue
./scripts/jira-api-wrapper.sh get_issue PROJ-123

# Quick lookup — narrowed fields only
./scripts/jira-api-wrapper.sh get_issue PROJ-123 --summary-only

# Create an issue with a plain-text description (MCP fallback available on REST failure)
./scripts/jira-api-wrapper.sh create_issue PROJECT "Task" "Summary" "Description"

# Create a rich-content issue from a markdown file, attached to an epic
./scripts/jira-api-wrapper.sh create_issue PROJECT "Story" "OAuth support" \
  --desc-file /tmp/oauth-spec.md \
  --parent PROJECT-172

# Inline markdown comment with a checkbox
./scripts/jira-api-wrapper.sh add_comment PROJ-123 \
  "## Update

- [x] Code review complete" --markdown

# Locally validate ADF before sending (catches mark exclusivity, missing localId, etc.)
./scripts/jira-api-wrapper.sh validate_adf /tmp/built-adf.json

# Bisect to find the first failing block in a large ADF doc
./scripts/jira-api-wrapper.sh validate_adf /tmp/built-adf.json --bisect

# Direct REST API call
./scripts/jira-rest-api.sh jira_get_issue PROJ-123

# Upload a diagram
./scripts/jira-mermaid-upload.sh PROJ-123 diagram.mmd
```

See [plugins/jira-writer/CHANGELOG.md](plugins/jira-writer/CHANGELOG.md) for v1.5.1 release notes.

## Troubleshooting

### REST API Connection Issues

#### 401 Unauthorized

- Verify `JIRA_API_KEY` format is `email:token` (not base64 encoded)
- Regenerate API token at <https://id.atlassian.com/manage-profile/security/api-tokens>

#### 404 Not Found

- Check `JIRA_DOMAIN` is correct (e.g., `company.atlassian.net`)
- Verify the issue key exists and you have access

#### Connection Failed

- Check network connectivity
- Verify domain is reachable: `curl -I https://your-domain.atlassian.net`

### MCP Fallback Not Working

- MCP is optional; the plugin works fully with just REST API
- If you want MCP fallback, configure it in Claude Code MCP settings

### Diagram Upload Fails

- Ensure `mmdc` is installed: `npm install -g @mermaid-js/mermaid-cli`
- Diagrams require REST API (no MCP fallback)
- Check diagram syntax by running: `mmdc -i diagram.mmd -o test.png`

## Resources

- [Atlassian Document Format](https://developer.atlassian.com/cloud/jira/platform/apis/document/structure/)
- [Jira REST API](https://developer.atlassian.com/cloud/jira/platform/rest/v3/)
- [Mermaid Documentation](https://mermaid.js.org/)

## License

MIT
