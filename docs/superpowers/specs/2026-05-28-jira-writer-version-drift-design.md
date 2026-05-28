# jira-writer: fix intermittent "No such file or directory" script error

**Date:** 2026-05-28
**Status:** Approved (design)

## Problem

Users intermittently see errors like:

```
/Users/<user>/.claude/plugins/cache/claude-kit/jira-writer/<version>/skills/jira-writer/scripts/jira-rest-api.sh: No such file or directory
```

The error appears "from time to time" and then resolves on its own (after a Claude Code session restart).

## Root cause

Version metadata has drifted across the three places that record it:

| Location | Version |
|---|---|
| `plugins/jira-writer/.claude-plugin/plugin.json` | `1.5.0` (canonical / current) |
| `.claude-plugin/marketplace.json` (plugin entry) | `1.1.0` (stale — not bumped across PRs #1, #2, #4, #5) |
| Local cache `~/.claude/plugins/cache/claude-kit/jira-writer/` | `1.3.0` only |

This fix ships as a fresh patch release, `1.5.1`, since it is a bug fix.

Because the marketplace registry advertises `1.1.0`, the installer never converges the local cache onto `1.5.0`. Each plugin update creates a new versioned cache directory (`…/<version>/…`) and removes the previous one.

The intermittent failure: when the plugin updates during a live session, `$CLAUDE_PLUGIN_ROOT` was captured pointing at the *old* version directory. Any script invocation that expands that env var then resolves to a directory that no longer exists, producing the raw bash "No such file or directory". A fresh session re-resolves `$CLAUDE_PLUGIN_ROOT`, so the error disappears — until the next update.

The raw bash error is opaque: neither the user nor Claude can tell from it that a mid-session plugin update is the cause.

## Goals

1. Make the marketplace registry match the canonical plugin version so installs converge.
2. Prevent the version metadata from drifting again (it has regressed across 4 PRs).
3. Replace the opaque bash error with an actionable diagnostic.
4. Document the recovery step for users.

## Non-goals

- Reinstalling the user's local cache — that's a one-time manual step (`/plugin` reinstall) after the fix lands, not part of this change.
- Self-healing path resolution that auto-selects a "correct" cache version directory — fragile (ambiguous which version is correct, breaks with multi-marketplace installs) and it masks the real fix.
- Stable-symlink plugin paths — a Claude Code harness concern, outside this plugin's control.
- Tooling that auto-rewrites versions across files — overkill for a two-file repo; a CI guard catches drift more cheaply.

## Design

### Layer 1 — Version-metadata sync

**Source of truth:** `plugins/jira-writer/.claude-plugin/plugin.json` is canonical. `.claude-plugin/marketplace.json` mirrors its version.

**Change:** Cut a fresh patch release `1.5.1`:
- Bump `version` in `plugins/jira-writer/.claude-plugin/plugin.json` from `1.5.0` to `1.5.1`.
- Set the `jira-writer` entry `version` in `.claude-plugin/marketplace.json` to `1.5.1` (from the stale `1.1.0`).

Both files land on `1.5.1`, so the registry and the canonical manifest agree.

**Guard (CI):** Add a `version-sync` job to `.github/workflows/jira-writer-tests.yml`. The job:
- reads `version` from `plugins/jira-writer/.claude-plugin/plugin.json` (jq),
- reads the `jira-writer` plugin entry `version` from `.claude-plugin/marketplace.json` (jq),
- exits non-zero with a clear message if they differ.

Runs on the same triggers as the existing test job (PRs and pushes touching the plugin).

### Layer 2 — Wrapper preflight diagnostic

**Change to `plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh`:**

Replace the bare `source "$SCRIPT_DIR/jira-rest-api.sh"` (line ~39) with a guarded source:

```bash
if [[ ! -f "$SCRIPT_DIR/jira-rest-api.sh" ]]; then
    echo "[ERROR] jira-writer scripts missing at: $SCRIPT_DIR" >&2
    echo "[ERROR] The plugin likely updated mid-session — restart Claude Code to refresh CLAUDE_PLUGIN_ROOT." >&2
    exit 127
fi
source "$SCRIPT_DIR/jira-rest-api.sh"
```

Exit code `127` ("command not found") is conventional for a missing executable/dependency and is distinct from the wrapper's existing error exits.

This is a fail-loud-with-guidance change, not a recovery mechanism: if the wrapper file itself is at a stale path it cannot run at all, which is what Layer 3 addresses.

### Layer 3 — SKILL.md troubleshooting note

Add a short subsection to `plugins/jira-writer/skills/jira-writer/SKILL.md` near the scripts/operations documentation:

```
### Troubleshooting

**"jira-writer scripts missing" or "No such file or directory" for a script path**
The plugin updated during this session, so $CLAUDE_PLUGIN_ROOT points at a
cache directory that no longer exists. Restart Claude Code to refresh it.
```

## Verification plan

- **Layer 1:**
  - After the bump, run the two jq reads locally and confirm both report `1.5.1`.
  - Confirm the new CI job passes on the synced tree.
  - Temporarily desync (edit one file), confirm the CI job fails, then revert.
- **Layer 2:**
  - In a scratch copy, remove `jira-rest-api.sh` next to the wrapper and invoke the wrapper.
  - Expect the `[ERROR] jira-writer scripts missing…` message on stderr and exit code `127`.
  - With the file present, confirm normal operation is unchanged.
- **Layer 3:** Documentation only; no automated test.

## Files touched

- `plugins/jira-writer/.claude-plugin/plugin.json` — bump to `1.5.1`.
- `.claude-plugin/marketplace.json` — set to `1.5.1`.
- `.github/workflows/jira-writer-tests.yml` — add `version-sync` job.
- `plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh` — guarded source.
- `plugins/jira-writer/skills/jira-writer/SKILL.md` — troubleshooting note.
- `plugins/jira-writer/CHANGELOG.md` — add a `1.5.1` entry describing the version-sync fix, wrapper diagnostic, and troubleshooting note.
- `README.md` — update the line referencing "v1.5.0 release notes" (line ~208) to `1.5.1`.
