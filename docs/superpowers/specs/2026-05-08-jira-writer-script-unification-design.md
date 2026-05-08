# jira-writer Script Unification & Robustness — Design

**Date:** 2026-05-08
**Plugin:** `plugins/jira-writer` (currently v1.1.0)
**Status:** Approved, ready for plan.

## Problem

When the model invokes the `jira-writer` skill, the first 1–3 bash calls frequently fail before a working call lands. Observed transcript:

1. `bash …/jira-writer/1.0.0/skills/jira-writer/scripts/jira-rest-api.sh issue GRAC-880` — wrong version path (was just bumped to 1.1.0).
2. `bash …/1.1.0/…/jira-rest-api.sh issue GRAC-880` — `Unknown function 'issue'`.
3. `bash …/jira-rest-api.sh` — dump usage to discover the real function name.

Three independent failure modes:

- **Versioned absolute path** is reconstructed from model memory; the version digit gets stale on every plugin bump.
- **Two CLI entry points** (`jira-rest-api.sh` and `jira-api-wrapper.sh`) accept overlapping-but-different command names. The model picks the wrong one.
- **Function-name typos.** The model writes `issue` when it means `get_issue` (wrapper) or `jira_get_issue` (low-level), and the script bounces it.

## Goals

1. Eliminate the wrong-script class of failure: exactly one runnable script.
2. Make function-name typos self-correcting via aliases and "did you mean?" hints.
3. Make script paths in `SKILL.md` immune to version bumps.

## Non-goals

- Marketplace cache-path layout changes.
- A globally installed `jira` shim in the user's PATH.
- Changes to mermaid scripts, prerequisites checker, or test-jira-connection.
- Changes to skill behavior, ADF generation, MCP fallback semantics, or any user-facing output beyond error messages.

## Design

Five changes in two files plus `SKILL.md`.

### 1. `jira-rest-api.sh` becomes a pure library

Currently the script is dual-purpose: sourceable (the wrapper sources it) and standalone-runnable (a `case` block at the bottom dispatches CLI args to functions). Remove the standalone CLI dispatch. The functions stay; only the bottom dispatch goes away.

Effect: there is now exactly one runnable script (`jira-api-wrapper.sh`). The model cannot pick the wrong one because there is no other one to pick.

Compatibility: the wrapper continues to `source` this file unchanged. No behavior change for any working call path.

### 2. Alias normalization in `jira-api-wrapper.sh`

Before the dispatch `case`, normalize the operation argument. Apply, in order:

1. Strip a leading `jira_` prefix (`jira_get_issue` → `get_issue`).
2. Convert camelCase to snake_case (`getIssue` → `get_issue`).
3. Map verb-only short forms to canonical operations:

   | Aliases | Canonical |
   |---|---|
   | `issue`, `get` | `get_issue` |
   | `create` | `create_issue` |
   | `update` | `update_issue` |
   | `comment` | `add_comment` |
   | `search`, `jql` | `search_jql` |
   | `projects` | `get_projects` |
   | `types`, `issue_types` | `get_issue_types` |
   | `transitions` | `get_transitions` |
   | `transition` | `transition_issue` |
   | `user`, `users`, `lookup` | `lookup_user` |
   | `worklog` | `add_worklog` |
   | `attach`, `attachment`, `upload` | `upload_attachment` |
   | `links`, `remote_links` | `get_remote_links` |
   | `test`, `ping` | `test_connection` |

   Implemented as a single `case` block in shell — no associative-array bashism required.

If the input matches a canonical op after normalization, dispatch normally.

### 3. "Did you mean?" suggestions on unknown op

If the input does not match a canonical op after normalization, print:

```
Unknown operation 'foo'.
Did you mean: <closest>, <closest>?
Run with no arguments to see full usage.
```

Closest-match algorithm: rank known ops by (a) shared prefix length with the input, then (b) substring containment, then (c) alphabetical. Return top 2. Pure POSIX shell — no `awk`/`python` deps beyond what the script already uses.

Exit code: 2 (distinct from the existing exit-1 cases).

### 4. `SKILL.md` — trim `jira-rest-api.sh` as a CLI

- Remove the "Low-level API access" row from the Script Selection Guide.
- Remove the `jira-rest-api.sh` code block under "Primary Scripts."
- Replace with one line: "All operations go through `jira-api-wrapper.sh`. The low-level functions in `jira-rest-api.sh` are sourced by the wrapper and are not invoked directly."

### 5. `SKILL.md` — swap script-invocation examples to `$CLAUDE_PLUGIN_ROOT`

Replace every example of the form `./scripts/jira-api-wrapper.sh <op> …` with:

```
"$CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh" <op> …
```

Rationale: Claude Code injects `$CLAUDE_PLUGIN_ROOT` into the environment when a plugin skill runs. The path is version-stable; the model copies the env var verbatim instead of reconstructing a versioned absolute path from memory.

**Wrapper guard:** add a one-line check at the top of `jira-api-wrapper.sh` that warns (to stderr, non-fatal) if `$CLAUDE_PLUGIN_ROOT` is unset *and* the invoking path doesn't resolve to a real file under a plugin cache. This catches plugin-runtime regressions early without breaking direct/manual invocations.

**Verification gate during implementation:** before changing `SKILL.md`, confirm `$CLAUDE_PLUGIN_ROOT` is populated when a plugin skill runs on this machine. If it is not populated, fall back to documenting the absolute base path explicitly (still better than `./scripts/...`, which the model expands to a guessed version) and revisit once the env var lands.

## Out of scope

- Mermaid scripts, prerequisites checker, test-connection — untouched.
- The hybrid REST-primary / MCP-fallback decision logic — unchanged.
- Behavior of any operation — unchanged. Only its invocation surface changes.

## Risks

- **`$CLAUDE_PLUGIN_ROOT` may not be set in all contexts.** Mitigated by the verification gate above and the wrapper guard. The script remains directly invokable by absolute path regardless.
- **Alias collisions.** `get` is intentionally aliased to `get_issue` (the most common read), not `get_projects` or `get_transitions`. Documented in the "Did you mean?" output so users discover the others.
- **Removing `jira-rest-api.sh` CLI may break external callers.** No known external callers — this script ships only inside the plugin. Worst-case mitigation: ship a deprecation shim that prints a one-line redirect to the wrapper and exits 0. Not in default scope.

## Acceptance

- `bash $CLAUDE_PLUGIN_ROOT/skills/jira-writer/scripts/jira-api-wrapper.sh issue GRAC-880` succeeds (alias resolution).
- `bash …/jira-api-wrapper.sh jira_get_issue GRAC-880` succeeds (prefix strip).
- `bash …/jira-api-wrapper.sh getIssue GRAC-880` succeeds (camelCase).
- `bash …/jira-api-wrapper.sh notarealop` exits 2 with a "Did you mean: …" suggestion.
- `bash …/jira-rest-api.sh anything` does *not* dispatch (file is library-only).
- `SKILL.md` contains zero references to `./scripts/` or to a versioned absolute path.
- All existing wrapper operations continue to work unchanged.
