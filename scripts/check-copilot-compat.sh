#!/usr/bin/env bash
# Validates that every plugin in this marketplace loads under BOTH Claude Code and
# GitHub Copilot CLI.
#
# Copilot resolves manifests from a fixed list of locations and requires a specific
# schema. Claude Code overlaps but is not identical. This script encodes the union so
# a change that silently breaks one harness fails CI instead.
#
# Requires: jq, node. Run from the repository root.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0
fail=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; fail=$((fail + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Manifest locations Copilot CLI probes, in order. `.claude-plugin/` is the 4th and
# is what this repo uses — valid for both harnesses, so no duplication is needed.
PLUGIN_MANIFEST_LOCATIONS=(".plugin/plugin.json" "plugin.json" ".github/plugin/plugin.json" ".claude-plugin/plugin.json")
MARKETPLACE_LOCATIONS=("marketplace.json" ".plugin/marketplace.json" ".github/plugin/marketplace.json" ".claude-plugin/marketplace.json")

# Hook events Copilot accepts (camelCase and PascalCase aliases both work).
VALID_HOOK_EVENTS="sessionStart SessionStart sessionEnd SessionEnd userPromptSubmitted UserPromptSubmit userPromptTransformed preToolUse PreToolUse postToolUse PostToolUse postToolUseFailure PostToolUseFailure preCompact PreCompact permissionRequest PermissionRequest notification agentStop Stop subagentStart subagentStop SubagentStop errorOccurred ErrorOccurred"

command -v jq   >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "node is required"; exit 1; }

# ---------------------------------------------------------------- marketplace ----
head_ "Marketplace manifest"

MARKETPLACE=""
for loc in "${MARKETPLACE_LOCATIONS[@]}"; do
  [ -f "$loc" ] && { MARKETPLACE="$loc"; break; }
done

if [ -z "$MARKETPLACE" ]; then
  bad "marketplace.json sits in a Copilot-accepted location" \
      "none of: ${MARKETPLACE_LOCATIONS[*]}"
else
  ok "marketplace.json in a Copilot-accepted location ($MARKETPLACE)"

  if jq empty "$MARKETPLACE" 2>/dev/null; then
    ok "marketplace.json is valid JSON"
  else
    bad "marketplace.json is valid JSON"
  fi

  for field in name owner plugins; do
    if [ "$(jq -r "has(\"$field\")" "$MARKETPLACE" 2>/dev/null)" = "true" ]; then
      ok "marketplace.json has required field: $field"
    else
      bad "marketplace.json has required field: $field"
    fi
  done

  # Copilot requires name/description/version/source on every plugin entry.
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    entry=$(jq -c --arg n "$name" '.plugins[] | select(.name == $n)' "$MARKETPLACE")
    missing=""
    for f in name description version source; do
      [ "$(jq -r --arg f "$f" 'has($f)' <<<"$entry")" = "true" ] || missing="$missing $f"
    done
    if [ -z "$missing" ]; then
      ok "marketplace entry '$name' has name/description/version/source"
    else
      bad "marketplace entry '$name' is missing:$missing"
    fi

    src=$(jq -r '.source' <<<"$entry")
    if [ -d "${src#./}" ]; then
      ok "marketplace entry '$name' source resolves ($src)"
    else
      bad "marketplace entry '$name' source resolves" "no such directory: $src"
    fi
  done < <(jq -r '.plugins[]?.name' "$MARKETPLACE" 2>/dev/null)
fi

# -------------------------------------------------------------------- plugins ----
for dir in plugins/*/; do
  dir="${dir%/}"
  [ -d "$dir" ] || continue
  head_ "Plugin: $dir"

  manifest=""
  for loc in "${PLUGIN_MANIFEST_LOCATIONS[@]}"; do
    [ -f "$dir/$loc" ] && { manifest="$dir/$loc"; break; }
  done

  if [ -z "$manifest" ]; then
    bad "plugin.json in a Copilot-accepted location" "none of: ${PLUGIN_MANIFEST_LOCATIONS[*]}"
    continue
  fi
  ok "plugin.json in a Copilot-accepted location (${manifest#"$dir"/})"

  if jq empty "$manifest" 2>/dev/null; then
    ok "plugin.json is valid JSON"
  else
    bad "plugin.json is valid JSON"
    continue
  fi

  pname=$(jq -r '.name // empty' "$manifest")
  if [ -n "$pname" ]; then
    ok "plugin.json has a name ($pname)"
  else
    bad "plugin.json has a name"
  fi

  # Copilot: kebab-case, <=64 chars, letters/numbers/hyphens.
  if printf '%s' "$pname" | grep -qE '^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$'; then
    ok "plugin name is Copilot-legal (kebab-case, <=64 chars)"
  else
    bad "plugin name is Copilot-legal (kebab-case, <=64 chars)" "got: '$pname'"
  fi

  # Version must match the marketplace listing, or users install a version that
  # does not exist. Claude Code and Copilot both read the listing.
  if [ -n "$MARKETPLACE" ]; then
    pver=$(jq -r '.version // empty' "$manifest")
    mver=$(jq -r --arg n "$pname" '.plugins[] | select(.name == $n) | .version // empty' "$MARKETPLACE")
    if [ -n "$pver" ] && [ "$pver" = "$mver" ]; then
      ok "version matches marketplace.json ($pver)"
    else
      bad "version matches marketplace.json" "plugin.json=$pver marketplace.json=$mver"
    fi
  fi

  # ------------------------------------------------------------------ skills ----
  for skill in "$dir"/skills/*/SKILL.md; do
    [ -f "$skill" ] || continue
    sdir=$(basename "$(dirname "$skill")")
    fm=$(awk '/^---$/{n++; next} n==1{print} n==2{exit}' "$skill")

    sname=$(printf '%s\n' "$fm" | sed -n 's/^name:[[:space:]]*//p' | head -1)
    if [ -n "$sname" ]; then
      ok "skill '$sdir' has frontmatter name"
    else
      bad "skill '$sdir' has frontmatter name" "required by Copilot"
    fi

    # description may be a folded block (`description: >-`), so just require the key.
    if printf '%s\n' "$fm" | grep -qE '^description:'; then
      ok "skill '$sdir' has frontmatter description"
    else
      bad "skill '$sdir' has frontmatter description" "required by Copilot"
    fi

    if [ "$sname" = "$sdir" ]; then
      ok "skill '$sdir' name matches its directory"
    else
      bad "skill '$sdir' name matches its directory" "name: '$sname'"
    fi

    if printf '%s' "$sname" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; then
      ok "skill '$sdir' name is lowercase-hyphenated"
    else
      bad "skill '$sdir' name is lowercase-hyphenated" "got: '$sname'"
    fi

    # An UNBRACED positional token in a skill body is rewritten with the invoking
    # caller's arguments before the agent ever reads the file — 0-indexed, and inside
    # code fences and backtick spans exactly as in prose. So `awk '{print $1}'` in a
    # snippet silently becomes `awk '{print /some/path}'` the moment the skill is
    # invoked with two arguments, and an out-of-range token is left alone, which is
    # why it survives testing with fewer args than it takes. Braced `${1}` is passed
    # through untouched; awk field refs must be avoided or rewritten in shell.
    body=$(awk '/^---$/{n++; next} n>=2' "$skill")
    posn=$(printf '%s\n' "$body" | grep -nE '\$[0-9]' | head -3 | tr '\n' ' ')
    if [ -z "$posn" ]; then
      ok "skill '$sdir' body has no unbraced positional tokens"
    else
      bad "skill '$sdir' body has no unbraced positional tokens" \
          "argument substitution would rewrite these: $posn"
    fi
  done

  # --------------------------------------------- bundled-launcher invocation ----
  # Copilot adds NO plugin bin/ to PATH and exports no plugin-root variable, so a
  # skill that calls its own bundled launcher by bare name is broken there.
  if [ -d "$dir/bin" ]; then
    for launcher in "$dir"/bin/*; do
      [ -f "$launcher" ] || continue
      lname=$(basename "$launcher")
      offenders=""
      # EVERY markdown file under skills/, not just SKILL.md — the reference/ docs are
      # progressive disclosure that SKILL.md routes the model into, so a bare-name
      # command there breaks under Copilot exactly the same way.
      #
      # Match the launcher name followed by something that looks like an OPERATION
      # (a snake_case op, or one of the hyphenated/bare ones) rather than any word, so
      # prose like "the jira-writer plugin" is not a false positive. Leading context
      # excludes `/` and `-` so paths (.../bin/jira-writer) and `command -v jira-writer`
      # inside the resolve preamble do not trip it.
      while IFS= read -r doc; do
        [ -f "$doc" ] || continue
        if grep -qE "(^|[^A-Za-z0-9/_.\"'-])${lname}[[:space:]]+([a-z]+_[a-z_]+|doctor|mermaid|mermaid-batch|connection-test)\b" "$doc"; then
          offenders="$offenders ${doc#"$dir"/skills/}"
        fi
      done < <(find "$dir/skills" -name '*.md' 2>/dev/null)
      if [ -z "$offenders" ]; then
        ok "no skill invokes '$lname' by bare name (Copilot has no bin/ on PATH)"
      else
        bad "no skill invokes '$lname' by bare name" \
            "offending skill(s):$offenders — resolve the launcher into a variable first"
      fi

      # And the resolve preamble must actually be documented somewhere.
      if grep -rqE 'installed-plugins/\*/' "$dir"/skills/*/SKILL.md 2>/dev/null; then
        ok "a Copilot-aware resolve preamble is documented for '$lname'"
      else
        bad "a Copilot-aware resolve preamble is documented for '$lname'" \
            "expected a ~/.copilot/installed-plugins/* fallback in a SKILL.md"
      fi
    done
  fi

  # ------------------------------------------------------------------- hooks ----
  if [ -f "$dir/hooks.json" ]; then
    if jq empty "$dir/hooks.json" 2>/dev/null; then
      ok "hooks.json is valid JSON"
    else
      bad "hooks.json is valid JSON"
      continue
    fi

    # Assert the top-level shape FIRST. Without this, a manifest whose key is
    # misspelled (e.g. "hook") makes every downstream jq return nothing, the loops
    # never run, and the file passes vacuously with a green tick.
    n_events=$(jq -r 'if (.hooks | type) == "object" then (.hooks | length) else -1 end' "$dir/hooks.json" 2>/dev/null)
    if [ "${n_events:--1}" -gt 0 ] 2>/dev/null; then
      ok "hooks.json has a non-empty top-level 'hooks' object ($n_events event(s))"
    else
      bad "hooks.json has a non-empty top-level 'hooks' object" \
          "got: $(jq -c 'keys' "$dir/hooks.json" 2>/dev/null) — a misspelled key passes every other check vacuously"
    fi

    while IFS= read -r ev; do
      [ -z "$ev" ] && continue
      if printf '%s' " $VALID_HOOK_EVENTS " | grep -q " $ev "; then
        ok "hooks.json event '$ev' is a valid Copilot event"
      else
        bad "hooks.json event '$ev' is a valid Copilot event"
      fi
    done < <(jq -r '.hooks | keys[]?' "$dir/hooks.json" 2>/dev/null)

    # A `bash`-only command hook is silently dead on native Windows. Require the
    # cross-platform `command` field, or an explicit powershell twin.
    bare_bash=$(jq -r '[.hooks[]?[]? | select(.type=="command") | select(has("command")|not) | select(has("powershell")|not)] | length' "$dir/hooks.json" 2>/dev/null)
    if [ "${bare_bash:-0}" = "0" ]; then
      ok "every command hook is cross-platform ('command', or bash+powershell)"
    else
      bad "every command hook is cross-platform" \
          "$bare_bash hook(s) define only 'bash' — inert on native Windows"
    fi

    # Referenced scripts must exist and parse.
    while IFS= read -r cmd; do
      [ -z "$cmd" ] && continue
      # Stop at whitespace or a quote: an unquoted `node ${PLUGIN_ROOT}/x.mjs --flag`
      # would otherwise capture "--flag" into the path and report a false failure.
      rel=$(printf '%s' "$cmd" | grep -oE '\$\{(CLAUDE_PLUGIN_ROOT|COPILOT_PLUGIN_ROOT|PLUGIN_ROOT)\}[^"'"'"'[:space:]]*' | head -1 | sed -E 's/^\$\{[A-Z_]+\}\///')
      [ -z "$rel" ] && continue
      if [ -f "$dir/$rel" ]; then
        ok "hook script exists: $rel"
        if [[ "$rel" == *.mjs || "$rel" == *.js ]]; then
          if node --check "$dir/$rel" 2>/dev/null; then
            ok "hook script parses: $rel"
          else
            bad "hook script parses: $rel"
          fi
        fi
      else
        bad "hook script exists: $rel" "referenced by hooks.json but not found"
      fi
    done < <(jq -r '.hooks[]?[]? | (.command // .bash // empty)' "$dir/hooks.json" 2>/dev/null)
  fi
done

head_ "Result"
printf '  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
