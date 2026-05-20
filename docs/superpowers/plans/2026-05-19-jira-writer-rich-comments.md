# jira-writer rich comments + create-issue ADF + marketplace rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the jira-writer wrapper accept pre-built ADF on `add_comment` and `create_issue` (auto-detected), eliminate the documented two-step create-then-update workaround for rich descriptions, fix the README's stale marketplace name, and add unit-test coverage for the detection logic.

**Architecture:** Add one shared bash helper `_to_adf_body` to `jira-api-wrapper.sh` that strictly detects an ADF document (`type:"doc"` + numeric `version` + array `content`) and either passes it through or wraps the input as a plain-text paragraph. Wire it into the two affected ops. Extend `output_mcp_fallback` with an optional `note` field so callers can flag the ADF-input-on-MCP-fallback degradation. No behavior change for existing plain-text callers — the fallback branch produces byte-identical ADF to the current code.

**Tech Stack:** bash, jq (already required), the existing `test-wrapper-dispatch.sh` test harness (`JIRA_WRAPPER_TEST_MODE=1` sources the wrapper without running dispatch).

**Spec:** `docs/superpowers/specs/2026-05-19-jira-writer-rich-comments-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh` | Modify | Add `_to_adf_body` helper; extend `output_mcp_fallback` with optional `note`; rewire `op_add_comment` and `op_create_issue` (description branch only). |
| `plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh` | Modify | Add unit tests for `_to_adf_body`, the rewired ops (with stubbed REST), and the `note`-bearing MCP fallback envelope. |
| `plugins/jira-writer/skills/jira-writer/SKILL.md` | Modify | Replace the two-step Path B "For new issues" recipe with a single `create_issue` call; add a "Rich comments" subsection; one-line note in Step 5a. |
| `README.md` | Modify | Replace `yunidbauza/jira-writer` marketplace and clone URLs with `yunidbauza/claude-kit`. |
| `plugins/jira-writer/.claude-plugin/plugin.json` | Modify | Bump `version` from `1.3.0` to `1.4.0`. |

All changes are in-place edits to existing files. No new files created.

---

### Task 1: Add `_to_adf_body` helper with full test coverage

**Files:**
- Modify: `plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh` (insert helper after `check_rest_available`, around line 80)
- Modify: `plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh` (append new tests)

- [ ] **Step 1: Write the failing tests**

Append the following block to `test-wrapper-dispatch.sh` immediately before the `--- summary ---` block (currently at line 82):

```bash
# --- _to_adf_body: plain text wraps in paragraph ---
out=$(_to_adf_body "plain text")
assert_eq "_to_adf_body plain: top type is doc" "doc" "$(printf '%s' "$out" | jq -r '.type')"
assert_eq "_to_adf_body plain: version is 1" "1" "$(printf '%s' "$out" | jq -r '.version')"
assert_eq "_to_adf_body plain: content[0].type is paragraph" "paragraph" "$(printf '%s' "$out" | jq -r '.content[0].type')"
assert_eq "_to_adf_body plain: text node value" "plain text" "$(printf '%s' "$out" | jq -r '.content[0].content[0].text')"

# --- _to_adf_body: valid ADF passes through unchanged ---
adf_in='{"type":"doc","version":1,"content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"H"}]}]}'
out=$(_to_adf_body "$adf_in")
assert_eq "_to_adf_body ADF: passes through identical" "$(printf '%s' "$adf_in" | jq -cS .)" "$(printf '%s' "$out" | jq -cS .)"

# --- _to_adf_body: non-ADF JSON-shaped input falls back to plain text ---
out=$(_to_adf_body '{"foo":"bar"}')
assert_eq "_to_adf_body non-ADF JSON: type still doc" "doc" "$(printf '%s' "$out" | jq -r '.type')"
assert_eq "_to_adf_body non-ADF JSON: text node is literal JSON" '{"foo":"bar"}' "$(printf '%s' "$out" | jq -r '.content[0].content[0].text')"

# --- _to_adf_body: ADF with leading whitespace recognized ---
adf_ws='   {"type":"doc","version":1,"content":[]}'
out=$(_to_adf_body "$adf_ws")
assert_eq "_to_adf_body ADF+whitespace: content array empty" "0" "$(printf '%s' "$out" | jq '.content | length')"
assert_eq "_to_adf_body ADF+whitespace: top type is doc" "doc" "$(printf '%s' "$out" | jq -r '.type')"

# --- _to_adf_body: ADF with string version rejected (strict check) ---
out=$(_to_adf_body '{"type":"doc","version":"1","content":[]}')
assert_eq "_to_adf_body string version: falls back to plain-text wrap" "paragraph" "$(printf '%s' "$out" | jq -r '.content[0].type')"

# --- _to_adf_body: non-JSON input ---
out=$(_to_adf_body "not json at all")
assert_eq "_to_adf_body non-JSON: text node value" "not json at all" "$(printf '%s' "$out" | jq -r '.content[0].content[0].text')"

# --- _to_adf_body: malformed JSON ---
out=$(_to_adf_body '{ malformed')
assert_eq "_to_adf_body malformed JSON: falls back to plain-text wrap" "paragraph" "$(printf '%s' "$out" | jq -r '.content[0].type')"
assert_eq "_to_adf_body malformed JSON: literal text preserved" "{ malformed" "$(printf '%s' "$out" | jq -r '.content[0].content[0].text')"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh`
Expected: All new `_to_adf_body` lines FAIL with "command not found: _to_adf_body" (or similar). The existing normalize_op/suggest_op tests still pass.

- [ ] **Step 3: Add the `_to_adf_body` helper**

In `jira-api-wrapper.sh`, insert the following function after `check_rest_available` (currently ends at line 80, just before the `# --- Operation Handlers ---` divider at line 82):

```bash
# _to_adf_body INPUT
# Echoes a valid ADF document JSON to stdout.
# - If INPUT parses as a JSON object with .type == "doc", numeric .version,
#   and array .content, echo it unchanged (pass-through).
# - Otherwise wrap INPUT as a single plain-text paragraph (legacy behavior).
_to_adf_body() {
    local input="$1"
    # Cheap pre-filter: must start with '{' (allow leading whitespace) to
    # even consider as JSON. Anything else is plain text.
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh`
Expected: All tests pass (existing + 11 new `_to_adf_body` lines). Final line: `Total: N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh \
        plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh
git commit -m "$(cat <<'EOF'
feat(jira-writer): add _to_adf_body helper with strict ADF detection

Accepts either plain text (wraps as paragraph, legacy behavior) or a
pre-built ADF doc (passes through). Strict check on type/version/content
prevents arbitrary JSON-shaped input from being treated as ADF.
EOF
)"
```

---

### Task 2: Wire `_to_adf_body` into `op_add_comment`

**Files:**
- Modify: `plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh:215-251`
- Modify: `plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh` (append)

- [ ] **Step 1: Write the failing tests**

Append to `test-wrapper-dispatch.sh` (before `--- summary ---`):

```bash
# --- op_add_comment: stub jira_add_comment to capture the data it receives ---
# Save originals so later tests can override differently if needed.
JIRA_DOMAIN_SAVE="${JIRA_DOMAIN:-}"
JIRA_API_KEY_SAVE="${JIRA_API_KEY:-}"
export JIRA_DOMAIN="example.atlassian.net"
export JIRA_API_KEY="user@example.com:fake-token"

CAPTURED_COMMENT_DATA=""
jira_add_comment() {
    # $1 = issue_key, $2 = data
    CAPTURED_COMMENT_DATA="$2"
    printf '%s' '{"id":"10001","self":"http://example/comment/10001"}'
    return 0
}

# Plain text input -> single paragraph
CAPTURED_COMMENT_DATA=""
op_add_comment PROJ-1 "plain text" >/dev/null
assert_eq "op_add_comment plain: body.content[0].type" \
    "paragraph" \
    "$(printf '%s' "$CAPTURED_COMMENT_DATA" | jq -r '.body.content[0].type')"
assert_eq "op_add_comment plain: text node value" \
    "plain text" \
    "$(printf '%s' "$CAPTURED_COMMENT_DATA" | jq -r '.body.content[0].content[0].text')"

# ADF input -> body equals input ADF
adf_in='{"type":"doc","version":1,"content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"H"}]}]}'
CAPTURED_COMMENT_DATA=""
op_add_comment PROJ-1 "$adf_in" >/dev/null
assert_eq "op_add_comment ADF: body equals input ADF" \
    "$(printf '%s' "$adf_in" | jq -cS .)" \
    "$(printf '%s' "$CAPTURED_COMMENT_DATA" | jq -cS '.body')"

# Non-ADF JSON -> wrapped as literal text
CAPTURED_COMMENT_DATA=""
op_add_comment PROJ-1 '{"foo":"bar"}' >/dev/null
assert_eq "op_add_comment non-ADF JSON: literal text preserved" \
    '{"foo":"bar"}' \
    "$(printf '%s' "$CAPTURED_COMMENT_DATA" | jq -r '.body.content[0].content[0].text')"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh`
Expected: The new `op_add_comment ADF: body equals input ADF` test FAILS — the current code wraps even valid ADF as plain text. Plain-text and non-ADF JSON cases happen to pass already.

- [ ] **Step 3: Rewire `op_add_comment` to use `_to_adf_body`**

In `jira-api-wrapper.sh`, replace lines 226-240 (the `comment_data=$(jq -n --arg text ...)` block) with:

```bash
    # Build comment data (ADF format). _to_adf_body passes through pre-built
    # ADF docs unchanged, or wraps plain text as a single paragraph.
    local body_adf
    body_adf=$(_to_adf_body "$comment_body")
    local comment_data
    comment_data=$(jq -n --argjson body "$body_adf" '{body: $body}')
```

The function's surrounding logic (credential check, REST call, MCP fallback) is unchanged.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh \
        plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh
git commit -m "fix(jira-writer): op_add_comment passes pre-built ADF through unchanged"
```

---

### Task 3: Wire `_to_adf_body` into `op_create_issue` (description branch)

**Files:**
- Modify: `plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh:116-139`
- Modify: `plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh` (append)

- [ ] **Step 1: Write the failing tests**

Append to `test-wrapper-dispatch.sh` (before `--- summary ---`):

```bash
# --- op_create_issue: stub jira_create_issue to capture issue_data ---
CAPTURED_CREATE_DATA=""
jira_create_issue() {
    CAPTURED_CREATE_DATA="$1"
    printf '%s' '{"id":"10001","key":"PROJ-1","self":"http://example/issue/PROJ-1"}'
    return 0
}

# Plain text description -> single paragraph
CAPTURED_CREATE_DATA=""
op_create_issue PROJ Task "Summary" "plain desc" >/dev/null
assert_eq "op_create_issue plain desc: description.content[0].type" \
    "paragraph" \
    "$(printf '%s' "$CAPTURED_CREATE_DATA" | jq -r '.fields.description.content[0].type')"
assert_eq "op_create_issue plain desc: text node value" \
    "plain desc" \
    "$(printf '%s' "$CAPTURED_CREATE_DATA" | jq -r '.fields.description.content[0].content[0].text')"

# ADF description -> passed through unchanged
adf_in='{"type":"doc","version":1,"content":[{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"item"}]}]}]}]}'
CAPTURED_CREATE_DATA=""
op_create_issue PROJ Task "Summary" "$adf_in" >/dev/null
assert_eq "op_create_issue ADF desc: description equals input ADF" \
    "$(printf '%s' "$adf_in" | jq -cS .)" \
    "$(printf '%s' "$CAPTURED_CREATE_DATA" | jq -cS '.fields.description')"

# Empty description -> description field absent (unchanged legacy behavior)
CAPTURED_CREATE_DATA=""
op_create_issue PROJ Task "Summary Only" >/dev/null
assert_eq "op_create_issue empty desc: description field is absent" \
    "false" \
    "$(printf '%s' "$CAPTURED_CREATE_DATA" | jq -r '.fields | has("description")')"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh`
Expected: `op_create_issue ADF desc: description equals input ADF` FAILS. The other two pass against current code.

- [ ] **Step 3: Rewire `op_create_issue` description branch**

In `jira-api-wrapper.sh`, replace lines 116-139 (the `if [[ -n "$description" ]]; then ... fi`'s **true branch only**) with:

```bash
    if [[ -n "$description" ]]; then
        local desc_adf
        desc_adf=$(_to_adf_body "$description")
        issue_data=$(jq -n \
            --arg project "$project_key" \
            --arg type "$issue_type" \
            --arg summary "$summary" \
            --argjson desc "$desc_adf" \
            '{
                "fields": {
                    "project": {"key": $project},
                    "issuetype": {"name": $type},
                    "summary": $summary,
                    "description": $desc
                }
            }')
```

The `else` branch (no description) and everything after `fi` is unchanged. The full updated block reads:

```bash
    # Build the issue data
    # Note: Jira API v3 requires description in ADF format. _to_adf_body
    # passes through pre-built ADF docs unchanged, or wraps plain text.
    local issue_data
    if [[ -n "$description" ]]; then
        local desc_adf
        desc_adf=$(_to_adf_body "$description")
        issue_data=$(jq -n \
            --arg project "$project_key" \
            --arg type "$issue_type" \
            --arg summary "$summary" \
            --argjson desc "$desc_adf" \
            '{
                "fields": {
                    "project": {"key": $project},
                    "issuetype": {"name": $type},
                    "summary": $summary,
                    "description": $desc
                }
            }')
    else
        issue_data=$(jq -n \
            --arg project "$project_key" \
            --arg type "$issue_type" \
            --arg summary "$summary" \
            '{
                "fields": {
                    "project": {"key": $project},
                    "issuetype": {"name": $type},
                    "summary": $summary
                }
            }')
    fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh \
        plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh
git commit -m "fix(jira-writer): op_create_issue passes pre-built ADF description through"
```

---

### Task 4: Extend `output_mcp_fallback` with optional `note` field

**Files:**
- Modify: `plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh:55-72`
- Modify: `plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh` (append)

- [ ] **Step 1: Write the failing tests**

Append to `test-wrapper-dispatch.sh` (before `--- summary ---`):

```bash
# --- output_mcp_fallback: 3-arg form (legacy) — no .note field ---
out=$(output_mcp_fallback "someOp" '{"x":1}' "boom" 2>/dev/null)
assert_eq "output_mcp_fallback 3-arg: api is mcp_fallback" "mcp_fallback" "$(printf '%s' "$out" | jq -r '.api')"
assert_eq "output_mcp_fallback 3-arg: operation" "someOp" "$(printf '%s' "$out" | jq -r '.operation')"
assert_eq "output_mcp_fallback 3-arg: rest_error" "boom" "$(printf '%s' "$out" | jq -r '.rest_error')"
assert_eq "output_mcp_fallback 3-arg: no note field" "false" "$(printf '%s' "$out" | jq -r 'has("note")')"

# --- output_mcp_fallback: 4-arg form — note merged ---
out=$(output_mcp_fallback "someOp" '{"x":1}' "boom" "original body was ADF" 2>/dev/null)
assert_eq "output_mcp_fallback 4-arg: note present" "original body was ADF" "$(printf '%s' "$out" | jq -r '.note')"
assert_eq "output_mcp_fallback 4-arg: other fields unchanged" "someOp" "$(printf '%s' "$out" | jq -r '.operation')"

# --- output_mcp_fallback: 4-arg form, empty note — field omitted ---
out=$(output_mcp_fallback "someOp" '{"x":1}' "boom" "" 2>/dev/null)
assert_eq "output_mcp_fallback empty note: field absent" "false" "$(printf '%s' "$out" | jq -r 'has("note")')"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh`
Expected: The 4-arg `note present` test FAILS — the current implementation ignores the 4th arg.

- [ ] **Step 3: Extend `output_mcp_fallback`**

In `jira-api-wrapper.sh`, replace lines 55-72 (the entire `output_mcp_fallback` function) with:

```bash
# Output MCP fallback signal
# Args: operation, params, error, [note]
# If note is non-empty, it's merged into the envelope as .note.
output_mcp_fallback() {
    local operation="$1"
    local params="$2"
    local error="${3:-}"
    local note="${4:-}"

    log_warn "REST API failed, signaling MCP fallback..."

    if [[ -n "$note" ]]; then
        jq -n \
            --arg operation "$operation" \
            --argjson params "$params" \
            --arg error "$error" \
            --arg note "$note" \
            '{
                "api": "mcp_fallback",
                "operation": $operation,
                "params": $params,
                "rest_error": $error,
                "note": $note
            }'
    else
        jq -n \
            --arg operation "$operation" \
            --argjson params "$params" \
            --arg error "$error" \
            '{
                "api": "mcp_fallback",
                "operation": $operation,
                "params": $params,
                "rest_error": $error
            }'
    fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh \
        plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh
git commit -m "feat(jira-writer): output_mcp_fallback accepts optional note field"
```

---

### Task 5: Emit `note` on MCP fallback when ADF was detected

**Files:**
- Modify: `plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh` (`op_add_comment` and `op_create_issue` MCP fallback paths)
- Modify: `plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh` (append)

Detection mechanism: `_to_adf_body` echoes byte-identical input when pass-through occurs. We compare the helper's output against the original input (trimmed of leading whitespace) — if they match and the input started with `{`, the input was ADF. Implemented as a small `_input_was_adf` predicate so the test surface stays narrow.

- [ ] **Step 1: Write the failing tests**

Append to `test-wrapper-dispatch.sh` (before `--- summary ---`):

```bash
# --- MCP fallback note: unset credentials, keep existing stubs in place ---
# Stubs from Tasks 2 & 3 (jira_add_comment, jira_create_issue) are still
# defined in this shell, but the no-credentials branch returns before
# calling them, so they won't fire here.
unset JIRA_DOMAIN JIRA_API_KEY

# --- add_comment with ADF body when REST credentials missing ---
adf_in='{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"hi"}]}]}'
out=$(op_add_comment PROJ-1 "$adf_in" 2>/dev/null) || true
note=$(printf '%s' "$out" | jq -r '.note // empty')
if [[ -n "$note" ]]; then
    PASS=$((PASS + 1))
    printf "PASS  op_add_comment ADF+no-creds: note set\n"
else
    FAIL=$((FAIL + 1))
    printf "FAIL  op_add_comment ADF+no-creds: expected .note in envelope, got:\n        %s\n" "$out"
fi

# --- add_comment with PLAIN body when REST creds missing => no note ---
out=$(op_add_comment PROJ-1 "plain text" 2>/dev/null) || true
has_note=$(printf '%s' "$out" | jq -r 'has("note")')
if [[ "$has_note" == "false" ]]; then
    PASS=$((PASS + 1))
    printf "PASS  op_add_comment plain+no-creds: no note field\n"
else
    FAIL=$((FAIL + 1))
    printf "FAIL  op_add_comment plain+no-creds: unexpected .note in envelope:\n        %s\n" "$out"
fi

# --- create_issue with ADF description when REST creds missing ---
adf_in='{"type":"doc","version":1,"content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"H"}]}]}'
out=$(op_create_issue PROJ Task "S" "$adf_in" 2>/dev/null) || true
note=$(printf '%s' "$out" | jq -r '.note // empty')
if [[ -n "$note" ]]; then
    PASS=$((PASS + 1))
    printf "PASS  op_create_issue ADF+no-creds: note set\n"
else
    FAIL=$((FAIL + 1))
    printf "FAIL  op_create_issue ADF+no-creds: expected .note in envelope, got:\n        %s\n" "$out"
fi
```

**Why no subshells:** `( ... )` would prevent `PASS`/`FAIL` increments from reaching the parent shell. Instead we unset credentials once at the start of this block — these are the last tests in the harness, so no restoration is needed. The stubs from Tasks 2 & 3 stay defined but never fire because the no-credentials branch returns before the REST call.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh`
Expected: The two `*ADF+no-creds: note set` tests FAIL — current code calls `output_mcp_fallback` with 3 args. The `plain+no-creds: no note field` test happens to pass already.

- [ ] **Step 3: Add `_input_was_adf` predicate and emit `note` on MCP fallback**

In `jira-api-wrapper.sh`, immediately after `_to_adf_body` (which Task 1 added), insert:

```bash
# _input_was_adf INPUT
# Returns 0 (success) if INPUT is a valid ADF doc as recognized by _to_adf_body.
# Used by ops to decide whether to attach an explanatory note when falling
# back to MCP (which renders raw strings as markdown/text, not ADF).
_input_was_adf() {
    local input="$1"
    [[ "$input" =~ ^[[:space:]]*\{ ]] || return 1
    printf '%s' "$input" | jq -e '
        type == "object"
        and .type == "doc"
        and (.version | type) == "number"
        and (.content | type) == "array"
    ' >/dev/null 2>&1
}
```

Then update both MCP fallback call sites:

**`op_add_comment` — replace the two `output_mcp_fallback "addCommentToJiraIssue" ...` calls** (one in the no-credentials branch around line 222, one in the REST-failed branch around line 248) with:

```bash
# In the no-credentials branch:
local _note=""
_input_was_adf "$comment_body" && _note="Original body was ADF; MCP fallback will render as text."
output_mcp_fallback "addCommentToJiraIssue" \
    "$(jq -n --arg key "$issue_key" --arg body "$comment_body" '{issueIdOrKey: $key, commentBody: $body}')" \
    "REST credentials not configured" \
    "$_note"
return 1
```

```bash
# In the REST-failed branch:
local _note=""
_input_was_adf "$comment_body" && _note="Original body was ADF; MCP fallback will render as text."
output_mcp_fallback "addCommentToJiraIssue" \
    "$(jq -n --arg key "$issue_key" --arg body "$comment_body" '{issueIdOrKey: $key, commentBody: $body}')" \
    "$result" \
    "$_note"
return 1
```

**`op_create_issue` — replace the `output_mcp_fallback "createJiraIssue" ...` calls** (the no-credentials branch around line 156 and the REST-failed branch around line 179) using the same pattern, gating the note on `_input_was_adf "$description"`. Use the same note string.

Concretely, in the no-credentials branch (currently a single-line call):

```bash
local _note=""
[[ -n "$description" ]] && _input_was_adf "$description" \
    && _note="Original description was ADF; MCP fallback will render as text."
output_mcp_fallback "createJiraIssue" "$issue_data" "REST credentials not configured" "$_note"
return 1
```

And in the REST-failed branch (currently builds `mcp_params` first):

```bash
local _note=""
[[ -n "$description" ]] && _input_was_adf "$description" \
    && _note="Original description was ADF; MCP fallback will render as text."
output_mcp_fallback "createJiraIssue" "$mcp_params" "$result" "$_note"
return 1
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh \
        plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh
git commit -m "feat(jira-writer): attach note to MCP fallback envelope when input was ADF"
```

---

### Task 6: Update SKILL.md — Path B simplification + rich comments subsection

**Files:**
- Modify: `plugins/jira-writer/skills/jira-writer/SKILL.md` (sections at ~line 360, ~line 436, near Path B end)

- [ ] **Step 1: Replace Path B "For new issues" two-step recipe**

In `SKILL.md`, find the block starting at line 436 (`**For new issues:**` under `#### Path B: Complex Content (REST API only)`) through line 447 (the closing fence of that `curl -X PUT` block). Replace with:

````markdown
**For new issues:**

```bash
# Build the ADF document in-context (per Step 5a), then pass it as the
# fourth argument to create_issue. The wrapper auto-detects pre-built ADF.
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" \
    create_issue PROJECT_KEY "Task" "Summary" '<ADF_DOCUMENT_JSON>'
```

If you need to attach mermaid images, follow the legacy two-step flow:
create the issue with summary only, upload diagrams, then `update_issue`
with description ADF referencing the attachment URLs.
````

- [ ] **Step 2: Add "Rich comments" subsection in Path B**

In `SKILL.md`, immediately after the "REST API update format:" block (ending around line 489) and before the "**On update failure with uploaded attachments:**" block (around line 491), insert:

````markdown
**Adding rich comments:**

The `add_comment` wrapper accepts both plain text and pre-built ADF. Strict
detection: a JSON object with `type:"doc"`, numeric `version`, and array
`content` is passed through; anything else is wrapped as a single paragraph.

```bash
# Simple text comment (unchanged):
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" \
    add_comment PROJ-123 "Quick note."

# Rich ADF comment (headings, lists, code blocks, checkboxes):
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" \
    add_comment PROJ-123 '{
        "type": "doc",
        "version": 1,
        "content": [
            {"type": "heading", "attrs": {"level": 2},
             "content": [{"type": "text", "text": "Review notes"}]},
            {"type": "bulletList", "content": [
                {"type": "listItem", "content": [
                    {"type": "paragraph", "content": [
                        {"type": "text", "text": "First point"}]}]}]}
        ]
    }'
```

If REST fails and the wrapper falls back to MCP signalling, the envelope
includes a `note` field warning that ADF input will not render rich
through the MCP path.
````

- [ ] **Step 3: Add one-line note in Step 5a**

In `SKILL.md`, find line 363 (`CONVERT markdown content to ADF nodes:` inside the Step 5a code fence). Immediately after the closing ``` of that fenced block (around line 393, just before `### Step 6: Write to Jira`), insert:

```markdown
The same ADF-build instructions above apply to **rich comments**, not just
descriptions. Build the ADF document, then pass it as the body argument to
`add_comment` — the wrapper auto-detects ADF and passes it through.
```

- [ ] **Step 4: Verify the file still parses as Markdown and runs through any linters**

Run: `bash plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-dispatch.sh` (sanity — should still pass)
Run: `grep -n 'Path B\|add_comment\|rich' plugins/jira-writer/skills/jira-writer/SKILL.md | head -20`
Expected: New "Adding rich comments" header appears, single-step `create_issue` example present, Step 5a note present.

- [ ] **Step 5: Commit**

```bash
git add plugins/jira-writer/skills/jira-writer/SKILL.md
git commit -m "docs(jira-writer): document rich comments and one-step create_issue with ADF"
```

---

### Task 7: Update README.md — marketplace + clone URLs

**Files:**
- Modify: `README.md:12`, `README.md:24-27`

- [ ] **Step 1: Replace the marketplace add command**

In `README.md`, change line 12 from:

```bash
/plugin marketplace add yunidbauza/jira-writer
```

to:

```bash
/plugin marketplace add yunidbauza/claude-kit
```

- [ ] **Step 2: Replace the manual-install clone block**

In `README.md`, lines 24-27 currently read:

```bash
git clone https://github.com/yunidbauza/jira-writer.git /tmp/jira-writer
cp -r /tmp/jira-writer/plugins/jira-writer ~/.claude/plugins/
chmod +x ~/.claude/plugins/jira-writer/skills/jira-writer/scripts/*.sh
rm -rf /tmp/jira-writer
```

Replace with:

```bash
git clone https://github.com/yunidbauza/claude-kit.git /tmp/claude-kit
cp -r /tmp/claude-kit/plugins/jira-writer ~/.claude/plugins/
chmod +x ~/.claude/plugins/jira-writer/skills/jira-writer/scripts/*.sh
rm -rf /tmp/claude-kit
```

Note: the `chmod` line stays exactly as-is — that path is the *installed* plugin location, not the clone path.

- [ ] **Step 3: Verify**

Run: `grep -n 'yunidbauza/jira-writer\|/tmp/jira-writer' README.md`
Expected: No matches (all replaced).

Run: `grep -n 'yunidbauza/claude-kit\|/tmp/claude-kit' README.md`
Expected: Three matches — marketplace add line, clone URL, cleanup `rm`.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: fix README install instructions for claude-kit rename"
```

---

### Task 8: Version bump

**Files:**
- Modify: `plugins/jira-writer/.claude-plugin/plugin.json`

- [ ] **Step 1: Bump version**

In `plugins/jira-writer/.claude-plugin/plugin.json`, change:

```json
"version": "1.3.0",
```

to:

```json
"version": "1.4.0",
```

- [ ] **Step 2: Verify**

Run: `jq -r '.version' plugins/jira-writer/.claude-plugin/plugin.json`
Expected: `1.4.0`

- [ ] **Step 3: Commit**

```bash
git add plugins/jira-writer/.claude-plugin/plugin.json
git commit -m "chore: bump jira-writer to v1.4.0 for rich ADF input support"
```

---

### Task 9: Manual smoke test (one-time, post-merge, requires real Jira credentials)

**Files:** none — verification only.

This task is **not automated** because it requires real Jira credentials and a real project. Skip if no test Jira is available; flag to the user instead.

- [ ] **Step 1: Set credentials**

```bash
export JIRA_DOMAIN="<your-test-instance>.atlassian.net"
export JIRA_API_KEY="<email>:<api-token>"
```

- [ ] **Step 2: Test rich comment**

```bash
bash plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh \
    add_comment <TEST_ISSUE_KEY> '{
        "type": "doc",
        "version": 1,
        "content": [
            {"type": "heading", "attrs": {"level": 2},
             "content": [{"type": "text", "text": "Smoke test"}]},
            {"type": "bulletList", "content": [
                {"type": "listItem", "content": [
                    {"type": "paragraph", "content": [
                        {"type": "text", "text": "Item one"}]}]},
                {"type": "listItem", "content": [
                    {"type": "paragraph", "content": [
                        {"type": "text", "text": "Item two"}]}]}]},
            {"type": "codeBlock", "attrs": {"language": "bash"},
             "content": [{"type": "text", "text": "echo hello"}]}
        ]
    }'
```

Open the issue in Jira's web UI. Expected: heading, bullet list, and code block render as native ADF — not as a literal JSON string.

- [ ] **Step 3: Test single-step rich create**

```bash
bash plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh \
    create_issue <TEST_PROJECT> Task "Smoke test rich description" '{
        "type": "doc",
        "version": 1,
        "content": [
            {"type": "heading", "attrs": {"level": 1},
             "content": [{"type": "text", "text": "Overview"}]},
            {"type": "paragraph",
             "content": [{"type": "text", "text": "Created in one API call."}]}
        ]
    }'
```

Open the new issue. Expected: heading and paragraph render rich. No additional `update_issue` call needed.

- [ ] **Step 4: Backward compat — plain text comment**

```bash
bash plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh \
    add_comment <TEST_ISSUE_KEY> "Plain comment, no markdown."
```

Expected: Renders as plain paragraph (same as before this change).

---

## Self-review notes (from author)

- **Spec coverage:** all spec sections map to tasks. Helper → Task 1. add_comment fix → Task 2. create_issue fix → Task 3. MCP fallback `note` → Tasks 4+5. Docs → Tasks 6+7. Version → Task 8. Manual smoke → Task 9.
- **Type/name consistency:** helper name `_to_adf_body`, predicate `_input_was_adf`, envelope field `note`, version `1.4.0` — all consistent across tasks.
- **No placeholders:** every code block contains exact code; every command has expected output.
- **TDD shape preserved:** Tasks 1-5 all follow write-test → fail → implement → pass → commit. Tasks 6-9 are non-code or external-state-dependent so they skip the test-first ritual.
