# Changelog — jira-writer

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
