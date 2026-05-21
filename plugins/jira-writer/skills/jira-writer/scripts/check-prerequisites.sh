#!/usr/bin/env bash
#
# check-prerequisites.sh
#
# Checks all prerequisites for the jira-writer skill.
# Returns JSON with status of each dependency.
#
# The plugin uses REST API as the primary (and only verified) method.
# MCP is a passive fallback handled by Claude Code's tool runtime at
# call time — this script cannot detect MCP availability and will NOT
# claim readiness on MCP's behalf.
#
# Usage:
#   ./check-prerequisites.sh
#
# Output (JSON):
#   {
#     "rest_api": {
#       "available": true,
#       "authenticated": true,
#       "user": { "displayName": "...", "email": "..." }
#     },
#     "mmdc": { "available": true, "path": "/path/to/mmdc" },
#     "jira_domain": { "available": true, "value": "company.atlassian.net" },
#     "jira_api_key": { "available": true, "length": 123 },
#     "all_ready": true,
#     "diagram_ready": true,
#     "api_method": "rest"
#   }
#
# Possible api_method values:
#   "rest"               - REST credentials present and authentication verified
#   "rest_auth_failed"   - REST credentials present but authentication failed
#   "rest_not_configured"- No REST credentials; MCP NOT reported as available
#                          (only Claude Code's tool runtime can detect MCP)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check mmdc
mmdc_available=false
mmdc_path=""
if command -v mmdc &> /dev/null; then
    mmdc_available=true
    mmdc_path=$(which mmdc)
fi

# Check curl
curl_available=false
if command -v curl &> /dev/null; then
    curl_available=true
fi

# Check jq
jq_available=false
if command -v jq &> /dev/null; then
    jq_available=true
fi

# Check JIRA_DOMAIN
jira_domain_available=false
jira_domain_value=""
if [[ -n "${JIRA_DOMAIN:-}" ]]; then
    jira_domain_available=true
    jira_domain_value="$JIRA_DOMAIN"
fi

# Check JIRA_API_KEY
jira_api_key_available=false
jira_api_key_length=0
if [[ -n "${JIRA_API_KEY:-}" ]]; then
    jira_api_key_available=true
    jira_api_key_length=${#JIRA_API_KEY}
fi

# Test REST API authentication if credentials are available
rest_authenticated=false
rest_user_name=""
rest_user_email=""
rest_error=""

if [[ "$jira_domain_available" == "true" ]] && [[ "$jira_api_key_available" == "true" ]] && [[ "$curl_available" == "true" ]] && [[ "$jq_available" == "true" ]]; then
    # Test authentication
    auth_header=$(echo -n "$JIRA_API_KEY" | base64)
    response=$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Basic $auth_header" \
        -H "Content-Type: application/json" \
        "https://$JIRA_DOMAIN/rest/api/3/myself" 2>&1) || true

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        rest_authenticated=true
        rest_user_name=$(echo "$body" | jq -r '.displayName // "Unknown"')
        rest_user_email=$(echo "$body" | jq -r '.emailAddress // "Unknown"')
    else
        case "$http_code" in
            401) rest_error="Invalid credentials" ;;
            403) rest_error="Access forbidden" ;;
            404) rest_error="Invalid domain or endpoint" ;;
            000) rest_error="Connection failed" ;;
            *) rest_error="HTTP $http_code error" ;;
        esac
    fi
fi

# Determine REST API availability
rest_api_available=false
if [[ "$jira_domain_available" == "true" ]] && [[ "$jira_api_key_available" == "true" ]]; then
    rest_api_available=true
fi

# Determine overall readiness
# all_ready = REST API credentials present and authentication verified
# diagram_ready = can upload and embed diagrams (requires REST API)
all_ready=false
diagram_ready=false
api_method="none"

if [[ "$rest_authenticated" == "true" ]]; then
    all_ready=true
    api_method="rest"

    # Diagram support requires mmdc
    if [[ "$mmdc_available" == "true" ]]; then
        diagram_ready=true
    fi
elif [[ "$rest_api_available" == "true" ]]; then
    # REST credentials configured but auth failed - user needs to fix
    all_ready=false
    api_method="rest_auth_failed"
else
    # No REST credentials configured. We cannot detect MCP availability from
    # this script (only Claude Code's tool runtime knows), so the script
    # cannot vouch for readiness. Report this honestly.
    all_ready=false
    api_method="rest_not_configured"
fi

# Build REST API user JSON
rest_user_json="null"
if [[ "$rest_authenticated" == "true" ]]; then
    rest_user_json=$(jq -n \
        --arg name "$rest_user_name" \
        --arg email "$rest_user_email" \
        '{displayName: $name, email: $email}')
fi

# Output JSON — use jq -n with --arg/--argjson so that any special
# characters in paths, domains, or error messages cannot break the JSON.
jq -n \
    --argjson rest_api_available   "$rest_api_available" \
    --argjson rest_authenticated   "$rest_authenticated" \
    --argjson rest_user            "$rest_user_json" \
    --arg     rest_error           "$rest_error" \
    --argjson mmdc_available       "$mmdc_available" \
    --arg     mmdc_path            "$mmdc_path" \
    --argjson curl_available       "$curl_available" \
    --argjson jq_available         "$jq_available" \
    --argjson jira_domain_available "$jira_domain_available" \
    --arg     jira_domain_value    "$jira_domain_value" \
    --argjson jira_api_key_available "$jira_api_key_available" \
    --argjson jira_api_key_length  "$jira_api_key_length" \
    --argjson all_ready            "$all_ready" \
    --argjson diagram_ready        "$diagram_ready" \
    --arg     api_method           "$api_method" \
    '{
        "rest_api": {
            "available": $rest_api_available,
            "authenticated": $rest_authenticated,
            "user": $rest_user,
            "error": (if $rest_error == "" then null else $rest_error end)
        },
        "mcp": {
            "note": "MCP availability is determined by Claude Code'\''s tool runtime at call time — not detectable from this script"
        },
        "mmdc": {
            "available": $mmdc_available,
            "path": (if $mmdc_path == "" then null else $mmdc_path end),
            "install_cmd": "npm install -g @mermaid-js/mermaid-cli"
        },
        "curl": {
            "available": $curl_available
        },
        "jq": {
            "available": $jq_available,
            "install_cmd": "brew install jq"
        },
        "jira_domain": {
            "available": $jira_domain_available,
            "value": (if $jira_domain_value == "" then null else $jira_domain_value end),
            "env_var": "JIRA_DOMAIN"
        },
        "jira_api_key": {
            "available": $jira_api_key_available,
            "length": $jira_api_key_length,
            "env_var": "JIRA_API_KEY",
            "format": "email@domain.com:api_token (NOT base64 encoded)"
        },
        "all_ready": $all_ready,
        "diagram_ready": $diagram_ready,
        "api_method": $api_method,
        "setup_instructions": {
            "rest_api": {
                "step1": "Get API token from: https://id.atlassian.com/manage-profile/security/api-tokens",
                "step2": "export JIRA_DOMAIN=\"company.atlassian.net\"",
                "step3": "export JIRA_API_KEY=\"your-email@company.com:your-api-token\""
            },
            "diagrams": {
                "step1": "npm install -g @mermaid-js/mermaid-cli"
            }
        }
    }'
