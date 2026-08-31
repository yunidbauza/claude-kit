#!/usr/bin/env bash
#
# test-credentials.sh
#
# Covers jira-credentials.sh: the resolution matrix for the split form
# (JIRA_EMAIL + JIRA_API_KEY), the deprecated combined form
# (JIRA_API_KEY="email:token"), and the half-migrated state.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [[ $# -gt 1 ]] && echo "      $2"; FAIL=$((FAIL + 1)); }

# The library must exist as a sibling — every script sources it by that path.
if [[ ! -f "$SCRIPT_DIR/jira-credentials.sh" ]]; then
    fail "jira-credentials.sh exists" "not found at $SCRIPT_DIR"
    echo "$PASS passed, $FAIL failed"
    exit 1
fi
pass "jira-credentials.sh exists"

# Run one assertion in a clean subshell: env is set from scratch each time so
# the developer's own exported credentials cannot leak into a case.
# Usage: expect_pair <label> <expected-pair-or-EMPTY> <env assignments...>
expect_pair() {
    local label="$1" expected="$2"
    shift 2
    local actual rc
    actual=$(env -u JIRA_EMAIL -u JIRA_API_KEY -u JIRA_DOMAIN "$@" bash -c '
        source "'"$SCRIPT_DIR"'/jira-credentials.sh"
        jira_credentials_pair
    ' 2>/dev/null)
    rc=$?
    if [[ "$expected" == "EMPTY" ]]; then
        if [[ $rc -ne 0 && -z "$actual" ]]; then
            pass "$label"
        else
            fail "$label" "expected failure, got rc=$rc pair='$actual'"
        fi
    elif [[ $rc -eq 0 && "$actual" == "$expected" ]]; then
        pass "$label"
    else
        fail "$label" "expected '$expected', got rc=$rc '$actual'"
    fi
}

# Usage: expect_predicate <label> <fn> <expected 0|1> <env assignments...>
expect_predicate() {
    local label="$1" fn="$2" expected="$3"
    shift 3
    local rc
    env -u JIRA_EMAIL -u JIRA_API_KEY -u JIRA_DOMAIN "$@" bash -c '
        source "'"$SCRIPT_DIR"'/jira-credentials.sh"
        '"$fn"'
    ' >/dev/null 2>&1
    rc=$?
    if [[ $rc -eq $expected ]]; then
        pass "$label"
    else
        fail "$label" "expected rc=$expected, got rc=$rc"
    fi
}

# --- Resolution matrix -------------------------------------------------------

expect_pair "split form resolves to email:token" \
    "you@company.com:tok123" \
    JIRA_EMAIL=you@company.com JIRA_API_KEY=tok123

expect_pair "legacy combined form still resolves" \
    "you@company.com:tok123" \
    JIRA_API_KEY=you@company.com:tok123

expect_pair "half-migrated form drops the duplicated email prefix" \
    "you@company.com:tok123" \
    JIRA_EMAIL=you@company.com JIRA_API_KEY=you@company.com:tok123

expect_pair "bare token without JIRA_EMAIL does not resolve" \
    "EMPTY" \
    JIRA_API_KEY=tok123

expect_pair "JIRA_EMAIL without a token does not resolve" \
    "EMPTY" \
    JIRA_EMAIL=you@company.com

expect_pair "nothing set does not resolve" "EMPTY"

expect_pair "a token containing a colon survives the split form" \
    "you@company.com:tok:123" \
    JIRA_EMAIL=you@company.com JIRA_API_KEY=tok:123

# --- Availability (pair + domain) --------------------------------------------

expect_predicate "available with domain + split creds" jira_credentials_available 0 \
    JIRA_DOMAIN=example.atlassian.net JIRA_EMAIL=you@company.com JIRA_API_KEY=tok123

expect_predicate "unavailable without JIRA_DOMAIN" jira_credentials_available 1 \
    JIRA_EMAIL=you@company.com JIRA_API_KEY=tok123

expect_predicate "unavailable without JIRA_EMAIL" jira_credentials_available 1 \
    JIRA_DOMAIN=example.atlassian.net JIRA_API_KEY=tok123

expect_predicate "available with domain + legacy creds" jira_credentials_available 0 \
    JIRA_DOMAIN=example.atlassian.net JIRA_API_KEY=you@company.com:tok123

# --- Format classification ---------------------------------------------------

expect_predicate "split form is not flagged legacy" jira_credentials_is_legacy 1 \
    JIRA_EMAIL=you@company.com JIRA_API_KEY=tok123

expect_predicate "combined form is flagged legacy" jira_credentials_is_legacy 0 \
    JIRA_API_KEY=you@company.com:tok123

expect_predicate "half-migrated form is detected" jira_credentials_is_half_migrated 0 \
    JIRA_EMAIL=you@company.com JIRA_API_KEY=you@company.com:tok123

expect_predicate "split form is not flagged half-migrated" jira_credentials_is_half_migrated 1 \
    JIRA_EMAIL=you@company.com JIRA_API_KEY=tok123

# --- Auth header --------------------------------------------------------------

hdr=$(env -u JIRA_EMAIL -u JIRA_API_KEY JIRA_EMAIL=you@company.com JIRA_API_KEY=tok123 bash -c '
    source "'"$SCRIPT_DIR"'/jira-credentials.sh"
    jira_credentials_auth_header
' 2>/dev/null)
expected_hdr=$(printf '%s' 'you@company.com:tok123' | base64 | tr -d '\n')
if [[ "$hdr" == "$expected_hdr" ]]; then
    pass "auth header is base64 of the resolved pair"
else
    fail "auth header is base64 of the resolved pair" "expected '$expected_hdr', got '$hdr'"
fi

# The header must carry no trailing newline — it is interpolated straight into
# an HTTP header value.
if [[ "$hdr" != *$'\n'* ]]; then
    pass "auth header contains no newline"
else
    fail "auth header contains no newline"
fi

# --- Missing-variable reporting ------------------------------------------------

missing=$(env -u JIRA_EMAIL -u JIRA_API_KEY -u JIRA_DOMAIN bash -c '
    source "'"$SCRIPT_DIR"'/jira-credentials.sh"
    jira_credentials_missing_vars
' 2>/dev/null | tr '\n' ' ')
if [[ "$missing" == *JIRA_DOMAIN* && "$missing" == *JIRA_EMAIL* && "$missing" == *JIRA_API_KEY* ]]; then
    pass "missing_vars lists all three when nothing is set"
else
    fail "missing_vars lists all three when nothing is set" "got '$missing'"
fi

missing=$(env -u JIRA_EMAIL -u JIRA_API_KEY -u JIRA_DOMAIN \
    JIRA_DOMAIN=example.atlassian.net JIRA_API_KEY=you@company.com:tok bash -c '
    source "'"$SCRIPT_DIR"'/jira-credentials.sh"
    jira_credentials_missing_vars
' 2>/dev/null | tr -d '[:space:]')
if [[ -z "$missing" ]]; then
    pass "missing_vars is empty for the legacy combined form"
else
    fail "missing_vars is empty for the legacy combined form" "got '$missing'"
fi

missing=$(env -u JIRA_EMAIL -u JIRA_API_KEY -u JIRA_DOMAIN \
    JIRA_DOMAIN=example.atlassian.net JIRA_API_KEY=tok bash -c '
    source "'"$SCRIPT_DIR"'/jira-credentials.sh"
    jira_credentials_missing_vars
' 2>/dev/null | tr -d '[:space:]')
if [[ "$missing" == "JIRA_EMAIL" ]]; then
    pass "missing_vars names JIRA_EMAIL for a bare token"
else
    fail "missing_vars names JIRA_EMAIL for a bare token" "got '$missing'"
fi

# --- Deprecation warning -------------------------------------------------------

warn_out=$(env -u JIRA_EMAIL -u JIRA_API_KEY JIRA_API_KEY=you@company.com:tok bash -c '
    source "'"$SCRIPT_DIR"'/jira-credentials.sh"
    jira_credentials_warn_if_legacy
    jira_credentials_warn_if_legacy
' 2>&1 >/dev/null)
warn_count=$(grep -c 'deprecated' <<<"$warn_out")
if [[ "$warn_count" -eq 1 ]]; then
    pass "legacy warning is emitted exactly once per process"
else
    fail "legacy warning is emitted exactly once per process" "matched $warn_count times in: $warn_out"
fi

stdout_out=$(env -u JIRA_EMAIL -u JIRA_API_KEY JIRA_API_KEY=you@company.com:tok bash -c '
    source "'"$SCRIPT_DIR"'/jira-credentials.sh"
    jira_credentials_warn_if_legacy
' 2>/dev/null)
if [[ -z "$stdout_out" ]]; then
    pass "legacy warning writes nothing to stdout"
else
    fail "legacy warning writes nothing to stdout" "got '$stdout_out'"
fi

quiet_out=$(env -u JIRA_EMAIL -u JIRA_API_KEY JIRA_EMAIL=you@company.com JIRA_API_KEY=tok bash -c '
    source "'"$SCRIPT_DIR"'/jira-credentials.sh"
    jira_credentials_warn_if_legacy
' 2>&1)
if [[ -z "$quiet_out" ]]; then
    pass "split form warns about nothing"
else
    fail "split form warns about nothing" "got '$quiet_out'"
fi

half_out=$(env -u JIRA_EMAIL -u JIRA_API_KEY \
    JIRA_EMAIL=you@company.com JIRA_API_KEY=you@company.com:tok bash -c '
    source "'"$SCRIPT_DIR"'/jira-credentials.sh"
    jira_credentials_warn_if_legacy
' 2>&1 >/dev/null)
if grep -q 'still starts with' <<<"$half_out"; then
    pass "half-migrated form gets its own warning"
else
    fail "half-migrated form gets its own warning" "got '$half_out'"
fi

# Resolution itself must stay silent: callers capture it with 2>&1 into jq.
noise=$(env -u JIRA_EMAIL -u JIRA_API_KEY JIRA_API_KEY=you@company.com:tok bash -c '
    source "'"$SCRIPT_DIR"'/jira-credentials.sh"
    jira_credentials_pair >/dev/null
    jira_credentials_auth_header >/dev/null
' 2>&1)
if [[ -z "$noise" ]]; then
    pass "resolution path writes nothing to stderr"
else
    fail "resolution path writes nothing to stderr" "got '$noise'"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
