#!/usr/bin/env bash
#
# test-bin-launcher.sh
#
# Regression test for how SKILL.md invokes the launcher.
#
# Original cause (pre-1.6.0): $CLAUDE_PLUGIN_ROOT is NEVER present in the Bash
# tool shell — it is exported only to hook/MCP subprocesses — so SKILL.md must
# not build script paths from it.
#
# Second cause (1.10.0, Copilot CLI support): the fix at the time (v1.5.2, commit
# 5a96c13; v1.6.0 only restated it) was to invoke by BARE NAME, relying on Claude
# Code auto-adding each plugin's bin/ to PATH. Note the ORIGINAL contract was
# "never build a path from $CLAUDE_PLUGIN_ROOT" — bare names were the mechanism,
# not the requirement — which is why "$JW" still satisfies it.
# Copilot CLI does neither — no bin/ on PATH, and no plugin-root variable in the
# shell at all — so bare-name invocation is unresolvable there. SKILL.md must now
# resolve the launcher into $JW (PATH first, then the Copilot and Claude install
# roots, newest-first) and call "$JW" <op>, which works in both harnesses.
#
# This test proves the bin/jira-writer dispatcher works with CLAUDE_PLUGIN_ROOT
# unset from an unrelated working directory, and that SKILL.md instructs the
# portable form: no $CLAUDE_PLUGIN_ROOT paths, no bare-name commands, a documented
# resolve preamble, and "$JW" call sites.
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
        unset CLAUDE_PLUGIN_ROOT JIRA_DOMAIN JIRA_EMAIL JIRA_API_KEY
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
    # Until 1.10.0 this asserted the opposite — that SKILL.md invoked the launcher by
    # BARE NAME — because Claude Code puts each plugin's bin/ on the Bash tool PATH.
    # Copilot CLI does not: no bin/ on PATH, and no plugin-root variable in the shell,
    # so bare-name examples are `command not found` there 100% of the time. The
    # portable contract is now "resolve into $JW first, then call \"$JW\" <op>", which
    # works in both harnesses. Bare-name examples are therefore a REGRESSION.
    # Deliberately NOT anchored to line-start: indented lines, `$ ` prompts and
    # inline-backtick mentions are bare-name invocations too. Matching an operation
    # (snake_case, or a known bare op) rather than any word keeps prose such as
    # "the jira-writer plugin" from being a false positive.
    BARE_RE="(^|[^A-Za-z0-9/_.\"'-])jira-writer[[:space:]]+([a-z]+_[a-z_]+|doctor|mermaid|mermaid-batch|connection-test)"
    # reference/*.md counts: SKILL.md routes the model into those files, so a
    # bare-name command there fails under Copilot exactly the same way.
    REF_DIR="$(dirname "$SKILL_MD")/reference"
    bare_hits=0
    for doc in "$SKILL_MD" "$REF_DIR"/*.md; do
        [[ -f "$doc" ]] || continue
        n=$(grep -cE "$BARE_RE" "$doc" 2>/dev/null || true)
        if [[ "${n:-0}" -gt 0 ]]; then
            bare_hits=$((bare_hits + n))
            echo "      bare-name in $(basename "$doc"): $n"
        fi
    done
    if [[ "$bare_hits" -eq 0 ]]; then
        pass "no bare-name jira-writer commands in SKILL.md or reference/"
    else
        fail "no bare-name jira-writer commands in SKILL.md or reference/" \
            "$bare_hits example(s) — unresolvable under Copilot CLI; use \"\$JW\" <op>"
    fi

    if grep -qE '"\$JW" (create_issue|get_issue|search_jql|update_issue|add_comment)' "$SKILL_MD"; then
        pass "SKILL.md invokes the launcher through the resolved \$JW"
    else
        fail "SKILL.md invokes the launcher through the resolved \$JW" \
            "no \"\$JW\" <op> examples found"
    fi

    # The resolve preamble itself must stay documented, or the model has no way to
    # populate $JW under Copilot.
    if grep -q 'copilot/installed-plugins' "$SKILL_MD" && grep -q 'command -v jira-writer' "$SKILL_MD"; then
        pass "SKILL.md documents the cross-harness resolve preamble"
    else
        fail "SKILL.md documents the cross-harness resolve preamble" \
            "expected both 'command -v jira-writer' and a ~/.copilot/installed-plugins fallback"
    fi

    # Sequential `ls` calls, not one `ls` with two globs: a single ls sorts all
    # matches together and '.claude' sorts before '.copilot', so Copilot would
    # resolve to a Claude cache copy. And -t keeps newest-first so a stale version
    # never wins. Both are easy to "simplify" away in a later edit.
    if grep -q 'ls -td ~/.copilot/installed-plugins' "$SKILL_MD" &&
       grep -q 'ls -td ~/.claude/plugins/cache' "$SKILL_MD"; then
        pass "resolve preamble uses separate, newest-first (ls -td) lookups"
    else
        fail "resolve preamble uses separate, newest-first (ls -td) lookups" \
            "expected two distinct 'ls -td' calls; a single ls with both globs picks the wrong harness"
    fi
else
    fail "SKILL.md present" "missing: $SKILL_MD"
fi

# --- summary -----------------------------------------------------------------
echo
printf "Total: %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
