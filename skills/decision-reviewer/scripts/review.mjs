#!/usr/bin/env node
/**
 * decision-reviewer — answer a batch of open questions in the browser; decisions
 * are written straight back into the markdown (the md is the single source of truth).
 *
 *   node review.mjs --file questions.md               serve on an ephemeral port + open the browser
 *   node review.mjs --file questions.md --port 4499   pin the port
 *   node review.mjs --file questions.md --no-open     don't auto-open the browser
 *   node review.mjs --file questions.md --selftest [--expect N]   parse + round-trip checks (never writes)
 *   node review.mjs --file questions.md --summary     print answered/open questions (harvest step)
 *
 * Format (full grammar in the skill's REFERENCE.md):
 *   # Title — shown as the page title
 *   > project context preamble (blockquote; fed to the Discuss chat)
 *   ## Section name            (arbitrary; groups questions in the nav)
 *   ### Q1. Question title?    (globally unique Qn ids; ✅ added when answered)
 *   One-line why.
 *   *Affects:* a, b            (optional)
 *   - **Decides:** ...
 *   - **Recommendation:** ...
 *   - **Other options:** ...
 *   - **Decision (YYYY-MM-DD):** ...   (written by this tool)
 *   Multi-line field values continue on 2-space-indented lines.
 *
 * Answered questions get a ✅ in the heading. Resume = just reopen the page:
 * it re-parses the file and shows what's left. Killing the server loses nothing.
 */
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { createServer } from 'node:http'
import { execFile } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { dirname, join, resolve, basename } from 'node:path'
import { homedir } from 'node:os'

const args = process.argv.slice(2)
const argVal = (name, dflt) => {
  const i = args.indexOf(name)
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt
}
const FILE = resolve(argVal('--file', ''))
if (!argVal('--file', '')) {
  console.error('Usage: node review.mjs --file <questions.md> [--port N] [--no-open] [--selftest [--expect N]] [--summary]')
  process.exit(1)
}
const PORT = Number(argVal('--port', 0)) || 0
const mdDir = dirname(FILE)

// project root = nearest ancestor of the md with a .git dir (cwd for the Discuss chat)
const root = (() => {
  let cur = mdDir
  for (let i = 0; i < 30; i++) {
    if (existsSync(join(cur, '.git'))) return cur
    const up = dirname(cur)
    if (up === cur) break
    cur = up
  }
  return mdDir
})()

// ---------------------------------------------------------------- parsing

const reTitle = /^# (.+)$/
const reSection = /^## (.+)$/
const reQuestion = /^### (Q\d+)\. (✅ )?(.*)$/
const reField = /^- \*\*(Decides|Recommendation|Other options):\*\* (.*)$/
const reDecision = /^- \*\*Decision(?: \((\d{4}-\d{2}-\d{2})\))?:\*\* (.*)$/

const FIELD_KEY = { Decides: 'decides', Recommendation: 'recommendation', 'Other options': 'options' }

export function parse(md) {
  const lines = md.split('\n')
  const st = { title: '', context: [], sections: [], orphans: [], drift: [] }
  let section = null
  let q = null
  let last = null // {obj, key} for 2-space multi-line continuations
  let sawSection = false
  let fence = false
  let fieldsSeen = false

  for (const line of lines) {
    let m
    // fenced code blocks are inert — nothing inside them is structure
    if (/^(```|~~~)/.test(line)) { fence = !fence; if (q) q.body.push(line); last = null; continue }
    if (fence) { if (q && line.trim()) q.body.push(line); continue }
    if (!st.title && (m = line.match(reTitle))) { st.title = m[1].trim(); continue }
    if ((m = line.match(reSection))) {
      section = { name: m[1].trim(), questions: [] }
      st.sections.push(section)
      q = null; last = null; sawSection = true
      continue
    }
    if ((m = line.match(reQuestion))) {
      if (!section) { section = { name: 'Questions', questions: [] }; st.sections.push(section) }
      q = { qid: m[1], title: m[3], body: [], affects: '', decides: '', recommendation: '', options: '', decision: '', decisionDate: '', answered: !!m[2] }
      section.questions.push(q)
      last = null; fieldsSeen = false
      continue
    }
    // any other heading (####, a second H1, a malformed ###) is structural drift
    if (/^#{1,6} /.test(line)) { st.orphans.push(line); q = null; last = null; continue }
    if (!q) {
      // before the first section: blockquote lines form the project-context preamble
      if (!sawSection && line.startsWith('> ')) st.context.push(line.slice(2))
      else if (!sawSection && line === '>') st.context.push('')
      else if (sawSection && /^>( |$)/.test(line)) st.drift.push('context blockquote after the first "##" is ignored — move it above the first section')
      // field/decision bullets floating outside a question = format drift
      else if (reField.test(line) || reDecision.test(line)) st.orphans.push(line)
      continue
    }
    if (line.startsWith('*Affects:*')) { q.affects = line.replace(/^\*Affects:\*\s*/, ''); last = null; continue }
    m = line.match(reDecision)
    if (m) { q.decisionDate = m[1] || ''; q.decision = m[2]; q.answered = true; last = { obj: q, key: 'decision' }; fieldsSeen = true; continue }
    m = line.match(reField)
    if (m) { const k = FIELD_KEY[m[1]]; q[k] = m[2]; last = { obj: q, key: k }; fieldsSeen = true; continue }
    // continuation may be a whitespace-only line (blank line inside a multi-paragraph value)
    if (last && line.startsWith('  ')) { last.obj[last.key] += '\n' + line.slice(2); continue }
    last = null
    if (line.trim() && !line.startsWith('#')) {
      // plain text after field bullets started is almost always a mis-indented continuation
      if (fieldsSeen) st.drift.push(q.qid + ': body text after field bullets (' + JSON.stringify(line.slice(0, 60)) + ') — wrap field values with a 2-space indent')
      q.body.push(line)
    }
  }
  return st
}

export function allQuestions(st) {
  const out = []
  for (const s of st.sections) for (const q of s.questions) out.push({ section: s.name, q })
  return out
}

// ------------------------------------------------------------- write-back

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
// local wall-clock date, not UTC — a decision made at 9pm in São Paulo is "today"
const today = () => {
  const d = new Date()
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0')
}

export function setDecision(md, target) {
  const lines = md.split('\n')
  const text = (target.decision || '').replace(/\r\n?/g, '\n').trim()
  const headRe = new RegExp('^### ' + escapeRe(target.qid) + '\\. ')
  const start = lines.findIndex((l) => headRe.test(l))
  if (start < 0) throw new Error(target.qid + ' not found')
  let end = lines.length
  let fence = false
  for (let i = start + 1; i < lines.length; i++) {
    if (/^(```|~~~)/.test(lines[i])) { fence = !fence; continue }
    if (!fence && /^#{1,6} /.test(lines[i])) { end = i; break }
  }
  // drop any existing decision (incl. 2-space continuation lines)
  for (let i = start + 1; i < end; i++) {
    if (/^- \*\*Decision(?: \([^)]*\))?:\*\*/.test(lines[i])) {
      let j = i + 1
      while (j < end && lines[j].startsWith('  ')) j++
      lines.splice(i, j - i); end -= j - i
      break
    }
  }
  const h = lines[start].match(reQuestion)
  if (!h) throw new Error('malformed heading for ' + target.qid)
  lines[start] = '### ' + h[1] + '. ' + (text ? '✅ ' : '') + h[3]
  if (text) {
    // insert after the last non-blank line of the question block — no anchor field required
    let at = start
    for (let i = start + 1; i < end; i++) if (lines[i].trim()) at = i
    const parts = text.split('\n')
    lines.splice(at + 1, 0, '- **Decision (' + today() + '):** ' + parts[0], ...parts.slice(1).map((p) => '  ' + p))
  }
  return lines.join('\n')
}

// --------------------------------------------------------------- selftest

if (args.includes('--selftest')) {
  const md = readFileSync(FILE, 'utf8')
  const st = parse(md)
  const qs = allQuestions(st)
  console.log('title:', st.title || '(none)', '| sections:', st.sections.length, '| questions:', qs.length)
  let bad = 0
  const miss = (...m) => { bad++; console.log('FAIL', ...m) }

  if (!qs.length) miss('no questions parsed — the file does not match the format (see REFERENCE.md)')
  const expect = Number(argVal('--expect', 0))
  if (expect && expect !== qs.length) miss('expected ' + expect + ' questions but parsed ' + qs.length + ' — formatting silently failed somewhere')
  if (!expect) console.log('note: no --expect N given — a silently dropped question cannot be detected')
  for (const o of st.orphans) miss('unparsed line (format drift):', JSON.stringify(o.slice(0, 90)))
  for (const d of st.drift) miss('format drift:', d)
  for (const s of st.sections) if (!s.questions.length) miss('section with no parsed questions:', JSON.stringify(s.name))
  const seen = new Set()
  for (const { q } of qs) {
    if (seen.has(q.qid)) miss('duplicate id', q.qid)
    seen.add(q.qid)
    if (!q.body.length) miss(q.qid, 'missing why (body line under the heading)')
    for (const k of ['decides', 'recommendation', 'options']) if (!q[k]) miss(q.qid, 'missing', k)
  }

  // round-trip on in-memory copies only. Synthesize an all-unanswered base first so
  // this never skips: clearing real answers in memory gives a stable baseline that
  // set-then-clear must restore byte-identically.
  if (qs.length) {
    let base = md
    try {
      for (const { q } of qs) if (q.answered) base = setDecision(base, { qid: q.qid, decision: '' })
      const get = (m, id) => allQuestions(parse(m)).map((x) => x.q).find((x) => x.qid === id)
      for (const { q } of qs.slice(0, 2)) {
        let m2 = setDecision(base, { qid: q.qid, decision: 'test line1\nline2' })
        const r1 = get(m2, q.qid)
        if (!r1 || r1.decision !== 'test line1\nline2' || !r1.answered) miss('round-trip', q.qid, JSON.stringify(r1 && r1.decision))
        m2 = setDecision(m2, { qid: q.qid, decision: 'replaced' })
        if (get(m2, q.qid).decision !== 'replaced') miss('overwrite', q.qid)
        m2 = setDecision(m2, { qid: q.qid, decision: 'para1\n\npara2' })
        if (get(m2, q.qid).decision !== 'para1\n\npara2') miss('blank-line round-trip', q.qid, JSON.stringify(get(m2, q.qid).decision))
        m2 = setDecision(m2, { qid: q.qid, decision: '' })
        if (m2 !== base) miss('not byte-identical after clearing', q.qid)
      }
    } catch (e) {
      miss('round-trip threw:', String(e.message || e))
    }
  }
  console.log(bad ? 'SELFTEST FAILED (' + bad + ')' : 'SELFTEST OK — ' + qs.length + ' questions across ' + st.sections.length + ' sections')
  process.exit(bad ? 1 : 0)
}

// ---------------------------------------------------------------- summary

if (args.includes('--summary')) {
  const st = parse(readFileSync(FILE, 'utf8'))
  const qs = allQuestions(st)
  const answered = qs.filter((x) => x.q.answered)
  console.log((st.title || basename(FILE)) + ' — ' + answered.length + '/' + qs.length + ' answered')
  for (const s of st.sections) {
    console.log('\n## ' + s.name)
    for (const q of s.questions) {
      if (q.answered) console.log('✅ ' + q.qid + '. ' + q.title + '\n   → ' + q.decision.replace(/\n/g, '\n   '))
      else console.log('○ ' + q.qid + '. ' + q.title)
    }
  }
  process.exit(0)
}

// ------------------------------------------------------- chat with Claude
// Threads live in <mdDir>/.oq/<file>.chats.json — NEVER in the markdown, so the
// parse/write-back contract above is untouched.

const CHATS_FILE = join(mdDir, '.oq', basename(FILE).replace(/\.md$/i, '') + '.chats.json')
const loadChats = () => { try { return JSON.parse(readFileSync(CHATS_FILE, 'utf8')) } catch { return {} } }
const saveChats = (c) => { mkdirSync(dirname(CHATS_FILE), { recursive: true }); writeFileSync(CHATS_FILE, JSON.stringify(c, null, 1)) }

function findTarget(qid) {
  const st = parse(readFileSync(FILE, 'utf8'))
  for (const { q } of allQuestions(st)) if (q.qid === qid) return { st, q }
  return null
}

function chatContext(st, item) {
  return [
    'You are discussing ONE question from an async decision-review session with the person who has to decide it.',
    'PROJECT CONTEXT: ' + (st.title || 'untitled') + (st.context.length ? ' — ' + st.context.join(' ').trim() : ''),
    'The questions file is ' + FILE + '; the project root is ' + root + '.',
    'You have READ-ONLY file access (Read/Glob/Grep). Read project files when the question references them. Never modify files.',
    '',
    'QUESTION ' + item.qid + ': ' + item.title,
    'WHY: ' + item.body.join(' '),
    item.affects ? 'AFFECTS: ' + item.affects : '',
    'DECIDES: ' + item.decides,
    'RECOMMENDATION: ' + item.recommendation,
    'OTHER OPTIONS: ' + item.options,
    item.answered ? 'DECISION SO FAR (' + (item.decisionDate || 'undated') + '): ' + item.decision : 'NOT YET DECIDED.',
    '',
    'Audience: the decision-maker reviewing these questions. Be concise and plain-language; when asked for an opinion, take a clear stance. Output renders with minimal markdown (inline `code`, **bold**, line breaks) — no headings or tables.',
  ].filter(Boolean).join('\n')
}

function claudeBin() {
  if (process.env.CLAUDE_BIN) return process.env.CLAUDE_BIN
  const local = join(homedir(), '.claude', 'local', 'claude')
  try { readFileSync(local); return local } catch { return 'claude' }
}

function runClaude(cliArgs, cb) {
  execFile(claudeBin(), cliArgs, { cwd: root, maxBuffer: 64 * 1024 * 1024, timeout: 420000, env: process.env }, (err, stdout, stderr) => {
    if (err && !stdout) {
      if (err.code === 'ENOENT') return cb(new Error('claude CLI not found (set CLAUDE_BIN to its path)'))
      // prefer stderr — err.message starts with the full command line, which buries the real error
      const detail = String(stderr || '').trim() || String(err.message || err)
      return cb(new Error(('claude exited (' + (err.code ?? 'killed') + '): ' + detail).slice(0, 400)))
    }
    let j
    try { j = JSON.parse(stdout) } catch { return cb(new Error('unparseable claude output: ' + String(stdout).slice(0, 200))) }
    if (j.is_error) return cb(new Error(String(j.result || j.subtype || 'claude error').slice(0, 400)))
    cb(null, j)
  })
}

// ------------------------------------------------------------------- HTML

const HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Decision review</title>
<style>
  :root {
    --bg: #f6f7f9; --panel: #fff; --ink: #1a2333; --muted: #5b6678; --line: #e3e7ee;
    --accent: #2563eb; --green: #16a34a; --green-bg: #f0fdf4; --green-line: #bbf7d0;
    --blue-bg: #eff6ff; --blue-line: #bfdbfe; --amber: #b45309;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0f1420; --panel: #161d2d; --ink: #e6eaf2; --muted: #93a0b4; --line: #273042;
      --accent: #60a5fa; --green: #4ade80; --green-bg: #11231a; --green-line: #1d4029;
      --blue-bg: #14213a; --blue-line: #1e3a5f; --amber: #fbbf24;
    }
  }
  * { box-sizing: border-box; }
  body { margin: 0; font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--ink); }
  code { background: var(--blue-bg); border: 1px solid var(--blue-line); border-radius: 4px; padding: 0 4px; font-size: 13px; }
  header { position: sticky; top: 0; z-index: 5; background: var(--panel); border-bottom: 1px solid var(--line); padding: 10px 20px; display: flex; align-items: center; gap: 16px; }
  header h1 { font-size: 15px; margin: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 40vw; }
  .progress { flex: 1; max-width: 420px; height: 8px; background: var(--line); border-radius: 6px; overflow: hidden; }
  .progress > div { height: 100%; background: var(--green); transition: width .3s; }
  .ptext { font-size: 13px; color: var(--muted); white-space: nowrap; }
  .filters { display: flex; gap: 6px; margin-left: auto; }
  .filters button { border: 1px solid var(--line); background: var(--panel); color: var(--muted); border-radius: 6px; padding: 4px 10px; font-size: 13px; cursor: pointer; }
  .filters button.on { background: var(--accent); border-color: var(--accent); color: #fff; }
  .layout { display: flex; }
  nav { width: 290px; flex-shrink: 0; padding: 14px 8px 40px 14px; position: sticky; top: 49px; height: calc(100vh - 49px); overflow-y: auto; }
  nav a { display: flex; justify-content: space-between; gap: 8px; padding: 5px 8px; border-radius: 6px; color: var(--ink); text-decoration: none; font-size: 13.5px; cursor: pointer; }
  nav a:hover { background: var(--panel); }
  nav a.on { background: var(--accent); color: #fff; }
  nav a.done { color: var(--muted); }
  nav a.on .badge { background: rgba(255,255,255,.25); color: #fff; }
  .badge { font-size: 11.5px; background: var(--line); color: var(--muted); border-radius: 10px; padding: 0 7px; align-self: center; white-space: nowrap; }
  .badge.full { background: var(--green-bg); color: var(--green); border: 1px solid var(--green-line); }
  main { flex: 1; min-width: 0; padding: 18px 24px 80px; max-width: 1000px; }
  .card { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 16px 18px; margin-bottom: 14px; }
  .card.answered { border-left: 3px solid var(--green); }
  .qhead { display: flex; gap: 10px; align-items: baseline; }
  .qhead h3 { margin: 0 0 4px; font-size: 15.5px; line-height: 1.45; flex: 1; }
  .chip { font-size: 11.5px; border-radius: 10px; padding: 1px 8px; white-space: nowrap; }
  .chip.ans { background: var(--green-bg); color: var(--green); border: 1px solid var(--green-line); }
  .chip.open { background: var(--blue-bg); color: var(--accent); border: 1px solid var(--blue-line); }
  .field { margin-top: 8px; font-size: 13.5px; }
  .field .lbl { font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: .07em; display: block; margin-bottom: 2px; }
  .why { color: var(--muted); }
  .why .lbl { color: var(--muted); }
  .decides { background: var(--blue-bg); border: 1px solid var(--blue-line); border-radius: 8px; padding: 8px 11px; }
  .decides .lbl { color: var(--accent); }
  .rec { background: var(--green-bg); border: 1px solid var(--green-line); border-radius: 8px; padding: 8px 11px; }
  .rec .lbl { color: var(--green); }
  .opts { color: var(--muted); }
  .opts .lbl { color: var(--amber); }
  .affects { font-size: 12.5px; color: var(--muted); font-style: italic; margin-top: 2px; }
  .decision { margin-top: 12px; border-top: 1px dashed var(--line); padding-top: 10px; }
  .decision textarea { width: 100%; min-height: 64px; resize: vertical; border: 1px solid var(--line); border-radius: 8px; background: var(--bg); color: var(--ink); font: inherit; font-size: 14px; padding: 8px 10px; }
  .decision textarea:focus { outline: 2px solid var(--accent); border-color: transparent; }
  .dbtns { display: flex; gap: 8px; margin-top: 8px; align-items: center; }
  .dbtns button { border-radius: 7px; padding: 6px 13px; font-size: 13.5px; cursor: pointer; border: 1px solid var(--line); background: var(--panel); color: var(--ink); }
  .dbtns .save { background: var(--accent); border-color: var(--accent); color: #fff; font-weight: 600; }
  .dbtns .save:disabled { opacity: .45; cursor: default; }
  .dbtns .userec { color: var(--green); border-color: var(--green-line); background: var(--green-bg); }
  .dbtns .clear { color: var(--muted); margin-left: auto; }
  .dmeta { font-size: 12px; color: var(--muted); }
  .empty { text-align: center; color: var(--muted); padding: 60px 0; }
  .empty button { margin-top: 12px; border: 1px solid var(--accent); color: var(--accent); background: none; border-radius: 8px; padding: 8px 16px; font-size: 14px; cursor: pointer; }
  .toast { position: fixed; bottom: 18px; right: 18px; background: #b91c1c; color: #fff; padding: 10px 16px; border-radius: 8px; font-size: 13.5px; display: none; max-width: 440px; }
  abbr[title] { text-decoration: underline dotted; text-underline-offset: 2px; cursor: help; }
  .chat { margin-top: 10px; border-top: 1px dashed var(--line); padding-top: 10px; }
  .clog { display: flex; flex-direction: column; gap: 6px; margin-bottom: 8px; }
  .msg { padding: 7px 10px; border-radius: 8px; font-size: 13.5px; max-width: 92%; line-height: 1.5; }
  .msg.user { align-self: flex-end; background: var(--blue-bg); border: 1px solid var(--blue-line); }
  .msg.claude { align-self: flex-start; background: var(--bg); border: 1px solid var(--line); }
  .chat textarea { width: 100%; min-height: 40px; resize: vertical; border: 1px solid var(--line); border-radius: 8px; background: var(--bg); color: var(--ink); font: inherit; font-size: 14px; padding: 8px 10px; }
  .chat textarea:focus { outline: 2px solid var(--accent); border-color: transparent; }
  .cbtns { display: flex; gap: 8px; margin-top: 6px; align-items: center; }
  .cbtns button { border-radius: 7px; padding: 5px 12px; font-size: 13px; cursor: pointer; border: 1px solid var(--line); background: var(--panel); color: var(--ink); }
  .cbtns button:disabled { opacity: .45; cursor: default; }
  .cbtns .csend { background: var(--accent); border-color: var(--accent); color: #fff; font-weight: 600; }
  .cstatus { font-size: 12px; color: var(--muted); }
  .cstatus.busy::after { content: '…'; animation: dots 1.2s steps(4, end) infinite; }
  @keyframes dots { 0% { content: ''; } 25% { content: '.'; } 50% { content: '..'; } 75% { content: '...'; } }
</style>
</head>
<body>
<header>
  <h1 id="title">Decision review</h1>
  <div class="progress"><div id="pbar" style="width:0"></div></div>
  <span class="ptext" id="ptext"></span>
  <div class="filters" id="filters">
    <button data-f="open">Unanswered</button>
    <button data-f="all">All</button>
    <button data-f="answered">Answered</button>
  </div>
</header>
<div class="layout">
  <nav id="nav"></nav>
  <main id="main"></main>
</div>
<div class="toast" id="toast"></div>
<script>
'use strict';
var state = null;
var current = null;
var filter = 'open';
var chats = {};
var legend = {};
var openChats = {};

function esc(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
function mdi(s) {
  // minimal inline markdown: \`code\` and **bold**; newlines become <br>
  var h = esc(s);
  h = h.replace(/\\\`([^\\\`]+)\\\`/g, function (_, c) { return '<code>' + c + '</code>'; });
  h = h.replace(/\\*\\*([^*]+)\\*\\*/g, '<strong>$1</strong>');
  // Q-id tooltips (single pass — replacements are not rescanned)
  h = h.replace(/\\b(Q\\d{1,3})\\b/g, function (tok) {
    var t = legend[tok];
    if (!t) return tok;
    return '<abbr title="' + esc(t).replace(/"/g, '&quot;') + '">' + tok + '</abbr>';
  });
  return h.replace(/\\n/g, '<br>');
}
function toast(msg) {
  var t = document.getElementById('toast');
  t.textContent = msg; t.style.display = 'block';
  setTimeout(function () { t.style.display = 'none'; }, 5000);
}
function counts(items) {
  var a = 0;
  for (var i = 0; i < items.length; i++) if (items[i].answered) a++;
  return { a: a, t: items.length };
}
function renderNav() {
  var nav = document.getElementById('nav');
  var html = '';
  var ta = 0, tt = 0;
  for (var i = 0; i < state.sections.length; i++) {
    var s = state.sections[i], c = counts(s.questions);
    ta += c.a; tt += c.t;
    html += '<a data-g="' + esc(s.name) + '" class="' + (s.name === current ? 'on ' : '') + (c.a === c.t ? 'done' : '') + '">'
      + '<span>' + esc(s.name) + '</span>'
      + '<span class="badge' + (c.a === c.t ? ' full' : '') + '">' + c.a + '/' + c.t + '</span></a>';
  }
  nav.innerHTML = html;
  var links = nav.querySelectorAll('a');
  for (var j = 0; j < links.length; j++) {
    links[j].addEventListener('click', function () { current = this.getAttribute('data-g'); render(); });
  }
  document.getElementById('pbar').style.width = (tt ? (100 * ta / tt) : 0) + '%';
  document.getElementById('ptext').textContent = ta + ' / ' + tt + ' answered';
}
function fieldHtml(cls, lbl, val) {
  return '<div class="field ' + cls + '"><span class="lbl">' + lbl + '</span>' + mdi(val) + '</div>';
}
function makeCard(item) {
  var card = document.createElement('div');
  card.className = 'card' + (item.answered ? ' answered' : '');
  var html = '<div class="qhead"><h3><strong>' + esc(item.qid) + '.</strong> ' + mdi(item.title) + '</h3>'
    + '<span class="chip ' + (item.answered ? 'ans">✅ Answered' : 'open">Open') + '</span></div>';
  if (item.body.length) html += '<div class="field why">' + mdi(item.body.join('\\n')) + '</div>';
  if (item.affects) html += '<div class="affects">Affects: ' + mdi(item.affects) + '</div>';
  html += fieldHtml('decides', 'Decides', item.decides);
  html += fieldHtml('rec', 'Recommendation', item.recommendation);
  if (item.options) html += fieldHtml('opts', 'Other options', item.options);
  html += '<div class="decision">'
    + '<textarea placeholder="Your decision… (Cmd/Ctrl+Enter to save)"></textarea>'
    + '<div class="dbtns">'
    + '<button class="save">Save decision</button>'
    + '<button class="userec">Use recommendation</button>'
    + '<button class="discuss">💬 Discuss</button>'
    + '<span class="dmeta"></span>'
    + (item.answered ? '<button class="clear">Clear answer</button>' : '')
    + '</div></div>';
  html += '<div class="chat" style="display:none">'
    + '<div class="clog"></div>'
    + '<textarea placeholder="Ask Claude about this question… (Cmd/Ctrl+Enter to send)"></textarea>'
    + '<div class="cbtns">'
    + '<button class="csend">Send</button>'
    + '<button class="cexplain">Explain this question</button>'
    + '<span class="cstatus"></span>'
    + '</div></div>';
  card.innerHTML = html;

  var ta = card.querySelector('textarea');
  var saveBtn = card.querySelector('.save');
  var meta = card.querySelector('.dmeta');
  ta.value = item.decision || '';
  if (item.decisionDate) meta.textContent = 'answered ' + item.decisionDate;
  function grow() { ta.style.height = 'auto'; ta.style.height = Math.max(64, ta.scrollHeight + 2) + 'px'; }
  ta.addEventListener('input', grow);
  setTimeout(grow, 0);

  function post(decision, onOk) {
    saveBtn.disabled = true;
    fetch('/api/decision', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ qid: item.qid, decision: decision }) })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
      .then(function (res) {
        saveBtn.disabled = false;
        if (!res.ok) { toast('Save failed: ' + (res.j.error || 'unknown')); return; }
        onOk();
      })
      .catch(function (e) { saveBtn.disabled = false; toast('Save failed: ' + e); });
  }
  saveBtn.addEventListener('click', function () {
    var v = ta.value.trim();
    if (!v) { toast('Write a decision first (or use Clear to un-answer).'); return; }
    post(v, function () {
      item.decision = v; item.answered = true;
      var d = new Date();
      item.decisionDate = d.getFullYear() + '-' + ('0' + (d.getMonth() + 1)).slice(-2) + '-' + ('0' + d.getDate()).slice(-2);
      render();
    });
  });
  card.querySelector('.userec').addEventListener('click', function () {
    ta.value = item.recommendation; grow(); ta.focus();
  });
  var clearBtn = card.querySelector('.clear');
  if (clearBtn) clearBtn.addEventListener('click', function () {
    post('', function () { item.decision = ''; item.answered = false; item.decisionDate = ''; render(); });
  });
  ta.addEventListener('keydown', function (e) {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') saveBtn.click();
  });

  // ----- per-question chat with Claude (threads live in .oq/<file>.chats.json)
  var chatKey = item.qid;
  var chatEl = card.querySelector('.chat');
  var clog = chatEl.querySelector('.clog');
  var cta = chatEl.querySelector('textarea');
  var csend = chatEl.querySelector('.csend');
  var cexplain = chatEl.querySelector('.cexplain');
  var cstatus = chatEl.querySelector('.cstatus');
  function renderLog() {
    var th = chats[chatKey];
    var h2 = '';
    if (th) for (var i = 0; i < th.messages.length; i++) {
      var m2 = th.messages[i];
      h2 += '<div class="msg ' + (m2.role === 'user' ? 'user' : 'claude') + '">' + mdi(m2.text) + '</div>';
    }
    clog.innerHTML = h2;
  }
  function openChat() {
    openChats[chatKey] = true;
    chatEl.style.display = 'block';
    renderLog();
  }
  if (openChats[chatKey]) openChat();
  card.querySelector('.discuss').addEventListener('click', function () {
    if (chatEl.style.display === 'none') { openChat(); cta.focus(); }
    else { chatEl.style.display = 'none'; openChats[chatKey] = false; }
  });
  function sendChat(text) {
    text = (text || '').trim();
    if (!text || csend.disabled) return;
    var th = chats[chatKey] || (chats[chatKey] = { messages: [], sessionId: '' });
    th.messages.push({ role: 'user', text: text });
    renderLog();
    cta.value = '';
    csend.disabled = true; cexplain.disabled = true;
    cstatus.textContent = 'Claude is thinking'; cstatus.className = 'cstatus busy';
    fetch('/api/chat', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ qid: item.qid, message: text }) })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
      .then(function (res) {
        csend.disabled = false; cexplain.disabled = false;
        cstatus.textContent = ''; cstatus.className = 'cstatus';
        if (!res.ok) { th.messages.pop(); renderLog(); toast('Chat failed: ' + (res.j.error || 'unknown')); return; }
        th.sessionId = res.j.sessionId;
        th.messages.push({ role: 'claude', text: res.j.reply });
        renderLog();
      })
      .catch(function (e) {
        csend.disabled = false; cexplain.disabled = false;
        cstatus.textContent = ''; cstatus.className = 'cstatus';
        th.messages.pop(); renderLog(); toast('Chat failed: ' + e);
      });
  }
  csend.addEventListener('click', function () { sendChat(cta.value); });
  cexplain.addEventListener('click', function () {
    sendChat('Explain this question in plain language: what is the underlying problem, and what would each option mean in practice? Under 250 words.');
  });
  cta.addEventListener('keydown', function (e) {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') sendChat(cta.value);
  });

  return card;
}
function nextOpenSection() {
  for (var i = 0; i < state.sections.length; i++) {
    var c = counts(state.sections[i].questions);
    if (c.a < c.t) return state.sections[i].name;
  }
  return null;
}
function render() {
  renderNav();
  var main = document.getElementById('main');
  main.innerHTML = '';
  var g = null;
  for (var i = 0; i < state.sections.length; i++) if (state.sections[i].name === current) g = state.sections[i];
  if (!g) g = state.sections[0];
  var shown = 0;
  if (g) for (var k = 0; k < g.questions.length; k++) {
    var it = g.questions[k];
    if (filter === 'open' && it.answered) continue;
    if (filter === 'answered' && !it.answered) continue;
    main.appendChild(makeCard(it));
    shown++;
  }
  if (!shown) {
    var div = document.createElement('div');
    div.className = 'empty';
    var nxt = nextOpenSection();
    if (filter === 'open' && nxt && (!g || nxt !== g.name)) {
      div.innerHTML = '🎉 Nothing left here.<br><button>Go to next unanswered section</button>';
      div.querySelector('button').addEventListener('click', function () { current = nxt; render(); window.scrollTo(0, 0); });
    } else if (filter === 'open' && !nxt) {
      var all = 0;
      for (var n = 0; n < state.sections.length; n++) all += state.sections[n].questions.length;
      div.innerHTML = '🏁 All ' + all + ' questions answered. The markdown has every decision recorded — tell Claude you are done.';
    } else {
      div.textContent = 'Nothing matches this filter.';
    }
    main.appendChild(div);
  }
  var fb = document.querySelectorAll('#filters button');
  for (var f = 0; f < fb.length; f++) fb[f].className = fb[f].getAttribute('data-f') === filter ? 'on' : '';
}
document.getElementById('filters').addEventListener('click', function (e) {
  var b = e.target.closest('button');
  if (!b) return;
  filter = b.getAttribute('data-f');
  render();
});
Promise.all([
  fetch('/api/state').then(function (r) { return r.json(); }),
  fetch('/api/chats').then(function (r) { return r.json(); }).catch(function () { return {}; })
]).then(function (rs) {
  state = rs[0];
  chats = rs[1] || {};
  if (state.title) {
    document.title = state.title;
    document.getElementById('title').textContent = state.title;
  }
  for (var i = 0; i < state.sections.length; i++)
    for (var j = 0; j < state.sections[i].questions.length; j++) {
      var q = state.sections[i].questions[j];
      legend[q.qid] = q.title;
    }
  var nxt = nextOpenSection();
  if (nxt) current = nxt;
  render();
});
</script>
</body>
</html>
`

// ----------------------------------------------------------------- server

const server = createServer((req, res) => {
  const json = (code, obj) => {
    res.writeHead(code, { 'content-type': 'application/json' })
    res.end(JSON.stringify(obj))
  }
  try {
    if (req.method === 'GET' && (req.url === '/' || req.url.startsWith('/?'))) {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
      res.end(HTML)
    } else if (req.method === 'GET' && req.url === '/api/state') {
      json(200, { file: FILE, ...parse(readFileSync(FILE, 'utf8')) })
    } else if (req.method === 'GET' && req.url === '/api/chats') {
      json(200, loadChats())
    } else if (req.method === 'POST' && req.url === '/api/chat') {
      let body = ''
      req.on('data', (c) => { body += c })
      req.on('end', () => {
        try {
          if (body.length > 1e6) return json(413, { ok: false, error: 'request too large' })
          const t = JSON.parse(body)
          const msg = String(t.message || '').trim()
          if (!msg) return json(400, { ok: false, error: 'empty message' })
          const found = findTarget(String(t.qid || ''))
          if (!found) return json(404, { ok: false, error: 'question not found in the md' })
          const key = String(t.qid)
          const thread = loadChats()[key] || { messages: [], sessionId: '' }
          const freshArgs = () => {
            let prompt = chatContext(found.st, found.q)
            // a stale session id loses Claude's memory — replay the recent thread so it can continue
            if (thread.messages.length) {
              const tail = thread.messages.slice(-6).map((p) => (p.role === 'user' ? 'USER: ' : 'CLAUDE: ') + String(p.text).slice(0, 1200))
              prompt += '\n\nPRIOR DISCUSSION (recovered from an expired session):\n' + tail.join('\n')
            }
            return ['-p', prompt + '\n\nUSER: ' + msg, '--output-format', 'json', '--allowedTools', 'Read', 'Glob', 'Grep']
          }
          const done = (err, j) => {
            if (err) return json(502, { ok: false, error: String(err.message || err) })
            const ts = new Date().toISOString()
            // append onto a fresh read — concurrent sends (other questions OR this one) both survive
            const all = loadChats()
            const cur = all[key] || { messages: [], sessionId: '' }
            cur.sessionId = j.session_id || cur.sessionId
            cur.messages.push({ role: 'user', text: msg, ts }, { role: 'claude', text: String(j.result || ''), ts })
            all[key] = cur
            saveChats(all)
            json(200, { ok: true, key, reply: String(j.result || ''), sessionId: cur.sessionId })
          }
          if (thread.sessionId) {
            runClaude(['-p', msg, '--resume', thread.sessionId, '--output-format', 'json', '--allowedTools', 'Read', 'Glob', 'Grep'], (err, j) => {
              // stale session id (threads persist for weeks) — retry once with a fresh context
              if (err) { thread.sessionId = ''; return runClaude(freshArgs(), done) }
              done(null, j)
            })
          } else {
            runClaude(freshArgs(), done)
          }
        } catch (e) {
          json(e instanceof SyntaxError ? 400 : 500, { ok: false, error: String(e.message || e) })
        }
      })
    } else if (req.method === 'POST' && req.url === '/api/decision') {
      let body = ''
      req.on('data', (c) => { body += c })
      req.on('end', () => {
        try {
          if (body.length > 1e6) return json(413, { ok: false, error: 'request too large' })
          const target = JSON.parse(body)
          const md = readFileSync(FILE, 'utf8')
          writeFileSync(FILE, setDecision(md, target))
          json(200, { ok: true })
        } catch (e) {
          // 400 = bad request JSON, 500 = filesystem trouble, 409 = the md no longer matches the page
          const code = e instanceof SyntaxError ? 400 : (e && e.code ? 500 : 409)
          json(code, { ok: false, error: String(e.message || e) })
        }
      })
    } else {
      res.writeHead(404)
      res.end('not found')
    }
  } catch (e) {
    res.writeHead(500)
    res.end(String(e.message || e))
  }
})

server.on('error', (e) => {
  console.error(e.code === 'EADDRINUSE' ? `Port ${PORT} is busy — rerun without --port to get a free one.` : String(e))
  process.exit(1)
})

const isMain = (() => {
  try { return import.meta.url === pathToFileURL(process.argv[1]).href } catch { return false }
})()

if (isMain) {
  server.listen(PORT, '127.0.0.1', () => {
    const url = `http://127.0.0.1:${server.address().port}`
    console.log(`Reviewing ${FILE}`)
    console.log(`→ ${url}  (decisions are written back into the md; Ctrl+C to stop)`)
    if (!args.includes('--no-open') && process.platform === 'darwin') execFile('open', [url], () => {})
  })
}
