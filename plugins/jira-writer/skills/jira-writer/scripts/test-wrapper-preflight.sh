#!/usr/bin/env bash
#
# test-wrapper-preflight.sh
#
# Verifies jira-api-wrapper.sh fails loudly (clear message + exit 127) when
# its sibling jira-rest-api.sh is missing — the stale-$CLAUDE_PLUGIN_ROOT case.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Copy ONLY the wrapper — deliberately omit jira-rest-api.sh.
cp "$SCRIPT_DIR/jira-api-wrapper.sh" "$TMP/jira-api-wrapper.sh"
chmod +x "$TMP/jira-api-wrapper.sh"

set +e
output="$("$TMP/jira-api-wrapper.sh" get_issue PROJ-1 2>&1)"
code=$?
set -e

fail=0
if [[ $code -ne 127 ]]; then
    echo "FAIL: expected exit code 127, got $code"
    fail=1
fi
if ! grep -q "jira-writer scripts missing" <<<"$output"; then
    echo "FAIL: expected 'jira-writer scripts missing' in output"
    echo "----- actual output -----"
    echo "$output"
    echo "-------------------------"
    fail=1
fi

if [[ $fail -eq 0 ]]; then
    echo "PASS: wrapper preflight emits diagnostic and exits 127"
fi
exit $fail
