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

function tokenToAdf(token) {
  switch (token.type) {
    case 'heading':
      return { type: 'heading', attrs: { level: token.depth }, content: inlineTokens(token.tokens) };
    case 'paragraph':
      return { type: 'paragraph', content: inlineTokens(token.tokens) };
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
