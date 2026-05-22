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

test('bullet list of non-task items becomes bulletList (regression: task=false guard)', async () => {
  const adf = await convert('- one\n- two\n- three');
  assert.equal(adf.content[0].type, 'bulletList');
  assert.equal(adf.content[0].content.length, 3);
  assert.equal(adf.content[0].content[0].type, 'listItem');
  assert.equal(adf.content[0].content[0].content[0].type, 'paragraph');
  assert.equal(adf.content[0].content[0].content[0].content[0].text, 'one');
});

test('ordered list becomes orderedList', async () => {
  const adf = await convert('1. first\n2. second');
  assert.equal(adf.content[0].type, 'orderedList');
  assert.equal(adf.content[0].content.length, 2);
});

test('fenced code block becomes codeBlock with language', async () => {
  const adf = await convert('```js\nconst x = 1;\n```');
  assert.equal(adf.content[0].type, 'codeBlock');
  assert.equal(adf.content[0].attrs.language, 'js');
  assert.equal(adf.content[0].content[0].type, 'text');
  assert.equal(adf.content[0].content[0].text, 'const x = 1;\n');
});

test('blockquote wraps inner paragraph', async () => {
  const adf = await convert('> quoted');
  assert.equal(adf.content[0].type, 'blockquote');
  assert.equal(adf.content[0].content[0].type, 'paragraph');
  assert.equal(adf.content[0].content[0].content[0].text, 'quoted');
});

test('hr becomes rule node', async () => {
  const adf = await convert('---');
  assert.equal(adf.content[0].type, 'rule');
});

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

test('task list with mixed states becomes taskList', async () => {
  const adf = await convert('- [ ] todo one\n- [x] done two\n- [ ] todo three');
  const tl = adf.content[0];
  assert.equal(tl.type, 'taskList');
  assert.match(tl.attrs.localId, UUID_RE);
  assert.equal(tl.content.length, 3);
  const states = tl.content.map(i => i.attrs.state);
  assert.deepEqual(states, ['TODO', 'DONE', 'TODO']);
  for (const item of tl.content) {
    assert.equal(item.type, 'taskItem');
    assert.match(item.attrs.localId, UUID_RE);
  }
});

test('each taskItem gets a unique localId', async () => {
  const adf = await convert('- [ ] a\n- [ ] b\n- [ ] c');
  const ids = adf.content[0].content.map(i => i.attrs.localId);
  assert.equal(new Set(ids).size, 3);
});

test('mixed list (some task, some not) treats as taskList when any item is task', async () => {
  const adf = await convert('- [x] checked\n- plain');
  assert.equal(adf.content[0].type, 'taskList');
  assert.equal(adf.content[0].content.length, 2);
});

test('strong wraps text in strong mark', async () => {
  const adf = await convert('**bold**');
  const node = adf.content[0].content[0];
  assert.equal(node.text, 'bold');
  assert.deepEqual(node.marks, [{ type: 'strong' }]);
});

test('emphasis wraps text in em mark', async () => {
  const adf = await convert('*italic*');
  const node = adf.content[0].content[0];
  assert.deepEqual(node.marks, [{ type: 'em' }]);
});

test('code span produces code mark', async () => {
  const adf = await convert('`x = 1`');
  const node = adf.content[0].content[0];
  assert.equal(node.text, 'x = 1');
  assert.deepEqual(node.marks, [{ type: 'code' }]);
});

test('link wraps text in link mark with href attrs', async () => {
  const adf = await convert('[click](https://example.com)');
  const node = adf.content[0].content[0];
  assert.equal(node.text, 'click');
  assert.equal(node.marks[0].type, 'link');
  assert.equal(node.marks[0].attrs.href, 'https://example.com');
});

test('code mark is exclusive — strong+code keeps only code', async () => {
  const adf = await convert('**`compile.ts`**');
  const node = adf.content[0].content.find(n => n.text === 'compile.ts');
  assert.ok(node, 'expected a text node for compile.ts');
  const types = (node.marks || []).map(m => m.type).sort();
  assert.deepEqual(types, ['code']);
});

test('HTML entities in text are unescaped', async () => {
  const adf = await convert('use <category> tag & "quotes"');
  const text = adf.content[0].content.map(n => n.text).join('');
  assert.ok(text.includes('<category>'), `got: ${text}`);
  assert.ok(text.includes('&'), `got: ${text}`);
  assert.ok(text.includes('"quotes"'), `got: ${text}`);
});

test('hard break in paragraph becomes hardBreak node', async () => {
  const adf = await convert('line one  \nline two');
  const types = adf.content[0].content.map(n => n.type);
  assert.ok(types.includes('hardBreak'), `types: ${types}`);
});
