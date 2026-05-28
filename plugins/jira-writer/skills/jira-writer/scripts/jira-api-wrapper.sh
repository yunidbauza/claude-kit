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
#   On success:
#     { "api": "rest", "data": {...} }
#   On REST failure with MCP fallback available:
#     { "api": "mcp_fallback", "operation": "...", "params": {...},
#       "rest_error": "...", "note": "..." (optional) }
#   The "note" field is present when the original user input was a pre-built
#   ADF document — it warns the agent that the MCP fallback path will render
#   the content as text, not rich ADF.
#   On non-recoverable error (no MCP retry path, e.g. attachment upload):
#     { "api": "error", "operation": "...", "params": {...},
#       "rest_error": "...", "note": "..." (optional) }
#   The "error" envelope shares the same fields as "mcp_fallback" but has
#   api:"error" and signals that no MCP retry is possible.
#
# Environment Variables:
#   JIRA_DOMAIN   - Your Jira domain (e.g., company.atlassian.net)
#   JIRA_API_KEY  - Your email:api_token (NOT base64 encoded)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the REST API functions. If the sibling file is missing, the plugin
# likely updated mid-session and $CLAUDE_PLUGIN_ROOT points at a removed cache
# directory — fail loudly with guidance instead of a raw bash error.
if [[ ! -f "$SCRIPT_DIR/jira-rest-api.sh" ]]; then
    echo "[ERROR] jira-writer scripts missing at: $SCRIPT_DIR" >&2
    echo "[ERROR] The plugin likely updated mid-session — restart Claude Code to refresh CLAUDE_PLUGIN_ROOT." >&2
    exit 127
fi
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

# Check if REST API is available
check_rest_available() {
    if [[ -z "${JIRA_DOMAIN:-}" ]] || [[ -z "${JIRA_API_KEY:-}" ]]; then
        return 1
    fi
    return 0
}

# Shared jq filter for ADF document detection. Used by _to_adf_body and
# _input_was_adf to keep their definitions of "is this ADF?" in lockstep.
_ADF_DOC_JQ_FILTER='
    type == "object"
    and .type == "doc"
    and (.version | type) == "number"
    and (.content | type) == "array"
'

# _to_adf_body INPUT
# Echoes a valid ADF document JSON to stdout.
# - If INPUT parses as a JSON object with .type == "doc", numeric .version,
#   and array .content, echo it unchanged (pass-through).
# - Otherwise wrap INPUT as a single plain-text paragraph (legacy behavior).
_to_adf_body() {
    local input="${1:-}"
    # Cheap pre-filter: must start with '{' (allow leading whitespace) to
    # even consider as JSON. Anything else is plain text.
    if [[ "$input" =~ ^[[:space:]]*\{ ]]; then
        if printf '%s' "$input" | jq -e "$_ADF_DOC_JQ_FILTER" >/dev/null 2>&1; then
            printf '%s\n' "$input"
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

# _input_was_adf INPUT
# Returns 0 (success) if INPUT is a valid ADF doc as recognized by _to_adf_body.
# Used by ops to decide whether to attach an explanatory note when falling
# back to MCP (which renders raw strings as markdown/text, not ADF).
_input_was_adf() {
    local input="${1:-}"
    [[ "$input" =~ ^[[:space:]]*\{ ]] || return 1
    printf '%s' "$input" | jq -e "$_ADF_DOC_JQ_FILTER" >/dev/null 2>&1
}

# _parse_flags KNOWN_CSV -- "$@"
# Splits "$@" into:
#   _POSITIONAL=(...)   positional args
#   _FLAGS=(name=val ...) single-value flags
#   _BOOLS=(name ...)     boolean (value-less) flags
# KNOWN_CSV is a comma-separated list of long flag names. Single-value vs
# boolean is determined by lookahead: if the next token starts with -- or is
# absent, treat as boolean. Unknown flags pass through as positional args.
_parse_flags() {
    local known_csv="$1"; shift
    [[ "${1:-}" == "--" ]] && shift
    _POSITIONAL=()
    _FLAGS=()
    _BOOLS=()
    local known=",$known_csv,"
    while [[ $# -gt 0 ]]; do
        local arg="$1"
        if [[ "$arg" == --* ]]; then
            local name="${arg#--}"
            if [[ "$known" == *",$name,"* ]]; then
                # Bool flags: markdown, bisect, summary-only
                if [[ "$name" == "markdown" || "$name" == "bisect" || "$name" == "summary-only" ]]; then
                    _BOOLS+=("$name")
                    shift
                else
                    if [[ $# -lt 2 ]]; then
                        echo "Error: flag --$name requires a value" >&2
                        return 2
                    fi
                    _FLAGS+=("$name=$2")
                    shift 2
                fi
            else
                _POSITIONAL+=("$arg")
                shift
            fi
        else
            _POSITIONAL+=("$arg")
            shift
        fi
    done
}

# _flag_value NAME — echoes the value of the named single-value flag, or "" if absent.
_flag_value() {
    local name="$1" entry
    for entry in "${_FLAGS[@]:-}"; do
        [[ "$entry" == "$name="* ]] && { echo "${entry#*=}"; return 0; }
    done
    return 0
}

# _has_bool NAME — returns 0 if the named bool flag is present.
_has_bool() {
    local name="$1" entry
    for entry in "${_BOOLS[@]:-}"; do
        [[ "$entry" == "$name" ]] && return 0
    done
    return 1
}

# _resolve_content_input POSITIONAL_DESC DESC_FILE MARKDOWN_BOOL
# Echoes ADF JSON on stdout. Echoes informational messages to stderr.
# Priority (first match wins):
#   1. DESC_FILE non-empty       → read file, MD → ADF
#   2. MARKDOWN_BOOL == "1"      → POSITIONAL_DESC treated as MD, MD → ADF
#   3. POSITIONAL_DESC is ADF doc → passthrough
#   4. POSITIONAL_DESC otherwise → plain text paragraph wrap
# Empty POSITIONAL_DESC + no DESC_FILE + no MARKDOWN returns empty (caller decides).
_resolve_content_input() {
    local desc="${1:-}"
    local desc_file="${2:-}"
    local md_flag="${3:-}"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -n "$desc_file" && -n "$desc" ]]; then
        log_warn "--desc-file supplied; positional description ignored"
    fi

    if [[ -n "$desc_file" ]]; then
        if [[ ! -r "$desc_file" ]]; then
            log_error "--desc-file path not readable: $desc_file"
            return 1
        fi
        if ! command -v node >/dev/null 2>&1; then
            log_error "Node 18+ required for --desc-file but 'node' not found in PATH"
            return 1
        fi
        node "$script_dir/markdown-to-adf.mjs" "$desc_file" || return 1
        return 0
    fi

    if [[ "$md_flag" == "1" ]]; then
        if [[ -z "$desc" ]]; then
            log_error "--markdown supplied without a description argument"
            return 1
        fi
        if ! command -v node >/dev/null 2>&1; then
            log_error "Node 18+ required for --markdown but 'node' not found in PATH"
            return 1
        fi
        local tmp
        tmp="$(mktemp)" || return 1
        printf '%s' "$desc" > "$tmp"
        node "$script_dir/markdown-to-adf.mjs" "$tmp"
        local rc=$?
        rm -f "$tmp"
        return $rc
    fi

    # Pass-through for ADF; wrap as paragraph otherwise (existing behavior).
    _to_adf_body "$desc"
}

# _usage_for_op OP — returns one-line usage signature for the given op.
_usage_for_op() {
    case "$1" in
      create_issue) echo "create_issue PROJECT TYPE SUMMARY [DESC] [--desc-file PATH] [--markdown] [--parent KEY]" ;;
      update_issue) echo "update_issue KEY FIELDS_JSON [--desc-file PATH] [--markdown]" ;;
      add_comment) echo "add_comment KEY BODY [--desc-file PATH] [--markdown]" ;;
      get_issue) echo "get_issue KEY [FIELDS] [--summary-only]" ;;
      validate_adf) echo "validate_adf PATH_TO_ADF_JSON [--bisect]" ;;
      get_transitions) echo "get_transitions KEY" ;;
      transition_issue) echo "transition_issue KEY TRANSITION_ID" ;;
      search_jql) echo "search_jql JQL [max_results]" ;;
      get_projects) echo "get_projects [max_results]" ;;
      get_issue_types) echo "get_issue_types PROJECT" ;;
      lookup_user) echo "lookup_user QUERY" ;;
      add_worklog) echo "add_worklog KEY TIME_SPENT" ;;
      upload_attachment) echo "upload_attachment KEY FILE [name]" ;;
      get_remote_links) echo "get_remote_links KEY" ;;
      test_connection) echo "test_connection" ;;
      *) echo "$1 [args...]" ;;
    esac
}

# _validate_adf_or_error ADF_JSON OP_NAME
# Runs adf-validate.mjs on the input. On failure, emits api:"error" envelope
# to stdout (and returns 1) so callers can short-circuit before HTTP.
# Silently no-ops if Node is unavailable (the REST call will catch errors).
_validate_adf_or_error() {
    local adf="$1" op="$2"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if ! command -v node >/dev/null 2>&1; then
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    printf '%s' "$adf" > "$tmp"
    local result rc
    result=$(node "$script_dir/adf-validate.mjs" "$tmp" 2>&1) && rc=0 || rc=$?
    rm -f "$tmp"
    if [[ $rc -ne 0 ]]; then
        local rule path msg
        rule=$(echo "$result" | jq -r '.rule // "validation_failed"')
        path=$(echo "$result" | jq -r '.path // ""')
        msg=$(echo "$result"  | jq -r '.message // "ADF validation failed"')
        jq -n --arg op "$op" --arg rule "$rule" --arg path "$path" --arg msg "$msg" \
            '{api:"error", operation:$op, rule:$rule, path:$path, error:$msg}'
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

    local desc_file="$(_flag_value desc-file)"
    local markdown_bool="0"; _has_bool markdown && markdown_bool="1"

    local desc_adf=""
    if [[ -n "$description" || -n "$desc_file" || "$markdown_bool" == "1" ]]; then
        desc_adf=$(_resolve_content_input "$description" "$desc_file" "$markdown_bool") || {
            jq -n --arg op "create_issue" '{api:"error", operation:$op, error:"failed to resolve description input"}'
            return 1
        }
    fi

    local _is_adf="0"
    if [[ -n "$desc_file" || "$markdown_bool" == "1" ]]; then
        _is_adf="1"
    elif [[ -n "$description" ]] && _input_was_adf "$description"; then
        _is_adf="1"
    fi
    if [[ "$_is_adf" == "1" && -n "$desc_adf" ]]; then
        _validate_adf_or_error "$desc_adf" "create_issue" || return 1
    fi

    local parent_key="$(_flag_value parent)"
    if [[ -n "$parent_key" ]]; then
        if ! [[ "$parent_key" =~ ^[A-Z][A-Z0-9_]+-[0-9]+$ ]]; then
            jq -n --arg op "create_issue" --arg p "$parent_key" \
              '{api:"error", operation:$op, error:("--parent must match ^[A-Z][A-Z0-9_]+-[0-9]+$ — got: " + $p)}'
            return 1
        fi
    fi

    local issue_data
    if [[ -n "$desc_adf" && -n "$parent_key" ]]; then
        issue_data=$(jq -n \
            --arg project "$project_key" --arg type "$issue_type" --arg summary "$summary" \
            --argjson desc "$desc_adf" --arg parent "$parent_key" \
            '{fields:{project:{key:$project}, issuetype:{name:$type}, summary:$summary, description:$desc, parent:{key:$parent}}}')
    elif [[ -n "$desc_adf" ]]; then
        issue_data=$(jq -n \
            --arg project "$project_key" --arg type "$issue_type" \
            --arg summary "$summary" --argjson desc "$desc_adf" \
            '{fields:{project:{key:$project}, issuetype:{name:$type}, summary:$summary, description:$desc}}')
    elif [[ -n "$parent_key" ]]; then
        issue_data=$(jq -n \
            --arg project "$project_key" --arg type "$issue_type" \
            --arg summary "$summary" --arg parent "$parent_key" \
            '{fields:{project:{key:$project}, issuetype:{name:$type}, summary:$summary, parent:{key:$parent}}}')
    else
        issue_data=$(jq -n \
            --arg project "$project_key" --arg type "$issue_type" --arg summary "$summary" \
            '{fields:{project:{key:$project}, issuetype:{name:$type}, summary:$summary}}')
    fi

    if [[ "${JIRA_WRITER_DRY_RUN:-}" == "1" ]]; then
        echo "$issue_data"
        return 0
    fi

    # Check REST availability
    if ! check_rest_available; then
        local _note=""
        [[ -n "$description" ]] && _input_was_adf "$description" \
            && _note="Original description was ADF; MCP fallback will render as text."
        output_mcp_fallback "createJiraIssue" "$issue_data" "REST credentials not configured" "$_note"
        return 1
    fi

    # Try REST API
    local result
    if result=$(jira_create_issue "$issue_data" 2>&1); then
        output_rest_success "$result"
        return 0
    else
        if [[ "$_is_adf" == "1" ]]; then
            log_error "REST create failed: $result"
            jq -n --arg op "create_issue" --arg project "$project_key" --arg type "$issue_type" --arg summary "$summary" --arg err "$result" \
                '{api:"error", operation:$op, params:{projectKey:$project, issueTypeName:$type, summary:$summary}, rest_error:$err,
                  note:"REST failed for ADF input — MCP fallback not viable."}'
            return 1
        fi
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
        local _note=""
        [[ -n "$description" ]] && _input_was_adf "$description" \
            && _note="Original description was ADF; MCP fallback will render as text."
        output_mcp_fallback "createJiraIssue" "$mcp_params" "$result" "$_note"
        return 1
    fi
}

# Update issue operation
op_update_issue() {
    local issue_key="$1"
    local fields_json="$2"
    local is_adf_input="${3:-0}"

    # Validate JSON input before anything else so the error returns regardless
    # of credential state.
    if ! printf '%s' "$fields_json" | jq -e . >/dev/null 2>&1; then
        jq -n --arg key "$issue_key" --arg input "$fields_json" '{
            "api": "error",
            "error": "Invalid JSON in fields argument",
            "operation": "update_issue",
            "issue_key": $key,
            "input": $input
        }'
        return 1
    fi

    # Pre-flight ADF validation when input was constructed as ADF
    if [[ "$is_adf_input" == "1" ]]; then
        local desc
        desc=$(echo "$fields_json" | jq -c '.description // empty')
        if [[ -n "$desc" && "$desc" != "null" ]]; then
            _validate_adf_or_error "$desc" "update_issue" || return 1
        fi
    fi

    # Build MCP params once, reused at both fallback sites.
    local mcp_params
    mcp_params=$(jq -n --arg key "$issue_key" --argjson fields "$fields_json" \
        '{issueIdOrKey: $key, fields: $fields}')

    # Check REST availability
    if ! check_rest_available; then
        output_mcp_fallback "editJiraIssue" "$mcp_params" "REST credentials not configured"
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
        if [[ "$is_adf_input" == "1" ]]; then
            log_error "REST update failed: $result"
            jq -n --arg op "update_issue" --arg key "$issue_key" --arg err "$result" \
                '{api:"error", operation:$op, params:{issueIdOrKey:$key}, rest_error:$err,
                  note:"REST failed for ADF input — MCP fallback not viable."}'
            return 1
        fi
        output_mcp_fallback "editJiraIssue" "$mcp_params" "$result"
        return 1
    fi
}

# Add comment operation
op_add_comment() {
    local issue_key="$1"
    local comment_body="$2"
    local is_adf_input="${3:-0}"

    # Check REST availability
    if ! check_rest_available; then
        local _note=""
        _input_was_adf "$comment_body" && _note="Original body was ADF; MCP fallback will render as text."
        output_mcp_fallback "addCommentToJiraIssue" \
            "$(jq -n --arg key "$issue_key" --arg body "$comment_body" '{issueIdOrKey: $key, commentBody: $body}')" \
            "REST credentials not configured" \
            "$_note"
        return 1
    fi

    # Build comment data (ADF format). _to_adf_body passes through pre-built
    # ADF docs unchanged, or wraps plain text as a single paragraph.
    local body_adf
    body_adf=$(_to_adf_body "$comment_body")
    local comment_data
    comment_data=$(jq -n --argjson body "$body_adf" '{body: $body}')

    # Pre-flight ADF validation when input was constructed as ADF
    if [[ "$is_adf_input" == "1" ]]; then
        _validate_adf_or_error "$body_adf" "add_comment" || return 1
    fi

    # Try REST API
    local result
    if result=$(jira_add_comment "$issue_key" "$comment_data" 2>&1); then
        output_rest_success "$result"
        return 0
    else
        if [[ "$is_adf_input" == "1" ]]; then
            log_error "REST add_comment failed: $result"
            jq -n --arg op "add_comment" --arg key "$issue_key" --arg err "$result" \
                '{api:"error", operation:$op, params:{issueIdOrKey:$key}, rest_error:$err,
                  note:"REST failed for ADF input — MCP fallback not viable."}'
            return 1
        fi
        local _note=""
        _input_was_adf "$comment_body" && _note="Original body was ADF; MCP fallback will render as text."
        output_mcp_fallback "addCommentToJiraIssue" \
            "$(jq -n --arg key "$issue_key" --arg body "$comment_body" '{issueIdOrKey: $key, commentBody: $body}')" \
            "$result" \
            "$_note"
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
    [[ "$max_results" =~ ^[0-9]+$ ]] || max_results=50

    # Sanity-check jq availability early. Without jq the URL-encoding step in
    # jira-rest-api.sh would silently pass raw unencoded JQL to the API.
    # Using echo (not jq) here because jq itself would be unavailable.
    if ! command -v jq >/dev/null 2>&1; then
        echo '{"api":"error","error":"jq is required but not installed","operation":"searchJiraIssuesUsingJql"}'
        return 1
    fi

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
    [[ "$max_results" =~ ^[0-9]+$ ]] || max_results=50

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

    # Note: MCP cannot upload attachments, so no fallback available.
    # Both error branches emit the same envelope shape (api:"error") with
    # standard operation/params fields so agents can parse them uniformly.
    # Unlike mcp_fallback, api:"error" is non-recoverable — there is no MCP
    # retry path for attachment uploads.
    if ! check_rest_available; then
        jq -n --arg key "$issue_key" --arg file "$file_path" --arg name "$filename" '{
            "api": "error",
            "operation": "uploadJiraAttachment",
            "params": {issueIdOrKey: $key, file_path: $file, filename: $name},
            "rest_error": "REST credentials not configured",
            "note": "Attachment upload requires REST credentials; no MCP fallback available."
        }'
        return 1
    fi

    # Try REST API.
    # NOTE: the && / || pattern is treated as a conditional under `set -e`,
    # so a failing upload doesn't exit the script before we capture rc.
    local result rc
    if [[ -n "$filename" ]]; then
        result=$(jira_upload_attachment "$issue_key" "$file_path" "$filename" 2>&1) && rc=0 || rc=$?
    else
        result=$(jira_upload_attachment "$issue_key" "$file_path" 2>&1) && rc=0 || rc=$?
    fi

    if [[ $rc -eq 0 ]]; then
        output_rest_success "$result"
        return 0
    else
        jq -n --arg key "$issue_key" --arg file "$file_path" --arg name "$filename" --arg error "$result" '{
            "api": "error",
            "operation": "uploadJiraAttachment",
            "params": {issueIdOrKey: $key, file_path: $file, filename: $name},
            "rest_error": $error,
            "note": "Attachment upload is REST-only; no MCP fallback available."
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
# Recommended values match test-jira-connection.sh:
#   "rest_api"       - REST authenticated successfully
#   "rest_fix_auth"  - REST creds present but auth failed
#   "rest_configure" - REST creds missing
op_test_connection() {
    # Check REST availability first
    if ! check_rest_available; then
        jq -n '{
            "rest_api": {
                "available": false,
                "reason": "Credentials not configured (JIRA_DOMAIN and/or JIRA_API_KEY missing)"
            },
            "recommended": "rest_configure"
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
            "recommended": "rest_api"
        }'
        return 0
    else
        jq -n --arg error "$result" '{
            "rest_api": {
                "available": true,
                "authenticated": false,
                "error": $error
            },
            "recommended": "rest_fix_auth"
        }'
        return 1
    fi
}

# Validate ADF operation
op_validate_adf() {
    local input_path="$1"
    local bisect_flag=""
    if [[ "${2:-}" == "--bisect" ]]; then bisect_flag="--bisect"; fi
    if [[ -z "$input_path" || ! -r "$input_path" ]]; then
        jq -n '{api:"error", operation:"validate_adf", error:"path required and must be readable"}'
        return 1
    fi
    if ! command -v node >/dev/null 2>&1; then
        jq -n '{api:"error", operation:"validate_adf", error:"Node 18+ required for validate_adf"}'
        return 1
    fi
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local result rc
    result=$(node "$script_dir/adf-validate.mjs" "$input_path" $bisect_flag 2>&1) && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
        jq -n --argjson data "$result" '{api:"rest", data:$data}'
        return 0
    else
        jq -n --argjson data "$result" '{api:"error", operation:"validate_adf",
                                          error:($data.message // "validation failed"),
                                          rule:($data.rule // null),
                                          path:($data.path // null)}'
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
    echo "  validate_adf PATH_TO_ADF_JSON [--bisect] - Validate ADF locally (no Jira call)" >&2
    echo "  test_connection                  - Test API connection" >&2
    echo "" >&2
    echo "Output:" >&2
    echo "  Success:       {\"api\": \"rest\", \"data\": {...}}" >&2
    echo "  MCP fallback:  {\"api\": \"mcp_fallback\", \"operation\": \"...\", \"params\": {...}, \"rest_error\": \"...\", \"note\": \"...\" (optional)}" >&2
    echo "  Non-recoverable error (no MCP retry path, e.g. attachment upload):" >&2
    echo "                 {\"api\": \"error\", \"operation\": \"...\", \"params\": {...}, \"rest_error\": \"...\"}" >&2
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
    validate_adf
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
# Prints the 2 canonical ops most similar to INPUT, comma-separated.
# Ranking: shared prefix length DESC, then substring containment, then
#          common character count, then length closeness (penalty for
#          length difference so shorter/exact-length ops win ties).
suggest_op() {
    local input="$1"
    local op prefix_len
    local len_input=${#input}

    # Build "score op" lines, sort, take top 2.
    local scored=""
    for op in "${KNOWN_OPS[@]}"; do
        # Shared prefix length (weight: *100 to dominate).
        prefix_len=0
        local i max=${#input}
        [[ ${#op} -lt $max ]] && max=${#op}
        for ((i = 0; i < max; i++)); do
            [[ "${input:$i:1}" == "${op:$i:1}" ]] || break
            prefix_len=$((prefix_len + 1))
        done

        # Substring bonus (weight: *50).
        local substring_bonus=0
        if [[ "$op" == *"$input"* ]] || [[ -n "$input" && "$input" == *"$op"* ]]; then
            substring_bonus=50
        fi

        # Common character count — count chars in input present in op (weight: *1).
        local char_score=0
        local remaining="$op"
        for ((i = 0; i < ${#input}; i++)); do
            local ch="${input:$i:1}"
            if [[ "$remaining" == *"$ch"* ]]; then
                char_score=$((char_score + 1))
                # Remove first occurrence so each char counts once.
                remaining="${remaining/$ch/}"
            fi
        done

        # Length-delta penalty: subtract abs(len(op) - len(input)) to break
        # ties in favour of ops closest in length to the input.
        local len_op=${#op}
        local len_delta=$((len_input - len_op))
        [[ $len_delta -lt 0 ]] && len_delta=$((-len_delta))

        local score=$((prefix_len * 100 + substring_bonus + char_score - len_delta))
        scored+=$(printf '%d %s\n' "$score" "$op")$'\n'
    done

    # Sort numerically in reverse, take top 2 op names.
    printf '%s' "$scored" | sort -k1,1nr | head -n 2 | awk '{print $2}' | paste -sd, -
}

# Only run dispatch when invoked directly (not sourced for testing).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ -z "${JIRA_WRAPPER_TEST_MODE:-}" ]]; then
    # Plugin-runtime sanity warning.
    # When invoked from a plugin skill, $CLAUDE_PLUGIN_ROOT should be set
    # and the script's path should contain /plugins/cache/. If neither is
    # true, warn (but do not fail) — direct invocations remain valid.
    if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]] && [[ "${BASH_SOURCE[0]}" != *"/plugins/cache/"* ]]; then
        echo "[WARN] CLAUDE_PLUGIN_ROOT is unset and script is not under /plugins/cache/." >&2
        echo "[WARN] If you invoked this from a Claude Code skill, the plugin runtime may have changed." >&2
    fi

    # Source-only mode: when called with `--source-only`, expose functions but skip dispatch.
    if [[ "${1:-}" == "--source-only" ]]; then
        return 0 2>/dev/null || exit 0
    fi

    if [[ $# -lt 1 ]]; then
        print_usage
        exit 1
    fi

    operation="$1"
    shift
    operation="$(normalize_op "$operation")"

    case "$operation" in
        get_issue)
            _parse_flags "summary-only" -- "$@"
            if [[ ${#_POSITIONAL[@]} -gt 0 ]]; then set -- "${_POSITIONAL[@]}"; else set --; fi
            if [[ $# -lt 1 ]]; then
                echo "Error: missing required arguments for get_issue" >&2
                echo "Usage: $(_usage_for_op get_issue)" >&2
                exit 1
            fi
            if _has_bool summary-only; then
                op_get_issue "$1" "summary,issuetype,parent,status,assignee"
            else
                op_get_issue "$@"
            fi
            ;;
        create_issue)
            _parse_flags "desc-file,markdown,parent" -- "$@"
            if [[ ${#_POSITIONAL[@]} -gt 0 ]]; then set -- "${_POSITIONAL[@]}"; else set --; fi
            if [[ $# -lt 3 ]]; then
                echo "Error: missing required arguments for create_issue" >&2
                echo "Usage: $(_usage_for_op create_issue)" >&2
                exit 1
            fi
            op_create_issue "$@"
            ;;
        update_issue)
            _parse_flags "desc-file,markdown" -- "$@"
            if [[ ${#_POSITIONAL[@]} -gt 0 ]]; then set -- "${_POSITIONAL[@]}"; else set --; fi
            _df="$(_flag_value desc-file)"; _md="0"
            _has_bool markdown && _md="1"
            if [[ -n "$_df" || "$_md" == "1" ]]; then
                if [[ $# -lt 1 ]]; then
                    echo "Error: missing required arguments for update_issue" >&2
                    echo "Usage: $(_usage_for_op update_issue)" >&2
                    exit 1
                fi
                _key="$1"
                _adf=$(_resolve_content_input "${2:-}" "$_df" "$_md") || {
                    jq -n --arg op "update_issue" '{api:"error", operation:$op, error:"failed to resolve description input"}'
                    exit 1
                }
                _fields=$(jq -n --argjson desc "$_adf" '{description: $desc}')
                op_update_issue "$_key" "$_fields" "1"
            else
                if [[ $# -lt 2 ]]; then
                    echo "Error: missing required arguments for update_issue" >&2
                    echo "Usage: $(_usage_for_op update_issue)" >&2
                    exit 1
                fi
                _is_adf="0"
                # If the fields_json contains an ADF doc as .description, treat as ADF input
                # Mirrors _ADF_DOC_JQ_FILTER but inspects .description inside a fields_json
                # wrapper instead of the top-level input. Keep in sync if _ADF_DOC_JQ_FILTER
                # changes.
                if [[ -n "${2:-}" ]] && echo "$2" | jq -e '.description | (type == "object" and .type == "doc" and (.version | type) == "number" and (.content | type) == "array")' >/dev/null 2>&1; then
                    _is_adf="1"
                fi
                op_update_issue "$1" "$2" "$_is_adf"
            fi
            ;;
        add_comment)
            _parse_flags "desc-file,markdown" -- "$@"
            if [[ ${#_POSITIONAL[@]} -gt 0 ]]; then set -- "${_POSITIONAL[@]}"; else set --; fi
            _df="$(_flag_value desc-file)"; _md="0"
            _has_bool markdown && _md="1"
            if [[ -n "$_df" || "$_md" == "1" ]]; then
                if [[ $# -lt 1 ]]; then
                    echo "Error: missing required arguments for add_comment" >&2
                    echo "Usage: $(_usage_for_op add_comment)" >&2
                    exit 1
                fi
                _key="$1"
                _adf=$(_resolve_content_input "${2:-}" "$_df" "$_md") || {
                    jq -n --arg op "add_comment" '{api:"error", operation:$op, error:"failed to resolve comment body"}'
                    exit 1
                }
                op_add_comment "$_key" "$_adf" "1"
            else
                if [[ $# -lt 2 ]]; then
                    echo "Error: missing required arguments for add_comment" >&2
                    echo "Usage: $(_usage_for_op add_comment)" >&2
                    exit 1
                fi
                _is_adf_comment="0"
                _input_was_adf "${2:-}" && _is_adf_comment="1"
                op_add_comment "$1" "$2" "$_is_adf_comment"
            fi
            ;;
        get_transitions)
            [[ $# -lt 1 ]] && { echo "Error: missing required arguments for get_transitions" >&2; echo "Usage: $(_usage_for_op get_transitions)" >&2; exit 1; }
            op_get_transitions "$@"
            ;;
        transition_issue)
            [[ $# -lt 2 ]] && { echo "Error: missing required arguments for transition_issue" >&2; echo "Usage: $(_usage_for_op transition_issue)" >&2; exit 1; }
            op_transition_issue "$@"
            ;;
        search_jql)
            [[ $# -lt 1 ]] && { echo "Error: missing required arguments for search_jql" >&2; echo "Usage: $(_usage_for_op search_jql)" >&2; exit 1; }
            op_search_jql "$@"
            ;;
        get_projects)
            op_get_projects "$@"
            ;;
        get_issue_types)
            [[ $# -lt 1 ]] && { echo "Error: missing required arguments for get_issue_types" >&2; echo "Usage: $(_usage_for_op get_issue_types)" >&2; exit 1; }
            op_get_issue_types "$@"
            ;;
        lookup_user)
            [[ $# -lt 1 ]] && { echo "Error: missing required arguments for lookup_user" >&2; echo "Usage: $(_usage_for_op lookup_user)" >&2; exit 1; }
            op_lookup_user "$@"
            ;;
        add_worklog)
            [[ $# -lt 2 ]] && { echo "Error: missing required arguments for add_worklog" >&2; echo "Usage: $(_usage_for_op add_worklog)" >&2; exit 1; }
            op_add_worklog "$@"
            ;;
        upload_attachment)
            [[ $# -lt 2 ]] && { echo "Error: missing required arguments for upload_attachment" >&2; echo "Usage: $(_usage_for_op upload_attachment)" >&2; exit 1; }
            op_upload_attachment "$@"
            ;;
        get_remote_links)
            [[ $# -lt 1 ]] && { echo "Error: missing required arguments for get_remote_links" >&2; echo "Usage: $(_usage_for_op get_remote_links)" >&2; exit 1; }
            op_get_remote_links "$@"
            ;;
        validate_adf)
            _parse_flags "bisect" -- "$@"
            if [[ ${#_POSITIONAL[@]} -gt 0 ]]; then set -- "${_POSITIONAL[@]}"; else set --; fi
            if [[ $# -lt 1 ]]; then
                echo "Error: missing required arguments for validate_adf" >&2
                echo "Usage: $(_usage_for_op validate_adf)" >&2
                exit 1
            fi
            if _has_bool bisect; then
                op_validate_adf "$1" --bisect
            else
                op_validate_adf "$1"
            fi
            ;;
        test_connection)
            op_test_connection
            ;;
        *)
            suggestion="$(suggest_op "$operation")"
            echo "Unknown operation '$operation'." >&2
            if [[ -n "$suggestion" ]]; then
                echo "Did you mean: ${suggestion}?" >&2
            fi
            echo "Run with no arguments to see full usage." >&2
            exit 2
            ;;
    esac
fi
