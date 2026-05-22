#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/jira-api-wrapper.sh" --source-only 2>/dev/null || true

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "  ✓ $1"; }

# _parse_flags KNOWN_FLAGS_CSV -- "$@"
# Sets globals:
#   _POSITIONAL=(...)
#   _FLAGS=(flag1=val1 flag2=val2 ...)  // single-value flags
#   _BOOLS=(boolflag ...)               // value-less flags

test_basic() {
  _parse_flags "desc-file,markdown,parent,summary-only,bisect" -- \
    INCORP Story "Add OAuth" --desc-file /tmp/x.md --parent INCORP-1
  [[ "${_POSITIONAL[*]}" == "INCORP Story Add OAuth" ]] || fail "positional: ${_POSITIONAL[*]}"
  [[ "${_FLAGS[*]}" == *"desc-file=/tmp/x.md"* ]] || fail "missing desc-file: ${_FLAGS[*]}"
  [[ "${_FLAGS[*]}" == *"parent=INCORP-1"* ]] || fail "missing parent: ${_FLAGS[*]}"
  pass "basic"
}

test_bool_flag() {
  _parse_flags "markdown,bisect" -- foo --markdown bar
  [[ "${_POSITIONAL[*]}" == "foo bar" ]] || fail "positional with bool: ${_POSITIONAL[*]}"
  [[ "${_BOOLS[*]}" == *"markdown"* ]] || fail "missing bool markdown: ${_BOOLS[*]}"
  pass "bool flag"
}

test_unknown_flag_is_positional() {
  _parse_flags "desc-file" -- a --unknown b c
  [[ "${_POSITIONAL[*]}" == "a --unknown b c" ]] || fail "unknown stayed positional: ${_POSITIONAL[*]}"
  pass "unknown flag treated as positional"
}

test_basic
test_bool_flag
test_unknown_flag_is_positional
echo "test-wrapper-flags.sh: all pass"
