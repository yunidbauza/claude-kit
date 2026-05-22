#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { marked } from './vendor/marked/marked.esm.js';

function inlineTokens(tokens) {
  const out = [];
  for (const t of tokens || []) {
    if (t.type === 'text') out.push({ type: 'text', text: t.text });
  }
  return out;
}

function listItem(item) {
  const blocks = (item.tokens || [])
    .map(t => t.type === 'text' ? { type: 'paragraph', content: inlineTokens(t.tokens || [{ type: 'text', text: t.text }]) } : tokenToAdf(t))
    .filter(Boolean);
  return { type: 'listItem', content: blocks.length ? blocks : [{ type: 'paragraph', content: [] }] };
}

function tokenToAdf(token) {
  switch (token.type) {
    case 'heading':
      return { type: 'heading', attrs: { level: token.depth }, content: inlineTokens(token.tokens) };
    case 'paragraph':
      return { type: 'paragraph', content: inlineTokens(token.tokens) };
    case 'list': {
      const isTaskList = token.items.some(it => it.task === true);
      if (isTaskList) return null; // task lists handled in Task 4
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
