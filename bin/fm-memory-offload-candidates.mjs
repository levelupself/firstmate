#!/usr/bin/env node
// Read-only proposal format: id, file, section, tier, marker, estimated_tokens,
// skills, projects. JSON is an array; default is escaped TSV with a header.
// Entries are top-level Markdown list items with indented continuations (even
// across blanks), or blank-separated prose/fenced blocks. Headings and standalone
// HTML comments are context, not entries; headings and lists inside fences are
// content. Section is the current heading hierarchy joined by " / ".
// Hash the exact first line (without its line ending); estimate the entry's UTF-8
// bytes after trimming trailing whitespace, using ceil(bytes / 3). Rank by tokens
// descending, then id and section in codepoint order. This is a proposal only:
// tier clocks, evidence, ownership and conditionality remain stow decisions.
// Hints use whole case-folded Unicode words (>=4 characters, excluding generic
// trigger words) shared with frontmatter descriptions of Git-untracked local
// skills, and whole registered project names mentioned anywhere in the entry.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';

const codeRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const home = path.resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || codeRoot);
const data = path.resolve(process.env.FM_DATA_OVERRIDE || path.join(home, 'data'));
const compare = (a, b) => a < b ? -1 : a > b ? 1 : 0;

function stat(file) {
  try { return fs.lstatSync(file); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
function regularText(file) {
  const info = stat(file);
  if (!info) return '';
  if (!info.isFile() || info.isSymbolicLink()) throw new Error(`not an ordinary regular file: ${file}`);
  return fs.readFileSync(file, 'utf8');
}
function directory(dir) {
  const info = stat(dir);
  if (!info) return false;
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error(`not an ordinary directory: ${dir}`);
  return true;
}

function description(text) {
  const lines = text.split(/\r?\n/);
  if (lines[0] !== '---') return '';
  const end = lines.indexOf('---', 1);
  if (end < 0) return '';
  for (let i = 1; i < end; i++) {
    const match = /^description:\s*(.*)$/.exec(lines[i]);
    if (!match) continue;
    let value = match[1];
    if (/^[>|][+-]?$/.test(value)) {
      value = '';
      while (++i < end && /^(\s+\S|\s*$)/.test(lines[i])) value += ` ${lines[i].trim()}`;
    }
    return value.replace(/^(['"])(.*)\1$/, '$2');
  }
  return '';
}
const stop = new Set('after before when whenever while under about agent agents skill skills firstmate captain should always never using with from into that this these those only must load loaded invoke use used'.split(' '));
function words(text) {
  return new Set((text.toLowerCase().match(/[\p{L}\p{N}_-]+/gu) || [])
    .filter(word => word.length >= 4 && !stop.has(word)));
}
function localSkills() {
  const tracked = execFileSync('git', ['-C', home, 'ls-files', '-z', '--', '.agents/skills/'], { encoding: 'utf8' }).split('\0');
  const dir = path.join(home, '.agents/skills');
  if (!directory(path.join(home, '.agents')) || !directory(dir)) return [];
  return fs.readdirSync(dir).sort(compare).flatMap(name => {
    const prefix = `.agents/skills/${name}/`;
    if (tracked.some(file => file === prefix.slice(0, -1) || file.startsWith(prefix))) return [];
    const skillDir = path.join(dir, name);
    const info = stat(skillDir);
    if (!info?.isDirectory() || info.isSymbolicLink()) return [];
    const skillPath = path.join(skillDir, 'SKILL.md');
    const skill = stat(skillPath);
    if (!skill?.isFile() || skill.isSymbolicLink()) return [];
    return [{ name, words: words(description(regularText(skillPath))) }];
  });
}
function projects() {
  return [...new Set(regularText(path.join(data, 'projects.md')).split(/\r?\n/)
    .flatMap(line => /^-\s+(\S+)\s+(?:\[[^\]]+\]\s+)?-\s/.exec(line)?.[1] || []))].sort(compare);
}
function mentions(text, name) {
  const escaped = name.toLowerCase().replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`(?<![\\p{L}\\p{N}_-])${escaped}(?![\\p{L}\\p{N}_-])`, 'u').test(text.toLowerCase());
}

function entries(text, file) {
  const result = [];
  const headings = [];
  let current = [], list = false, fence = null;
  function flush() {
    const content = current.join('\n').trimEnd();
    current = [];
    list = false;
    if (!content) return;
    const marker = [...content.matchAll(/<!--(?:[ap]:\d{4}-\d{2}-\d{2}|P|g)-->/g)].at(-1)?.[0] || '';
    const tier = marker.startsWith('<!--p:') ? 'perishable'
      : marker.startsWith('<!--a:') || marker === '<!--g-->' ? 'aging'
        : marker === '<!--P-->' || file !== 'data/learnings.md' ? 'pinned' : 'aging';
    result.push({ id: `${file}:${createHash('sha256').update(content.split('\n')[0]).digest('hex')}`,
      file, section: headings.filter(Boolean).join(' / '), tier, marker,
      estimated_tokens: Math.ceil(Buffer.byteLength(content) / 3), content });
  }
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (fence) {
      current.push(line);
      const close = /^\s*(`{3,}|~{3,})\s*$/.exec(line);
      if (close && close[1][0] === fence[0] && close[1].length >= fence.length) fence = null;
      continue;
    }
    const heading = /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line);
    if (heading) {
      flush();
      headings.length = heading[1].length;
      headings[heading[1].length - 1] = heading[2];
      continue;
    }
    if (/^\s*<!--.*-->\s*$/.test(line)) { if (!current.length) continue; }
    const bullet = /^(?:[-*+]\s+|\d+[.)]\s+)/.test(line);
    if (bullet) { flush(); list = true; }
    if (!line.trim()) {
      const next = lines.slice(i + 1).find(value => value.trim());
      if (list && next && /^\s+\S/.test(next)) current.push(line);
      else flush();
      continue;
    }
    if (list && !bullet && !/^\s/.test(line)) flush();
    const open = /^\s*(`{3,}|~{3,})/.exec(line);
    if (open) fence = open[1];
    current.push(line);
  }
  flush();
  return result;
}

try {
  const args = process.argv.slice(2);
  if (args.length === 1 && ['-h', '--help'].includes(args[0])) {
    console.log('Usage: fm-memory-offload-candidates.sh [--json]\nRead-only proposals ranked by estimated tokens; stow judges eligibility.');
    process.exit(0);
  }
  if (args.length > 1 || (args.length && args[0] !== '--json')) throw new Error('Usage: fm-memory-offload-candidates.sh [--json]');
  directory(data);
  const skills = localSkills(), names = projects();
  const rows = ['captain.md', 'captain-shared.md', 'learnings.md'].flatMap(name => {
    const file = `data/${name}`;
    return entries(regularText(path.join(data, name)), file).map(({ content, ...row }) => {
      const tokens = words(content);
      return { ...row, skills: skills.filter(skill => [...skill.words].some(word => tokens.has(word))).map(skill => skill.name),
        projects: names.filter(name => mentions(content, name)) };
    });
  }).sort((a, b) => b.estimated_tokens - a.estimated_tokens || compare(a.id, b.id) || compare(a.section, b.section));
  if (args[0] === '--json') console.log(JSON.stringify(rows, null, 2));
  else {
    const keys = ['id', 'file', 'section', 'tier', 'marker', 'estimated_tokens', 'skills', 'projects'];
    console.log(keys.join('\t'));
    for (const row of rows) console.log(keys.map(key => String(Array.isArray(row[key]) ? row[key].join(',') : row[key])
      .replace(/\\/g, '\\\\').replace(/\t/g, '\\t').replace(/\r/g, '\\r').replace(/\n/g, '\\n')).join('\t'));
  }
} catch (error) {
  console.error(`memory-offload-candidates: ${error.message}`);
  process.exitCode = 2;
}
