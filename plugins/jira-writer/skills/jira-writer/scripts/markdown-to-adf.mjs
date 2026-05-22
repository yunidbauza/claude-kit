#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
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

function listItem(item) {
  const blocks = (item.tokens || [])
    .map(t => t.type === 'text' ? { type: 'paragraph', content: inlineTokens(t.tokens || [{ type: 'text', text: t.text }]) } : tokenToAdf(t))
    .filter(Boolean);
  return { type: 'listItem', content: blocks.length ? blocks : [{ type: 'paragraph', content: [] }] };
}

function taskList(items) {
  return {
    type: 'taskList',
    attrs: { localId: randomUUID() },
    content: items.map(it => {
      const inner = (it.tokens || []).find(t => t.type === 'text');
      return {
        type: 'taskItem',
        attrs: { localId: randomUUID(), state: it.checked ? 'DONE' : 'TODO' },
        content: inner ? inlineTokens(inner.tokens || [{ type: 'text', text: inner.text }]) : [],
      };
    }),
  };
}

function tokenToAdf(token) {
  switch (token.type) {
    case 'heading':
      return { type: 'heading', attrs: { level: token.depth }, content: inlineTokens(token.tokens) };
    case 'paragraph':
      return { type: 'paragraph', content: inlineTokens(token.tokens) };
    case 'list': {
      const isTaskList = token.items.some(it => it.task === true);
      if (isTaskList) return taskList(token.items);
      return {
        type: token.ordered ? 'orderedList' : 'bulletList',
        content: token.items.map(listItem),
      };
    }
    case 'code':
      return {
        type: 'codeBlock',
        attrs: { language: token.lang || null },
        content: token.text ? [{ type: 'text', text: token.text + (token.text.endsWith('\n') ? '' : '\n') }] : [],
      };
    case 'blockquote':
      return { type: 'blockquote', content: (token.tokens || []).map(tokenToAdf).filter(Boolean) };
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
      return { type: 'table', content: [headerRow, ...bodyRows] };
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
    content: tokens.map(tokenToAdf).filter(Boolean),
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

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(e => { console.error(e.stack || e.message); process.exit(1); });
}
