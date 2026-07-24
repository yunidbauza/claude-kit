#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { marked } from './vendor/marked/marked.esm.mjs';

const HTML_ENTITIES = { '&lt;': '<', '&gt;': '>', '&amp;': '&', '&quot;': '"', '&#39;': "'" };
function unescapeHtml(s) {
  return s.replace(/&(?:lt|gt|amp|quot|#39);/g, m => HTML_ENTITIES[m]);
}

function addMark(node, mark) {
  if (node.type !== 'text') return;
  const existing = node.marks || [];
  const hasCode = existing.some(m => m.type === 'code');
  const isCode = mark.type === 'code';
  if (hasCode && !isCode) return;          // drop incoming non-code when code present
  if (isCode && existing.length) node.marks = []; // drop existing when code arrives
  (node.marks ||= []).push(mark);
}

function inlineTokens(tokens) {
  const out = [];
  for (const t of tokens || []) {
    if (t.type === 'text') {
      out.push({ type: 'text', text: unescapeHtml(t.text) });
    } else if (t.type === 'strong') {
      const inner = inlineTokens(t.tokens);
      for (const n of inner) addMark(n, { type: 'strong' });
      out.push(...inner);
    } else if (t.type === 'em') {
      const inner = inlineTokens(t.tokens);
      for (const n of inner) addMark(n, { type: 'em' });
      out.push(...inner);
    } else if (t.type === 'del') {
      const inner = inlineTokens(t.tokens);
      for (const n of inner) addMark(n, { type: 'strike' });
      out.push(...inner);
    } else if (t.type === 'codespan') {
      out.push({ type: 'text', text: unescapeHtml(t.text), marks: [{ type: 'code' }] });
    } else if (t.type === 'link') {
      const inner = inlineTokens(t.tokens);
      for (const n of inner) addMark(n, { type: 'link', attrs: { href: t.href } });
      out.push(...inner);
    } else if (t.type === 'br') {
      out.push({ type: 'hardBreak' });
    } else if (t.type === 'escape') {
      out.push({ type: 'text', text: t.text });
    } else if (t.type === 'html') {
      out.push({ type: 'text', text: t.text });
    }
  }
  return out;
}

// tokenToAdf may return a single node or an array (taskList with trailing
// nested blocks) — this flattens either shape into a block list.
function blocksFromTokens(tokens) {
  return (tokens || []).flatMap(t => {
    const r = tokenToAdf(t);
    return r ? (Array.isArray(r) ? r : [r]) : [];
  });
}

function listItem(item) {
  const blocks = (item.tokens || []).flatMap(t => {
    if (t.type === 'text') return [{ type: 'paragraph', content: inlineTokens(t.tokens || [{ type: 'text', text: t.text }]) }];
    const r = tokenToAdf(t);
    return r ? (Array.isArray(r) ? r : [r]) : [];
  });
  return { type: 'listItem', content: blocks.length ? blocks : [{ type: 'paragraph', content: [] }] };
}

function taskList(items) {
  // ADF taskItem content is inline-only, so nested/follow-on blocks under a
  // task item (sublists, extra paragraphs — marked emits follow-on paragraphs
  // as additional 'text' tokens) can't live inside the item. They are emitted
  // immediately after the taskList segment containing their item, splitting
  // the list to preserve reading order; nothing is dropped.
  const out = [];
  let current = null;
  const flush = () => { if (current) out.push(current); current = null; };
  for (const it of items) {
    const toks = it.tokens || [];
    const inner = toks.find(t => t.type === 'text');
    if (!current) current = { type: 'taskList', attrs: { localId: randomUUID() }, content: [] };
    current.content.push({
      type: 'taskItem',
      attrs: { localId: randomUUID(), state: it.checked ? 'DONE' : 'TODO' },
      content: inner ? inlineTokens(inner.tokens || [{ type: 'text', text: inner.text }]) : [],
    });
    const trailing = [];
    for (const t of toks) {
      if (t === inner) continue;
      if (t.type === 'text') {
        // Follow-on paragraph inside the item — same handling as listItem.
        trailing.push({ type: 'paragraph', content: inlineTokens(t.tokens || [{ type: 'text', text: t.text }]) });
        continue;
      }
      const r = tokenToAdf(t);
      if (r) trailing.push(...(Array.isArray(r) ? r : [r]));
    }
    if (trailing.length) {
      flush();
      out.push(...trailing);
    }
  }
  flush();
  return out.length === 1 ? out[0] : out;
}

function tokenToAdf(token) {
  switch (token.type) {
    case 'heading':
      return { type: 'heading', attrs: { level: token.depth }, content: inlineTokens(token.tokens) };
    case 'paragraph':
      return { type: 'paragraph', content: inlineTokens(token.tokens) };
    case 'list': {
      // Mixed task/plain lists fall back to bulletList — taskList would force
      // plain items into checkbox taskItem nodes they never had.
      const isTaskList = token.items.every(it => it.task === true);
      if (isTaskList) return taskList(token.items);
      return {
        type: token.ordered ? 'orderedList' : 'bulletList',
        content: token.items.map(listItem),
      };
    }
    case 'code':
      return {
        type: 'codeBlock',
        // language must be a string when present — omit attrs entirely for
        // unlabeled fences rather than emitting language: null.
        ...(token.lang ? { attrs: { language: token.lang } } : {}),
        content: token.text ? [{ type: 'text', text: token.text + (token.text.endsWith('\n') ? '' : '\n') }] : [],
      };
    case 'blockquote':
      return { type: 'blockquote', content: blocksFromTokens(token.tokens) };
    case 'hr':
      return { type: 'rule' };
    case 'table': {
      const headerRow = {
        type: 'tableRow',
        content: token.header.map(cell => ({
          type: 'tableHeader',
          attrs: {},
          content: [{ type: 'paragraph', content: inlineTokens(cell.tokens) }],
        })),
      };
      const bodyRows = token.rows.map(row => ({
        type: 'tableRow',
        content: row.map(cell => ({
          type: 'tableCell',
          attrs: {},
          content: [{ type: 'paragraph', content: inlineTokens(cell.tokens) }],
        })),
      }));
      // Canonical table attrs per reference/adf.md (and the repo's
      // adf-helpers.mjs) — previously omitted here, diverging from both.
      return {
        type: 'table',
        attrs: { isNumberColumnEnabled: false, layout: 'default' },
        content: [headerRow, ...bodyRows],
      };
    }
    case 'space':
      return null;
    default:
      return null;
  }
}

export function convertMarkdown(md) {
  const tokens = marked.lexer(md);
  return {
    type: 'doc',
    version: 1,
    content: blocksFromTokens(tokens),
  };
}

async function main() {
  const [, , inputPath, outputPath] = process.argv;
  if (!inputPath) {
    console.error('usage: markdown-to-adf.mjs <input.md> [output.json]');
    process.exit(2);
  }
  const md = await readFile(inputPath, 'utf8');
  const adf = convertMarkdown(md);
  const json = JSON.stringify(adf, null, 2);
  if (outputPath) await writeFile(outputPath, json);
  else process.stdout.write(json + '\n');
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(e => { console.error(e.stack || e.message); process.exit(1); });
}
