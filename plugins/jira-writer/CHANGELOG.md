# Changelog — jira-writer

## 1.6.1 — 2026-07-10

### Fixed
- **`update_issue` no longer drops the positional `FIELDS_JSON` when `--desc-file` (or `--markdown`) is also passed.** Previously the launcher built the update payload as `{description: <body>}` only, silently discarding any other fields (most commonly a `summary` rename) — so "rename + rewrite body" required two separate calls. The dispatcher now **merges** the positional `FIELDS_JSON` with the resolved description body (`$FIELDS_JSON + {description: ...}`, so the file body wins on the `.description` key) and sends a single REST/MCP update. A non-object positional is ignored with a `[WARN]` instead of corrupting the payload. This matches the `update_issue KEY FIELDS_JSON [--desc-file PATH] [--markdown]` signature already documented in SKILL.md.

### Added
- `test-wrapper-flags.sh`: two regression tests — `FIELDS_JSON` summary survives alongside a `--desc-file` body in one call, and `--desc-file` alone still updates the description without inventing a `summary` field.

### Changed
- SKILL.md frontmatter `model` bumped `claude-sonnet-4-6` → `claude-sonnet-5`.

## 1.6.0 — 2026-07-07

### Changed
- **SKILL.md rewritten as a lean dispatcher (progressive disclosure).** The skill body is auto-injected into every session, so its size is a permanent context tax. Trimmed it from ~1112 lines / ~7k tokens to **124 lines / ~1.4k tokens (~80% reduction)** while keeping everything needed on a normal invocation: prerequisites, the REST-first/MCP-fallback rule, the bare-`jira-writer` invocation warning, the full command cheat-sheet, the `--desc-file --markdown` recommended path, the response-envelope quick reference, and a when-to-read-what table.

### Added
- `reference/` directory holding the detail that used to live inline, loaded on demand only when a task needs it:
  - `reference/workflow.md` — full Step 1–7 flow (mermaid processing, complexity detection, append/replace/insert/prepend update modes, rollback).
  - `reference/adf.md` — ADF node catalog, inline marks, media layouts, gotchas, rich-comment example.
  - `reference/mermaid.md` — diagram types, conversion options, filename/validation conventions, upload helpers.
  - `reference/troubleshooting.md` — envelope shapes, graceful degradation, error table, rollback, known issues.
  - `reference/examples.md` — the 10 worked request→execution walkthroughs.

No behavioral change: same launcher, same ops, same flags. Documentation reorganization only.

## 1.5.2 — 2026-06-06

### Fixed
- **Definitive fix for the recurring "`$CLAUDE_PLUGIN_ROOT` isn't exported into the Bash shell" error.** Root cause: `$CLAUDE_PLUGIN_ROOT` is exported only to hook and MCP/LSP subprocesses — **never** to the Bash tool shell — yet SKILL.md instructed the model to invoke scripts as `"$CLAUDE_PLUGIN_ROOT/skills/.../jira-api-wrapper.sh"`. The variable expanded to empty, the path failed, and the model improvised a fallback (and printed the message) on every call. The 1.5.1 "stale-path" guard addressed a different, rarer case (a *set-but-stale* variable after a mid-session update) and so never resolved this.

### Added
- `bin/jira-writer` launcher. Claude Code auto-adds each plugin's `bin/` to the Bash tool `PATH`, so the skill now invokes everything by **bare name** (`jira-writer <op>`) with zero dependence on `$CLAUDE_PLUGIN_ROOT`. Reserved subcommands `doctor`, `connection-test`, `mermaid`, and `mermaid-batch` route to the diagnostic/mermaid helpers; all other args forward to `jira-api-wrapper.sh`.
- `test-bin-launcher.sh` (wired into CI): proves bare-name dispatch works with `CLAUDE_PLUGIN_ROOT` unset from any working directory, and guards against `$CLAUDE_PLUGIN_ROOT` script paths creeping back into SKILL.md.

### Changed
- SKILL.md: all command examples now use `jira-writer …` instead of `"$CLAUDE_PLUGIN_ROOT/…"`; added an explicit "How to invoke" note and an updated troubleshooting entry (`command not found` → restart; skill-base-dir fallback for the current session).

## 1.5.1 — 2026-05-28

### Fixed
- Synced `marketplace.json` with `plugin.json` so installs converge on the latest release (the registry was stuck advertising `1.1.0`).
- `jira-api-wrapper.sh` now prints a clear diagnostic and exits 127 when its sibling `jira-rest-api.sh` is missing, instead of a raw "No such file or directory". This occurs when the plugin updates mid-session and `$CLAUDE_PLUGIN_ROOT` points at a removed cache directory — restart Claude Code to recover.

### Added
- CI `version-sync` job that fails when `plugin.json` and `marketplace.json` versions disagree.
- SKILL.md troubleshooting note explaining the mid-session-update failure and the restart fix.

## 1.5.0 — 2026-05-22

Resolves all items in `jira-writer-improvements.md`.

### Added
- `markdown-to-adf.mjs` — Node 18+ converter, vendored `marked@13.0.3` (item 1)
- `adf-validate.mjs` — lightweight ADF rule checks; mark exclusivity, localId presence, tableCell attrs, inline-in-block (items 2, 5)
- `--desc-file PATH` and `--markdown` flags on `create_issue`, `update_issue`, `add_comment` (items 1, 8)
- `--parent KEY` flag on `create_issue` with format validation (item 6)
- `--summary-only` flag on `get_issue` (item 8)
- `validate_adf PATH [--bisect]` op for explicit validation and INVALID_INPUT bisecting (items 4, 5)
- `check-prerequisites.sh` now reports Node availability
- SKILL.md: ADF gotchas section, rich-content workflow, updated ops table (item 7)

### Changed
- **BREAKING (behavior):** ADF and markdown-converted inputs that fail at REST now emit `api:"error"` instead of `api:"mcp_fallback"`. Plain-text input is unchanged. (item 3)
- Missing-arg errors now print the full operation signature including optional flags. (item 8)
- Mark exclusivity is enforced both in the converter and pre-flight validator.

### Runtime
- Node 18+ is required when using `--desc-file`, `--markdown`, or `validate_adf`. The plugin works without Node for plain-text and ADF-passthrough paths.
