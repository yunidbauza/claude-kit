#!/usr/bin/env bash
#
# jira-credentials.sh
#
# Source-only library. Single source of truth for resolving the Jira
# Basic-auth credential pair from the environment.
#
# Preferred form (since 1.11.0) — three variables, one job each:
#   JIRA_DOMAIN   - Jira host, e.g. company.atlassian.net (no scheme, no path)
#   JIRA_EMAIL    - Atlassian account email, e.g. you@company.com
#   JIRA_API_KEY  - the raw API token (NOT base64, no email prefix)
#
# Deprecated form (pre-1.11.0) — still accepted so existing setups keep working:
#   JIRA_API_KEY  - "you@company.com:token", email and token in one variable
#
# NOTHING on the resolution path writes to stderr. Callers capture the output of
# authenticated helpers with `2>&1` and feed the result to jq, so a stray log
# line there would corrupt their JSON. Human-facing deprecation output lives in
# jira_credentials_warn_if_legacy, which CLI entry points call once at startup —
# before any operation whose output gets captured.
#
# Usage:
#   source "$SCRIPT_DIR/jira-credentials.sh"
#   header=$(jira_credentials_auth_header) || { ...; }
#

# Idempotent: sourced by jira-rest-api.sh and, directly, by the standalone
# diagnostics. Loading it twice must not reset the one-shot warning latch.
[[ -n "${_JIRA_CREDENTIALS_SH_LOADED:-}" ]] && return 0
_JIRA_CREDENTIALS_SH_LOADED=1

_JIRA_CREDENTIALS_LEGACY_WARNED=0

# jira_credentials_pair
# Echoes "email:token" on stdout, ready to base64-encode for Basic auth.
# Returns 1 when the environment cannot produce a pair. Silent either way.
jira_credentials_pair() {
    local email="${JIRA_EMAIL:-}"
    local key="${JIRA_API_KEY:-}"

    [[ -z "$key" ]] && return 1

    if [[ -n "$email" ]]; then
        # Half-migrated setup: JIRA_EMAIL is set but JIRA_API_KEY still holds
        # the old "email:token" pair. Drop the duplicated prefix instead of
        # building "email:email:token", which could only ever 401.
        if [[ "$key" == "$email:"* ]]; then
            key="${key#"$email":}"
        fi
        [[ -z "$key" ]] && return 1
        printf '%s:%s\n' "$email" "$key"
        return 0
    fi

    # Deprecated single-variable form: the colon means the email is in there.
    if [[ "$key" == *:* ]]; then
        printf '%s\n' "$key"
        return 0
    fi

    # A bare token with no JIRA_EMAIL is not enough to authenticate.
    return 1
}

# jira_credentials_auth_header
# Echoes the base64 blob for `Authorization: Basic <blob>`. Returns 1 (silently)
# when credentials cannot be resolved.
jira_credentials_auth_header() {
    local pair
    pair=$(jira_credentials_pair) || return 1
    printf '%s' "$pair" | base64 | tr -d '\n'
}

# jira_credentials_available
# 0 when JIRA_DOMAIN is set AND a credential pair resolves.
jira_credentials_available() {
    [[ -n "${JIRA_DOMAIN:-}" ]] || return 1
    jira_credentials_pair >/dev/null 2>&1
}

# jira_credentials_is_legacy
# 0 when the deprecated single-variable form is what supplies the email.
jira_credentials_is_legacy() {
    [[ -z "${JIRA_EMAIL:-}" && "${JIRA_API_KEY:-}" == *:* ]]
}

# jira_credentials_is_half_migrated
# 0 when JIRA_EMAIL is set but JIRA_API_KEY still carries the "email:" prefix.
jira_credentials_is_half_migrated() {
    local email="${JIRA_EMAIL:-}"
    [[ -n "$email" && "${JIRA_API_KEY:-}" == "$email:"* ]]
}

# jira_credentials_missing_vars
# Echoes, one per line, the variables the user still needs to set. Empty output
# means credentials resolve. JIRA_EMAIL is not reported missing when the legacy
# pair already carries it.
jira_credentials_missing_vars() {
    local missing=()
    [[ -z "${JIRA_DOMAIN:-}" ]] && missing+=("JIRA_DOMAIN")
    [[ -z "${JIRA_API_KEY:-}" ]] && missing+=("JIRA_API_KEY")
    if [[ -z "${JIRA_EMAIL:-}" ]] && ! jira_credentials_is_legacy; then
        missing+=("JIRA_EMAIL")
    fi
    # ${arr[@]+...} yields zero words for an empty array under `set -u`.
    printf '%s\n' ${missing[@]+"${missing[@]}"}
}

# jira_credentials_setup_hint
# The canonical setup snippet, for error messages and diagnostics.
jira_credentials_setup_hint() {
    cat <<'HINT'
export JIRA_DOMAIN="company.atlassian.net"   # host only, no https://, no trailing slash
export JIRA_EMAIL="you@company.com"
export JIRA_API_KEY="your_api_token"         # raw token, NOT base64
HINT
}

# jira_credentials_warn_if_legacy
# Emits at most one deprecation notice per process, to stderr. Safe to call from
# CLI entry points; never call it from a path whose output a caller captures.
jira_credentials_warn_if_legacy() {
    [[ "$_JIRA_CREDENTIALS_LEGACY_WARNED" == "1" ]] && return 0

    if jira_credentials_is_legacy; then
        _JIRA_CREDENTIALS_LEGACY_WARNED=1
        {
            echo -e "${YELLOW:-}[WARN]${NC:-} JIRA_API_KEY holding \"email:token\" is deprecated."
            echo "       Split it into two variables instead:"
            echo "         export JIRA_EMAIL=\"you@company.com\""
            echo "         export JIRA_API_KEY=\"your_api_token\"   # raw token only"
            echo "       The combined form still works for now and will be removed in a future release."
        } >&2
        return 0
    fi

    if jira_credentials_is_half_migrated; then
        _JIRA_CREDENTIALS_LEGACY_WARNED=1
        {
            echo -e "${YELLOW:-}[WARN]${NC:-} JIRA_EMAIL is set, but JIRA_API_KEY still starts with \"\$JIRA_EMAIL:\"."
            echo "       Using the token half only. Drop the email prefix from JIRA_API_KEY:"
            echo "         export JIRA_API_KEY=\"your_api_token\"   # raw token only"
        } >&2
        return 0
    fi

    return 0
}
