#!/usr/bin/env node
/**
 * Tests for the portable goal-on Stop verifier.
 * Run: node --test test-verify-goal.mjs
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  decide,
  section,
  checkboxItems,
  hasEvidence,
  sessionIdOf,
  readPayload,
  splitFrontmatter,
  setHeaderStatus,
  setHeaderField,
  headerValue,
} from './verify-goal.mjs';

const brief = ({
  status = 'ACTIVE',
  turns = 0,
  budget = 8,
  outcome = '- [x] done thing\n',
  evidence = '$ npm test\nok\n',
} = {}) => `---
status: ${status}
route: code
turns_used: ${turns}
turn_budget: ${budget}
branch: goal/x
---

## Task

Do the thing.

## Outcome

${outcome}
## Stop Rules

Stop after ${budget} turns.

## Verification evidence

${evidence}`;

// --- terminal statuses release the turn -------------------------------------

for (const status of ['PENDING-APPROVAL', 'CLEARED', 'DONE', 'FAILED', 'NEEDS-DECISION']) {
  test(`status ${status} allows the turn to end`, () => {
    // Unmet outcome + no evidence: only the status may release it.
    const md = brief({ status, outcome: '- [ ] not done\n', evidence: '' });
    assert.equal(decide(md).action, 'allow');
  });
}

test('PENDING-APPROVAL never blocks — it is the Phase 1 approval gate', () => {
  const md = brief({ status: 'PENDING-APPROVAL', outcome: '- [ ] a\n- [ ] b\n', evidence: '' });
  const r = decide(md, () => '2026-01-01T00:00:00.000Z');
  assert.equal(r.action, 'allow');
  // It writes — the liveness stamp — but must not touch the status, which is the
  // user's approval gate.
  assert.match(r.write, /^status: PENDING-APPROVAL$/m);
  assert.match(r.write, /^last_verified: 2026-01-01T00:00:00\.000Z$/m);
});

// --- blocking ----------------------------------------------------------------

test('ACTIVE with unchecked outcome items blocks and names them', () => {
  const md = brief({ outcome: '- [x] first\n- [ ] second thing\n- [ ] third thing\n' });
  const r = decide(md);
  assert.equal(r.action, 'block');
  assert.match(r.reason, /2 Outcome item\(s\) still unchecked/);
  assert.match(r.reason, /second thing/);
});

test('ACTIVE with all items checked but empty evidence blocks', () => {
  const md = brief({ outcome: '- [x] all done\n', evidence: '' });
  const r = decide(md);
  assert.equal(r.action, 'block');
  assert.match(r.reason, /Verification evidence" is empty/);
});

test('the placeholder alone does not count as evidence', () => {
  const md = brief({ outcome: '- [x] all done\n', evidence: '(appended during Phase 2)\n' });
  assert.equal(decide(md).action, 'block');
});

test('blocking increments turns_used in the written header', () => {
  const md = brief({ turns: 2, outcome: '- [ ] nope\n' });
  const r = decide(md);
  assert.equal(r.action, 'block');
  assert.match(r.write, /^turns_used: 3$/m);
});

// --- completion --------------------------------------------------------------

test('all checked plus real evidence releases and writes DONE', () => {
  const md = brief({ outcome: '- [x] a\n- [x] b\n', evidence: '$ pnpm test\n12 passed\n' });
  const r = decide(md);
  assert.equal(r.action, 'allow');
  assert.match(r.write, /^status: DONE$/m);
});

// --- stop rule ---------------------------------------------------------------

test('turns_used >= turn_budget writes FAILED and releases', () => {
  const md = brief({ turns: 8, budget: 8, outcome: '- [ ] never finished\n', evidence: '' });
  const r = decide(md);
  assert.equal(r.action, 'allow', 'must not block past the budget — the harness gives up anyway');
  assert.match(r.write, /^status: FAILED$/m);
});

test('budget trip takes precedence over an otherwise-complete brief', () => {
  const md = brief({ turns: 9, budget: 8 });
  assert.match(decide(md).write, /^status: FAILED$/m);
});

// --- fail open ---------------------------------------------------------------

test('a brief with no frontmatter fails open', () => {
  assert.equal(decide('# just a document\n\nno header here').action, 'allow');
});

test('a brief with no status field fails open', () => {
  assert.equal(decide('---\nroute: code\n---\n\n## Outcome\n\n- [ ] x\n').action, 'allow');
});

test('garbage input does not throw', () => {
  for (const input of ['', '---\n---\n', '---\nstatus:\n---\n']) {
    assert.doesNotThrow(() => decide(input));
  }
});

// --- payload parsing ---------------------------------------------------------

test('both sessionId conventions are accepted', () => {
  assert.equal(sessionIdOf({ sessionId: 'abc' }), 'abc');
  assert.equal(sessionIdOf({ session_id: 'xyz' }), 'xyz');
  assert.equal(sessionIdOf({}), null);
});

test('malformed payloads parse to an empty object rather than throwing', () => {
  assert.deepEqual(readPayload('not json'), {});
  assert.deepEqual(readPayload(''), {});
  assert.deepEqual(readPayload('{"sessionId":"s1"}'), { sessionId: 's1' });
});

// --- helpers -----------------------------------------------------------------

test('section stops at the next heading and does not leak a literal Z', () => {
  const body = '## Outcome\n\n- [x] one\n\n## Stop Rules\n\nstop\n';
  const out = section(body, 'Outcome');
  assert.match(out, /- \[x\] one/);
  assert.doesNotMatch(out, /Stop Rules/);
});

test('section reads the final heading through end-of-string', () => {
  const body = '## Outcome\n\n- [x] one\n\n## Verification evidence\n\n$ cmd\nout\n';
  assert.match(section(body, 'Verification evidence'), /\$ cmd/);
});

test('checkboxItems ignores ticked boxes and handles * bullets', () => {
  assert.deepEqual(checkboxItems('- [x] a\n- [ ] b\n* [ ] c\n').unchecked, ['b', 'c']);
  assert.deepEqual(checkboxItems('- [x] a\n').unchecked, []);
  assert.equal(checkboxItems('- [x] a\n- [ ] b\n').total, 2);
  assert.equal(checkboxItems('no checkboxes here\n').total, 0);
});

test('hasEvidence ignores headings and whitespace', () => {
  assert.equal(hasEvidence('\n\n   \n'), false);
  assert.equal(hasEvidence('### A heading only\n'), false);
  assert.equal(hasEvidence('### Run\n$ cmd\nok\n'), true);
});

test('splitFrontmatter tolerates CRLF line endings', () => {
  const s = splitFrontmatter('---\r\nstatus: ACTIVE\r\n---\r\nbody');
  assert.ok(s);
  assert.match(s.header, /status: ACTIVE/);
});

test('setHeaderStatus rewrites only the header status', () => {
  const md = '---\nstatus: ACTIVE\n---\n\nstatus: ACTIVE in the body stays\n';
  const out = setHeaderStatus(md, 'DONE');
  assert.match(out, /^status: DONE$/m);
  assert.match(out, /status: ACTIVE in the body stays/);
});

// --- regressions from the PR #30 self review ------------------------------------
// Each of these previously produced a FALSE SUCCESS (a `DONE` stamp on a brief that
// was not actually verified) or silently disabled the stop rule.

test('no ## Outcome section: releases but never stamps DONE', () => {
  const md = '---\nstatus: ACTIVE\nturns_used: 0\nturn_budget: 8\n---\n\n## Task\n\nx\n';
  const r = decide(md);
  assert.equal(r.action, 'allow');
  assert.doesNotMatch(r.write, /status: DONE/, 'unverifiable brief must not be marked DONE');
  assert.match(r.write, /^status: ACTIVE$/m);
});

test('Outcome written as prose with no checkboxes: releases but never stamps DONE', () => {
  const md = brief({ outcome: 'Ship the thing and make sure it works.\n' });
  const r = decide(md);
  assert.equal(r.action, 'allow');
  assert.doesNotMatch(r.write, /status: DONE/);
  assert.match(r.write, /^status: ACTIVE$/m);
});

test('a heading-like line inside a fenced block does not truncate the Outcome', () => {
  const outcome = [
    '- [x] first',
    '',
    '```md',
    '## not a heading',
    '```',
    '',
    '- [ ] genuinely unfinished',
    '',
  ].join('\n');
  const r = decide(brief({ outcome }));
  assert.equal(r.action, 'block', 'the item after the fence must still be seen');
  assert.match(r.reason, /genuinely unfinished/);
});

test('section still returns fenced evidence content intact', () => {
  const body = '## Verification evidence\n\n```\n## output heading\nok\n```\n';
  const out = section(body, 'Verification evidence');
  assert.match(out, /## output heading/, 'masking must not delete fenced content');
  assert.equal(hasEvidence(out), true);
});

test('an unrelated ## heading does not end a section (only siblings do)', () => {
  const body = '## Outcome\n\n- [ ] a\n\n## Some Other Heading\n\n- [ ] b\n\n## Stop Rules\n\nx\n';
  assert.equal(checkboxItems(section(body, 'Outcome')).unchecked.length, 2);
});

for (const [label, raw] of [
  ['an inline # comment', 'turns_used: 2   # bumped by the verifier'],
  ['a quoted value', 'turns_used: "2"'],
  ['extra whitespace', 'turns_used:    2   '],
]) {
  test(`turns_used with ${label} still increments (stop rule stays live)`, () => {
    const md = `---\nstatus: ACTIVE\n${raw}\nturn_budget: 8\n---\n\n## Outcome\n\n- [ ] x\n\n## Verification evidence\n\nout\n`;
    const r = decide(md);
    assert.equal(r.action, 'block');
    assert.match(r.write, /^turns_used: 3$/m, 'a no-op bump would loop forever and never hit FAILED');
  });
}

test('turns_used missing entirely is inserted rather than silently dropped', () => {
  const md = '---\nstatus: ACTIVE\nturn_budget: 8\n---\n\n## Outcome\n\n- [ ] x\n\n## Verification evidence\n\nout\n';
  const r = decide(md);
  assert.equal(r.action, 'block');
  assert.match(r.write, /^turns_used: 1$/m);
});

test('headerValue tolerates comments and quotes', () => {
  const h = 'status: ACTIVE  # running\nturn_budget: "12"\n';
  assert.equal(headerValue(h, 'status'), 'ACTIVE');
  assert.equal(headerValue(h, 'turn_budget'), '12');
});

test('setHeaderField rewrites a commented value and touches only the header', () => {
  const md = '---\nstatus: ACTIVE   # was pending\n---\n\nstatus: ACTIVE stays in the body\n';
  const out = setHeaderField(md, 'status', 'DONE');
  assert.match(out, /^status: DONE$/m);
  assert.match(out, /status: ACTIVE stays in the body/);
});

test('sessionIdOf rejects ids that could escape the brief directory', () => {
  assert.equal(sessionIdOf({ sessionId: '../../etc/passwd' }), null);
  assert.equal(sessionIdOf({ sessionId: 'a/b' }), null);
  assert.equal(sessionIdOf({ sessionId: '..' }), null);
  assert.equal(sessionIdOf({ sessionId: 'ok-123_ABC.def' }), 'ok-123_ABC.def');
});

// --- the liveness stamp ------------------------------------------------------

// `last_verified` is the only evidence that the verifier ran at all. Both verifiers
// fail open on any error — mandatory, so a broken one cannot wedge a session — and
// failing open is indistinguishable from succeeding unless something is written
// down. Under Claude Code the failure is real: the `agent` hook reads the brief
// through the Read tool, and a bypass-permissions session denies it.

const AT = () => '2026-01-01T00:00:00.000Z';

test('every decision that parsed the brief stamps last_verified', () => {
  const cases = {
    'awaiting approval': brief({ status: 'PENDING-APPROVAL' }),
    terminal: brief({ status: 'DONE' }),
    'budget spent': brief({ turns: 8, budget: 8 }),
    verified: brief(),
    blocking: brief({ outcome: '- [ ] not done\n', evidence: '' }),
    'nothing to verify': brief({ outcome: 'prose, no checkboxes\n' }),
  };

  for (const [label, md] of Object.entries(cases)) {
    const r = decide(md, AT);
    assert.match(
      r.write ?? '',
      /^last_verified: 2026-01-01T00:00:00\.000Z$/m,
      `${label}: must record that the verifier ran`,
    );
  }
});

test('a brief with no frontmatter is not stamped', () => {
  // Nothing was parsed, so there is nothing to make a liveness claim about — a
  // stamp here would assert the verifier read a brief it never understood.
  const r = decide('# just a document\n\nno header here', AT);
  assert.equal(r.action, 'allow');
  assert.equal(r.write, undefined);
});

test('the stamp is refreshed rather than appended twice', () => {
  const once = decide(brief(), () => '2026-01-01T00:00:00.000Z').write;
  const twice = decide(once, () => '2026-02-02T00:00:00.000Z').write;

  assert.equal((twice.match(/^last_verified:/gm) ?? []).length, 1);
  assert.match(twice, /^last_verified: 2026-02-02T00:00:00\.000Z$/m);
});

test('stamping leaves the body untouched', () => {
  const md = brief();
  const r = decide(md, AT);
  const bodyOf = (text) => text.slice(text.indexOf('---', 4) + 3);

  assert.equal(bodyOf(r.write), bodyOf(md));
});
