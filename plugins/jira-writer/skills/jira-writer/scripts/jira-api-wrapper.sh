#!/usr/bin/env bash
#
# jira-api-wrapper.sh
#
# Unified interface for Jira operations.
# Tries REST API first (primary), falls back to MCP signal if REST fails.
#
# Usage:
#   ./jira-api-wrapper.sh <operation> [args...]
#
# Operations mirror the Jira REST API functions but with a unified interface
# that handles API selection and fallback signaling.
#
# Output (JSON):
#   On success: { "api": "rest", "data": {...} }
#   On REST failure: { "api": "mcp_fallback", "operation": "...", "params": {...} }
#
# Environment Variables:
#   JIRA_DOMAIN   - Your Jira domain (e.g., company.atlassian.net)
#   JIRA_API_KEY  - Your email:api_token (NOT base64 encoded)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the REST API functions
source "$SCRIPT_DIR/jira-rest-api.sh"

# Colors for output (only when stderr is a terminal)
if [[ -t 2 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

# Logging functions (to stderr)
log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Output success response with REST API data
output_rest_success() {
    local data="$1"
    jq -n --argjson data "$data" '{"api": "rest", "data": $data}'
}

# Output MCP fallback signal
output_mcp_fallback() {
    local operation="$1"
    local params="$2"
    local error="${3:-}"

    log_warn "REST API failed, signaling MCP fallback..."

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
}

# Check if REST API is available
check_rest_available() {
    if [[ -z "${JIRA_DOMAIN:-}" ]] || [[ -z "${JIRA_API_KEY:-}" ]]; then
        return 1
    fi
    return 0
}

# --- Operation Handlers ---

# Get issue operation
op_get_issue() {
    local issue_key="$1"
    local fields="${2:-}"

    # Check REST availability
    if ! check_rest_available; then
        output_mcp_fallback "getJiraIssue" "$(jq -n --arg key "$issue_key" '{issueIdOrKey: $key}')" "REST credentials not configured"
        return 1
    fi

    # Try REST API
    local result
    if result=$(jira_get_issue "$issue_key" "$fields" 2>&1); then
        output_rest_success "$result"
        return 0
    else
        output_mcp_fallback "getJiraIssue" "$(jq -n --arg key "$issue_key" '{issueIdOrKey: $key}')" "$result"
        return 1
    fi
}

# Create issue operation
op_create_issue() {
    local project_key="$1"
    local issue_type="$2"
    local summary="$3"
    local description="${4:-}"

    # Build the issue data
    # Note: Jira API v3 requires description in ADF format
    local issue_data
    if [[ -n "$description" ]]; then
        issue_data=$(jq -n \
            --arg project "$project_key" \
            --arg type "$issue_type" \
            --arg summary "$summary" \
            --arg desc "$description" \
            '{
                "fields": {
                    "project": {"key": $project},
                    "issuetype": {"name": $type},
                    "summary": $summary,
                    "description": {
                        "type": "doc",
                        "version": 1,
                        "content": [{
                            "type": "paragraph",
                            "content": [{
                                "type": "text",
                                "text": $desc
                            }]
                        }]
                    }
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

    # Check REST availability
    if ! check_rest_available; then
        output_mcp_fallback "createJiraIssue" "$issue_data" "REST credentials not configured"
        return 1
    fi

    # Try REST API
    local result
    if result=$(jira_create_issue "$issue_data" 2>&1); then
        output_rest_success "$result"
        return 0
    else
        # Fall back params for MCP
        local mcp_params
        mcp_params=$(jq -n \
            --arg project "$project_key" \
            --arg type "$issue_type" \
            --arg summary "$summary" \
            --arg desc "$description" \
            '{
                projectKey: $project,
                issueTypeName: $type,
                summary: $summary,
                description: $desc
            }')
        output_mcp_fallback "createJiraIssue" "$mcp_params" "$result"
        return 1
    fi
}

# Update issue operation
op_update_issue() {
    local issue_key="$1"
    local fields_json="$2"

    # Check REST availability
    if ! check_rest_available; then
        output_mcp_fallback "editJiraIssue" "$(jq -n --arg key "$issue_key" --argjson fields "$fields_json" '{issueIdOrKey: $key, fields: $fields}')" "REST credentials not configured"
        return 1
    fi

    # Build update data
    local update_data
    update_data=$(jq -n --argjson fields "$fields_json" '{"fields": $fields}')

    # Try REST API
    local result
    if result=$(jira_update_issue "$issue_key" "$update_data" 2>&1); then
        # Update returns empty on success (204), return minimal success response
        if [[ -z "$result" ]]; then
            output_rest_success '{"success": true}'
        else
            output_rest_success "$result"
        fi
        return 0
    else
        output_mcp_fallback "editJiraIssue" "$(jq -n --arg key "$issue_key" --argjson fields "$fields_json" '{issueIdOrKey: $key, fields: $fields}')" "$result"
        return 1
    fi
}

# Add comment operation
op_add_comment() {
    local issue_key="$1"
    local comment_body="$2"

    # Check REST availability
    if ! check_rest_available; then
        output_mcp_fallback "addCommentToJiraIssue" "$(jq -n --arg key "$issue_key" --arg body "$comment_body" '{issueIdOrKey: $key, commentBody: $body}')" "REST credentials not configured"
        return 1
    fi

    # Build comment data (ADF format)
    local comment_data
    comment_data=$(jq -n --arg text "$comment_body" '{
        "body": {
            "type": "doc",
            "version": 1,
            "content": [{
                "type": "paragraph",
                "content": [{
                    "type": "text",
                    "text": $text
                }]
            }]
        }
    }')

    # Try REST API
    local result
    if result=$(jira_add_comment "$issue_key" "$comment_data" 2>&1); then
        output_rest_success "$result"
        return 0
    else
        output_mcp_fallback "addCommentToJiraIssue" "$(jq -n --arg key "$issue_key" --arg body "$comment_body" '{issueIdOrKey: $key, commentBody: $body}')" "$result"
        return 1
    fi
}

# Get transitions operation
op_get_transitions() {
    local issue_key="$1"

    # Check REST availability
    if ! check_rest_available; then
        output_mcp_fallback "getTransitionsForJiraIssue" "$(jq -n --arg key "$issue_key" '{issueIdOrKey: $key}')" "REST credentials not configured"
        return 1
    fi

    # Try REST API
    local result
    if result=$(jira_get_transitions "$issue_key" 2>&1); then
        output_rest_success "$result"
        return 0
    else
        output_mcp_fallback "getTransitionsForJiraIssue" "$(jq -n --arg key "$issue_key" '{issueIdOrKey: $key}')" "$result"
        return 1
    fi
}

# Transition issue operation
op_transition_issue() {
    local issue_key="$1"
    local transition_id="$2"

    # Check REST availability
    if ! check_rest_available; then
        output_mcp_fallback "transitionJiraIssue" "$(jq -n --arg key "$issue_key" --arg tid "$transition_id" '{issueIdOrKey: $key, transition: {id: $tid}}')" "REST credentials not configured"
        return 1
    fi

    # Build transition data
    local transition_data
    transition_data=$(jq -n --arg tid "$transition_id" '{"transition": {"id": $tid}}')

    # Try REST API
    local result
    if result=$(jira_transition_issue "$issue_key" "$transition_data" 2>&1); then
        if [[ -z "$result" ]]; then
            output_rest_success '{"success": true}'
        else
            output_rest_success "$result"
        fi
        return 0
    else
        output_mcp_fallback "transitionJiraIssue" "$(jq -n --arg key "$issue_key" --arg tid "$transition_id" '{issueIdOrKey: $key, transition: {id: $tid}}')" "$result"
        return 1
    fi
}

# Search with JQL operation
op_search_jql() {
    local jql="$1"
    local max_results="${2:-50}"

    # Check REST availability
    if ! check_rest_available; then
        output_mcp_fallback "searchJiraIssuesUsingJql" "$(jq -n --arg jql "$jql" --argjson max "$max_results" '{jql: $jql, maxResults: $max}')" "REST credentials not configured"
        return 1
    fi

    # Try REST API
    local result
    if result=$(jira_search_jql "$jql" "$max_results" 2>&1); then
        output_rest_success "$result"
        return 0
    else
        output_mcp_fallback "searchJiraIssuesUsingJql" "$(jq -n --arg jql "$jql" --argjson max "$max_results" '{jql: $jql, maxResults: $max}')" "$result"
        return 1
    fi
}

# Get projects operation
op_get_projects() {
    local max_results="${1:-50}"

    # Check REST availability
    if ! check_rest_available; then
        output_mcp_fallback "getVisibleJiraProjects" "$(jq -n --argjson max "$max_results" '{maxResults: $max}')" "REST credentials not configured"
        return 1
    fi

    # Try REST API
    local result
    if result=$(jira_get_projects "$max_results" 2>&1); then
        output_rest_success "$result"
        return 0
    else
        output_mcp_fallback "getVisibleJiraProjects" "$(jq -n --argjson max "$max_results" '{maxResults: $max}')" "$result"
        return 1
    fi
}

# Get issue types operation
op_get_issue_types() {
    local project_key="$1"

    # Check REST availability
    if ! check_rest_available; then
        output_mcp_fallback "getJiraProjectIssueTypesMetadata" "$(jq -n --arg key "$project_key" '{projectIdOrKey: $key}')" "REST credentials not configured"
        return 1
    fi

    # Try REST API
    local result
    if result=$(jira_get_issue_types "$project_key" 2>&1); then
        output_rest_success "$result"
        return 0
    else
        output_mcp_fallback "getJiraProjectIssueTypesMetadata" "$(jq -n --arg key "$project_key" '{projectIdOrKey: $key}')" "$result"
        return 1
    fi
}

# Lookup user operation
op_lookup_user() {
    local query="$1"

    # Check REST availability
    if ! check_rest_available; then
        output_mcp_fallback "lookupJiraAccountId" "$(jq -n --arg q "$query" '{searchString: $q}')" "REST credentials not configured"
        return 1
    fi

    # Try REST API
    local result
    if result=$(jira_lookup_user "$query" 2>&1); then
        output_rest_success "$result"
        return 0
    else
        output_mcp_fallback "lookupJiraAccountId" "$(jq -n --arg q "$query" '{searchString: $q}')" "$result"
        return 1
    fi
}

# Add worklog operation
op_add_worklog() {
    local issue_key="$1"
    local time_spent="$2"

    # Check REST availability
    if ! check_rest_available; then
        output_mcp_fallback "addWorklogToJiraIssue" "$(jq -n --arg key "$issue_key" --arg time "$time_spent" '{issueIdOrKey: $key, timeSpent: $time}')" "REST credentials not configured"
        return 1
    fi

    # Build worklog data
    local worklog_data
    worklog_data=$(jq -n --arg time "$time_spent" '{"timeSpent": $time}')

    # Try REST API
    local result
    if result=$(jira_add_worklog "$issue_key" "$worklog_data" 2>&1); then
        output_rest_success "$result"
        return 0
    else
        output_mcp_fallback "addWorklogToJiraIssue" "$(jq -n --arg key "$issue_key" --arg time "$time_spent" '{issueIdOrKey: $key, timeSpent: $time}')" "$result"
        return 1
    fi
}

# Upload attachment operation
op_upload_attachment() {
    local issue_key="$1"
    local file_path="$2"
    local filename="${3:-}"

    # Note: MCP cannot upload attachments, so no fallback available
    if ! check_rest_available; then
        jq -n '{
            "api": "error",
            "error": "REST API required for attachments (MCP cannot upload files)",
            "setup_required": ["JIRA_DOMAIN", "JIRA_API_KEY"]
        }'
        return 1
    fi

    # Try REST API
    local result
    if [[ -n "$filename" ]]; then
        result=$(jira_upload_attachment "$issue_key" "$file_path" "$filename" 2>&1)
    else
        result=$(jira_upload_attachment "$issue_key" "$file_path" 2>&1)
    fi

    if [[ $? -eq 0 ]]; then
        output_rest_success "$result"
        return 0
    else
        jq -n --arg error "$result" '{
            "api": "error",
            "error": $error,
            "note": "Attachment upload is REST-only (no MCP fallback available)"
        }'
        return 1
    fi
}

# Get remote links operation
op_get_remote_links() {
    local issue_key="$1"

    # Check REST availability
    if ! check_rest_available; then
        output_mcp_fallback "getJiraIssueRemoteIssueLinks" "$(jq -n --arg key "$issue_key" '{issueIdOrKey: $key}')" "REST credentials not configured"
        return 1
    fi

    # Try REST API
    local result
    if result=$(jira_get_remote_links "$issue_key" 2>&1); then
        output_rest_success "$result"
        return 0
    else
        output_mcp_fallback "getJiraIssueRemoteIssueLinks" "$(jq -n --arg key "$issue_key" '{issueIdOrKey: $key}')" "$result"
        return 1
    fi
}

# Test connection operation
op_test_connection() {
    # Check REST availability first
    if ! check_rest_available; then
        jq -n '{
            "rest_api": {
                "available": false,
                "reason": "Credentials not configured (JIRA_DOMAIN and/or JIRA_API_KEY missing)"
            },
            "recommended": "mcp"
        }'
        return 1
    fi

    # Try REST API
    local result
    if result=$(jira_test_connection 2>&1); then
        local user_info="$result"
        jq -n --argjson user "$user_info" '{
            "rest_api": {
                "available": true,
                "authenticated": true,
                "user": $user.user
            },
            "recommended": "rest"
        }'
        return 0
    else
        jq -n --arg error "$result" '{
            "rest_api": {
                "available": true,
                "authenticated": false,
                "error": $error
            },
            "recommended": "mcp"
        }'
        return 1
    fi
}

# --- Main Entry Point ---

print_usage() {
    echo "Usage: $0 <operation> [args...]" >&2
    echo "" >&2
    echo "Operations:" >&2
    echo "  get_issue KEY [fields]           - Get issue details" >&2
    echo "  create_issue PROJECT TYPE SUMMARY [desc] - Create new issue" >&2
    echo "  update_issue KEY FIELDS_JSON     - Update issue fields" >&2
    echo "  add_comment KEY BODY             - Add comment to issue" >&2
    echo "  get_transitions KEY              - Get available transitions" >&2
    echo "  transition_issue KEY TRANSITION_ID - Transition issue status" >&2
    echo "  search_jql JQL [max_results]     - Search with JQL" >&2
    echo "  get_projects [max_results]       - List visible projects" >&2
    echo "  get_issue_types PROJECT          - Get issue types for project" >&2
    echo "  lookup_user QUERY                - Search for users" >&2
    echo "  add_worklog KEY TIME_SPENT       - Add worklog entry" >&2
    echo "  upload_attachment KEY FILE [name] - Upload file attachment" >&2
    echo "  get_remote_links KEY             - Get remote issue links" >&2
    echo "  test_connection                  - Test API connection" >&2
    echo "" >&2
    echo "Output:" >&2
    echo "  Success: {\"api\": \"rest\", \"data\": {...}}" >&2
    echo "  Fallback: {\"api\": \"mcp_fallback\", \"operation\": \"...\", \"params\": {...}}" >&2
}

# --- Operation name normalization ---

# Canonical operation names. Order matters for suggest_op output.
KNOWN_OPS=(
    get_issue
    create_issue
    update_issue
    add_comment
    get_transitions
    transition_issue
    search_jql
    get_projects
    get_issue_types
    lookup_user
    add_worklog
    upload_attachment
    get_remote_links
    test_connection
)

# normalize_op INPUT
# Returns the canonical operation name for INPUT.
# Resolution order:
#   1. Already canonical -> return as-is.
#   2. Strip leading "jira_" prefix.
#   3. Convert camelCase to snake_case.
#   4. Map verb-only aliases to canonical ops.
#   5. Unknown -> return input unchanged (caller decides).
normalize_op() {
    local op="$1"

    # 1. Canonical match.
    local known
    for known in "${KNOWN_OPS[@]}"; do
        if [[ "$op" == "$known" ]]; then
            printf '%s\n' "$op"
            return 0
        fi
    done

    # 2. Strip leading "jira_" prefix.
    if [[ "$op" == jira_* ]]; then
        local stripped="${op#jira_}"
        for known in "${KNOWN_OPS[@]}"; do
            if [[ "$stripped" == "$known" ]]; then
                printf '%s\n' "$stripped"
                return 0
            fi
        done
        op="$stripped"
    fi

    # 3. camelCase -> snake_case (insert _ before each upper, then lowercase).
    if [[ "$op" =~ [A-Z] ]]; then
        local snake
        snake=$(printf '%s' "$op" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr '[:upper:]' '[:lower:]')
        for known in "${KNOWN_OPS[@]}"; do
            if [[ "$snake" == "$known" ]]; then
                printf '%s\n' "$snake"
                return 0
            fi
        done
        op="$snake"
    fi

    # 4. Verb-only aliases.
    case "$op" in
        issue|get)              printf 'get_issue\n'; return 0 ;;
        create)                 printf 'create_issue\n'; return 0 ;;
        update)                 printf 'update_issue\n'; return 0 ;;
        comment)                printf 'add_comment\n'; return 0 ;;
        search|jql)             printf 'search_jql\n'; return 0 ;;
        projects)               printf 'get_projects\n'; return 0 ;;
        types|issue_types)      printf 'get_issue_types\n'; return 0 ;;
        transitions)            printf 'get_transitions\n'; return 0 ;;
        transition)             printf 'transition_issue\n'; return 0 ;;
        user|users|lookup)      printf 'lookup_user\n'; return 0 ;;
        worklog)                printf 'add_worklog\n'; return 0 ;;
        attach|attachment|upload) printf 'upload_attachment\n'; return 0 ;;
        links|remote_links)     printf 'get_remote_links\n'; return 0 ;;
        test|ping)              printf 'test_connection\n'; return 0 ;;
    esac

    # 5. Unknown — return input unchanged.
    printf '%s\n' "$1"
}

# suggest_op INPUT
# Returns up to 2 canonical ops most similar to INPUT, comma-separated.
# Stub: returns first two known ops. Real ranking lands in Task 5.
suggest_op() {
    printf '%s, %s\n' "${KNOWN_OPS[0]}" "${KNOWN_OPS[1]}"
}

# Only run dispatch when invoked directly (not sourced for testing).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ -z "${JIRA_WRAPPER_TEST_MODE:-}" ]]; then
    if [[ $# -lt 1 ]]; then
        print_usage
        exit 1
    fi

    operation="$1"
    shift
    operation="$(normalize_op "$operation")"

    case "$operation" in
        get_issue)
            [[ $# -lt 1 ]] && { echo "Error: get_issue requires issue key" >&2; exit 1; }
            op_get_issue "$@"
            ;;
        create_issue)
            [[ $# -lt 3 ]] && { echo "Error: create_issue requires PROJECT TYPE SUMMARY" >&2; exit 1; }
            op_create_issue "$@"
            ;;
        update_issue)
            [[ $# -lt 2 ]] && { echo "Error: update_issue requires KEY FIELDS_JSON" >&2; exit 1; }
            op_update_issue "$@"
            ;;
        add_comment)
            [[ $# -lt 2 ]] && { echo "Error: add_comment requires KEY BODY" >&2; exit 1; }
            op_add_comment "$@"
            ;;
        get_transitions)
            [[ $# -lt 1 ]] && { echo "Error: get_transitions requires issue key" >&2; exit 1; }
            op_get_transitions "$@"
            ;;
        transition_issue)
            [[ $# -lt 2 ]] && { echo "Error: transition_issue requires KEY TRANSITION_ID" >&2; exit 1; }
            op_transition_issue "$@"
            ;;
        search_jql)
            [[ $# -lt 1 ]] && { echo "Error: search_jql requires JQL query" >&2; exit 1; }
            op_search_jql "$@"
            ;;
        get_projects)
            op_get_projects "$@"
            ;;
        get_issue_types)
            [[ $# -lt 1 ]] && { echo "Error: get_issue_types requires project key" >&2; exit 1; }
            op_get_issue_types "$@"
            ;;
        lookup_user)
            [[ $# -lt 1 ]] && { echo "Error: lookup_user requires query" >&2; exit 1; }
            op_lookup_user "$@"
            ;;
        add_worklog)
            [[ $# -lt 2 ]] && { echo "Error: add_worklog requires KEY TIME_SPENT" >&2; exit 1; }
            op_add_worklog "$@"
            ;;
        upload_attachment)
            [[ $# -lt 2 ]] && { echo "Error: upload_attachment requires KEY FILE" >&2; exit 1; }
            op_upload_attachment "$@"
            ;;
        get_remote_links)
            [[ $# -lt 1 ]] && { echo "Error: get_remote_links requires issue key" >&2; exit 1; }
            op_get_remote_links "$@"
            ;;
        test_connection)
            op_test_connection
            ;;
        *)
            echo "Error: Unknown operation '$operation'" >&2
            print_usage
            exit 1
            ;;
    esac
fi
