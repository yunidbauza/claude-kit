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

    # Validate JSON — must be an array of diagram objects, not a bare object
    # (jq 'length' on an object counts keys and .[$i] then dies mid-loop).
    if ! echo "$diagrams_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        log_error "diagrams_json must be a JSON array of {code, filename} objects"
        exit 1
    fi

    local count
    count=$(echo "$diagrams_json" | jq 'length')
    log_info "Processing $count diagrams for issue $issue_key"

    local results="[]"
    local success_count=0
    local fail_count=0

    # Single stderr capture file reused across iterations, registered with an
    # EXIT trap so SIGINT/SIGTERM mid-loop doesn't leak the file to /tmp.
    # Deliberately NOT `local`: the trap fires after main() returns, when a
    # local would already be unset — under `set -u` that kills the trap,
    # leaks the file, and clobbers the script's exit status.
    upload_stderr=$(mktemp)
    trap 'rm -f "$upload_stderr"' EXIT

    # Process each diagram. C-style loop: `seq 0 -1` on BSD/macOS counts
    # DOWN (emits 0 and -1), so an empty array would run two bogus renders.
    for ((i = 0; i < count; i++)); do
        local code
        local filename

        code=$(echo "$diagrams_json" | jq -r ".[$i].code")
        filename=$(echo "$diagrams_json" | jq -r ".[$i].filename // \"diagram-$((i+1)).png\"")

        log_info "Processing diagram $((i+1))/$count: $filename"

        # Call single upload script — capture stdout (JSON) and stderr separately.
        # Truncate the stderr file at the start of each iteration.
        : > "$upload_stderr"
        local upload_stdout
        local upload_rc=0
        local result
        upload_stdout=$("$SCRIPT_DIR/jira-mermaid-upload.sh" "$issue_key" "$code" "$filename" 2>"$upload_stderr") || upload_rc=$?
        if [[ $upload_rc -eq 0 ]]; then
            # stdout is the JSON payload — no awk stripping needed
            local attachment_id content_url reported_fn
            attachment_id=$(printf '%s' "$upload_stdout" | jq -r '.attachment_id // empty')
            content_url=$(printf '%s' "$upload_stdout" | jq -r '.content_url // empty')
            # The child normalizes the filename (sanitize + .png suffix);
            # report what actually landed in Jira, not the raw input.
            reported_fn=$(printf '%s' "$upload_stdout" | jq -r '.filename // empty')
            result=$(jq -n \
                --arg fn "${reported_fn:-$filename}" \
                --arg id "$attachment_id" \
                --arg url "$content_url" \
                '{filename: $fn, attachment_id: $id, content_url: $url, success: true}')
            success_count=$((success_count + 1))
        else
            local errmsg
            errmsg=$(cat "$upload_stderr")
            result=$(jq -n \
                --arg fn "$filename" \
                --arg err "$errmsg" \
                '{filename: $fn, success: false, error: $err}')
            fail_count=$((fail_count + 1))
            log_warn "Failed to process $filename: $errmsg"
        fi

        results=$(echo "$results" | jq ". + [$result]")
    done

    log_info "Completed: $success_count succeeded, $fail_count failed"

    # Output results
    echo "$results"
}

main "$@"
