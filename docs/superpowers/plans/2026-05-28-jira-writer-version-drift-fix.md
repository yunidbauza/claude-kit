# jira-writer Version-Drift / Stale-Path Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the intermittent `No such file or directory` jira-writer script error by syncing version metadata (cut as patch release `1.5.1`), guarding against it in CI, giving the wrapper a clear diagnostic, and documenting recovery.

**Architecture:** Four independent changes. (1) Bump both version manifests to `1.5.1` so the marketplace registry matches the canonical plugin manifest and installs converge. (2) Add a CI job that fails on version drift. (3) Add a fail-loud preflight to `jira-api-wrapper.sh` so a stale `$CLAUDE_PLUGIN_ROOT` yields an actionable error instead of a raw bash one. (4) Document the failure + recovery in SKILL.md, CHANGELOG, and README.

**Tech Stack:** Bash, GitHub Actions, `jq`, JSON manifests, Markdown docs.

---

## Background / Root Cause

`plugins/jira-writer/.claude-plugin/plugin.json` (canonical) is at `1.5.0`, but `.claude-plugin/marketplace.json` still advertises `1.1.0` — it was never bumped across PRs #1, #2, #4, #5. Because the registry advertises an old version, local caches never converge on the latest. Each plugin update creates a new versioned cache dir (`~/.claude/plugins/cache/claude-kit/jira-writer/<version>/…`) and removes the old one. When the plugin updates mid-session, `$CLAUDE_PLUGIN_ROOT` still points at the removed dir, so any script invocation fails with a raw `No such file or directory`. A session restart re-resolves the path, which is why the error is intermittent.

Full spec: `docs/superpowers/specs/2026-05-28-jira-writer-version-drift-design.md`.

## File Structure

- `plugins/jira-writer/.claude-plugin/plugin.json` — bump `version` to `1.5.1`.
- `.claude-plugin/marketplace.json` — set `jira-writer` entry `version` to `1.5.1`.
- `.github/workflows/jira-writer-tests.yml` — add `marketplace.json` to trigger paths, add a `version-sync` job, add a step to run the new wrapper preflight test.
- `plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh` — guarded `source`.
- `plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-preflight.sh` — new test for the guard.
- `plugins/jira-writer/skills/jira-writer/SKILL.md` — troubleshooting note.
- `plugins/jira-writer/CHANGELOG.md` — `1.5.1` entry.
- `README.md` — version reference on line ~208.

---

### Task 1: Bump both version manifests to 1.5.1

**Files:**
- Modify: `plugins/jira-writer/.claude-plugin/plugin.json:3`
- Modify: `.claude-plugin/marketplace.json:12`

- [ ] **Step 1: Bump `plugin.json`**

In `plugins/jira-writer/.claude-plugin/plugin.json`, change line 3 from:

```json
  "version": "1.5.0",
```

to:

```json
  "version": "1.5.1",
```

- [ ] **Step 2: Sync `marketplace.json`**

In `.claude-plugin/marketplace.json`, change line 12 from:

```json
      "version": "1.1.0",
```

to:

```json
      "version": "1.5.1",
```

- [ ] **Step 3: Verify both manifests agree**

Run:

```bash
cd /Users/yunidbauza/Projects/claude-kit
p=$(jq -r '.version' plugins/jira-writer/.claude-plugin/plugin.json)
m=$(jq -r '.plugins[] | select(.name == "jira-writer") | .version' .claude-plugin/marketplace.json)
echo "plugin=$p marketplace=$m"
[[ "$p" == "1.5.1" && "$m" == "1.5.1" ]] && echo OK || echo MISMATCH
```

Expected output:

```
plugin=1.5.1 marketplace=1.5.1
OK
```

- [ ] **Step 4: Commit**

```bash
git add plugins/jira-writer/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore: cut jira-writer 1.5.1 and sync marketplace.json version"
```

---

### Task 2: Add CI version-sync guard

Prevents the two manifests from drifting again. The existing workflow only triggers on `plugins/jira-writer/**` and its own path; `.claude-plugin/marketplace.json` is outside that, so the trigger paths must be widened or a marketplace-only change would skip the check.

**Files:**
- Modify: `.github/workflows/jira-writer-tests.yml:4-11` (trigger paths)
- Modify: `.github/workflows/jira-writer-tests.yml:14` (add job under `jobs:`)

- [ ] **Step 1: Add `marketplace.json` to both trigger path lists**

In `.github/workflows/jira-writer-tests.yml`, change lines 3-12 from:

```yaml
on:
  push:
    paths:
      - 'plugins/jira-writer/**'
      - '.github/workflows/jira-writer-tests.yml'
  pull_request:
    paths:
      - 'plugins/jira-writer/**'
      - '.github/workflows/jira-writer-tests.yml'
  workflow_dispatch:
```

to:

```yaml
on:
  push:
    paths:
      - 'plugins/jira-writer/**'
      - '.claude-plugin/marketplace.json'
      - '.github/workflows/jira-writer-tests.yml'
  pull_request:
    paths:
      - 'plugins/jira-writer/**'
      - '.claude-plugin/marketplace.json'
      - '.github/workflows/jira-writer-tests.yml'
  workflow_dispatch:
```

- [ ] **Step 2: Add the `version-sync` job**

In the same file, under `jobs:` (after the existing `test:` job block, i.e. after the final step on line 38), add this new job. It must be indented two spaces to sit as a sibling of `test:`:

```yaml
  version-sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install jq
        run: sudo apt-get update && sudo apt-get install -y jq
      - name: Verify plugin.json and marketplace.json versions match
        run: |
          plugin_version=$(jq -r '.version' plugins/jira-writer/.claude-plugin/plugin.json)
          marketplace_version=$(jq -r '.plugins[] | select(.name == "jira-writer") | .version' .claude-plugin/marketplace.json)
          echo "plugin.json:      $plugin_version"
          echo "marketplace.json: $marketplace_version"
          if [[ "$plugin_version" != "$marketplace_version" ]]; then
            echo "::error::jira-writer version mismatch: plugin.json=$plugin_version marketplace.json=$marketplace_version"
            exit 1
          fi
```

- [ ] **Step 3: Verify the job's shell logic passes on the synced tree**

Run the same comparison the CI job runs:

```bash
cd /Users/yunidbauza/Projects/claude-kit
plugin_version=$(jq -r '.version' plugins/jira-writer/.claude-plugin/plugin.json)
marketplace_version=$(jq -r '.plugins[] | select(.name == "jira-writer") | .version' .claude-plugin/marketplace.json)
echo "plugin.json:      $plugin_version"
echo "marketplace.json: $marketplace_version"
if [[ "$plugin_version" != "$marketplace_version" ]]; then echo "MISMATCH"; exit 1; else echo "MATCH"; fi
```

Expected output:

```
plugin.json:      1.5.1
marketplace.json: 1.5.1
MATCH
```

- [ ] **Step 4: Verify the job's shell logic FAILS when desynced**

Temporarily simulate drift (no file edit needed — override the variable inline):

```bash
cd /Users/yunidbauza/Projects/claude-kit
plugin_version=$(jq -r '.version' plugins/jira-writer/.claude-plugin/plugin.json)
marketplace_version="9.9.9"
if [[ "$plugin_version" != "$marketplace_version" ]]; then echo "MISMATCH (expected)"; else echo "UNEXPECTED MATCH"; fi
```

Expected output:

```
MISMATCH (expected)
```

- [ ] **Step 5: Validate the workflow YAML parses**

Run:

```bash
cd /Users/yunidbauza/Projects/claude-kit
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/jira-writer-tests.yml')); print('YAML OK')"
```

Expected output:

```
YAML OK
```

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/jira-writer-tests.yml
git commit -m "ci: add version-sync guard for jira-writer manifests"
```

---

### Task 3: Add wrapper preflight diagnostic (TDD)

When `jira-rest-api.sh` is missing next to the wrapper (the stale-`$CLAUDE_PLUGIN_ROOT` case), the wrapper currently dies on the bare `source` with a raw bash error and exit code 1. Replace it with an explicit check that prints an actionable message and exits 127.

**Files:**
- Create: `plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-preflight.sh`
- Modify: `plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh:38-39`
- Modify: `.github/workflows/jira-writer-tests.yml` (add a test step)

- [ ] **Step 1: Write the failing test**

Create `plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-preflight.sh` with exactly:

```bash
#!/usr/bin/env bash
#
# test-wrapper-preflight.sh
#
# Verifies jira-api-wrapper.sh fails loudly (clear message + exit 127) when
# its sibling jira-rest-api.sh is missing — the stale-$CLAUDE_PLUGIN_ROOT case.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Copy ONLY the wrapper — deliberately omit jira-rest-api.sh.
cp "$SCRIPT_DIR/jira-api-wrapper.sh" "$TMP/jira-api-wrapper.sh"
chmod +x "$TMP/jira-api-wrapper.sh"

set +e
output="$("$TMP/jira-api-wrapper.sh" get_issue PROJ-1 2>&1)"
code=$?
set -e

fail=0
if [[ $code -ne 127 ]]; then
    echo "FAIL: expected exit code 127, got $code"
    fail=1
fi
if ! grep -q "jira-writer scripts missing" <<<"$output"; then
    echo "FAIL: expected 'jira-writer scripts missing' in output"
    echo "----- actual output -----"
    echo "$output"
    echo "-------------------------"
    fail=1
fi

if [[ $fail -eq 0 ]]; then
    echo "PASS: wrapper preflight emits diagnostic and exits 127"
fi
exit $fail
```

- [ ] **Step 2: Make the test executable and run it to verify it FAILS**

Run:

```bash
cd /Users/yunidbauza/Projects/claude-kit/plugins/jira-writer/skills/jira-writer/scripts
chmod +x test-wrapper-preflight.sh
bash test-wrapper-preflight.sh; echo "exit=$?"
```

Expected: FAIL — the test reports a wrong exit code (1, from the bare `source` failure under `set -e`) and/or a missing message, e.g.:

```
FAIL: expected exit code 127, got 1
FAIL: expected 'jira-writer scripts missing' in output
...
exit=1
```

- [ ] **Step 3: Add the preflight guard to the wrapper**

In `plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh`, replace lines 38-39:

```bash
# Source the REST API functions
source "$SCRIPT_DIR/jira-rest-api.sh"
```

with:

```bash
# Source the REST API functions. If the sibling file is missing, the plugin
# likely updated mid-session and $CLAUDE_PLUGIN_ROOT points at a removed cache
# directory — fail loudly with guidance instead of a raw bash error.
if [[ ! -f "$SCRIPT_DIR/jira-rest-api.sh" ]]; then
    echo "[ERROR] jira-writer scripts missing at: $SCRIPT_DIR" >&2
    echo "[ERROR] The plugin likely updated mid-session — restart Claude Code to refresh CLAUDE_PLUGIN_ROOT." >&2
    exit 127
fi
source "$SCRIPT_DIR/jira-rest-api.sh"
```

- [ ] **Step 4: Run the test to verify it PASSES**

Run:

```bash
cd /Users/yunidbauza/Projects/claude-kit/plugins/jira-writer/skills/jira-writer/scripts
bash test-wrapper-preflight.sh; echo "exit=$?"
```

Expected output:

```
PASS: wrapper preflight emits diagnostic and exits 127
exit=0
```

- [ ] **Step 5: Verify no regression — the wrapper still runs normally when the file is present**

Run (the wrapper should get past the guard and reach its own arg/dispatch logic, NOT print the preflight error):

```bash
cd /Users/yunidbauza/Projects/claude-kit/plugins/jira-writer/skills/jira-writer/scripts
JIRA_DOMAIN="" JIRA_API_KEY="" bash jira-api-wrapper.sh 2>&1 | head -5
```

Expected: usage / argument output from the wrapper itself. It must NOT contain `jira-writer scripts missing`.

- [ ] **Step 6: Wire the test into CI**

In `.github/workflows/jira-writer-tests.yml`, inside the `test:` job, after the existing `Run existing wrapper-dispatch tests` step (lines 33-35), add:

```yaml
      - name: Run wrapper preflight test
        working-directory: plugins/jira-writer/skills/jira-writer/scripts
        run: bash test-wrapper-preflight.sh
```

- [ ] **Step 7: Validate the workflow YAML still parses**

Run:

```bash
cd /Users/yunidbauza/Projects/claude-kit
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/jira-writer-tests.yml')); print('YAML OK')"
```

Expected output:

```
YAML OK
```

- [ ] **Step 8: Commit**

```bash
cd /Users/yunidbauza/Projects/claude-kit
git add plugins/jira-writer/skills/jira-writer/scripts/jira-api-wrapper.sh \
        plugins/jira-writer/skills/jira-writer/scripts/test-wrapper-preflight.sh \
        .github/workflows/jira-writer-tests.yml
git commit -m "fix: wrapper emits clear diagnostic and exits 127 when scripts are missing"
```

---

### Task 4: Add SKILL.md troubleshooting note

**Files:**
- Modify: `plugins/jira-writer/skills/jira-writer/SKILL.md:183`

- [ ] **Step 1: Insert the troubleshooting subsection**

In `plugins/jira-writer/skills/jira-writer/SKILL.md`, immediately after line 183 (the line `All operations go through \`jira-api-wrapper.sh\`. The low-level functions in \`jira-rest-api.sh\` are sourced by the wrapper and are not invoked directly.`) and before the `#### Primary Scripts` heading, insert a blank line then:

```markdown
#### Troubleshooting

**"jira-writer scripts missing" or a raw "No such file or directory" for a script path**
The plugin updated during this session, so `$CLAUDE_PLUGIN_ROOT` points at a cache
directory that no longer exists. Restart Claude Code to refresh it.
```

- [ ] **Step 2: Verify the note is present**

Run:

```bash
grep -n "jira-writer scripts missing" /Users/yunidbauza/Projects/claude-kit/plugins/jira-writer/skills/jira-writer/SKILL.md
```

Expected: one match inside the new `#### Troubleshooting` subsection.

- [ ] **Step 3: Commit**

```bash
cd /Users/yunidbauza/Projects/claude-kit
git add plugins/jira-writer/skills/jira-writer/SKILL.md
git commit -m "docs: add SKILL.md troubleshooting note for mid-session plugin updates"
```

---

### Task 5: Add CHANGELOG entry and update README version reference

**Files:**
- Modify: `plugins/jira-writer/CHANGELOG.md:1-3` (insert new entry after the title)
- Modify: `README.md:208`

- [ ] **Step 1: Add the `1.5.1` CHANGELOG entry**

In `plugins/jira-writer/CHANGELOG.md`, the file begins with:

```markdown
# Changelog — jira-writer

## 1.5.0 — 2026-05-22
```

Insert the following block between the `# Changelog — jira-writer` title and the `## 1.5.0 — 2026-05-22` heading (so `1.5.1` appears first):

```markdown
## 1.5.1 — 2026-05-28

### Fixed
- Synced `marketplace.json` with `plugin.json` so installs converge on the latest release (the registry was stuck advertising `1.1.0`).
- `jira-api-wrapper.sh` now prints a clear diagnostic and exits 127 when its sibling `jira-rest-api.sh` is missing, instead of a raw "No such file or directory". This occurs when the plugin updates mid-session and `$CLAUDE_PLUGIN_ROOT` points at a removed cache directory — restart Claude Code to recover.

### Added
- CI `version-sync` job that fails when `plugin.json` and `marketplace.json` versions disagree.
- SKILL.md troubleshooting note explaining the mid-session-update failure and the restart fix.

```

- [ ] **Step 2: Update the README version reference**

In `README.md`, change line 208 from:

```markdown
See [plugins/jira-writer/CHANGELOG.md](plugins/jira-writer/CHANGELOG.md) for v1.5.0 release notes.
```

to:

```markdown
See [plugins/jira-writer/CHANGELOG.md](plugins/jira-writer/CHANGELOG.md) for v1.5.1 release notes.
```

- [ ] **Step 3: Verify both docs reference 1.5.1**

Run:

```bash
cd /Users/yunidbauza/Projects/claude-kit
grep -n "1.5.1" plugins/jira-writer/CHANGELOG.md README.md
```

Expected: matches in the new CHANGELOG heading (`## 1.5.1 — 2026-05-28`) and in README line 208.

- [ ] **Step 4: Commit**

```bash
cd /Users/yunidbauza/Projects/claude-kit
git add plugins/jira-writer/CHANGELOG.md README.md
git commit -m "docs: add 1.5.1 changelog entry and update README version reference"
```

---

## Final Verification

- [ ] **Run the full local equivalent of CI**

```bash
cd /Users/yunidbauza/Projects/claude-kit/plugins/jira-writer/skills/jira-writer/scripts
node --test test-markdown-to-adf.mjs test-adf-validate.mjs
bash test-wrapper-flags.sh
bash test-wrapper-dispatch.sh
bash test-wrapper-preflight.sh
bash check-prerequisites.sh | jq -e '.node.available == true' >/dev/null && echo "prereqs OK"
```

Expected: all test scripts report success; `test-wrapper-preflight.sh` prints `PASS: …`; `prereqs OK` prints.

- [ ] **Confirm version sync one last time**

```bash
cd /Users/yunidbauza/Projects/claude-kit
jq -r '.version' plugins/jira-writer/.claude-plugin/plugin.json
jq -r '.plugins[] | select(.name == "jira-writer") | .version' .claude-plugin/marketplace.json
```

Expected: both print `1.5.1`.

- [ ] **Confirm clean git state**

```bash
cd /Users/yunidbauza/Projects/claude-kit
git status
```

Expected: working tree clean, 5 new commits ahead.

## Post-Merge (manual, not part of this plan)

Once merged, the user reinstalls/updates the plugin locally (`/plugin` update flow) so the cache converges on `1.5.1`. The stale `1.3.0` cache directory is replaced. This step is operational and outside the code change.
