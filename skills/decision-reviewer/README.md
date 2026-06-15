# decision-reviewer

> An agent skill for Claude Code and other `SKILL.md`-aware agents.

Turn a pile of open decisions into a durable, agent-readable decision log,
answered asynchronously in the browser. When a planning / spec / PRD task
surfaces a batch of questions with real tradeoffs, the agent:

1. **researches and writes** the questions into a structured markdown file
   (one question per `### Qn.` block: a one-line *why*, what it *Decides*, a
   grounded *Recommendation*, and *Other options*);
2. **validates** the file with a built-in `--selftest` gate so a malformed
   question can never reach the browser;
3. **serves a local review UI** where you answer at your own pace. Decisions
   write straight back into the markdown — the file is the single source of
   truth, the server holds no state, and killing it loses nothing.

Each question card has **Use recommendation** (one-click accept), **Clear**, and
**💬 Discuss** — which spins up a read-only Claude scoped to that one question,
with project context drawn from the file's own header. When you're done, the
agent harvests the answered file with `--summary` and carries the decisions into
the work.

## Why not just ask inline?

For one or two quick questions, your agent should use its normal inline
question UI. This skill earns its setup cost at **~6+ decisions**, when answers
need free-text nuance, out-of-order or multi-sitting review, or when the
answered log itself is a deliverable other agents will consume.

## Install

```bash
npx skills add otaviosoares/agent-skills@decision-reviewer
```

## Requirements

- **Node.js** (uses only the standard library — no dependencies).
- The **💬 Discuss** feature shells out to the `claude` CLI; without it the rest
  of the skill works unchanged. Override the binary with `CLAUDE_BIN`.

## Files

| File | Purpose |
|---|---|
| `SKILL.md` | Workflow + triggers the agent follows |
| `REFERENCE.md` | Format grammar, CLI flags, troubleshooting |
| `TEMPLATE.md` | Skeleton the agent copies and fills in |
| `scripts/review.mjs` | The zero-dependency parser + review server |

## Using the server by hand

```bash
node scripts/review.mjs --file questions.md                 # serve + open browser
node scripts/review.mjs --file questions.md --selftest --expect N   # validate
node scripts/review.mjs --file questions.md --summary       # answered/open digest
```

## License

[MIT](../../LICENSE)
