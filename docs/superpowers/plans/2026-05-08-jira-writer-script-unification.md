# jira-writer Script Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate three failure modes in the jira-writer skill's first invocations (versioned absolute path, two CLI entry points, function-name typos) by unifying scripts, adding alias tolerance, and switching SKILL.md examples to `$CLAUDE_PLUGIN_ROOT`.

**Architecture:** `jira-rest-api.sh` becomes a pure sourceable library (CLI dispatch removed). `jira-api-wrapper.sh` gains an `normalize_op()` function that resolves aliases (verb-only, `jira_*` prefix, camelCase) and a `suggest_op()` function for "did you mean?" hints. SKILL.md examples are rewritten to use `$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh`.

**Tech Stack:** Bash, jq, curl. Tests are pure bash (no bats dependency) using a minimal `assert_eq` helper.

**Working directory for all tasks:** `/Users/yunid.bauza/Projects/yunid/claude-kit/plugins/jira-writer/skills/jira-writer/`

**Branch:** `feat/jira-writer-script-unification` (already checked out)

**Spec:** `docs/superpowers/specs/2026-05-08-jira-writer-script-unification-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `scripts/jira-rest-api.sh` | Modify | Remove `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` block at the bottom (lines ~511 to EOF). Becomes library-only. |
| `scripts/jira-api-wrapper.sh` | Modify | Add `normalize_op()`, `suggest_op()`, `KNOWN_OPS` array, `BASH_SOURCE` guard around dispatch, and `$CLAUDE_PLUGIN_ROOT` warning. Apply normalization before the existing `case`. |
| `scripts/test-wrapper-dispatch.sh` | Create | Bash test runner exercising `normalize_op` and `suggest_op` directly via sourcing. ~80 lines. |
| `SKILL.md` | Modify | Trim "Low-level" guidance for `jira-rest-api.sh`; replace every `./scripts/...` with `"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/..."`. |
| `plugin.json` | Modify | Bump version to `1.2.0`. |

---

## Task 1: Test harness — write failing tests for normalize_op

**Files:**
- Create: `scripts/test-wrapper-dispatch.sh`

The wrapper currently has no extracted normalize function and no `BASH_SOURCE` guard, so this test will fail to source cleanly. That's the desired starting failure.

- [ ] **Step 1: Create the test file**

Write `scripts/test-wrapper-dispatch.sh`:

```bash
#!/usr/bin/env bash
# Tests for jira-api-wrapper.sh dispatch helpers.
# Sources the wrapper and exercises normalize_op / suggest_op directly.
# Run: bash scripts/test-wrapper-dispatch.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        printf "PASS  %s\n" "$label"
    else
        FAIL=$((FAIL + 1))
        printf "FAIL  %s\n        expected: %q\n        actual:   %q\n" \
            "$label" "$expected" "$actual"
    fi
}

# Source the wrapper in test mode (skips dispatch).
JIRA_WRAPPER_TEST_MODE=1
export JIRA_WRAPPER_TEST_MODE
# shellcheck source=jira-api-wrapper.sh
source "$SCRIPT_DIR/jira-api-wrapper.sh"

# --- normalize_op: identity for canonical ops ---
assert_eq "canonical get_issue passes through" "get_issue" "$(normalize_op get_issue)"
assert_eq "canonical create_issue passes through" "create_issue" "$(normalize_op create_issue)"
assert_eq "canonical search_jql passes through" "search_jql" "$(normalize_op search_jql)"

# --- normalize_op: jira_ prefix strip ---
assert_eq "strip jira_ prefix get" "get_issue" "$(normalize_op jira_get_issue)"
assert_eq "strip jira_ prefix create" "create_issue" "$(normalize_op jira_create_issue)"
assert_eq "strip jira_ prefix search" "search_jql" "$(normalize_op jira_search_jql)"

# --- normalize_op: camelCase to snake_case ---
assert_eq "camelCase getIssue" "get_issue" "$(normalize_op getIssue)"
assert_eq "camelCase createIssue" "create_issue" "$(normalize_op createIssue)"
assert_eq "camelCase getProjects" "get_projects" "$(normalize_op getProjects)"

# --- normalize_op: verb-only aliases ---
assert_eq "alias issue -> get_issue" "get_issue" "$(normalize_op issue)"
assert_eq "alias create -> create_issue" "create_issue" "$(normalize_op create)"
assert_eq "alias update -> update_issue" "update_issue" "$(normalize_op update)"
assert_eq "alias comment -> add_comment" "add_comment" "$(normalize_op comment)"
assert_eq "alias search -> search_jql" "search_jql" "$(normalize_op search)"
assert_eq "alias jql -> search_jql" "search_jql" "$(normalize_op jql)"
assert_eq "alias projects -> get_projects" "get_projects" "$(normalize_op projects)"
assert_eq "alias types -> get_issue_types" "get_issue_types" "$(normalize_op types)"
assert_eq "alias transitions -> get_transitions" "get_transitions" "$(normalize_op transitions)"
assert_eq "alias transition -> transition_issue" "transition_issue" "$(normalize_op transition)"
assert_eq "alias user -> lookup_user" "lookup_user" "$(normalize_op user)"
assert_eq "alias attach -> upload_attachment" "upload_attachment" "$(normalize_op attach)"
assert_eq "alias upload -> upload_attachment" "upload_attachment" "$(normalize_op upload)"
assert_eq "alias links -> get_remote_links" "get_remote_links" "$(normalize_op links)"
assert_eq "alias test -> test_connection" "test_connection" "$(normalize_op test)"

# --- normalize_op: unknown returns input unchanged ---
assert_eq "unknown op passes through unchanged" "notarealop" "$(normalize_op notarealop)"

# --- suggest_op: returns at least one canonical op for typo ---
suggestion="$(suggest_op get_isue)"
case "$suggestion" in
    *get_issue*) printf "PASS  suggest_op get_isue includes get_issue\n"; PASS=$((PASS + 1)) ;;
    *) printf "FAIL  suggest_op get_isue did not include get_issue (got: %q)\n" "$suggestion"; FAIL=$((FAIL + 1)) ;;
esac

suggestion="$(suggest_op projct)"
case "$suggestion" in
    *get_projects*) printf "PASS  suggest_op projct includes get_projects\n"; PASS=$((PASS + 1)) ;;
    *) printf "FAIL  suggest_op projct did not include get_projects (got: %q)\n" "$suggestion"; FAIL=$((FAIL + 1)) ;;
esac

# --- summary ---
echo
printf "Total: %d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
```

Make it executable:

```bash
chmod +x scripts/test-wrapper-dispatch.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run from the skill dir:

```bash
cd /Users/yunid.bauza/Projects/yunid/claude-kit/plugins/jira-writer/skills/jira-writer
bash scripts/test-wrapper-dispatch.sh
```

Expected: failure. Likely modes:
- The wrapper's top-level code runs the dispatch with no args, prints usage, and exits 1 during `source` — the test runner halts before any assertion.
- Or sourcing succeeds but `normalize_op: command not found` for every assertion.

Either is acceptable as a starting "red" — the function does not exist yet.

- [ ] **Step 3: Commit the failing test**

```bash
git add scripts/test-wrapper-dispatch.sh
git commit -m "test: harness for jira-api-wrapper dispatch helpers (failing)"
```

---

## Task 2: Add BASH_SOURCE guard and stub normalize_op / suggest_op

**Files:**
- Modify: `scripts/jira-api-wrapper.sh`

Goal: make sourcing the wrapper safe (skip dispatch) and define the two functions as no-op stubs that the canonical-passes-through tests will satisfy. Aliases come in Task 4.

- [ ] **Step 1: Wrap the dispatch in a `BASH_SOURCE` guard**

In `scripts/jira-api-wrapper.sh`, find the block starting at the operation parsing (around line 535–547, the `if [[ $# -eq 0 ]]; then print_usage; exit 1; fi` and the `case "$operation"`). Wrap *everything from that point to EOF* in:

```bash
# Only run dispatch when invoked directly (not sourced for testing).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ -z "${JIRA_WRAPPER_TEST_MODE:-}" ]]; then
    # ... existing dispatch code ...
fi
```

Concretely: locate the line `if [[ $# -eq 0 ]]; then` near the bottom, prepend the guard `if` above it, and add the closing `fi` after the final `esac`.

- [ ] **Step 2: Define stub helper functions above the dispatch**

Insert *before* the dispatch guard, after the existing op_* function definitions:

```bash
# --- Operation name normalization ---

# Canonical operation names. Order matters for suggest_op output.
KNOWN_OPS=(
    get_issue
    create_issue
    update_issue
    add_comment
    get_transitions
    transition_issue
    search_jql
    get_projects
    get_issue_types
    lookup_user
    add_worklog
    upload_attachment
    get_remote_links
    test_connection
)

# normalize_op INPUT
# Stub: returns input unchanged. Real aliases land in Task 4.
normalize_op() {
    printf '%s\n' "$1"
}

# suggest_op INPUT
# Returns up to 2 canonical ops most similar to INPUT, comma-separated.
# Stub: returns first two known ops. Real ranking lands in Task 5.
suggest_op() {
    printf '%s, %s\n' "${KNOWN_OPS[0]}" "${KNOWN_OPS[1]}"
}
```

- [ ] **Step 3: Run tests to verify partial pass**

```bash
bash scripts/test-wrapper-dispatch.sh
```

Expected: the three "canonical X passes through" tests PASS. The "unknown op passes through" test PASSes. All alias tests still FAIL (stub returns input unchanged for those). Both `suggest_op` tests likely FAIL (stub returns wrong ops). This is the expected intermediate state.

- [ ] **Step 4: Commit**

```bash
git add scripts/jira-api-wrapper.sh
git commit -m "refactor(jira-writer): add BASH_SOURCE guard and stub normalize_op/suggest_op"
```

---

## Task 3: Make jira-rest-api.sh library-only

**Files:**
- Modify: `scripts/jira-rest-api.sh`

The script currently dispatches to functions when run directly. Removing the dispatch leaves it sourceable-only and eliminates the wrong-script class of failure described in the spec.

- [ ] **Step 1: Remove the CLI dispatch block**

Open `scripts/jira-rest-api.sh`, find the comment `# --- Main entry point for CLI usage ---` near the bottom (around line 510). Delete that comment and everything below it through the end of file (the `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` block, including its closing `fi`).

The file should now end with the closing `}` of the last function (`jira_test_connection`).

- [ ] **Step 2: Verify the file is still valid bash and sourceable**

```bash
bash -n scripts/jira-rest-api.sh && echo "syntax OK"
```

Expected output: `syntax OK`

```bash
bash -c 'source scripts/jira-rest-api.sh && declare -F jira_get_issue'
```

Expected: prints `jira_get_issue` (function exists after sourcing).

- [ ] **Step 3: Verify direct invocation no longer dispatches**

```bash
bash scripts/jira-rest-api.sh anything 2>&1 || true
echo "exit: $?"
```

Expected: no output from the script (no usage banner, no "Unknown function" error). Exit code 0. The script defines functions but does nothing else.

- [ ] **Step 4: Verify the wrapper still works**

```bash
bash scripts/jira-api-wrapper.sh 2>&1 | head -3
```

Expected: the wrapper's usage banner (still works because it sources `jira-rest-api.sh` for the function definitions, not its dispatch).

- [ ] **Step 5: Run the wrapper test harness — should still be at the same partial-pass state**

```bash
bash scripts/test-wrapper-dispatch.sh
```

Expected: same pass/fail counts as end of Task 2.

- [ ] **Step 6: Commit**

```bash
git add scripts/jira-rest-api.sh
git commit -m "refactor(jira-writer): make jira-rest-api.sh library-only

Removes the CLI dispatch block. The script is now sourceable-only;
all CLI access goes through jira-api-wrapper.sh."
```

---

## Task 4: Implement alias normalization

**Files:**
- Modify: `scripts/jira-api-wrapper.sh`

Replace the `normalize_op` stub with the real alias map.

- [ ] **Step 1: Replace `normalize_op` with the full implementation**

In `scripts/jira-api-wrapper.sh`, replace the stub `normalize_op` function with:

```bash
# normalize_op INPUT
# Returns the canonical operation name for INPUT.
# Resolution order:
#   1. Already canonical -> return as-is.
#   2. Strip leading "jira_" prefix.
#   3. Convert camelCase to snake_case.
#   4. Map verb-only aliases to canonical ops.
#   5. Unknown -> return input unchanged (caller decides).
normalize_op() {
    local op="$1"

    # 1. Canonical match.
    local known
    for known in "${KNOWN_OPS[@]}"; do
        if [[ "$op" == "$known" ]]; then
            printf '%s\n' "$op"
            return 0
        fi
    done

    # 2. Strip leading "jira_" prefix.
    if [[ "$op" == jira_* ]]; then
        local stripped="${op#jira_}"
        for known in "${KNOWN_OPS[@]}"; do
            if [[ "$stripped" == "$known" ]]; then
                printf '%s\n' "$stripped"
                return 0
            fi
        done
        op="$stripped"
    fi

    # 3. camelCase -> snake_case (insert _ before each upper, then lowercase).
    if [[ "$op" =~ [A-Z] ]]; then
        local snake
        snake=$(printf '%s' "$op" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr '[:upper:]' '[:lower:]')
        for known in "${KNOWN_OPS[@]}"; do
            if [[ "$snake" == "$known" ]]; then
                printf '%s\n' "$snake"
                return 0
            fi
        done
        op="$snake"
    fi

    # 4. Verb-only aliases.
    case "$op" in
        issue|get)              printf 'get_issue\n'; return 0 ;;
        create)                 printf 'create_issue\n'; return 0 ;;
        update)                 printf 'update_issue\n'; return 0 ;;
        comment)                printf 'add_comment\n'; return 0 ;;
        search|jql)             printf 'search_jql\n'; return 0 ;;
        projects)               printf 'get_projects\n'; return 0 ;;
        types|issue_types)      printf 'get_issue_types\n'; return 0 ;;
        transitions)            printf 'get_transitions\n'; return 0 ;;
        transition)             printf 'transition_issue\n'; return 0 ;;
        user|users|lookup)      printf 'lookup_user\n'; return 0 ;;
        worklog)                printf 'add_worklog\n'; return 0 ;;
        attach|attachment|upload) printf 'upload_attachment\n'; return 0 ;;
        links|remote_links)     printf 'get_remote_links\n'; return 0 ;;
        test|ping)              printf 'test_connection\n'; return 0 ;;
    esac

    # 5. Unknown — return input unchanged.
    printf '%s\n' "$1"
}
```

- [ ] **Step 2: Run the tests**

```bash
bash scripts/test-wrapper-dispatch.sh
```

Expected: every `normalize_op` test PASSes (canonical, prefix strip, camelCase, all verb aliases, unknown passthrough). The two `suggest_op` tests still FAIL (stub).

- [ ] **Step 3: Apply normalization in the dispatch**

Find the dispatch block (now inside the `BASH_SOURCE` guard from Task 2). Right after the line `operation="$1"; shift`, insert:

```bash
operation="$(normalize_op "$operation")"
```

So the case statement now branches on the normalized name.

- [ ] **Step 4: Smoke-test the dispatch (no API call)**

```bash
bash scripts/jira-api-wrapper.sh issue 2>&1
```

Expected: `Error: get_issue requires issue key` (because the alias `issue` resolved to `get_issue` and then hit the existing arg-count check). Exit code 1.

```bash
bash scripts/jira-api-wrapper.sh getIssue 2>&1
```

Expected: same — `Error: get_issue requires issue key`.

```bash
bash scripts/jira-api-wrapper.sh jira_get_projects 2>&1 | head -3
```

Expected: real API call (or `JIRA_DOMAIN/JIRA_API_KEY` setup error), not "Unknown operation". This proves the alias resolved.

- [ ] **Step 5: Commit**

```bash
git add scripts/jira-api-wrapper.sh
git commit -m "feat(jira-writer): normalize op aliases before dispatch

Wrapper now accepts: canonical names, jira_ prefix, camelCase, and
verb-only short forms (issue, create, comment, search, projects, etc.).
Resolves the function-name typo class of failure."
```

---

## Task 5: Implement "did you mean?" suggestions

**Files:**
- Modify: `scripts/jira-api-wrapper.sh`

Replace the `suggest_op` stub with a real prefix-and-substring ranking. Wire it into the unknown-op error path with exit code 2.

- [ ] **Step 1: Replace `suggest_op` with the real implementation**

```bash
# suggest_op INPUT
# Prints the 2 canonical ops most similar to INPUT, comma-separated.
# Ranking: shared prefix length DESC, then substring containment, then alpha.
suggest_op() {
    local input="$1"
    local op prefix_len shared best=""

    # Build "score op" lines, sort, take top 2.
    local scored=""
    for op in "${KNOWN_OPS[@]}"; do
        # Shared prefix length.
        prefix_len=0
        local i max=${#input}
        [[ ${#op} -lt $max ]] && max=${#op}
        for ((i = 0; i < max; i++)); do
            [[ "${input:$i:1}" == "${op:$i:1}" ]] || break
            prefix_len=$((prefix_len + 1))
        done

        # Substring bonus (input is contained in op, or vice versa).
        local substring_bonus=0
        if [[ "$op" == *"$input"* ]] || [[ -n "$input" && "$input" == *"$op"* ]]; then
            substring_bonus=5
        fi

        local score=$((prefix_len * 10 + substring_bonus))
        scored+=$(printf '%04d %s\n' "$score" "$op")$'\n'
    done

    # Sort by score DESC, take top 2 op names.
    printf '%s' "$scored" | sort -r | head -n 2 | awk '{print $2}' | paste -sd, -
}
```

- [ ] **Step 2: Wire suggest_op into the unknown-op error**

Find the `*)` arm of the dispatch `case`:

```bash
    *)
        echo "Error: Unknown operation '$operation'" >&2
        print_usage
        exit 1
        ;;
```

Replace with (the dispatch lives at the top level, inside the `BASH_SOURCE` guard from Task 2 — not in a function — so do not use `local`):

```bash
    *)
        suggestion="$(suggest_op "$operation")"
        echo "Unknown operation '$operation'." >&2
        if [[ -n "$suggestion" ]]; then
            echo "Did you mean: ${suggestion}?" >&2
        fi
        echo "Run with no arguments to see full usage." >&2
        exit 2
        ;;
```

- [ ] **Step 3: Run the test harness**

```bash
bash scripts/test-wrapper-dispatch.sh
```

Expected: all tests PASS, including both `suggest_op` tests. Final line: `Total: N passed, 0 failed`.

- [ ] **Step 4: Smoke-test unknown-op behavior**

```bash
bash scripts/jira-api-wrapper.sh notarealop 2>&1; echo "exit: $?"
```

Expected output:

```
Unknown operation 'notarealop'.
Did you mean: <some_op>, <some_op>?
Run with no arguments to see full usage.
exit: 2
```

```bash
bash scripts/jira-api-wrapper.sh get_isue 2>&1; echo "exit: $?"
```

Expected: suggestion includes `get_issue`. Exit code 2.

- [ ] **Step 5: Commit**

```bash
git add scripts/jira-api-wrapper.sh
git commit -m "feat(jira-writer): suggest closest op on unknown input (exit 2)"
```

---

## Task 6: Add CLAUDE_PLUGIN_ROOT verification gate and warning

**Files:**
- Modify: `scripts/jira-api-wrapper.sh`

Per the spec: confirm `$CLAUDE_PLUGIN_ROOT` is populated when a plugin skill runs; if not, fall back gracefully. Add a non-fatal stderr warning when the env var is unset *and* the script wasn't invoked under a path containing `/plugins/cache/`. This catches plugin-runtime regressions without breaking direct invocations.

- [ ] **Step 1: Verify $CLAUDE_PLUGIN_ROOT is populated for plugin skills on this machine**

Quick check: run any wrapper command under conditions where the env var should be set, and confirm it is. From a fresh Claude Code session running the jira-writer skill, run `echo "CLAUDE_PLUGIN_ROOT=$CLAUDE_PLUGIN_ROOT"` via Bash. Two outcomes:

- **Set** (e.g., `CLAUDE_PLUGIN_ROOT=/Users/.../plugins/cache/claude-kit/jira-writer/1.1.0`): proceed with this task as written.
- **Unset or empty:** stop here, report back, and revisit. The SKILL.md change in Task 7 will need to use a different version-stable mechanism (e.g., the literal "Base directory for this skill" line guidance) instead.

Document the outcome inline in this checkbox before continuing.

- [ ] **Step 2: Add the warning at the top of the dispatch block**

In `scripts/jira-api-wrapper.sh`, immediately *inside* the `BASH_SOURCE` guard (so it runs only on direct invocation, not when sourced), before the existing `if [[ $# -eq 0 ]]` arg check, insert:

```bash
# Plugin-runtime sanity warning.
# When invoked from a plugin skill, $CLAUDE_PLUGIN_ROOT should be set
# and the script's path should contain /plugins/cache/. If neither is
# true, warn (but do not fail) — direct invocations remain valid.
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]] && [[ "${BASH_SOURCE[0]}" != *"/plugins/cache/"* ]]; then
    echo "[WARN] CLAUDE_PLUGIN_ROOT is unset and script is not under /plugins/cache/." >&2
    echo "[WARN] If you invoked this from a Claude Code skill, the plugin runtime may have changed." >&2
fi
```

- [ ] **Step 3: Verify the warning fires only when expected**

Direct invocation from inside the plugin cache (path matches): no warning expected.

```bash
unset CLAUDE_PLUGIN_ROOT
bash /tmp/some-copy-of/jira-api-wrapper.sh 2>&1 | head -5
```

(Manually copy the script to `/tmp` first if you want to exercise the warning path.) Expected: warning lines appear when the path is *not* under `/plugins/cache/` and the env var is unset.

```bash
CLAUDE_PLUGIN_ROOT=/fake bash scripts/jira-api-wrapper.sh 2>&1 | head -5
```

Expected: no warning (env var is set). Usage banner prints normally.

- [ ] **Step 4: Re-run the test harness to confirm no regression**

```bash
bash scripts/test-wrapper-dispatch.sh
```

Expected: all tests still PASS. (The warning runs only inside the dispatch guard, so it does not fire during sourced tests.)

- [ ] **Step 5: Commit**

```bash
git add scripts/jira-api-wrapper.sh
git commit -m "feat(jira-writer): warn when CLAUDE_PLUGIN_ROOT is unset off-cache"
```

---

## Task 7: Update SKILL.md

**Files:**
- Modify: `SKILL.md`

Apply two sweeping edits: trim `jira-rest-api.sh` CLI guidance, and swap script-invocation examples to `$CLAUDE_PLUGIN_ROOT`.

- [ ] **Step 1: Trim the Script Selection Guide table**

In `SKILL.md`, find the section "#### Script Selection Guide" and the table beneath it. Replace the entire table and the "IMPORTANT:" sentence below it with:

```markdown
All operations go through `jira-api-wrapper.sh`. The low-level functions in `jira-rest-api.sh` are sourced by the wrapper and are not invoked directly.
```

- [ ] **Step 2: Remove the `jira-rest-api.sh` "Low-level" code block**

Find the `**jira-rest-api.sh** (Low-level - advanced use only)` heading and the bash code block that follows it (about 6 lines, ending before "#### Diagnostic Scripts"). Delete the heading and the entire code block.

- [ ] **Step 3: Replace every `./scripts/...` invocation with `$CLAUDE_PLUGIN_ROOT/...`**

Use a single `find`-and-replace pass across `SKILL.md`. The pattern to replace:

- `./scripts/jira-api-wrapper.sh` → `"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh"`
- `./scripts/jira-mermaid-upload.sh` → `"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-mermaid-upload.sh"`
- `./scripts/jira-mermaid-batch-upload.sh` → `"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-mermaid-batch-upload.sh"`
- `./scripts/test-jira-connection.sh` → `"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/test-jira-connection.sh"`
- `./scripts/check-prerequisites.sh` → `"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/check-prerequisites.sh"`

Use the Edit tool with `replace_all: true` for each. Note the leading and trailing double-quote characters — they protect against spaces in expanded paths.

- [ ] **Step 4: Verify no stale references remain**

```bash
cd /Users/yunid.bauza/Projects/yunid/claude-kit/plugins/jira-writer/skills/jira-writer
grep -n "\./scripts/" SKILL.md && echo "FOUND — fix above"  || echo "clean"
grep -n "jira-rest-api\.sh" SKILL.md
```

Expected: first command prints `clean`. Second command prints lines that mention `jira-rest-api.sh` only as a passing reference ("sourced by the wrapper"); none should describe it as a CLI.

- [ ] **Step 5: Commit**

```bash
git add SKILL.md
git commit -m "docs(jira-writer): use \$CLAUDE_PLUGIN_ROOT in script examples

Removes versioned/relative path examples that the model regenerates
from memory (and gets wrong on version bumps). Trims jira-rest-api.sh
guidance now that it is library-only."
```

---

## Task 8: Bump plugin version and final verification

**Files:**
- Modify: `plugins/jira-writer/.claude-plugin/plugin.json`

- [ ] **Step 1: Bump version**

Edit `plugins/jira-writer/.claude-plugin/plugin.json`. Find the `"version": "1.1.0"` field and change it to `"version": "1.2.0"`.

- [ ] **Step 2: Final test run**

```bash
cd /Users/yunid.bauza/Projects/yunid/claude-kit/plugins/jira-writer/skills/jira-writer
bash scripts/test-wrapper-dispatch.sh
```

Expected: all tests pass.

```bash
bash -n scripts/jira-api-wrapper.sh && bash -n scripts/jira-rest-api.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 3: Final smoke tests**

```bash
bash scripts/jira-api-wrapper.sh issue 2>&1                 # alias resolves
bash scripts/jira-api-wrapper.sh jira_get_issue 2>&1        # prefix strip
bash scripts/jira-api-wrapper.sh getIssue 2>&1              # camelCase
bash scripts/jira-api-wrapper.sh notarealop 2>&1; echo "exit: $?"  # did-you-mean, exit 2
bash scripts/jira-rest-api.sh anything 2>&1; echo "exit: $?"       # library-only, exit 0
```

Expected behaviors:
- Aliases land on `Error: get_issue requires issue key` (alias resolved, then arg-count check).
- Unknown op prints "Did you mean: …?" and exits 2.
- `jira-rest-api.sh` produces no output and exits 0.

- [ ] **Step 4: Commit version bump**

```bash
cd /Users/yunid.bauza/Projects/yunid/claude-kit
git add plugins/jira-writer/.claude-plugin/plugin.json
git commit -m "chore: bump jira-writer to v1.2.0

Unifies CLI entry point, adds alias/typo tolerance, switches SKILL.md
examples to \$CLAUDE_PLUGIN_ROOT. See spec
docs/superpowers/specs/2026-05-08-jira-writer-script-unification-design.md."
```

- [ ] **Step 5: Push branch (do not merge — leave PR creation to user)**

```bash
git push -u origin feat/jira-writer-script-unification
```

Stop here. The user will open the PR.

---

## Acceptance Checklist (re-run after Task 8)

Mirror of the spec's acceptance section. Confirm each:

- [ ] `bash scripts/jira-api-wrapper.sh issue GRAC-XXX` resolves the alias (errors only if API call fails, not "Unknown operation").
- [ ] `bash scripts/jira-api-wrapper.sh jira_get_issue GRAC-XXX` resolves via prefix strip.
- [ ] `bash scripts/jira-api-wrapper.sh getIssue GRAC-XXX` resolves via camelCase.
- [ ] `bash scripts/jira-api-wrapper.sh notarealop` exits 2 with "Did you mean: …".
- [ ] `bash scripts/jira-rest-api.sh anything` does not dispatch (no output, exit 0).
- [ ] `grep -E '\./scripts/' SKILL.md` returns nothing.
- [ ] `bash scripts/test-wrapper-dispatch.sh` reports zero failures.
