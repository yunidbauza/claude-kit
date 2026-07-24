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
#   mermaid_file_or_code - Path to .mmd file OR mermaid code as string.
#                          A path must contain no whitespace — args with
#                          spaces/newlines are always treated as code.
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

# Shared REST helpers — attachment upload goes through jira_upload_attachment
# so sanitization, auth, and the attachments endpoint live in one place.
# (Sourcing also re-gates the color vars on [[ -t 2 ]], keeping ANSI codes
# out of captured stderr.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/jira-rest-api.sh"

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

    # Sanitize: ; and quotes are curl -F metacharacters (;type=, ;headers=)
    # and would corrupt the multipart spec the name is interpolated into.
    output_filename="${output_filename//[^a-zA-Z0-9._-]/_}"

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

    # Handle mermaid input (file or string). Only treat it as a path when the
    # file exists AND the argument contains no whitespace — real mermaid
    # source always has spaces/newlines, so a stray cwd file named e.g.
    # "flowchart" can't silently substitute its contents for literal code.
    if [[ -f "$mermaid_input" && ! "$mermaid_input" =~ [[:space:]] ]]; then
        log_info "Reading mermaid from file: $mermaid_input"
        cp "$mermaid_input" "$mmd_file"
    else
        log_info "Using mermaid code from argument"
        printf '%s\n' "$mermaid_input" > "$mmd_file"
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

    # Upload to Jira via the shared REST helper — one implementation of the
    # sanitize regex, auth header (incl. the base64 newline strip), and the
    # attachments endpoint, instead of a parallel curl path here.
    log_info "Uploading to Jira issue $issue_key..."

    local body rc=0
    body=$(jira_upload_attachment "$issue_key" "$png_file" "$output_filename") || rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "Upload failed for issue $issue_key (see errors above)"
        exit 4
    fi

    # Extract attachment info
    local attachment_id
    local content_url

    attachment_id=$(echo "$body" | jq -r '.[0].id // empty')
    if [[ -z "$attachment_id" ]]; then
        log_error "Unexpected upload response (no attachment id): $body"
        exit 4
    fi
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
