# Changelog — jira-writer

## 1.9.0 — 2026-07-27

### Added
- **`update_issue --append`** — lossless append to an existing description.
  Field report: agents had to hand-splice ADF because `--desc-file` /
  `--markdown` always REPLACE the whole description, and round-tripping a
  rich body (tables, checkboxes, embedded images) through markdown is
  silently lossy. `--append` fetches the current description ADF and
  concatenates the new content nodes onto it before the PUT — the existing
  body is never converted. Requires REST (no-creds is a hard error and
  REST-failure offers no MCP retry: any fallback would overwrite). SKILL.md
  now warns that the default replaces; workflow.md points plain appends at
  the flag. Regression tests: merge order + existing-content preservation,
  and the no-creds hard error.

### Fixed
- **`link_issues` created every link inverted.** `link_issues A Blocks B`
  produced "A is blocked by B" (field report from real ticket workflows).
  Verified against live Jira link objects (`GET /issueLink/{id}`) on
  known-direction links plus a create→inspect→delete round-trip: in Jira's
  model the issue that PERFORMS the link type's outward verb ("blocks") is
  stored as the link's **inwardIssue** — the opposite of the "obvious"
  reading (and of the Atlassian KB summary the 1.7.0 implementation relied
  on). The wrapper now POSTs arg1→inwardIssue / arg3→outwardIssue, so
  `link_issues A Blocks B` genuinely yields "A blocks B". Arg order is
  unchanged (still reads as the sentence); anyone who pre-swapped args to
  work around the bug must un-swap.
- MCP fallback params encode the same corrected mapping; the "MCP inverts
  direction" warning is reframed — that reported bug appears to be this
  same misreading. `get_issue` READING guidance was already correct.
- Direction regression test flipped to pin the verified mapping.

## 1.8.0 — 2026-07-24

Backport of three adversarial-review rounds run against the jira-mate port
(aplaceformom/claude-skills PR #48). The APFM-specific `JIRA_DOMAIN` default
was again NOT backported — this plugin stays site-agnostic.

### Fixed
- **Converter data loss (three classes).** `~~strikethrough~~` text was
  deleted outright (no `del` token case — now a `strike` mark); nested
  blocks under task items were dropped; and follow-on paragraphs inside
  task items (marked emits them as extra `text` tokens) were dropped. The
  taskList now splits at items with nested/follow-on content so trailing
  blocks land right after their item — nothing dropped, reading order kept.
- **Batch upload exited 1 on every run** — the EXIT trap referenced a
  `local` that is out of scope when the trap fires; under `set -u` even a
  fully successful run exited 1 and leaked its temp file.
- **Batch edge cases:** BSD `seq` counts down on empty arrays (two bogus
  renders of the literal string "null"); non-array `diagrams_json` crashed
  mid-loop. Now a C-style loop + up-front array validation, and results
  report the child's **normalized filename** (sanitize + `.png`), not the
  raw input.
- **Typo'd flags silently corrupted payloads** — `--dsc-file` became the
  literal issue description. Unknown whitespace-free letter-led `--flags`
  are now a hard error (exit 2, known-flags list shown); multi-word data
  starting with `--word ` still passes, and a lone `--` is honored as the
  conventional end-of-flags marker. Duplicate value flags resolve
  last-wins.
- **`get_issue KEY FIELDS --summary-only`** silently discarded the FIELDS
  positional despite the documented signature — now unioned.
- **Mermaid input routing:** literal code colliding with a same-named file
  in the cwd was silently read from disk. A path must now be
  whitespace-free; args with spaces/newlines are always treated as code
  (documented in usage + reference/mermaid.md).
- **`create_issue` MCP fallbacks** used the REST `fields` envelope instead
  of the createJiraIssue param shape, and dropped `--parent` (the tool has
  a top-level `parent` param). Both fixed.
- **Documented `Task` default implemented** — `create_issue PROJECT
  SUMMARY` (2 positionals) now creates a Task, as SKILL.md promised.

### Changed
- **Markdown-first MCP fallbacks, symmetric across branches.** When the
  content came from `--markdown`/`--desc-file`, both the no-creds AND the
  REST-failure paths now emit `mcp_fallback` carrying the lossless
  original markdown (MCP renders markdown natively) instead of converted
  ADF or a spurious "fallback not viable" error; only hand-built ADF keeps
  the no-retry `api:"error"`. A shared `_md_fallback_note` helper warns
  when the markdown contains checkboxes/images/diagrams the MCP renders as
  plain text.
- **No-creds `--markdown`/`--desc-file` paths no longer require Node** —
  the ADF conversion is skipped when the MCP fallback is the destination.
- **Mermaid upload delegates to the shared `jira_upload_attachment`** —
  one implementation of sanitization, auth, and the attachments endpoint
  (also guards against a missing attachment id and gates ANSI colors).
- **Converter shape alignment:** table nodes carry the canonical
  `{isNumberColumnEnabled, layout}` attrs documented in reference/adf.md;
  unlabeled code fences omit `attrs` instead of emitting `language: null`.
- `doctor` reports a missing jq in static JSON instead of dying on `jq -n`;
  `get_remote_links`/`test_connection` documented in SKILL.md; consistency
  cleanups (ADF-note gating unified on `is_adf_input`, `$_ADF_DOC_JQ_FILTER`
  reused in the update dispatch, validator-crash envelopes agree on
  `path: null`).

### Tests
- 12 new/updated: strikethrough, loose task items, taskList splitting,
  table attrs, code-fence attrs (converter); unknown-flag error, multi-word
  dash data, `--` end-of-flags, last-wins duplicates, Task default,
  markdown-carrying update fallbacks (wrapper); dispatch ADF-note tests
  pass the `is_adf_input` flag the real dispatcher computes.

## 1.7.0 — 2026-07-23

### Added
- **`link_issues OUTWARD_KEY LINK_TYPE INWARD_KEY`** — create issue links via
  REST `POST /rest/api/3/issueLink`. Direction is explicit and verified
  against Atlassian docs and live link data: the **first argument is the
  outward issue**, which carries the link type's outward description —
  `link_issues A Blocks B` ⇒ "A blocks B" (B shows "is blocked by A"). Arg
  order reads as the sentence. Aliases: `link`, `link_issue`.
- **`get_link_types`** — list the site's issue link types with their
  inward/outward wording (REST `GET /rest/api/3/issueLinkType`). Aliases:
  `link_types`, `linktypes`.
- MCP fallback for `link_issues` targets `createIssueLink` and carries a
  prominent warning: Atlassian's MCP tool has an open bug that **inverts**
  link direction (atlassian/atlassian-mcp-server#112) — verify with
  `get_issue` after any MCP-created link.
- `reference/troubleshooting.md` gotcha #9 documenting direction semantics,
  how to read `issuelinks` entries in `get_issue` output, and the MCP
  inversion bug.
- Tests: mock-curl regression test asserting the POST body direction
  (arg1 = `outwardIssue`), arity guard test, and normalize/alias tests.

## 1.6.2 — 2026-07-13

Backport of defect fixes found while porting this plugin into the APFM shared
repo as `jira-mate` (claude-skills PR #48), where an AI reviewer and a live
verification pass surfaced them. Behavior is otherwise unchanged.

### Fixed
- **Linux base64 line-wrap in diagnostics.** `check-prerequisites.sh` and
  `test-jira-connection.sh` built the Basic auth header without `tr -d '\n'`;
  GNU base64 wraps at 76 chars, so long credentials made `doctor` /
  `connection-test` report false auth failures on Linux (the REST library
  already stripped correctly).
- **Silent no-op on paths with spaces.** `markdown-to-adf.mjs` and
  `adf-validate.mjs` gated `main()` on `import.meta.url === file://argv[1]`,
  which never matches when the install path contains URL-escapable characters
  — the scripts exited 0 with empty output. Now compares against
  `pathToFileURL(argv[1]).href`.
- **Mixed task/plain lists corrupted.** A list mixing `- [ ]` and plain items
  was forced entirely into `taskList`, giving plain items checkboxes they
  never had. Mixed lists now fall back to `bulletList` (`some` → `every`).
- **Wrapper died on validator crash.** When `adf-validate.mjs` crashed (e.g.
  unparseable input), both validation paths fed its raw stack trace to jq
  (`--argjson` / parse), killing the wrapper with a jq usage error instead of
  an envelope. Non-JSON validator output is now wrapped as
  `{api:"error", rule:"validator_crash"}`.
- **Unencoded `fields` query param.** `jira_search_jql` and `jira_get_issue`
  appended the caller-supplied `fields` list raw; custom field names with
  spaces silently malformed the URL. Now percent-encoded like `jql`.
- **curl `-F` metacharacters in attachment filenames.** Caller-supplied
  filenames are interpolated into the multipart spec where `;` and quotes are
  curl syntax; sanitized to `[a-zA-Z0-9._-]` in the mermaid uploader and
  `jira_upload_attachment` (spaces become `_`).
- **Inline mermaid input via `echo`.** Input consisting solely of echo flag
  characters (`-n`/`-e`/`-E`) would vanish; now written with `printf '%s\n'`.
- **Docs:** SKILL.md's `add_comment "…\n…"` example used `\n` inside double
  quotes (bash sends it literally) — now a real multi-line string; one
  workflow.md curl example showed a raw un-base64'd Authorization header, and
  two more (workflow.md, troubleshooting.md) base64-encoded without the
  newline strip.

### Changed
- **`--bisect` de-advertised.** The validator reports the failing
  `block_index` natively, so the flag never changed the outcome. Removed from
  SKILL.md, `reference/adf.md`, and usage strings; still accepted silently
  for compatibility.
- **Hardening (no behavior change in shipped paths):** `_jira_init_cache`
  registers its cleanup EXIT trap only when no trap exists (never clobbers a
  future sourcing caller's cleanup); `_resolve_content_input`'s temp-file
  cleanup is now reachable regardless of the call site's errexit context
  (`|| rc=$?`); `_flag_value` / `_has_bool` iterate with the zero-word
  `${arr[@]+"${arr[@]}"}` idiom instead of `"${arr[@]:-}"` (which yields one
  empty word on an empty array).

### Tests
- Updated the mixed-list test to assert the corrected `bulletList` fallback
  (it previously codified the corrupting behavior) and the `--summary-only`
  URL assertion to expect the percent-encoded `fields` param.

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
