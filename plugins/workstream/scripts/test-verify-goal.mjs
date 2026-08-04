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
  uncheckedItems,
  hasEvidence,
  sessionIdOf,
  readPayload,
  splitFrontmatter,
  setHeaderStatus,
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
  const r = decide(md);
  assert.equal(r.action, 'allow');
  assert.equal(r.write, undefined, 'must not rewrite the header while awaiting approval');
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

test('uncheckedItems ignores ticked boxes and handles * bullets', () => {
  assert.deepEqual(uncheckedItems('- [x] a\n- [ ] b\n* [ ] c\n'), ['b', 'c']);
  assert.deepEqual(uncheckedItems('- [x] a\n'), []);
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
