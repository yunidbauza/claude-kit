#!/usr/bin/env node
/**
 * goal-on Stop verifier — portable across Claude Code and GitHub Copilot CLI.
 *
 * Claude Code's goal-on SKILL.md declares an `agent`-type Stop hook that verifies the
 * Outcome semantically (an LLM reads the brief and judges the evidence). Copilot CLI
 * has no LLM-prompt hook type — only `command`, `http`, and `prompt` (sessionStart
 * only) — so this script is the mechanical equivalent wired up in `hooks.json`.
 *
 * Mechanical, not semantic. It enforces the contract the brief already encodes:
 *   - every `## Outcome` item is ticked `- [x]`, and
 *   - `## Verification evidence` actually contains something.
 * It does NOT judge whether the evidence is convincing. That difference is
 * documented in the workstream README.
 *
 * Both harnesses accept the same Stop/agentStop output shape:
 *   {"decision":"allow"} | {"decision":"block","reason":"..."}
 *
 * FAILING OPEN IS MANDATORY. A broken verifier must never wedge a session, so every
 * unexpected condition returns allow.
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const TERMINAL = new Set([
  'PENDING-APPROVAL', // Phase 1 is waiting on the user — must be allowed to end
  'CLEARED',
  'DONE',
  'FAILED',
  'NEEDS-DECISION',
]);

function allow() {
  process.stdout.write(JSON.stringify({ decision: 'allow' }));
  process.exit(0);
}

function block(reason) {
  process.stdout.write(JSON.stringify({ decision: 'block', reason }));
  process.exit(0);
}

/** Read the hook payload from stdin, falling back to argv. Never throws. */
export function readPayload(raw) {
  try {
    const text = raw ?? readFileSync(0, 'utf8');
    if (!text || !text.trim()) return {};
    return JSON.parse(text);
  } catch {
    return {};
  }
}

/** Both naming conventions are valid; Copilot emits either. */
export function sessionIdOf(payload) {
  return payload?.sessionId || payload?.session_id || null;
}

/** Split a brief into { header, body }. Returns null if there is no frontmatter. */
export function splitFrontmatter(md) {
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(md);
  if (!m) return null;
  return { header: m[1], body: m[2] };
}

export function headerValue(header, key) {
  const m = new RegExp(`^${key}:\\s*(.+?)\\s*$`, 'm').exec(header);
  return m ? m[1].trim() : null;
}

/**
 * Extract a `## Section` body, up to the next `## ` heading or EOF.
 * NB: JavaScript has no `\Z`; end-of-string is `$(?![\s\S])` under the `m` flag.
 */
export function section(body, title) {
  const re = new RegExp(`^##\\s+${title}\\s*$([\\s\\S]*?)(?=^##\\s|$(?![\\s\\S]))`, 'mi');
  const m = re.exec(body);
  return m ? m[1] : '';
}

export function uncheckedItems(outcome) {
  return (outcome.match(/^[ \t]*[-*]\s*\[ \]\s*(.+)$/gm) || []).map((l) =>
    l.replace(/^[ \t]*[-*]\s*\[ \]\s*/, '').trim(),
  );
}

/** Evidence is "present" only if it has real content beyond the placeholder. */
export function hasEvidence(evidence) {
  const stripped = evidence
    .replace(/^\s*\(appended during Phase 2\)\s*$/gim, '')
    .replace(/^\s*#+.*$/gm, '')
    .trim();
  return stripped.length > 0;
}

export function setHeaderStatus(md, status) {
  return md.replace(/^(---\r?\n[\s\S]*?)^status:\s*.+?$/m, `$1status: ${status}`);
}

export function bumpTurns(md, next) {
  return md.replace(/^(---\r?\n[\s\S]*?)^turns_used:\s*\d+\s*$/m, `$1turns_used: ${next}`);
}

/**
 * Core decision. Pure apart from the file write, so tests can drive it directly.
 * Returns {action: 'allow'|'block', reason?, write?}
 */
export function decide(md) {
  const split = splitFrontmatter(md);
  if (!split) return { action: 'allow' }; // not a brief we understand — fail open

  const { header, body } = split;
  const status = headerValue(header, 'status');
  if (!status || TERMINAL.has(status)) return { action: 'allow' };

  const turnsUsed = Number.parseInt(headerValue(header, 'turns_used') ?? '0', 10) || 0;
  const budget = Number.parseInt(headerValue(header, 'turn_budget') ?? '8', 10) || 8;

  // Stop rule tripped: record the failure and release, never loop forever.
  if (turnsUsed >= budget) {
    return { action: 'allow', write: setHeaderStatus(md, 'FAILED') };
  }

  const outcome = section(body, 'Outcome');
  const evidence = section(body, 'Verification evidence');
  const unmet = uncheckedItems(outcome);
  const evidenceOk = hasEvidence(evidence);

  if (unmet.length === 0 && evidenceOk) {
    return { action: 'allow', write: setHeaderStatus(md, 'DONE') };
  }

  const reasons = [];
  if (unmet.length) {
    reasons.push(
      `${unmet.length} Outcome item(s) still unchecked: ` +
        unmet.slice(0, 3).map((s) => `"${s.slice(0, 80)}"`).join('; ') +
        (unmet.length > 3 ? ` (+${unmet.length - 3} more)` : ''),
    );
  }
  if (!evidenceOk) {
    reasons.push('"## Verification evidence" is empty — record real command output');
  }
  reasons.push(`Turn ${turnsUsed + 1}/${budget}. Do the next unmet item, then tick it.`);

  return { action: 'block', reason: reasons.join('. '), write: bumpTurns(md, turnsUsed + 1) };
}

function main() {
  let briefPath;
  try {
    const sessionId = sessionIdOf(readPayload());
    if (!sessionId) allow();

    briefPath = join(homedir(), '.claude', 'workstream', 'goal-on', `${sessionId}.md`);
    if (!existsSync(briefPath)) allow(); // not a goal-on session

    const md = readFileSync(briefPath, 'utf8');
    const result = decide(md);

    if (result.write) {
      try {
        writeFileSync(briefPath, result.write, 'utf8');
      } catch {
        /* a read-only brief must not wedge the turn */
      }
    }
    if (result.action === 'block') block(result.reason);
    allow();
  } catch {
    allow(); // fail open, always
  }
}

// Only run when invoked directly, so the test file can import the helpers.
// NB: an `endsWith('verify-goal.mjs')` check is WRONG — 'test-verify-goal.mjs' also
// ends with it, so importing from the test would run main() and block on stdin.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
