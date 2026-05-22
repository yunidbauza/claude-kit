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

- **Ticket Management** - Create and update Jira issues
- **Rich Formatting** - Headings, bold, italic, links, code blocks, tables
- **Interactive Checkboxes** - `- [ ]` and `- [x]` as clickable task lists
- **Mermaid Diagrams** - Auto-convert and embed as images
- **Markdown Import** - Use .md files as ticket content
- **Automatic Fallback** - Uses MCP if REST API is unavailable

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
```

## How It Works

The plugin uses **REST API as the primary method** with MCP as a fallback:

```text
┌─────────────────────────────────────────────────────────────┐
│                     Jira Writer Skill                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   ┌─────────────────────────────────────────────────────┐   │
│   │               jira-api-wrapper.sh                    │   │
│   │  (Unified interface - tries REST first, MCP fallback)│   │
│   └─────────────────────────────────────────────────────┘   │
│                            │                                │
│              ┌─────────────┴─────────────┐                  │
│              ▼                           ▼                  │
│   ┌──────────────────┐       ┌──────────────────┐          │
│   │   REST API        │       │   MCP Fallback   │          │
│   │   (Primary)       │       │   (Secondary)    │          │
│   │                   │       │                   │          │
│   │ jira-rest-api.sh  │       │ Atlassian MCP    │          │
│   └──────────────────┘       └──────────────────┘          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### API Selection by Content Type

| Content              | API Used        | Fallback |
| -------------------- | --------------- | -------- |
| Text, lists, code    | REST (primary)  | MCP      |
| Checkboxes (`- [ ]`) | REST only       | None     |
| Mermaid diagrams     | REST only       | None     |
| Attachments          | REST only       | None     |

## Scripts

| Script | Purpose |
| ------ | ------- |
| `test-jira-connection.sh` | Test API connectivity and auth |
| `check-prerequisites.sh` | Verify all dependencies |
| `jira-api-wrapper.sh` | Unified interface (REST + MCP fallback) |
| `jira-rest-api.sh` | Core REST API functions |
| `jira-mermaid-upload.sh` | Upload single diagram |
| `jira-mermaid-batch-upload.sh` | Upload multiple diagrams |

### Script Usage Examples

```bash
# Test your connection
./scripts/test-jira-connection.sh

# Check prerequisites
./scripts/check-prerequisites.sh

# Get an issue via wrapper (REST first, MCP fallback)
./scripts/jira-api-wrapper.sh get_issue PROJ-123

# Create an issue
./scripts/jira-api-wrapper.sh create_issue PROJECT "Task" "Summary" "Description"

# Direct REST API call
./scripts/jira-rest-api.sh jira_get_issue PROJ-123

# Upload a diagram
./scripts/jira-mermaid-upload.sh PROJ-123 diagram.mmd
```

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
