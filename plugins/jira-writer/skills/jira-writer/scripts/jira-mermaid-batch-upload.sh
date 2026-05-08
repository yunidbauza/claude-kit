#!/usr/bin/env bash
#
# jira-mermaid-batch-upload.sh
#
# Uploads multiple Mermaid diagrams to a Jira issue.
# Accepts a JSON array of diagram definitions.
#
# Usage:
#   ./jira-mermaid-batch-upload.sh <issue_key> <diagrams_json>
#
# Arguments:
#   issue_key     - Jira issue key (e.g., PROJ-123)
#   diagrams_json - JSON array of diagrams, each with:
#                   { "code": "mermaid code", "filename": "name.png" }
#
# Example:
#   ./jira-mermaid-batch-upload.sh PROJ-123 '[
#     {"code": "graph TD; A-->B", "filename": "flow.png"},
#     {"code": "sequenceDiagram; A->>B: Hello", "filename": "sequence.png"}
#   ]'
#
# Output (JSON array):
#   [
#     { "filename": "flow.png", "attachment_id": "123", "content_url": "...", "success": true },
#     { "filename": "sequence.png", "attachment_id": "456", "content_url": "...", "success": true }
#   ]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

main() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 <issue_key> <diagrams_json>" >&2
        exit 1
    fi

    local issue_key="$1"
    local diagrams_json="$2"

    # Validate JSON
    if ! echo "$diagrams_json" | jq empty 2>/dev/null; then
        log_error "Invalid JSON provided"
        exit 1
    fi

    local count
    count=$(echo "$diagrams_json" | jq 'length')
    log_info "Processing $count diagrams for issue $issue_key"

    local results="[]"
    local success_count=0
    local fail_count=0

    # Process each diagram
    for i in $(seq 0 $((count - 1))); do
        local code
        local filename

        code=$(echo "$diagrams_json" | jq -r ".[$i].code")
        filename=$(echo "$diagrams_json" | jq -r ".[$i].filename // \"diagram-$((i+1)).png\"")

        log_info "Processing diagram $((i+1))/$count: $filename"

        # Call single upload script
        local result
        local json_result
        if result=$("$SCRIPT_DIR/jira-mermaid-upload.sh" "$issue_key" "$code" "$filename" 2>&1); then
            # Extract JSON from output (mmdc outputs noise to stdout before the JSON)
            json_result=$(echo "$result" | awk '/^\{/,/^\}/')
            result=$(echo "$json_result" | jq '. + {success: true}')
            success_count=$((success_count + 1))
        else
            result=$(jq -n --arg fn "$filename" --arg err "Upload failed" '{filename: $fn, success: false, error: $err}')
            fail_count=$((fail_count + 1))
            log_warn "Failed to process $filename"
        fi

        results=$(echo "$results" | jq ". + [$result]")
    done

    log_info "Completed: $success_count succeeded, $fail_count failed"

    # Output results
    echo "$results"
}

main "$@"
