#!/usr/bin/env bash
#
# test-bin-launcher.sh
#
# Regression test for the root cause behind the recurring
# "$CLAUDE_PLUGIN_ROOT isn't exported into the Bash shell" message:
# $CLAUDE_PLUGIN_ROOT is NEVER present in the Bash tool shell (it is exported
# only to hook/MCP subprocesses), so SKILL.md must invoke the plugin's scripts
# by BARE NAME via the plugin's bin/ directory (which Claude Code auto-adds to
# PATH), not via "$CLAUDE_PLUGIN_ROOT/...".
#
# This test proves the bin/jira-writer dispatcher works with CLAUDE_PLUGIN_ROOT
# unset, from an unrelated working directory, and that SKILL.md no longer tells
# the model to use the unset variable.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts -> jira-writer(skill) -> skills -> jira-writer(plugin root) -> bin
BIN_DIR="$(cd "$SCRIPT_DIR/../../../bin" 2>/dev/null && pwd || true)"
SKILL_MD="$SCRIPT_DIR/../SKILL.md"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf "PASS  %s\n" "$1"; }
fail() {
    FAIL=$((FAIL + 1))
    printf "FAIL  %s\n" "$1"
    [[ -n "${2:-}" ]] && printf "        %s\n" "$2"
}

# --- The dispatcher must exist and be executable -----------------------------
LAUNCHER="$BIN_DIR/jira-writer"
if [[ -n "$BIN_DIR" && -f "$LAUNCHER" ]]; then
    pass "bin/jira-writer exists"
else
    fail "bin/jira-writer exists" "expected launcher at: ${BIN_DIR:-<bin dir missing>}/jira-writer"
fi
if [[ -x "$LAUNCHER" ]]; then
    pass "bin/jira-writer is executable"
else
    fail "bin/jira-writer is executable" "not +x: $LAUNCHER"
fi

# --- Core fix: bare-name dispatch with CLAUDE_PLUGIN_ROOT UNSET, foreign cwd --
# Uses the wrapper's DRY_RUN short-circuit so no creds/network are needed.
# Proves: PATH lookup found the launcher, the launcher self-located and exec'd
# jira-api-wrapper.sh, the wrapper sourced its sibling jira-rest-api.sh, and the
# op handler ran — all without $CLAUDE_PLUGIN_ROOT.
if [[ -x "$LAUNCHER" ]]; then
    out=$(
        cd /tmp || exit 99
        unset CLAUDE_PLUGIN_ROOT
        PATH="$BIN_DIR:$PATH" JIRA_WRITER_DRY_RUN=1 \
            jira-writer create_issue PROJ Task "Hello from PATH" 2>/dev/null
    )
    rc=$?
    summary=$(printf '%s' "$out" | jq -r '.fields.summary // empty' 2>/dev/null)
    if [[ $rc -eq 0 && "$summary" == "Hello from PATH" ]]; then
        pass "bare-name dispatch works (CLAUDE_PLUGIN_ROOT unset, foreign cwd)"
    else
        fail "bare-name dispatch works (CLAUDE_PLUGIN_ROOT unset, foreign cwd)" \
            "rc=$rc summary='$summary' out='$out'"
    fi

    # No-arg passthrough reaches the wrapper's usage (proves default routing).
    out=$(
        unset CLAUDE_PLUGIN_ROOT
        PATH="$BIN_DIR:$PATH" jira-writer 2>&1
    )
    if [[ "$out" == *"Operations:"* ]]; then
        pass "no-arg dispatch reaches wrapper usage"
    else
        fail "no-arg dispatch reaches wrapper usage" "out='$out'"
    fi

    # Reserved subcommand routes to the diagnostic script (valid JSON output).
    out=$(
        unset CLAUDE_PLUGIN_ROOT JIRA_DOMAIN JIRA_API_KEY
        PATH="$BIN_DIR:$PATH" jira-writer doctor 2>/dev/null
    )
    if printf '%s' "$out" | jq -e 'has("rest_api")' >/dev/null 2>&1; then
        pass "reserved subcommand 'doctor' routes to check-prerequisites"
    else
        fail "reserved subcommand 'doctor' routes to check-prerequisites" "out='$out'"
    fi
else
    fail "bare-name dispatch works (CLAUDE_PLUGIN_ROOT unset, foreign cwd)" "launcher not executable; skipped"
fi

# --- Every entrypoint the dispatcher can route to must actually exist ---------
for target in \
    jira-api-wrapper.sh \
    check-prerequisites.sh \
    test-jira-connection.sh \
    jira-mermaid-upload.sh \
    jira-mermaid-batch-upload.sh; do
    if [[ -f "$SCRIPT_DIR/$target" ]]; then
        pass "dispatch target exists: $target"
    else
        fail "dispatch target exists: $target" "missing: $SCRIPT_DIR/$target"
    fi
done

# --- SKILL.md must not instruct the model to use the unset variable ----------
if [[ -f "$SKILL_MD" ]]; then
    if grep -q 'CLAUDE_PLUGIN_ROOT/skills' "$SKILL_MD"; then
        n=$(grep -c 'CLAUDE_PLUGIN_ROOT/skills' "$SKILL_MD")
        fail "SKILL.md has no \$CLAUDE_PLUGIN_ROOT script paths" \
            "$n remaining 'CLAUDE_PLUGIN_ROOT/skills...' command reference(s)"
    else
        pass "SKILL.md has no \$CLAUDE_PLUGIN_ROOT script paths"
    fi
    if grep -qE '(^|[^a-zA-Z-])jira-writer (create_issue|get_issue|search_jql|update_issue|add_comment)' "$SKILL_MD"; then
        pass "SKILL.md uses bare-name jira-writer invocation"
    else
        fail "SKILL.md uses bare-name jira-writer invocation" "no bare-name examples found"
    fi
else
    fail "SKILL.md present" "missing: $SKILL_MD"
fi

# --- summary -----------------------------------------------------------------
echo
printf "Total: %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
