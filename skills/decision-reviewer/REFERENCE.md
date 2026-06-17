# decision-reviewer — format reference

The bundled `scripts/review.mjs` parses the questions file with a strict,
line-oriented grammar. `--selftest` is the contract: if it passes, the UI will
render and save correctly. Copy `TEMPLATE.md` and fill it in rather than writing
the format from memory.

## Grammar

```
# Title                          one H1; becomes the page title
> context line(s)                blockquote before the first section; fed verbatim
                                 to the Discuss chat as project context
## Section name                  any text; groups questions in the nav sidebar
### Q1. Question title?          question heading; Qn ids must be globally unique
                                 across the whole file (Q1, Q2, … in order)
Why line(s).                     plain lines under the heading = the "why" body
*Affects:* a, b                  optional, one line
- **In plain terms:** …          optional; plain-language explanation, renders collapsed
- **Decides:** …                 required
- **Recommendation:** …          required
- **Other options:** …           required
- **Decision (YYYY-MM-DD):** …   written by the tool; never write this yourself
```

Load-bearing details:

- Heading literal is `### Q<digits>. ` — the period after the id is required
  (`Q1:` will not parse). Answered questions become `### Q1. ✅ Title`.
- Field bullets are exactly `- **Name:** value` at column 0. Multi-line values
  continue on lines indented **2 spaces** (a blank continuation line is two
  spaces). Wrapped text NOT indented 2 spaces is silently treated as body text.
- Every `###` line must be a question and every section must contain at least
  one question — anything else fails `--selftest` as drift.
- Prose that is not part of a question can only live before the first `##`
  heading. There is no appendix concept; don't add trailing notes sections.
- Decisions are spliced into the file at the end of the question block; the
  parser never re-serializes the document, so hand edits elsewhere survive.

## Writing-style contract (what made this format work)

- **Title states the either/or.** The reader should grasp the choice from the
  title alone: "Stripe Checkout or custom payment form?"
- **Why = one line.** What breaks or blocks if this stays undecided.
- **In plain terms** (optional) = the explanation you'd give if the reader clicked
  "Explain this question": the underlying problem in plain language and what each
  option means in practice. It renders collapsed, so it costs nothing to scanning
  but is there for the reader who doesn't get the terse version. You already did
  the research to write the question — capture that grounding here instead of
  discarding it. Add it when a question is genuinely hard to grasp cold; skip it
  when the title and why-line already stand on their own.
- **Decides** = the thing the answer pins down, not a restatement of the title.
- **Recommendation** = `Pick: X — <one clause>`. Every recommendation states its
  basis. If you did not verify a claim against the code/docs, prefix it
  `unverified — `. The UI has a one-click "Use recommendation" button, so an
  ungrounded recommendation is a machine for rubber-stamping bad decisions.
- **Other options** = alternatives written inline (or on 2-space-indented
  continuation lines — never as column-0 `- ` bullets, which the parser treats
  as drift), one tradeoff each, `(avoid)` for ruled-out ones.
- Fewer, well-grounded questions beat exhaustive coverage. Research first,
  ask second.

## CLI

```
node <skill>/scripts/review.mjs --file <questions.md>              serve + open browser (ephemeral port)
node <skill>/scripts/review.mjs --file <q.md> --selftest --expect N   validate; exits 1 on any failure
node <skill>/scripts/review.mjs --file <q.md> --summary            answered/open digest for harvesting
  --port N    pin the port        --no-open   don't auto-open the browser
```

`--selftest` checks: ≥1 question parsed, parsed count == `--expect` (always
pass `--expect` — it is the only check that catches a silently dropped
question), no unparsed/unexpected headings or stray field lines, no body text
after a question's field bullets (the mis-indented-continuation trap), the
context blockquote not stranded below the first section, no empty sections,
unique Qn ids, all of why/Decides/Recommendation/Other options non-empty, and
a byte-identical set-then-clear decision round-trip. It never writes the file.
Fenced code blocks (``` or ~~~) are inert: headings/bullets inside them are
ignored by the parser and the write-back.

## Sidecar state

Chat threads persist in `<dir>/.oq/<name>.chats.json` next to the questions
file (`<name>` = the filename without its `.md` extension) — never in the
markdown. The server holds no other state: every saved
decision is in the md instantly, so a killed server loses nothing and
relaunching is always safe. The Discuss chat shells out to the `claude` CLI
(override the binary with `CLAUDE_BIN`); each message is a real API call.

## Troubleshooting

| Symptom | Cause |
|---|---|
| selftest: `no questions parsed` | headings don't match `### Qn. ` (check the period) |
| selftest: 0 questions + orphans ending in `\r` | CRLF line endings — convert the file to LF |
| selftest: `expected N but parsed M` | some questions malformed and silently dropped — diff against TEMPLATE.md |
| selftest: `unparsed line (format drift)` | a `###` heading that isn't `Qn.`-shaped, or a field bullet outside a question |
| UI renders but Save fails | the md changed shape since the page loaded — reload the page |
| Discuss replies 502 | `claude` CLI missing (set `CLAUDE_BIN`) or the call timed out |
