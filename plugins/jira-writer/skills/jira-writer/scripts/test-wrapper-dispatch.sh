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
# Save originals so later tests can override differently if needed.
JIRA_DOMAIN_SAVE="${JIRA_DOMAIN:-}"
JIRA_API_KEY_SAVE="${JIRA_API_KEY:-}"
export JIRA_DOMAIN="example.atlassian.net"
export JIRA_API_KEY="user@example.com:fake-token"

# Use a temp file to capture data from within command-substitution subshells.
_COMMENT_CAPTURE_FILE="$(mktemp)"
trap 'rm -f "$_COMMENT_CAPTURE_FILE"' EXIT
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

# --- summary ---
echo
printf "Total: %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
