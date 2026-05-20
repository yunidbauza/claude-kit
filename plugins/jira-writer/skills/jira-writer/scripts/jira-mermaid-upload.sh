#!/usr/bin/env bash
#
# jira-mermaid-upload.sh
#
# Converts a Mermaid diagram to PNG and uploads it to a Jira issue as an attachment.
# Returns the attachment ID and content URL for embedding in ADF.
#
# Usage:
#   ./jira-mermaid-upload.sh <issue_key> <mermaid_file_or_code> [filename]
#
# Arguments:
#   issue_key           - Jira issue key (e.g., PROJ-123)
#   mermaid_file_or_code - Path to .mmd file OR mermaid code as string
#   filename            - Optional output filename (default: diagram.png)
#
# Environment Variables (required):
#   JIRA_DOMAIN   - Your Jira domain (e.g., company.atlassian.net)
#   JIRA_API_KEY  - Your email:api_token (NOT base64 encoded)
#
# Output (JSON):
#   { "attachment_id": "12345", "content_url": "https://...", "filename": "diagram.png" }
#
# Exit Codes:
#   0 - Success
#   1 - Missing arguments
#   2 - Prerequisites check failed
#   3 - Mermaid conversion failed
#   4 - Jira upload failed
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# --- Prerequisites Check ---
check_prerequisites() {
    local errors=0

    # Check mmdc
    if ! command -v mmdc &> /dev/null; then
        log_error "mermaid-cli (mmdc) not found"
        log_error "Install with: npm install -g @mermaid-js/mermaid-cli"
        errors=$((errors + 1))
    else
        log_info "mmdc found: $(which mmdc)"
    fi

    # Check curl
    if ! command -v curl &> /dev/null; then
        log_error "curl not found"
        errors=$((errors + 1))
    fi

    # Check jq
    if ! command -v jq &> /dev/null; then
        log_error "jq not found (required for JSON parsing)"
        log_error "Install with: brew install jq"
        errors=$((errors + 1))
    fi

    # Check JIRA_DOMAIN
    if [[ -z "${JIRA_DOMAIN:-}" ]]; then
        log_error "JIRA_DOMAIN environment variable not set"
        log_error "Set with: export JIRA_DOMAIN=\"company.atlassian.net\""
        errors=$((errors + 1))
    else
        log_info "JIRA_DOMAIN: $JIRA_DOMAIN"
    fi

    # Check JIRA_API_KEY
    if [[ -z "${JIRA_API_KEY:-}" ]]; then
        log_error "JIRA_API_KEY environment variable not set"
        log_error "Set with: export JIRA_API_KEY=\"email@domain.com:your_api_token\""
        errors=$((errors + 1))
    else
        log_info "JIRA_API_KEY: set (${#JIRA_API_KEY} chars)"
    fi

    if [[ $errors -gt 0 ]]; then
        return 1
    fi

    return 0
}

# --- Main Function ---
main() {
    # Parse arguments
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 <issue_key> <mermaid_file_or_code> [filename]" >&2
        echo "" >&2
        echo "Examples:" >&2
        echo "  $0 PROJ-123 diagram.mmd" >&2
        echo "  $0 PROJ-123 'graph TD; A-->B' flow-diagram.png" >&2
        exit 1
    fi

    local issue_key="$1"
    local mermaid_input="$2"
    local output_filename="${3:-diagram.png}"

    # Ensure filename ends with .png
    if [[ ! "$output_filename" =~ \.png$ ]]; then
        output_filename="${output_filename}.png"
    fi

    log_info "Issue: $issue_key"
    log_info "Output filename: $output_filename"

    # Check prerequisites
    log_info "Checking prerequisites..."
    if ! check_prerequisites; then
        log_error "Prerequisites check failed"
        exit 2
    fi

    # Create temp directory.
    # NOTE: temp_dir is intentionally script-scoped (no `local`) so it remains
    # in scope when the EXIT trap fires after main() returns. With `set -u`,
    # a local would be unset at trap time and rm -rf would fail.
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT

    local mmd_file="$temp_dir/diagram.mmd"
    local png_file="$temp_dir/$output_filename"

    # Handle mermaid input (file or string)
    if [[ -f "$mermaid_input" ]]; then
        log_info "Reading mermaid from file: $mermaid_input"
        cp "$mermaid_input" "$mmd_file"
    else
        log_info "Using mermaid code from argument"
        echo "$mermaid_input" > "$mmd_file"
    fi

    # Convert to PNG (stderr captured; temp file lives inside temp_dir so EXIT trap cleans it up)
    log_info "Converting to PNG..."
    local mmdc_stderr="$temp_dir/mmdc_stderr.txt"
    if ! mmdc -i "$mmd_file" -o "$png_file" \
        --backgroundColor white \
        --theme neutral \
        --scale 2 2>"$mmdc_stderr"; then
        log_error "Mermaid conversion failed: $(cat "$mmdc_stderr")"
        exit 3
    fi

    # Verify PNG was created and is non-empty
    if [[ ! -s "$png_file" ]]; then
        log_error "Mermaid conversion produced empty output: $(cat "$mmdc_stderr")"
        exit 3
    fi

    local png_size
    png_size=$(stat -f%z "$png_file" 2>/dev/null || stat -c%s "$png_file" 2>/dev/null)
    log_info "PNG created: $png_size bytes"

    # Upload to Jira
    log_info "Uploading to Jira issue $issue_key..."

    # Base64 encode the API key for Basic auth
    local auth_header
    auth_header=$(echo -n "$JIRA_API_KEY" | base64)

    local response
    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Basic $auth_header" \
        -H "X-Atlassian-Token: no-check" \
        -F "file=@$png_file;filename=$output_filename" \
        "https://$JIRA_DOMAIN/rest/api/3/issue/$issue_key/attachments")

    # Parse response
    local http_code
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        log_error "Upload failed with HTTP $http_code"
        log_error "Response: $body"

        case "$http_code" in
            401|403)
                log_error "Authentication failed. Check JIRA_API_KEY format (should be email:api_token)"
                ;;
            404)
                log_error "Issue $issue_key not found or no permission"
                ;;
        esac
        exit 4
    fi

    # Extract attachment info
    local attachment_id
    local content_url

    attachment_id=$(echo "$body" | jq -r '.[0].id')
    content_url="https://$JIRA_DOMAIN/rest/api/3/attachment/content/$attachment_id"

    log_info "Upload successful!"
    log_info "Attachment ID: $attachment_id"
    log_info "Content URL: $content_url"

    # Output JSON result (to stdout for script consumption)
    jq -n \
        --arg id "$attachment_id" \
        --arg url "$content_url" \
        --arg filename "$output_filename" \
        '{attachment_id: $id, content_url: $url, filename: $filename}'
}

# Run main function
main "$@"
