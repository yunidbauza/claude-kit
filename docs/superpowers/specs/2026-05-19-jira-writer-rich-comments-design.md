# jira-writer: rich comments + create-issue ADF + marketplace rename

**Status:** Draft — pending implementation plan
**Date:** 2026-05-19
**Affects:** `plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh`, `plugins/jira-writer/skills/jira-writer/SKILL.md`, `README.md`, `plugins/jira-writer/.claude-plugin/plugin.json`, `plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh`

## Problem

Two unrelated issues, fixed together because both touch user-facing surfaces of the same plugin.

### 1. `add_comment` (and `create_issue`) lose rich content

The wrapper's `op_add_comment` (`jira-api-wrapper.sh:215-251`) hardcodes the body argument into a single ADF paragraph:

```bash
content: [{ type: "paragraph", content: [{ type: "text", text: $text }] }]
```

Effect: markdown renders literally, multi-line content collapses, no ADF features (headings, lists, code blocks, checkboxes) are reachable through the wrapper. Users who need rich comments currently bypass the wrapper and call the REST endpoint directly with curl — the same workaround the skill documents for descriptions as "Path B: Complex Content (REST API only)" (SKILL.md ~line 432).

`op_create_issue` (lines 107-152) has the **same bug** on its `description` argument. The skill's Path B for new issues works around this by creating with summary only and then calling `update_issue` (which already accepts pre-built JSON) — an extra API call for no benefit.

`op_update_issue` is fine: it takes a pre-built JSON object via `--argjson fields`, so an agent can already submit rich ADF descriptions through the wrapper for updates.

### 2. README references the old marketplace name

The repo was renamed `jira-writer` → `claude-kit`. `README.md` still tells users to install via:

```
/plugin marketplace add yunidbauza/jira-writer
git clone https://github.com/yunidbauza/jira-writer.git /tmp/jira-writer
```

Both URLs 404. The plugin name *inside* the marketplace remains `jira-writer` — only the marketplace/repo identifier changed.

## Goals

1. Wrapper accepts both plain-text and pre-built ADF on user-content args without breaking existing plain-text callers.
2. Eliminate the documented two-step "create with summary only → update description" workaround for rich descriptions on new issues.
3. README install instructions work.
4. SKILL.md reflects the simpler workflow.
5. Test coverage for the detection logic so the contract is enforced.

## Non-goals (YAGNI)

- **No markdown→ADF converter in the wrapper.** The skill's Step 5a instructs the agent to build ADF in-context; no script currently performs this conversion, and adding one would be a significant new dependency for no demanded use case.
- **No `--adf` explicit flag.** Auto-detect with a strict ADF check is sufficient and keeps a single call style.
- **No `comment` field on `op_add_worklog`.** Worklog comments are also ADF and would benefit from the same treatment, but there is no current user demand. Flagged as a follow-up if/when needed.

## Design

### Shared helper: `_to_adf_body`

A single function in `jira-api-wrapper.sh`, used by both `op_add_comment` and `op_create_issue`. Echoes a valid ADF document JSON to stdout.

```bash
# _to_adf_body INPUT
# - If INPUT parses as a JSON object with .type == "doc", numeric .version,
#   and array .content, echo it unchanged (pass-through).
# - Otherwise wrap INPUT as a single plain-text paragraph (legacy behavior).
_to_adf_body() {
    local input="$1"
    if [[ "$input" =~ ^[[:space:]]*\{ ]]; then
        if printf '%s' "$input" | jq -e '
            type == "object"
            and .type == "doc"
            and (.version | type) == "number"
            and (.content | type) == "array"
        ' >/dev/null 2>&1; then
            printf '%s' "$input"
            return 0
        fi
    fi
    jq -n --arg text "$input" '{
        type: "doc",
        version: 1,
        content: [{
            type: "paragraph",
            content: [{ type: "text", text: $text }]
        }]
    }'
}
```

**Why the strict ADF check** (`type:"doc"` + numeric `version` + array `content`): rejects arbitrary JSON-shaped input that the user might literally want to post as a comment. A user passing `'{"foo":"bar"}'` as a comment body gets it rendered as plain text containing that literal string — predictable, no surprises.

**Why the `^[[:space:]]*\{` pre-filter:** avoids invoking jq on every plain-text comment (the common case). Cheap regex, then jq only on JSON-shaped strings.

**Why silent fallback on jq failure:** malformed JSON should never error out a comment post; it falls back to plain text, which is what a naive caller expects.

### Call-site changes

**`op_add_comment` — replace lines 226-240:**

```bash
local body_adf
body_adf=$(_to_adf_body "$comment_body")
local comment_data
comment_data=$(jq -n --argjson body "$body_adf" '{body: $body}')
```

**`op_create_issue` — replace lines 116-139 (description branch):**

```bash
local desc_adf
desc_adf=$(_to_adf_body "$description")
issue_data=$(jq -n \
    --arg project "$project_key" \
    --arg type "$issue_type" \
    --arg summary "$summary" \
    --argjson desc "$desc_adf" \
    '{ fields: { project: {key:$project}, issuetype: {name:$type}, summary: $summary, description: $desc } }')
```

The empty-description branch is unchanged.

### MCP fallback behavior

The MCP fallback shim passes a raw string (`commentBody`, `description`) — MCP servers expect markdown, not ADF. If REST fails and the original input was ADF JSON, the MCP fallback will render it as literal text, not rich content.

**Decision:** keep the existing raw-string fallback, but extend `output_mcp_fallback` to accept an optional `note` field so the agent can detect the degradation:

```bash
output_mcp_fallback "addCommentToJiraIssue" "$params" "$result" \
    "Original body was ADF; MCP fallback will render as text."
```

Implementation: add a 4th optional positional arg to `output_mcp_fallback`; if non-empty, merge into the JSON envelope as `.note`. Existing 3-arg call sites are unchanged.

Rationale for not converting ADF→markdown in shell: brittle, large surface area, no demand. Path B is already documented as REST-only — the agent knows what to do.

### Data flow

| Input to `add_comment` body arg | `_to_adf_body` output | Sent to REST |
|---|---|---|
| `"Just a sentence."` | plain-text paragraph (legacy) | `{body: {plain-text-paragraph}}` |
| Valid ADF JSON doc | pass-through | `{body: <input ADF>}` |
| `{"foo":"bar"}` | plain-text wrap containing literal JSON string | `{body: {paragraph with literal text}}` |
| `""` | empty plain-text paragraph | Jira likely 400s → MCP fallback path |
| Malformed JSON | plain-text wrap | sent as plain text |

`op_create_issue` data flow is identical for its `description` arg **when description is non-empty**. The existing empty-description branch (no `description` field in the request body) is preserved unchanged — `_to_adf_body` is only invoked inside the `[[ -n "$description" ]]` arm.

## Testing

Extend `plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh` with unit tests that stub the REST functions to echo their input, then assert on the data via jq.

| # | Input | Assertion |
|---|---|---|
| 1 | `add_comment KEY "plain text"` | comment_data has 1 paragraph, text node = `"plain text"` |
| 2 | `add_comment KEY '<valid ADF doc with heading>'` | comment_data.body equals input ADF exactly |
| 3 | `add_comment KEY '{"foo":"bar"}'` | falls back to plain-text wrap; text node = literal `{"foo":"bar"}` |
| 4 | `add_comment KEY '   <ADF doc with leading whitespace>'` | recognized as ADF, pass-through |
| 5 | `add_comment KEY '{"type":"doc","version":"1","content":[]}'` (string version) | falls back to plain-text wrap (strict check rejects) |
| 6 | `add_comment KEY 'not json'` | plain-text wrap (regex pre-filter rejects, jq not invoked) |
| 7 | `add_comment KEY '{ malformed'` | plain-text wrap (jq fails silently) |
| 8 | `create_issue PROJ Task "S" "plain desc"` | description is a plain-text paragraph |
| 9 | `create_issue PROJ Task "S" '<valid ADF doc>'` | description equals input ADF |
| 10 | `add_comment` with missing credentials + ADF input | MCP fallback envelope contains the new `note` field |

**Test mechanics:**

- Stub the low-level REST functions (`jira_add_comment`, `jira_create_issue`) in test scope to print their input data and exit 0, so assertions can inspect the data without network calls.
- For credential-missing cases, unset `JIRA_DOMAIN`/`JIRA_API_KEY` in a subshell.
- Keep zero new external dependencies — jq is already required by the wrapper.

**Manual smoke test (one-time, post-merge):**

- Real Jira: `add_comment` with a heading + bullet list + code block ADF doc — verify it renders rich.
- Real Jira: `create_issue` with a rich ADF description in one call — verify no two-step needed.

## Documentation updates

### `plugins/jira-writer/skills/jira-writer/SKILL.md`

1. **Step 6, Path B "For new issues"** (~line 436): replace the two-step `create with summary only → curl PUT description` recipe with a single `create_issue` call passing pre-built ADF as the description argument.
2. **Step 6, new subsection "Adding rich comments"** (insert near Path B): show both forms — plain text (unchanged) and rich ADF passed as the body string.
3. **Step 5a** (~line 360): one-line note that the same ADF-build instructions apply to comments, not just descriptions.
4. **Line 207** (existing `add_comment` example): unchanged. Plain-text form still works.

### `README.md` (repo root)

| Line | Old | New |
|---|---|---|
| 12 | `/plugin marketplace add yunidbauza/jira-writer` | `/plugin marketplace add yunidbauza/claude-kit` |
| 24 | `git clone https://github.com/yunidbauza/jira-writer.git /tmp/jira-writer` | `git clone https://github.com/yunidbauza/claude-kit.git /tmp/claude-kit` |
| 25 | `cp -r /tmp/jira-writer/plugins/jira-writer ~/.claude/plugins/` | `cp -r /tmp/claude-kit/plugins/jira-writer ~/.claude/plugins/` |
| 27 | `rm -rf /tmp/jira-writer` | `rm -rf /tmp/claude-kit` |

`/plugin install jira-writer` is unchanged — that's the plugin name within the marketplace.

### `plugins/jira-writer/README.md`

No install instructions, no changes needed.

### `plugins/jira-writer/.claude-plugin/plugin.json`

Version bump `1.3.0` → `1.4.0` (minor: backward-compatible API expansion).

## Risks & open questions

- **False-positive ADF detection on user-authored JSON-shaped comments.** Mitigated by the strict shape check (must have `type:"doc"` + numeric version + array content). A user pasting a JSON snippet for review will not have those exact top-level fields.
- **MCP fallback won't render ADF.** Accepted — documented via the new `note` field in the fallback envelope. The skill's Path B is already REST-only.
- **No regression in plain-text behavior.** The fallback branch of `_to_adf_body` produces byte-identical ADF to the current code path for plain-text input. Test case #1 enforces this.

## Out-of-scope follow-ups

- Add a `comment` field to `op_add_worklog` (worklog ADF comments). Open as a separate issue if a user requests it.
- Consider a `_to_adf_body --strict` mode for callers that want to error on malformed-JSON input rather than fall back. No current demand.
