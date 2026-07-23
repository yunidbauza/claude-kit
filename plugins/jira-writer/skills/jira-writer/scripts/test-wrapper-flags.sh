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

test_update_merges_fields_json_with_desc_file() {
  # Regression: update_issue must merge the positional FIELDS_JSON (e.g. a
  # summary rename) with the --desc-file body in a SINGLE call instead of
  # dropping the JSON. Uses the no-creds path so the mcp_fallback envelope
  # echoes the fields payload we can assert on.
  local tmp
  tmp=$(mktemp --suffix=.md 2>/dev/null || mktemp -t mdXXXX).md
  printf '# New body\n\nUpdated description paragraph.\n' > "$tmp"
  local out
  out=$(env -u JIRA_API_KEY -u JIRA_DOMAIN bash "$SCRIPT_DIR/jira-api-wrapper.sh" \
    update_issue INCORP-1 '{"summary":"New title"}' --desc-file "$tmp" 2>/dev/null || true)
  echo "$out" | jq -e '.api == "mcp_fallback"' >/dev/null \
    || fail "expected mcp_fallback without creds, got: $out"
  echo "$out" | jq -e '.params.fields.summary == "New title"' >/dev/null \
    || fail "summary from FIELDS_JSON must survive alongside --desc-file: $out"
  echo "$out" | jq -e '.params.fields.description.type == "doc"' >/dev/null \
    || fail "description ADF from --desc-file missing: $out"
  echo "$out" | jq -e '.params.fields.description.content[0].type == "heading"' >/dev/null \
    || fail "desc-file body should be markdown-converted ADF: $out"
  rm -f "$tmp"
  pass "update_issue merges FIELDS_JSON summary with --desc-file body"
}
test_update_merges_fields_json_with_desc_file

test_update_desc_file_only_still_works() {
  # No positional FIELDS_JSON: --desc-file alone updates just the description.
  local tmp
  tmp=$(mktemp --suffix=.md 2>/dev/null || mktemp -t mdXXXX).md
  printf 'plain body line\n' > "$tmp"
  local out
  out=$(env -u JIRA_API_KEY -u JIRA_DOMAIN bash "$SCRIPT_DIR/jira-api-wrapper.sh" \
    update_issue INCORP-1 --desc-file "$tmp" 2>/dev/null || true)
  echo "$out" | jq -e '.api == "mcp_fallback" and .params.fields.description.type == "doc"' >/dev/null \
    || fail "desc-file only should still update description: $out"
  echo "$out" | jq -e '.params.fields | has("summary") | not' >/dev/null \
    || fail "desc-file only must not invent a summary field: $out"
  rm -f "$tmp"
  pass "update_issue --desc-file alone updates description only"
}
test_update_desc_file_only_still_works

# Mock curl by prepending a temp dir to PATH that contains a fake curl.
setup_mock_curl() {
  MOCK_BIN=$(mktemp -d)
  cat > "$MOCK_BIN/curl" <<'BASH'
#!/usr/bin/env bash
# Emit two-line response matching `curl -s -w "\n%{http_code}"` output:
# body line then http_code line. Exit 0 so jira-rest-api.sh routes on http_code.
echo '{"errorMessages":["INVALID_INPUT"],"errors":{}}'
echo "400"
exit 0
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

test_envelope_shape_consistent_for_adf_errors() {
  setup_mock_curl
  # update_issue with ADF input → api:error with params.issueIdOrKey
  local out
  out=$(bash "$SCRIPT_DIR/jira-api-wrapper.sh" update_issue INCORP-1 \
    '{"description":{"type":"doc","version":1,"content":[]}}' 2>/dev/null || true)
  echo "$out" | jq -e '.params.issueIdOrKey == "INCORP-1"' >/dev/null \
    || fail "update_issue api:error envelope should have params.issueIdOrKey: $out"
  teardown_mock_curl
  pass "api:error envelopes use params wrapper consistently"
}

test_shallow_adf_doc_not_treated_as_full_adf() {
  setup_mock_curl
  # A malformed ADF doc (.description.type=="doc" but no version/content)
  # should NOT trigger strict ADF failure path — it's not really ADF.
  local out
  out=$(bash "$SCRIPT_DIR/jira-api-wrapper.sh" update_issue INCORP-1 \
    '{"description":{"type":"doc"}}' 2>/dev/null || true)
  # Should fall back to mcp_fallback (not api:error) because the description
  # doesn't pass the strict ADF shape check.
  echo "$out" | jq -e '.api == "mcp_fallback"' >/dev/null \
    || fail "malformed ADF should fall back to mcp_fallback, got: $out"
  teardown_mock_curl
  pass "malformed pseudo-ADF doesn't trigger strict-failure path"
}

test_envelope_shape_consistent_for_adf_errors
test_shallow_adf_doc_not_treated_as_full_adf

test_validate_adf_op_pass() {
  local tmp=$(mktemp)
  echo '{"type":"doc","version":1,"content":[]}' > "$tmp"
  local out
  out=$(bash "$SCRIPT_DIR/jira-api-wrapper.sh" validate_adf "$tmp")
  echo "$out" | jq -e '.api == "rest" and .data.ok == true' >/dev/null \
    || fail "validate_adf valid doc: $out"
  rm -f "$tmp"
  pass "validate_adf valid doc"
}

test_validate_adf_op_fail() {
  local tmp=$(mktemp)
  echo '{"type":"doc","version":1,"content":[{"type":"taskList","attrs":{},"content":[]}]}' > "$tmp"
  local out
  out=$(bash "$SCRIPT_DIR/jira-api-wrapper.sh" validate_adf "$tmp" 2>/dev/null || true)
  echo "$out" | jq -e '.api == "error" and (.error // .message | test("localId"))' >/dev/null \
    || fail "validate_adf invalid doc: $out"
  rm -f "$tmp"
  pass "validate_adf invalid doc"
}

test_validate_adf_op_pass
test_validate_adf_op_fail

test_parent_validates_format() {
  local out
  out=$(bash "$SCRIPT_DIR/jira-api-wrapper.sh" create_issue INCORP Story "x" --parent badformat 2>/dev/null || true)
  echo "$out" | jq -e '.api == "error" and (.error | test("parent"))' >/dev/null \
    || fail "bad --parent should hard-error: $out"
  pass "bad --parent hard-errored"
}

test_parent_passes_well_formed() {
  local out
  out=$(JIRA_WRITER_DRY_RUN=1 bash "$SCRIPT_DIR/jira-api-wrapper.sh" create_issue INCORP Story "x" --parent INCORP-9 2>/dev/null)
  echo "$out" | jq -e '.fields.parent.key == "INCORP-9"' >/dev/null \
    || fail "well-formed --parent should set fields.parent.key: $out"
  pass "well-formed --parent applied"
}

test_parent_validates_format
test_parent_passes_well_formed

test_summary_only_passes_fields() {
  MOCK_DIR=$(mktemp -d)
  cat > "$MOCK_DIR/curl" <<'BASH'
#!/usr/bin/env bash
echo "$@" > "$MOCK_LOG"
echo '{"key":"INCORP-1","fields":{"summary":"x","issuetype":{"name":"Bug"},"status":{"name":"Open"}}}'
echo "200"
BASH
  chmod +x "$MOCK_DIR/curl"
  export MOCK_LOG="$MOCK_DIR/log"
  export PATH="$MOCK_DIR:$PATH"
  export JIRA_DOMAIN="example.atlassian.net"
  export JIRA_API_KEY="u@e.com:x"

  bash "$SCRIPT_DIR/jira-api-wrapper.sh" get_issue INCORP-1 --summary-only >/dev/null
  # fields is percent-encoded before hitting the URL (commas become %2C)
  grep -q "fields=summary%2Cissuetype%2Cparent%2Cstatus%2Cassignee" "$MOCK_LOG" \
    || fail "--summary-only should narrow ?fields= param (URL-encoded). log: $(cat $MOCK_LOG)"

  PATH=$(echo "$PATH" | sed -e "s|$MOCK_DIR:||")
  rm -rf "$MOCK_DIR"
  pass "--summary-only narrows fields"
}

test_missing_arg_help_lists_signature() {
  local out
  out=$(bash "$SCRIPT_DIR/jira-api-wrapper.sh" create_issue 2>&1 || true)
  echo "$out" | grep -q "PROJECT.*TYPE.*SUMMARY" \
    || fail "missing-arg help should show full signature: $out"
  echo "$out" | grep -q -- "--parent" \
    || fail "missing-arg help should mention --parent flag: $out"
  pass "missing-arg help shows full signature"
}

test_summary_only_passes_fields
test_missing_arg_help_lists_signature

test_validate_adf_flag_order() {
  local tmp=$(mktemp)
  echo '{"type":"doc","version":1,"content":[]}' > "$tmp"
  # Flag BEFORE the path — must work the same as flag after
  local out
  out=$(bash "$SCRIPT_DIR/jira-api-wrapper.sh" validate_adf --bisect "$tmp")
  echo "$out" | jq -e '.api == "rest" and .data.ok == true' >/dev/null \
    || fail "validate_adf --bisect <path> (flag-first): $out"
  rm -f "$tmp"
  pass "validate_adf flag-order independent"
}

test_get_issue_empty_positional_arity() {
  local out
  out=$(bash "$SCRIPT_DIR/jira-api-wrapper.sh" get_issue --summary-only 2>&1 || true)
  # Should print missing-args error, NOT run with empty key
  echo "$out" | grep -q "missing required arguments for get_issue" \
    || fail "get_issue --summary-only (no key) should error, got: $out"
  pass "get_issue empty positional triggers arity guard"
}

test_create_issue_empty_positional_arity() {
  local out
  out=$(bash "$SCRIPT_DIR/jira-api-wrapper.sh" create_issue --markdown 2>&1 || true)
  echo "$out" | grep -q "missing required arguments for create_issue" \
    || fail "create_issue --markdown (no project/type/summary) should error, got: $out"
  pass "create_issue empty positional triggers arity guard"
}

test_link_issues_direction() {
  # Mock curl that logs the POST body and returns 201 with an empty body
  # (what POST /rest/api/3/issueLink actually returns).
  local mock_dir mock_log
  mock_dir=$(mktemp -d)
  mock_log="$mock_dir/body.log"
  cat > "$mock_dir/curl" <<BASH
#!/usr/bin/env bash
prev=""
for a in "\$@"; do
  [[ "\$prev" == "--data-raw" ]] && printf '%s\n' "\$a" >> "$mock_log"
  prev="\$a"
done
echo ""
echo "201"
exit 0
BASH
  chmod +x "$mock_dir/curl"
  export PATH="$mock_dir:$PATH"
  export JIRA_DOMAIN="example.atlassian.net"
  export JIRA_API_KEY="user@example.com:fake-token"

  local out
  out=$(bash "$SCRIPT_DIR/jira-api-wrapper.sh" link_issues HB-1 Blocks HB-2 2>/dev/null)
  # DIRECTION: arg1 is the OUTWARD issue (carries "blocks"); arg3 is INWARD
  # ("is blocked by"). Getting this backwards is the classic issue-link bug.
  jq -e '.type.name == "Blocks" and .outwardIssue.key == "HB-1" and .inwardIssue.key == "HB-2"' \
    "$mock_log" >/dev/null \
    || fail "link_issues direction wrong. body: $(cat "$mock_log")"
  echo "$out" | jq -e '.api == "rest" and .data.success == true' >/dev/null \
    || fail "link_issues 201 (empty body) should be rest success, got: $out"

  PATH=$(echo "$PATH" | sed -e "s|$mock_dir:||")
  rm -rf "$mock_dir"
  pass "link_issues posts correct direction (arg1=outward=blocker)"
}

test_link_issues_arity() {
  local out
  out=$(bash "$SCRIPT_DIR/jira-api-wrapper.sh" link_issues HB-1 Blocks 2>&1 || true)
  echo "$out" | grep -q "missing required arguments for link_issues" \
    || fail "link_issues with 2 args should error, got: $out"
  pass "link_issues arity guard"
}

test_validate_adf_flag_order
test_get_issue_empty_positional_arity
test_create_issue_empty_positional_arity
test_link_issues_direction
test_link_issues_arity

echo "test-wrapper-flags.sh: all pass"
