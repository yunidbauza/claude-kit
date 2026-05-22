import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const HERE = new URL('.', import.meta.url).pathname;
const SCRIPT = join(HERE, 'adf-validate.mjs');

async function validate(doc, args = []) {
  const dir = await mkdtemp(join(tmpdir(), 'adfv-'));
  const input = join(dir, 'doc.json');
  await writeFile(input, JSON.stringify(doc));
  const res = spawnSync('node', [SCRIPT, input, ...args], { encoding: 'utf8' });
  await rm(dir, { recursive: true, force: true });
  return { code: res.status, out: JSON.parse(res.stdout || '{}'), err: res.stderr };
}

test('valid empty doc passes', async () => {
  const r = await validate({ type: 'doc', version: 1, content: [] });
  assert.equal(r.code, 0);
  assert.equal(r.out.ok, true);
});

test('rejects bad doc shape (missing type)', async () => {
  const r = await validate({ version: 1, content: [] });
  assert.equal(r.code, 1);
  assert.equal(r.out.ok, false);
  assert.equal(r.out.rule, 'doc_shape');
});

test('rejects code+strong on same text node', async () => {
  const doc = {
    type: 'doc', version: 1, content: [{
      type: 'paragraph', content: [{
        type: 'text', text: 'x', marks: [{ type: 'code' }, { type: 'strong' }],
      }],
    }],
  };
  const r = await validate(doc);
  assert.equal(r.code, 1);
  assert.equal(r.out.rule, 'mark_exclusivity');
  assert.equal(r.out.path, 'content[0].content[0]');
});

test('rejects taskList without localId', async () => {
  const doc = {
    type: 'doc', version: 1, content: [{
      type: 'taskList', attrs: {}, content: [],
    }],
  };
  const r = await validate(doc);
  assert.equal(r.code, 1);
  assert.equal(r.out.rule, 'missing_localId');
});

test('rejects taskItem without localId', async () => {
  const doc = {
    type: 'doc', version: 1, content: [{
      type: 'taskList', attrs: { localId: 'abc' }, content: [{
        type: 'taskItem', attrs: { state: 'TODO' }, content: [],
      }],
    }],
  };
  const r = await validate(doc);
  assert.equal(r.code, 1);
  assert.equal(r.out.rule, 'missing_localId');
});

test('rejects tableCell missing attrs', async () => {
  const doc = {
    type: 'doc', version: 1, content: [{
      type: 'table', content: [{
        type: 'tableRow', content: [{ type: 'tableCell', content: [] }],
      }],
    }],
  };
  const r = await validate(doc);
  assert.equal(r.code, 1);
  assert.equal(r.out.rule, 'missing_table_attrs');
});

test('rejects paragraph containing block child', async () => {
  const doc = {
    type: 'doc', version: 1, content: [{
      type: 'paragraph', content: [{ type: 'paragraph', content: [] }],
    }],
  };
  const r = await validate(doc);
  assert.equal(r.code, 1);
  assert.equal(r.out.rule, 'inline_in_block');
});

test('valid taskList passes', async () => {
  const doc = {
    type: 'doc', version: 1, content: [{
      type: 'taskList', attrs: { localId: 'tl-1' }, content: [{
        type: 'taskItem',
        attrs: { localId: 'ti-1', state: 'TODO' },
        content: [{ type: 'text', text: 'do thing' }],
      }],
    }],
  };
  const r = await validate(doc);
  assert.equal(r.code, 0);
  assert.equal(r.out.ok, true);
});

test('bisect returns lowest-index failing block', async () => {
  const doc = {
    type: 'doc', version: 1, content: [
      { type: 'paragraph', content: [{ type: 'text', text: 'ok' }] },
      { type: 'paragraph', content: [{ type: 'text', text: 'also ok' }] },
      { type: 'taskList', attrs: {}, content: [] }, // missing localId at index 2
      { type: 'paragraph', content: [{ type: 'text', text: 'never reached' }] },
    ],
  };
  const r = await validate(doc, ['--bisect']);
  assert.equal(r.code, 1);
  assert.equal(r.out.block_index, 2);
  assert.equal(r.out.rule, 'missing_localId');
});

test('bisect on valid doc returns ok', async () => {
  const r = await validate({ type: 'doc', version: 1, content: [] }, ['--bisect']);
  assert.equal(r.code, 0);
  assert.equal(r.out.ok, true);
});
