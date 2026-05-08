#!/usr/bin/env bash
#
# jira-rest-api.sh
#
# Core Jira REST API functions. Source-only library — not directly
# invokable. All CLI access goes through jira-api-wrapper.sh.
#
# Usage (from jira-api-wrapper.sh):
#   source "$SCRIPT_DIR/jira-rest-api.sh"
#   jira_get_issue "PROJ-123"
#
# Environment Variables (required):
#   JIRA_DOMAIN   - Your Jira domain (e.g., company.atlassian.net)
#   JIRA_API_KEY  - Your email:api_token (NOT base64 encoded)
#
# Session Caching:
#   Metadata (projects, issue types) is cached during script execution.
#   Cache is stored in /tmp/jira_cache_$$ and cleaned up on exit.
#

set -euo pipefail

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
_jira_log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
_jira_log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
_jira_log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Session cache directory
JIRA_CACHE_DIR="${JIRA_CACHE_DIR:-/tmp/jira_cache_$$}"

# Initialize cache directory
_jira_init_cache() {
    if [[ ! -d "$JIRA_CACHE_DIR" ]]; then
        mkdir -p "$JIRA_CACHE_DIR"
        # Register cleanup trap only once
        trap '_jira_cleanup_cache' EXIT
    fi
}

# Cleanup cache on exit
_jira_cleanup_cache() {
    if [[ -d "$JIRA_CACHE_DIR" ]]; then
        rm -rf "$JIRA_CACHE_DIR"
    fi
}

# Get cached value or return empty
_jira_cache_get() {
    local key="$1"
    local cache_file="$JIRA_CACHE_DIR/$key"
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return 0
    fi
    return 1
}

# Set cache value
_jira_cache_set() {
    local key="$1"
    local value="$2"
    _jira_init_cache
    echo "$value" > "$JIRA_CACHE_DIR/$key"
}

# --- Authentication ---

# Get base64 encoded auth header
_jira_get_auth_header() {
    if [[ -z "${JIRA_API_KEY:-}" ]]; then
        _jira_log_error "JIRA_API_KEY not set"
        return 1
    fi
    echo -n "$JIRA_API_KEY" | base64
}

# Check if credentials are configured
jira_check_credentials() {
    local missing=0

    if [[ -z "${JIRA_DOMAIN:-}" ]]; then
        _jira_log_error "JIRA_DOMAIN not set"
        missing=1
    fi

    if [[ -z "${JIRA_API_KEY:-}" ]]; then
        _jira_log_error "JIRA_API_KEY not set"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        return 1
    fi

    return 0
}

# --- Core HTTP Functions ---

# Make authenticated GET request
_jira_get() {
    local endpoint="$1"
    local auth_header
    auth_header=$(_jira_get_auth_header) || return 1

    curl -s -w "\n%{http_code}" \
        -H "Authorization: Basic $auth_header" \
        -H "Content-Type: application/json" \
        "https://$JIRA_DOMAIN$endpoint"
}

# Make authenticated POST request
_jira_post() {
    local endpoint="$1"
    local data="$2"
    local auth_header
    auth_header=$(_jira_get_auth_header) || return 1

    curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Basic $auth_header" \
        -H "Content-Type: application/json" \
        -d "$data" \
        "https://$JIRA_DOMAIN$endpoint"
}

# Make authenticated PUT request
_jira_put() {
    local endpoint="$1"
    local data="$2"
    local auth_header
    auth_header=$(_jira_get_auth_header) || return 1

    curl -s -w "\n%{http_code}" \
        -X PUT \
        -H "Authorization: Basic $auth_header" \
        -H "Content-Type: application/json" \
        -d "$data" \
        "https://$JIRA_DOMAIN$endpoint"
}

# Make authenticated DELETE request
_jira_delete() {
    local endpoint="$1"
    local auth_header
    auth_header=$(_jira_get_auth_header) || return 1

    curl -s -w "\n%{http_code}" \
        -X DELETE \
        -H "Authorization: Basic $auth_header" \
        "https://$JIRA_DOMAIN$endpoint"
}

# Parse response and check status code
_jira_parse_response() {
    local response="$1"
    local expected_codes="${2:-200}"

    local http_code
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')

    # Check if code is in expected list
    local valid=0
    for code in $expected_codes; do
        if [[ "$http_code" == "$code" ]]; then
            valid=1
            break
        fi
    done

    if [[ $valid -eq 0 ]]; then
        _jira_log_error "HTTP $http_code"
        if [[ -n "$body" ]]; then
            # Try to extract error message from JSON
            local error_msg
            error_msg=$(echo "$body" | jq -r '.errorMessages[0] // .message // empty' 2>/dev/null || echo "$body")
            if [[ -n "$error_msg" ]]; then
                _jira_log_error "$error_msg"
            fi
        fi
        echo "$body"
        return 1
    fi

    echo "$body"
    return 0
}

# --- Jira API Functions ---

# Get current user info (useful for testing auth)
jira_get_myself() {
    jira_check_credentials || return 1

    local response
    response=$(_jira_get "/rest/api/3/myself")
    _jira_parse_response "$response" "200"
}

# Get issue details
# Usage: jira_get_issue "PROJ-123" [fields]
jira_get_issue() {
    local issue_key="$1"
    local fields="${2:-}"

    jira_check_credentials || return 1

    local endpoint="/rest/api/3/issue/$issue_key"
    if [[ -n "$fields" ]]; then
        endpoint="$endpoint?fields=$fields"
    fi

    local response
    response=$(_jira_get "$endpoint")
    _jira_parse_response "$response" "200"
}

# Create a new issue
# Usage: jira_create_issue '{"fields": {...}}'
jira_create_issue() {
    local data="$1"

    jira_check_credentials || return 1

    local response
    response=$(_jira_post "/rest/api/3/issue" "$data")
    _jira_parse_response "$response" "201"
}

# Update an existing issue
# Usage: jira_update_issue "PROJ-123" '{"fields": {...}}'
jira_update_issue() {
    local issue_key="$1"
    local data="$2"

    jira_check_credentials || return 1

    local response
    response=$(_jira_put "/rest/api/3/issue/$issue_key" "$data")
    _jira_parse_response "$response" "204 200"
}

# Add comment to issue
# Usage: jira_add_comment "PROJ-123" '{"body": {...}}'
jira_add_comment() {
    local issue_key="$1"
    local data="$2"

    jira_check_credentials || return 1

    local response
    response=$(_jira_post "/rest/api/3/issue/$issue_key/comment" "$data")
    _jira_parse_response "$response" "201"
}

# Get available transitions for an issue
# Usage: jira_get_transitions "PROJ-123"
jira_get_transitions() {
    local issue_key="$1"

    jira_check_credentials || return 1

    local response
    response=$(_jira_get "/rest/api/3/issue/$issue_key/transitions")
    _jira_parse_response "$response" "200"
}

# Transition an issue to a new status
# Usage: jira_transition_issue "PROJ-123" '{"transition": {"id": "21"}}'
jira_transition_issue() {
    local issue_key="$1"
    local data="$2"

    jira_check_credentials || return 1

    local response
    response=$(_jira_post "/rest/api/3/issue/$issue_key/transitions" "$data")
    _jira_parse_response "$response" "204 200"
}

# Search issues with JQL
# Usage: jira_search_jql "project = PROJ" [max_results] [fields]
jira_search_jql() {
    local jql="$1"
    local max_results="${2:-50}"
    local fields="${3:-summary,status,issuetype,priority}"

    jira_check_credentials || return 1

    # URL encode the JQL
    local encoded_jql
    encoded_jql=$(echo -n "$jql" | jq -sRr @uri)

    local endpoint="/rest/api/3/search/jql?jql=$encoded_jql&maxResults=$max_results&fields=$fields"

    local response
    response=$(_jira_get "$endpoint")
    _jira_parse_response "$response" "200"
}

# Get all visible projects (with caching)
# Usage: jira_get_projects [max_results]
jira_get_projects() {
    local max_results="${1:-50}"

    jira_check_credentials || return 1

    # Check cache first
    local cache_key="projects_$max_results"
    local cached
    if cached=$(_jira_cache_get "$cache_key" 2>/dev/null); then
        echo "$cached"
        return 0
    fi

    local response
    response=$(_jira_get "/rest/api/3/project?maxResults=$max_results")
    local result
    result=$(_jira_parse_response "$response" "200") || return 1

    # Cache the result
    _jira_cache_set "$cache_key" "$result"
    echo "$result"
}

# Get issue types for a project (with caching)
# Usage: jira_get_issue_types "PROJ"
jira_get_issue_types() {
    local project_key="$1"

    jira_check_credentials || return 1

    # Check cache first
    local cache_key="issue_types_$project_key"
    local cached
    if cached=$(_jira_cache_get "$cache_key" 2>/dev/null); then
        echo "$cached"
        return 0
    fi

    local response
    response=$(_jira_get "/rest/api/3/project/$project_key")
    local result
    result=$(_jira_parse_response "$response" "200") || return 1

    # Extract issue types from project response
    local issue_types
    issue_types=$(echo "$result" | jq '.issueTypes')

    # Cache the result
    _jira_cache_set "$cache_key" "$issue_types"
    echo "$issue_types"
}

# Get field metadata for creating issues (with caching)
# Usage: jira_get_field_metadata "PROJ" "10001"
jira_get_field_metadata() {
    local project_key="$1"
    local issue_type_id="$2"

    jira_check_credentials || return 1

    # Check cache first
    local cache_key="field_meta_${project_key}_${issue_type_id}"
    local cached
    if cached=$(_jira_cache_get "$cache_key" 2>/dev/null); then
        echo "$cached"
        return 0
    fi

    local response
    response=$(_jira_get "/rest/api/3/issue/createmeta/$project_key/issuetypes/$issue_type_id")
    local result
    result=$(_jira_parse_response "$response" "200") || return 1

    # Cache the result
    _jira_cache_set "$cache_key" "$result"
    echo "$result"
}

# Search for users
# Usage: jira_lookup_user "john"
jira_lookup_user() {
    local query="$1"

    jira_check_credentials || return 1

    local encoded_query
    encoded_query=$(echo -n "$query" | jq -sRr @uri)

    local response
    response=$(_jira_get "/rest/api/3/user/search?query=$encoded_query")
    _jira_parse_response "$response" "200"
}

# Add worklog entry to issue
# Usage: jira_add_worklog "PROJ-123" '{"timeSpent": "2h", "comment": {...}}'
jira_add_worklog() {
    local issue_key="$1"
    local data="$2"

    jira_check_credentials || return 1

    local response
    response=$(_jira_post "/rest/api/3/issue/$issue_key/worklog" "$data")
    _jira_parse_response "$response" "201"
}

# Upload attachment to issue
# Usage: jira_upload_attachment "PROJ-123" "/path/to/file" [filename]
jira_upload_attachment() {
    local issue_key="$1"
    local file_path="$2"
    local filename="${3:-$(basename "$file_path")}"

    jira_check_credentials || return 1

    if [[ ! -f "$file_path" ]]; then
        _jira_log_error "File not found: $file_path"
        return 1
    fi

    local auth_header
    auth_header=$(_jira_get_auth_header) || return 1

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Basic $auth_header" \
        -H "X-Atlassian-Token: no-check" \
        -F "file=@$file_path;filename=$filename" \
        "https://$JIRA_DOMAIN/rest/api/3/issue/$issue_key/attachments")

    _jira_parse_response "$response" "200"
}

# Delete an attachment
# Usage: jira_delete_attachment "12345"
jira_delete_attachment() {
    local attachment_id="$1"

    jira_check_credentials || return 1

    local response
    response=$(_jira_delete "/rest/api/3/attachment/$attachment_id")
    _jira_parse_response "$response" "204"
}

# Get remote links for an issue
# Usage: jira_get_remote_links "PROJ-123"
jira_get_remote_links() {
    local issue_key="$1"

    jira_check_credentials || return 1

    local response
    response=$(_jira_get "/rest/api/3/issue/$issue_key/remotelink")
    _jira_parse_response "$response" "200"
}

# Test connection by getting current user
# Returns 0 if connection works, 1 otherwise
jira_test_connection() {
    local result
    if result=$(jira_get_myself 2>/dev/null); then
        local display_name
        display_name=$(echo "$result" | jq -r '.displayName // "Unknown"')
        local email
        email=$(echo "$result" | jq -r '.emailAddress // "Unknown"')

        jq -n \
            --arg connected "true" \
            --arg display_name "$display_name" \
            --arg email "$email" \
            '{connected: ($connected == "true"), user: {displayName: $display_name, email: $email}}'
        return 0
    else
        jq -n \
            --arg connected "false" \
            --arg error "Authentication failed or connection error" \
            '{connected: ($connected == "true"), error: $error}'
        return 1
    fi
}
