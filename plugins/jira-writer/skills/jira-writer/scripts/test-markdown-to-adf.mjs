import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const HERE = new URL('.', import.meta.url).pathname;
const SCRIPT = join(HERE, 'markdown-to-adf.mjs');

async function convert(md) {
  const dir = await mkdtemp(join(tmpdir(), 'md2adf-'));
  const input = join(dir, 'in.md');
  await writeFile(input, md);
  const res = spawnSync('node', [SCRIPT, input], { encoding: 'utf8' });
  await rm(dir, { recursive: true, force: true });
  if (res.status !== 0) throw new Error(`exit ${res.status}: ${res.stderr}`);
  return JSON.parse(res.stdout);
}

test('produces valid doc shape for empty input', async () => {
  const adf = await convert('');
  assert.equal(adf.type, 'doc');
  assert.equal(adf.version, 1);
  assert.deepEqual(adf.content, []);
});

test('paragraph becomes paragraph node', async () => {
  const adf = await convert('hello world');
  assert.equal(adf.content[0].type, 'paragraph');
  assert.equal(adf.content[0].content[0].type, 'text');
  assert.equal(adf.content[0].content[0].text, 'hello world');
});

test('heading levels 1-6 map to heading nodes', async () => {
  const adf = await convert('# h1\n\n## h2\n\n### h3\n\n#### h4\n\n##### h5\n\n###### h6');
  const levels = adf.content.map(n => n.attrs.level);
  assert.deepEqual(levels, [1, 2, 3, 4, 5, 6]);
  assert.equal(adf.content[0].type, 'heading');
  assert.equal(adf.content[0].content[0].text, 'h1');
});
