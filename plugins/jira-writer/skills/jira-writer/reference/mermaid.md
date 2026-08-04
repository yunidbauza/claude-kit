# Mermaid Reference

> `"$JW"` is the resolved `jira-writer` launcher. Claude Code puts it on `PATH`;
> Copilot CLI does not, so resolve it first — see "How to invoke" in `SKILL.md`:
> `JW=$(command -v jira-writer || { ls -td ~/.copilot/installed-plugins/*/jira-writer/bin/jira-writer 2>/dev/null; ls -td ~/.claude/plugins/cache/*/jira-writer/*/bin/jira-writer 2>/dev/null; } | head -1)`


For generating and embedding Mermaid diagrams. Requires `mmdc`
(`npm install -g @mermaid-js/mermaid-cli`). Diagram processing steps live in
`reference/workflow.md` (Step 4).

## Supported Diagram Types

| Type | Syntax Start | Use Case |
|------|--------------|----------|
| Flowchart | `graph TD` / `graph LR` | Process flows, decision trees |
| Sequence | `sequenceDiagram` | API calls, interactions |
| Class | `classDiagram` | Object models, relationships |
| State | `stateDiagram-v2` | State machines, lifecycles |
| ER | `erDiagram` | Database schemas |
| Gantt | `gantt` | Project timelines |
| Pie | `pie` | Proportions, distributions |
| Git | `gitGraph` | Branch strategies |
| Mindmap | `mindmap` | Concept organization |
| Timeline | `timeline` | Chronological events |

## Conversion Command

```bash
mmdc -i input.mmd -o output.png \
  --backgroundColor white \
  --theme neutral \
  --scale 2
```

| Option | Value | Rationale |
|--------|-------|-----------|
| `--backgroundColor` | `white` | Matches Jira's white background |
| `--theme` | `neutral` | Clean, professional look |
| `--scale` | `2` | High resolution for retina |

Alternative themes: `default`, `forest`, `dark`.

## Filename Convention

1. Nearby heading context: `auth-flow-diagram.png`
2. Diagram type: `sequence-diagram.png`
3. Fallback sequential: `diagram-1.png`, `diagram-2.png`

## Syntax Validation

Before conversion, validate syntax:
```bash
mmdc -i input.mmd -o /dev/null 2>&1
```
If exit code non-zero, report the error and skip the diagram.

## Upload Helpers

```bash
# Single diagram: convert to PNG and upload
"$JW" mermaid <issue_key> <mermaid_file_or_code> [filename]
# A file path must contain no whitespace — args with spaces/newlines are
# always treated as mermaid code.
# Returns: { "attachment_id": "...", "content_url": "...", "filename": "..." }

# Multiple diagrams in one call
"$JW" mermaid-batch <issue_key> '<json_array_of_diagrams>'
```
