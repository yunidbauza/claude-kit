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
 * Output shape is Copilot's agentStop contract:
 *   {"decision":"allow"} | {"decision":"block","reason":"..."}
 * (The Claude-side agent hook uses a different shape, `ok: true|false` — the two are
 * not interchangeable, which is why each harness gets its own verifier.)
 *
 * TWO FAILURE MODES ARE FORBIDDEN, and they pull in opposite directions:
 *   1. Wedging a session. Every unexpected condition must return allow.
 *   2. Recording a FALSE SUCCESS. Failing open must never mean writing `DONE` to a
 *      brief we could not actually verify — that destroys the audit trail. So
 *      "cannot verify" releases the turn WITHOUT stamping DONE.
 */

import { readFileSync, writeFileSync, existsSync, renameSync, realpathSync } from 'node:fs';
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

/** Headings that legitimately end a section in a goal-on brief. */
const SIBLING_HEADINGS = ['Task', 'Scope', 'Constraints', 'Outcome', 'Stop Rules', 'Verification evidence'];

function emit(decision, reason) {
  process.stdout.write(JSON.stringify(reason ? { decision, reason } : { decision }));
  // Set exitCode and return rather than process.exit(), which can drop buffered
  // stdout when it is a pipe.
  process.exitCode = 0;
}

/** Read the hook payload from stdin (or an explicit string, for tests). Never throws. */
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
  const id = payload?.sessionId || payload?.session_id || null;
  // The id becomes a filename. Reject anything that could escape the brief dir.
  if (typeof id !== 'string' || !/^[A-Za-z0-9._-]+$/.test(id) || id === '.' || id === '..') return null;
  return id;
}

/** Split a brief into { header, body }. Returns null if there is no frontmatter. */
export function splitFrontmatter(md) {
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(md);
  if (!m) return null;
  return { header: m[1], body: m[2] };
}

export function headerValue(header, key) {
  const m = new RegExp(`^${key}:[ \\t]*(.*)$`, 'm').exec(header);
  if (!m) return null;
  // Tolerate trailing `# comments` and quoted values — the brief template in
  // goal-on/SKILL.md demonstrates inline comments on header keys.
  return m[1].replace(/\s+#.*$/, '').trim().replace(/^["']|["']$/g, '');
}

/**
 * Blank out `#` characters that sit inside fenced code blocks, preserving offsets.
 * Without this, a line like `## not a heading` inside a fence inside `## Outcome`
 * truncates the section and hides the unchecked items below it.
 */
function maskFences(text) {
  const out = text.split('');
  let inFence = false;
  const lines = [];
  let idx = 0;
  for (const line of text.split('\n')) {
    lines.push({ start: idx, line });
    idx += line.length + 1;
  }
  for (const { start, line } of lines) {
    if (/^[ \t]*(```|~~~)/.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) {
      for (let i = 0; i < line.length; i++) {
        if (out[start + i] === '#') out[start + i] = ' ';
      }
    }
  }
  return out.join('');
}

/**
 * Extract a `## Section` body, up to the next sibling `## ` heading or EOF.
 * NB: JavaScript has no `\Z`; end-of-string is `$(?![\s\S])` under the `m` flag.
 * Boundaries are found on a fence-masked copy, then sliced out of the original, so
 * fenced content (command output, examples) is returned intact.
 */
export function section(body, title) {
  const masked = maskFences(body);
  const startRe = new RegExp(`^##[ \\t]+${title}[ \\t]*$`, 'mi');
  const s = startRe.exec(masked);
  if (!s) return '';
  const from = s.index + s[0].length;
  const endRe = new RegExp(`^##[ \\t]+(?:${SIBLING_HEADINGS.join('|')})\\b`, 'gmi');
  endRe.lastIndex = from;
  const e = endRe.exec(masked);
  return body.slice(from, e ? e.index : body.length);
}

export function checkboxItems(outcome) {
  const all = outcome.match(/^[ \t]*[-*][ \t]*\[[ xX]\][ \t]*(.*)$/gm) || [];
  const unchecked = (outcome.match(/^[ \t]*[-*][ \t]*\[ \][ \t]*(.*)$/gm) || []).map((l) =>
    l.replace(/^[ \t]*[-*][ \t]*\[ \][ \t]*/, '').trim(),
  );
  return { total: all.length, unchecked };
}

/** Evidence is "present" only if it has real content beyond the placeholder. */
export function hasEvidence(evidence) {
  const stripped = evidence
    .replace(/^\s*\(appended during Phase 2\)\s*$/gim, '')
    .replace(/^\s*#+.*$/gm, '')
    .trim();
  return stripped.length > 0;
}

/**
 * Set a key in the frontmatter header only, rewriting whatever value is there.
 * Deliberately lenient about the OLD value (comments, quotes, junk) — a strict
 * pattern here silently no-ops, which would stop turns_used advancing and mean the
 * turn_budget stop rule never fires.
 */
export function setHeaderField(md, key, value) {
  const m = /^(---\r?\n)([\s\S]*?)(\r?\n---)/.exec(md);
  if (!m) return md;
  const [, open, header, close] = m;
  const line = new RegExp(`^${key}:[^\\r\\n]*$`, 'm');
  const next = line.test(header)
    ? header.replace(line, `${key}: ${value}`)
    : `${header}\n${key}: ${value}`;
  return open + next + close + md.slice(m.index + m[0].length);
}

export const setHeaderStatus = (md, status) => setHeaderField(md, 'status', status);
export const bumpTurns = (md, next) => setHeaderField(md, 'turns_used', next);

/**
 * Core decision. Pure apart from the caller's file write, so tests drive it directly.
 * Returns {action: 'allow'|'block', reason?, write?}
 *
 * `now` is injected for the same reason the rest of this is pure: a real clock makes
 * the `last_verified` stamp unassertable.
 */
export function decide(md, now = () => new Date().toISOString()) {
  const split = splitFrontmatter(md);
  // Not a brief we understand — fail open, and stamp nothing. A `last_verified` on
  // a file this verifier could not parse would be a liveness claim about a brief it
  // never actually read.
  if (!split) return { action: 'allow' };

  /**
   * Every path below writes, and the stamp is why.
   *
   * `last_verified` is the only evidence that the verifier ran *at all*, and it
   * exists because the alternative is silence. Both verifiers fail open on any
   * error — mandatory, since one that failed closed could wedge a session with no
   * way out — but failing open is indistinguishable from succeeding unless
   * something is written down. Under Claude Code the failure is real and observed:
   * the `agent` hook reaches this file through the Read tool, and a session in
   * bypass-permissions mode denies it, so the verifier releases every turn having
   * checked nothing.
   *
   * A verifier that cannot read the brief cannot write this either, which is what
   * makes an absent stamp a reliable signal rather than a guess. Phase 1 always
   * ends on a turn boundary, so by the time Phase 2 begins the stamp is either
   * there or nothing is enforcing the goal. `SKILL.md` has the check.
   *
   * Stamped even on the terminal statuses. It costs one atomic write per turn end
   * and keeps the signal true for the whole session rather than only until the
   * goal is settled.
   */
  const stamped = setHeaderField(md, 'last_verified', now());

  const { header, body } = split;
  const status = headerValue(header, 'status');
  if (!status || TERMINAL.has(status)) return { action: 'allow', write: stamped };

  const turnsUsed = Number.parseInt(headerValue(header, 'turns_used') ?? '0', 10) || 0;
  const budget = Number.parseInt(headerValue(header, 'turn_budget') ?? '8', 10) || 8;

  // Stop rule tripped: record the failure and release, never loop forever.
  if (turnsUsed >= budget) {
    return { action: 'allow', write: setHeaderStatus(stamped, 'FAILED') };
  }

  const outcome = section(body, 'Outcome');
  const evidence = section(body, 'Verification evidence');
  const { total, unchecked } = checkboxItems(outcome);
  const evidenceOk = hasEvidence(evidence);

  // No Outcome section, or one with no checkbox items at all: there is nothing
  // mechanical to verify. Release the turn, but do NOT stamp DONE — claiming success
  // on an unverifiable brief is worse than not verifying at all. The liveness stamp
  // is not a success claim and rides along regardless.
  if (total === 0) return { action: 'allow', write: stamped };

  if (unchecked.length === 0 && evidenceOk) {
    return { action: 'allow', write: setHeaderStatus(stamped, 'DONE') };
  }

  const reasons = [];
  if (unchecked.length) {
    reasons.push(
      `${unchecked.length} Outcome item(s) still unchecked: ` +
        unchecked.slice(0, 3).map((s) => `"${s.slice(0, 80)}"`).join('; ') +
        (unchecked.length > 3 ? ` (+${unchecked.length - 3} more)` : ''),
    );
  }
  if (!evidenceOk) {
    reasons.push('"## Verification evidence" is empty — record real command output');
  }
  reasons.push(`Turn ${turnsUsed + 1}/${budget}. Do the next unmet item, then tick it.`);

  return { action: 'block', reason: reasons.join('. '), write: bumpTurns(stamped, turnsUsed + 1) };
}

/** Write via temp + rename so a crash mid-write cannot truncate the user's brief. */
function writeAtomic(path, contents) {
  const tmp = `${path}.tmp-${process.pid}`;
  try {
    writeFileSync(tmp, contents, 'utf8');
    renameSync(tmp, path);
  } catch {
    /* a read-only or unwritable brief must not wedge the turn */
  }
}

function main() {
  try {
    const sessionId = sessionIdOf(readPayload());
    if (!sessionId) return emit('allow');

    const briefPath = join(homedir(), '.claude', 'workstream', 'goal-on', `${sessionId}.md`);
    if (!existsSync(briefPath)) return emit('allow'); // not a goal-on session

    const md = readFileSync(briefPath, 'utf8');
    const result = decide(md);

    if (result.write) writeAtomic(briefPath, result.write);
    if (result.action === 'block') return emit('block', result.reason);
    return emit('allow');
  } catch {
    return emit('allow'); // fail open, always
  }
}

// Only run when invoked directly, so the test file can import the helpers.
// NB: an `endsWith('verify-goal.mjs')` check is WRONG — 'test-verify-goal.mjs' also
// ends with it, so importing from the test would run main() and block on stdin.
// argv[1] is realpath'd because Node realpaths import.meta.url but not argv[1]; without
// it, invoking through a symlink silently disables the hook.
if (process.argv[1]) {
  let entry = process.argv[1];
  try {
    entry = realpathSync(entry);
  } catch {
    /* keep the raw path */
  }
  if (import.meta.url === pathToFileURL(entry).href) main();
}
