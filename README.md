# agent-skills

A small collection of [agent skills](https://skills.sh) for Claude Code (and
other agents that read `SKILL.md`).

## Install

Install a single skill with [`npx skills`](https://github.com/vercel-labs/skills):

```bash
npx skills add otaviosoares/agent-skills@decision-reviewer
```

Or browse and pick interactively:

```bash
npx skills add otaviosoares/agent-skills
```

This drops the skill into your agent's skills directory (`.claude/skills/` for
Claude Code). Re-run with `npx skills update` to pull newer versions.

## Skills

### [decision-reviewer](skills/decision-reviewer)

Run an async decision-review session. When a planning, spec, or PRD task
surfaces a batch of open decisions, the agent writes them to a structured
markdown file and serves a local browser UI where you answer at your own pace —
decisions write straight back into the markdown, so the file is the single
source of truth and a durable decision log. Each question has a "💬 Discuss"
button that spins up a read-only Claude to talk through that one decision.

Best for ~6+ decisions with real tradeoffs; for one or two quick questions your
agent should just ask inline. See the [skill README](skills/decision-reviewer)
for the format and workflow.

### [loop-kit](skills/loop-kit)

Set up and run a context-bounded, multi-runner autonomous build loop driven by
an issue tracker (GitHub or GitLab). A stateless driver spawns a fresh headless
`claude -p` per iteration, so context never fills up — all state lives on the
tracker, and each tracker issue is the lock so N runners never collide. A
backend-agnostic `track` dispatcher seams GitHub/GitLab/local. Invoke it on a
repo to `init` it (emit the tracker config + a loop runbook + a launcher); the
4 per-project judgment blocks are left as fail-loud `<<FILL>>` tokens and nothing
is ever auto-committed. See the [skill README](skills/loop-kit) and
[REFERENCE.md](skills/loop-kit/REFERENCE.md).

## License

[MIT](LICENSE)
