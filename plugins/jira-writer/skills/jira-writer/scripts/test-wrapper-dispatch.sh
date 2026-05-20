#!/usr/bin/env bash
# Tests for jira-api-wrapper.sh dispatch helpers.
# Sources the wrapper and exercises normalize_op / suggest_op directly.
# Run: bash scripts/test-wrapper-dispatch.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        printf "PASS  %s\n" "$label"
    else
        FAIL=$((FAIL + 1))
        printf "FAIL  %s\n        expected: %q\n        actual:   %q\n" \
            "$label" "$expected" "$actual"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
        printf "PASS  %s\n" "$label"
    else
        FAIL=$((FAIL + 1))
        printf "FAIL  %s\n        needle:    %q\n        haystack:  %q\n" \
            "$label" "$needle" "$haystack"
    fi
}

# Source the wrapper in test mode (skips dispatch).
JIRA_WRAPPER_TEST_MODE=1
export JIRA_WRAPPER_TEST_MODE
# shellcheck source=jira-api-wrapper.sh
source "$SCRIPT_DIR/jira-api-wrapper.sh"

# --- Cleanup registry: any test that creates a temp file appends its path
# to _CLEANUP_FILES, and the EXIT trap removes them all. Avoids the
# trap-accumulation hazard where each new temp file's trap would override
# the previous one's cleanup.
_CLEANUP_FILES=()
trap 'rm -f "${_CLEANUP_FILES[@]:-}"' EXIT

# --- normalize_op: identity for canonical ops ---
assert_eq "canonical get_issue passes through" "get_issue" "$(normalize_op get_issue)"
assert_eq "canonical create_issue passes through" "create_issue" "$(normalize_op create_issue)"
assert_eq "canonical search_jql passes through" "search_jql" "$(normalize_op search_jql)"

# --- normalize_op: jira_ prefix strip ---
assert_eq "strip jira_ prefix get" "get_issue" "$(normalize_op jira_get_issue)"
assert_eq "strip jira_ prefix create" "create_issue" "$(normalize_op jira_create_issue)"
assert_eq "strip jira_ prefix search" "search_jql" "$(normalize_op jira_search_jql)"

# --- normalize_op: camelCase to snake_case ---
assert_eq "camelCase getIssue" "get_issue" "$(normalize_op getIssue)"
assert_eq "camelCase createIssue" "create_issue" "$(normalize_op createIssue)"
assert_eq "camelCase getProjects" "get_projects" "$(normalize_op getProjects)"

# --- normalize_op: verb-only aliases ---
assert_eq "alias issue -> get_issue" "get_issue" "$(normalize_op issue)"
assert_eq "alias create -> create_issue" "create_issue" "$(normalize_op create)"
assert_eq "alias update -> update_issue" "update_issue" "$(normalize_op update)"
assert_eq "alias comment -> add_comment" "add_comment" "$(normalize_op comment)"
assert_eq "alias search -> search_jql" "search_jql" "$(normalize_op search)"
assert_eq "alias jql -> search_jql" "search_jql" "$(normalize_op jql)"
assert_eq "alias projects -> get_projects" "get_projects" "$(normalize_op projects)"
assert_eq "alias types -> get_issue_types" "get_issue_types" "$(normalize_op types)"
assert_eq "alias transitions -> get_transitions" "get_transitions" "$(normalize_op transitions)"
assert_eq "alias transition -> transition_issue" "transition_issue" "$(normalize_op transition)"
assert_eq "alias user -> lookup_user" "lookup_user" "$(normalize_op user)"
assert_eq "alias attach -> upload_attachment" "upload_attachment" "$(normalize_op attach)"
assert_eq "alias upload -> upload_attachment" "upload_attachment" "$(normalize_op upload)"
assert_eq "alias links -> get_remote_links" "get_remote_links" "$(normalize_op links)"
assert_eq "alias test -> test_connection" "test_connection" "$(normalize_op test)"

# --- normalize_op: unknown returns input unchanged ---
assert_eq "unknown op passes through unchanged" "notarealop" "$(normalize_op notarealop)"

# --- suggest_op: returns at least one canonical op for typo ---
first_suggestion="$(suggest_op get_isue | cut -d',' -f1 | tr -d '[:space:]')"
assert_eq "suggest_op get_isue first suggestion is get_issue" "get_issue" "$first_suggestion"
assert_contains "suggest_op projct includes get_projects" "get_projects" "$(suggest_op projct)"

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

# --- op_add_comment: stub jira_add_comment to capture the data it receives ---
# Test-mode credentials. Subsequent tests assume these are set; Task 5
# unsets them explicitly when testing the no-credentials fallback path.
export JIRA_DOMAIN="example.atlassian.net"
export JIRA_API_KEY="user@example.com:fake-token"

# Use a temp file to capture data from within command-substitution subshells.
_COMMENT_CAPTURE_FILE="$(mktemp)"
_CLEANUP_FILES+=("$_COMMENT_CAPTURE_FILE")
jira_add_comment() {
    # $1 = issue_key, $2 = data
    printf '%s' "$2" > "$_COMMENT_CAPTURE_FILE"
    printf '%s' '{"id":"10001","self":"http://example/comment/10001"}'
    return 0
}

# Plain text input -> single paragraph
printf '' > "$_COMMENT_CAPTURE_FILE"
op_add_comment PROJ-1 "plain text" >/dev/null
CAPTURED_COMMENT_DATA="$(cat "$_COMMENT_CAPTURE_FILE")"
assert_eq "op_add_comment plain: body.content[0].type" \
    "paragraph" \
    "$(printf '%s' "$CAPTURED_COMMENT_DATA" | jq -r '.body.content[0].type')"
assert_eq "op_add_comment plain: text node value" \
    "plain text" \
    "$(printf '%s' "$CAPTURED_COMMENT_DATA" | jq -r '.body.content[0].content[0].text')"

# ADF input -> body equals input ADF
adf_in='{"type":"doc","version":1,"content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"H"}]}]}'
printf '' > "$_COMMENT_CAPTURE_FILE"
op_add_comment PROJ-1 "$adf_in" >/dev/null
CAPTURED_COMMENT_DATA="$(cat "$_COMMENT_CAPTURE_FILE")"
assert_eq "op_add_comment ADF: body equals input ADF" \
    "$(printf '%s' "$adf_in" | jq -cS .)" \
    "$(printf '%s' "$CAPTURED_COMMENT_DATA" | jq -cS '.body')"

# Non-ADF JSON -> wrapped as literal text
printf '' > "$_COMMENT_CAPTURE_FILE"
op_add_comment PROJ-1 '{"foo":"bar"}' >/dev/null
CAPTURED_COMMENT_DATA="$(cat "$_COMMENT_CAPTURE_FILE")"
assert_eq "op_add_comment non-ADF JSON: literal text preserved" \
    '{"foo":"bar"}' \
    "$(printf '%s' "$CAPTURED_COMMENT_DATA" | jq -r '.body.content[0].content[0].text')"

# --- op_create_issue: stub jira_create_issue to capture issue_data ---
# Use a separate temp file so this doesn't collide with comment captures.
_CREATE_CAPTURE_FILE="$(mktemp)"
_CLEANUP_FILES+=("$_CREATE_CAPTURE_FILE")
jira_create_issue() {
    # $1 = data
    printf '%s' "$1" > "$_CREATE_CAPTURE_FILE"
    printf '%s' '{"id":"10001","key":"PROJ-1","self":"http://example/issue/PROJ-1"}'
    return 0
}

# Plain text description -> single paragraph
> "$_CREATE_CAPTURE_FILE"
op_create_issue PROJ Task "Summary" "plain desc" >/dev/null
captured=$(cat "$_CREATE_CAPTURE_FILE")
assert_eq "op_create_issue plain desc: description.content[0].type" \
    "paragraph" \
    "$(printf '%s' "$captured" | jq -r '.fields.description.content[0].type')"
assert_eq "op_create_issue plain desc: text node value" \
    "plain desc" \
    "$(printf '%s' "$captured" | jq -r '.fields.description.content[0].content[0].text')"

# ADF description -> passed through unchanged
adf_in='{"type":"doc","version":1,"content":[{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"item"}]}]}]}]}'
> "$_CREATE_CAPTURE_FILE"
op_create_issue PROJ Task "Summary" "$adf_in" >/dev/null
captured=$(cat "$_CREATE_CAPTURE_FILE")
assert_eq "op_create_issue ADF desc: description equals input ADF" \
    "$(printf '%s' "$adf_in" | jq -cS .)" \
    "$(printf '%s' "$captured" | jq -cS '.fields.description')"

# Empty description -> description field absent (unchanged legacy behavior)
> "$_CREATE_CAPTURE_FILE"
op_create_issue PROJ Task "Summary Only" >/dev/null
captured=$(cat "$_CREATE_CAPTURE_FILE")
assert_eq "op_create_issue empty desc: description field is absent" \
    "false" \
    "$(printf '%s' "$captured" | jq -r '.fields | has("description")')"

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

# --- op_add_comment REST-fail + ADF emits note ---
# Replace the existing jira_add_comment stub with one that returns failure.
# Restore credentials (Task 5's no-creds tests already unset them).
export JIRA_DOMAIN="example.atlassian.net"
export JIRA_API_KEY="user@example.com:fake-token"

jira_add_comment() {
    printf '%s' "$2" > "$_COMMENT_CAPTURE_FILE"
    echo "simulated REST failure" >&2
    return 1
}

adf_in='{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"hi"}]}]}'
out=$(op_add_comment PROJ-1 "$adf_in" 2>/dev/null) || true
note=$(printf '%s' "$out" | jq -r '.note // empty')
if [[ -n "$note" ]]; then
    PASS=$((PASS + 1))
    printf "PASS  op_add_comment REST-fail+ADF: note set\n"
else
    FAIL=$((FAIL + 1))
    printf "FAIL  op_add_comment REST-fail+ADF: expected .note, got:\n        %s\n" "$out"
fi

# --- op_create_issue REST-fail + ADF emits note ---
jira_create_issue() {
    printf '%s' "$1" > "$_CREATE_CAPTURE_FILE"
    echo "simulated REST failure" >&2
    return 1
}

adf_in='{"type":"doc","version":1,"content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"H"}]}]}'
out=$(op_create_issue PROJ Task "S" "$adf_in" 2>/dev/null) || true
note=$(printf '%s' "$out" | jq -r '.note // empty')
if [[ -n "$note" ]]; then
    PASS=$((PASS + 1))
    printf "PASS  op_create_issue REST-fail+ADF: note set\n"
else
    FAIL=$((FAIL + 1))
    printf "FAIL  op_create_issue REST-fail+ADF: expected .note, got:\n        %s\n" "$out"
fi

# --- op_upload_attachment no-creds envelope shape ---
unset JIRA_DOMAIN JIRA_API_KEY

out=$(op_upload_attachment PROJ-1 /tmp/fakefile.png 2>/dev/null) || true
assert_eq "op_upload_attachment no-creds: api is error" "error" "$(printf '%s' "$out" | jq -r '.api')"
assert_eq "op_upload_attachment no-creds: operation is uploadJiraAttachment" "uploadJiraAttachment" "$(printf '%s' "$out" | jq -r '.operation')"
assert_eq "op_upload_attachment no-creds: rest_error mentions credentials" "true" "$(printf '%s' "$out" | jq -r '.rest_error | contains("credentials")')"

# --- op_update_issue rejects malformed JSON ---
# Credentials set so the error comes from JSON validation, not cred check.
export JIRA_DOMAIN="example.atlassian.net"
export JIRA_API_KEY="user@example.com:fake-token"

out=$(op_update_issue PROJ-1 'not json' 2>/dev/null) || true
assert_eq "op_update_issue malformed JSON: api is error" "error" "$(printf '%s' "$out" | jq -r '.api')"
assert_eq "op_update_issue malformed JSON: error mentions Invalid JSON" "true" "$(printf '%s' "$out" | jq -r '.error | contains("Invalid JSON")')"

# --- summary ---
echo
printf "Total: %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
