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
assert_contains "suggest_op get_isue includes get_issue" "get_issue" "$(suggest_op get_isue)"
assert_contains "suggest_op projct includes get_projects" "get_projects" "$(suggest_op projct)"

# --- summary ---
echo
printf "Total: %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
