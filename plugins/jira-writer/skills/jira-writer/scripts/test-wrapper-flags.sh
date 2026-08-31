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

test_unknown_flag_errors() {
  # Typo protection: a whitespace-free letter-led unknown --flag is a hard
  # error instead of silently becoming a positional (e.g. the description).
  local rc=0
  _parse_flags "desc-file" -- a --unknown b c 2>/dev/null || rc=$?
  [[ $rc -eq 2 ]] || fail "unknown flag should return 2, got $rc"
  pass "unknown letter-led flag is a hard error"
}

test_multiword_dash_data_is_positional() {
  _parse_flags "desc-file" -- K-1 "--force is deprecated, use --safe"
  [[ "${_POSITIONAL[*]}" == "K-1 --force is deprecated, use --safe" ]] \
    || fail "multi-word dash data: ${_POSITIONAL[*]}"
  pass "multi-word data starting with --word stays positional"
}

test_double_dash_ends_flags() {
  _parse_flags "markdown" -- K-1 -- --markdown
  [[ "${_POSITIONAL[*]}" == "K-1 --markdown" ]] || fail "-- end-of-flags: ${_POSITIONAL[*]}"
  [[ "${#_BOOLS[@]}" -eq 0 ]] || fail "bools should be empty: ${_BOOLS[*]:-}"
  pass "lone -- ends flag parsing"
}

test_duplicate_value_flag_last_wins() {
  _parse_flags "parent" -- K-1 --parent A-1 --parent A-2
  [[ "$(_flag_value parent)" == "A-2" ]] || fail "last --parent should win: $(_flag_value parent)"
  pass "duplicate value flags resolve last-wins"
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
test_unknown_flag_errors
test_multiword_dash_data_is_positional
test_double_dash_ends_flags
test_duplicate_value_flag_last_wins
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
  out=$(env -u JIRA_API_KEY -u JIRA_EMAIL -u JIRA_DOMAIN bash "$SCRIPT_DIR/jira-api-wrapper.sh" \
    update_issue INCORP-1 '{"summary":"New title"}' --desc-file "$tmp" 2>/dev/null || true)
  echo "$out" | jq -e '.api == "mcp_fallback"' >/dev/null \
    || fail "expected mcp_fallback without creds, got: $out"
  echo "$out" | jq -e '.params.fields.summary == "New title"' >/dev/null \
    || fail "summary from FIELDS_JSON must survive alongside --desc-file: $out"
  # No-creds fallback carries the ORIGINAL markdown (MCP renders markdown
  # natively), not converted ADF.
  echo "$out" | jq -e '.params.fields.description | type == "string" and startswith("# New body")' >/dev/null \
    || fail "desc-file body should be the original markdown string: $out"
  echo "$out" | jq -e '.note | test("markdown")' >/dev/null \
    || fail "markdown fallback should carry an explanatory note: $out"
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
  out=$(env -u JIRA_API_KEY -u JIRA_EMAIL -u JIRA_DOMAIN bash "$SCRIPT_DIR/jira-api-wrapper.sh" \
    update_issue INCORP-1 --desc-file "$tmp" 2>/dev/null || true)
  echo "$out" | jq -e '.api == "mcp_fallback" and (.params.fields.description | type == "string" and startswith("plain body line"))' >/dev/null \
    || fail "desc-file only should still update description (as original markdown): $out"
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
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_KEY="fake-token"
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
  export JIRA_EMAIL="u@e.com"
  export JIRA_API_KEY="x"

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
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_KEY="fake-token"

  local out
  out=$(bash "$SCRIPT_DIR/jira-api-wrapper.sh" link_issues HB-1 Blocks HB-2 2>/dev/null)
  # DIRECTION (verified against live Jira link objects): the issue that
  # PERFORMS the outward verb ("blocks") is the link's INWARD issue, so
  # arg1 → inwardIssue and arg3 → outwardIssue. Mapping arg1 to
  # outwardIssue is the inversion this regression test pins.
  jq -e '.type.name == "Blocks" and .inwardIssue.key == "HB-1" and .outwardIssue.key == "HB-2"' \
    "$mock_log" >/dev/null \
    || fail "link_issues direction wrong. body: $(cat "$mock_log")"
  echo "$out" | jq -e '.api == "rest" and .data.success == true' >/dev/null \
    || fail "link_issues 201 (empty body) should be rest success, got: $out"

  PATH=$(echo "$PATH" | sed -e "s|$mock_dir:||")
  rm -rf "$mock_dir"
  pass "link_issues posts correct direction (arg1=inward=performs the verb)"
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

test_create_issue_task_default() {
  # SKILL.md: "Default issue type is Task" — 2 positionals = PROJECT SUMMARY.
  local out
  out=$(JIRA_WRITER_DRY_RUN=1 JIRA_DOMAIN=example.atlassian.net JIRA_EMAIL=u@e.com JIRA_API_KEY=x \
    bash "$SCRIPT_DIR/jira-api-wrapper.sh" create_issue INCORP "Just a summary" 2>/dev/null)
  echo "$out" | jq -e '.fields.issuetype.name == "Task" and .fields.summary == "Just a summary"' >/dev/null \
    || fail "2-arg create should default type to Task: $out"
  pass "create_issue defaults type to Task with 2 positionals"
}
test_create_issue_task_default

test_update_append_merges_existing_description() {
  # --append must fetch the current description ADF and concatenate the new
  # content onto it (lossless: the existing body is never converted).
  local mock_dir mock_log tmp
  mock_dir=$(mktemp -d)
  mock_log="$mock_dir/put.log"
  cat > "$mock_dir/curl" <<BASH
#!/usr/bin/env bash
is_put=0; prev=""
for a in "\$@"; do
  [[ "\$prev" == "-X" && "\$a" == "PUT" ]] && is_put=1
  [[ "\$prev" == "--data-raw" ]] && printf '%s\n' "\$a" >> "$mock_log"
  prev="\$a"
done
if [[ \$is_put -eq 1 ]]; then echo ""; echo "204"; else
  echo '{"fields":{"description":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"EXISTING"}]}]}}}'
  echo "200"
fi
BASH
  chmod +x "$mock_dir/curl"
  export PATH="$mock_dir:$PATH"
  export JIRA_DOMAIN="example.atlassian.net"
  export JIRA_EMAIL="user@example.com"
  export JIRA_API_KEY="fake-token"
  tmp=$(mktemp -t mdXXXX).md
  printf '## Appended\n' > "$tmp"

  bash "$SCRIPT_DIR/jira-api-wrapper.sh" update_issue K-1 '{}' --desc-file "$tmp" --append >/dev/null 2>&1
  jq -e '.fields.description.content | length == 2
         and .[0].content[0].text == "EXISTING"
         and .[1].type == "heading"' "$mock_log" >/dev/null \
    || fail "--append should concatenate onto the existing description. PUT: $(cat "$mock_log")"

  rm -f "$tmp"
  PATH=$(echo "$PATH" | sed -e "s|$mock_dir:||")
  rm -rf "$mock_dir"
  pass "update_issue --append merges onto the existing description"
}
test_update_append_merges_existing_description

test_update_append_requires_rest() {
  # Without REST creds --append must hard-error: any MCP fallback would
  # overwrite the existing description.
  local tmp out
  tmp=$(mktemp -t mdXXXX).md
  printf 'extra\n' > "$tmp"
  out=$(env -u JIRA_API_KEY -u JIRA_EMAIL -u JIRA_DOMAIN bash "$SCRIPT_DIR/jira-api-wrapper.sh" \
    update_issue K-1 '{}' --desc-file "$tmp" --append 2>/dev/null || true)
  echo "$out" | jq -e '.api == "error" and (.error | test("append requires REST"))' >/dev/null \
    || fail "--append without creds should be api:error, got: $out"
  rm -f "$tmp"
  pass "update_issue --append without REST creds is a hard error"
}
test_update_append_requires_rest

echo "test-wrapper-flags.sh: all pass"
