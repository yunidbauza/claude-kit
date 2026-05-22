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

test_resolve_plain_text() {
  local out
  out=$(_resolve_content_input "hello world" "" "")
  echo "$out" | jq -e '.type == "doc" and .content[0].content[0].text == "hello world"' >/dev/null \
    || fail "plain text → paragraph wrap: $out"
  pass "resolve plain text"
}

test_resolve_adf_passthrough() {
  local adf='{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"hi"}]}]}'
  local out
  out=$(_resolve_content_input "$adf" "" "")
  echo "$out" | jq -e '.content[0].content[0].text == "hi"' >/dev/null \
    || fail "ADF passthrough: $out"
  pass "resolve ADF passthrough"
}

test_resolve_desc_file() {
  local tmp=$(mktemp --suffix=.md 2>/dev/null || mktemp -t mdXXXX).md
  printf '# heading\n\nparagraph\n' > "$tmp"
  local out
  out=$(_resolve_content_input "" "$tmp" "")
  echo "$out" | jq -e '.content[0].type == "heading" and .content[1].type == "paragraph"' >/dev/null \
    || fail "desc-file: $out"
  rm -f "$tmp"
  pass "resolve --desc-file"
}

test_resolve_markdown_flag() {
  local out
  out=$(_resolve_content_input "# heading" "" "1")
  echo "$out" | jq -e '.content[0].type == "heading"' >/dev/null \
    || fail "markdown flag: $out"
  pass "resolve --markdown"
}

test_basic
test_bool_flag
test_unknown_flag_is_positional
test_resolve_plain_text
test_resolve_adf_passthrough
test_resolve_desc_file
test_resolve_markdown_flag

test_add_comment_desc_file() {
  local tmp
  tmp=$(mktemp --suffix=.md 2>/dev/null || mktemp -t mdXXXX).md
  printf '## comment heading\n\nbody\n' > "$tmp"
  local out
  out=$(_resolve_content_input "" "$tmp" "")
  echo "$out" | jq -e '.content[0].type == "heading"' >/dev/null \
    || fail "add_comment desc-file resolve: $out"
  rm -f "$tmp"
  pass "add_comment shares resolver"
}
test_add_comment_desc_file

# Mock curl by prepending a temp dir to PATH that contains a fake curl.
setup_mock_curl() {
  MOCK_BIN=$(mktemp -d)
  cat > "$MOCK_BIN/curl" <<'BASH'
#!/usr/bin/env bash
# Echo a fake 4xx JSON body, set non-zero exit to emulate REST failure path
echo '{"errorMessages":["INVALID_INPUT"],"errors":{}}'
exit 22
BASH
  chmod +x "$MOCK_BIN/curl"
  export PATH="$MOCK_BIN:$PATH"
  export JIRA_DOMAIN="example.atlassian.net"
  export JIRA_API_KEY="user@example.com:fake-token"
}

teardown_mock_curl() {
  rm -rf "$MOCK_BIN"
  PATH=$(echo "$PATH" | sed -e "s|$MOCK_BIN:||")
}

test_adf_failure_is_hard_error() {
  setup_mock_curl
  local out
  out=$(bash "$SCRIPT_DIR/jira-api-wrapper.sh" update_issue INCORP-1 \
    '{"description":{"type":"doc","version":1,"content":[]}}' 2>/dev/null || true)
  echo "$out" | jq -e '.api == "error"' >/dev/null \
    || fail "ADF input REST failure should be api:error, got: $out"
  echo "$out" | jq -e '.rest_error | test("INVALID_INPUT")' >/dev/null \
    || fail "ADF input REST failure should include REST errorMessages: $out"
  teardown_mock_curl
  pass "ADF input → api:error on REST 4xx"
}

test_plain_text_failure_still_mcp_fallback() {
  setup_mock_curl
  local out
  out=$(bash "$SCRIPT_DIR/jira-api-wrapper.sh" create_issue INCORP Bug "x" "plain body" 2>/dev/null || true)
  echo "$out" | jq -e '.api == "mcp_fallback"' >/dev/null \
    || fail "plain text REST failure should still be mcp_fallback, got: $out"
  teardown_mock_curl
  pass "plain text → mcp_fallback on REST 4xx (unchanged)"
}

test_preflight_validation_blocks_invalid_adf() {
  local out
  out=$(bash "$SCRIPT_DIR/jira-api-wrapper.sh" update_issue INCORP-1 \
    '{"description":{"type":"doc","version":1,"content":[{"type":"taskList","attrs":{},"content":[]}]}}' \
    2>/dev/null || true)
  echo "$out" | jq -e '.api == "error" and (.rule // .error | test("localId"))' >/dev/null \
    || fail "missing localId should fail pre-flight: $out"
  pass "pre-flight validation blocks invalid ADF"
}

test_adf_failure_is_hard_error
test_plain_text_failure_still_mcp_fallback
test_preflight_validation_blocks_invalid_adf

echo "test-wrapper-flags.sh: all pass"
