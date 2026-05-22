#!/usr/bin/env node
import { readFile } from 'node:fs/promises';

const INLINE_TYPES = new Set(['text', 'hardBreak', 'mention', 'emoji', 'inlineCard']);

function fail(path, rule, message, node) {
  return { ok: false, path, rule, message, node };
}

function checkNode(node, path) {
  if (!node || typeof node !== 'object') {
    return fail(path, 'node_shape', 'node is not an object', node);
  }

  if (node.type === 'text') {
    const marks = node.marks || [];
    const hasCode = marks.some(m => m.type === 'code');
    if (hasCode && marks.some(m => m.type !== 'code')) {
      const types = marks.map(m => m.type);
      return fail(path, 'mark_exclusivity', `text node has marks [${types.join(',')}] — code is exclusive with strong/em/link`, node);
    }
  }

  if (node.type === 'taskList' || node.type === 'taskItem') {
    const id = node.attrs && node.attrs.localId;
    if (!id || typeof id !== 'string') {
      return fail(path, 'missing_localId', `${node.type} missing required localId attr`, node);
    }
  }

  if (node.type === 'tableCell' || node.type === 'tableHeader') {
    if (!node.attrs || typeof node.attrs !== 'object') {
      return fail(path, 'missing_table_attrs', `${node.type} requires an attrs object (may be empty)`, node);
    }
  }

  if (node.type === 'paragraph' && Array.isArray(node.content)) {
    for (let i = 0; i < node.content.length; i++) {
      const child = node.content[i];
      if (child && child.type && !INLINE_TYPES.has(child.type)) {
        return fail(`${path}.content[${i}]`, 'inline_in_block', `paragraph content must be inline; got ${child.type}`, child);
      }
    }
  }

  if (Array.isArray(node.content)) {
    for (let i = 0; i < node.content.length; i++) {
      const r = checkNode(node.content[i], `${path}.content[${i}]`);
      if (r) return r;
    }
  }
  return null;
}

export function validateAdf(doc) {
  if (!doc || doc.type !== 'doc' || typeof doc.version !== 'number' || !Array.isArray(doc.content)) {
    return fail('', 'doc_shape', 'top-level doc must be {type:"doc", version:number, content:array}', doc);
  }
  for (let i = 0; i < doc.content.length; i++) {
    const r = checkNode(doc.content[i], `content[${i}]`);
    if (r) return { ...r, block_index: i };
  }
  return { ok: true };
}

async function main() {
  const [, , inputPath, ...flags] = process.argv;
  if (!inputPath) {
    console.error('usage: adf-validate.mjs <input.json> [--bisect]');
    process.exit(2);
  }
  const doc = JSON.parse(await readFile(inputPath, 'utf8'));
  const result = validateAdf(doc);
  process.stdout.write(JSON.stringify(result) + '\n');
  process.exit(result.ok ? 0 : 1);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(e => { console.error(e.stack || e.message); process.exit(2); });
}
