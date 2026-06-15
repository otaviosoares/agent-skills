---
name: decision-reviewer
description: Runs an async decision-review session - writes a batch of open decisions to a structured markdown file and serves a local browser UI where the user answers at their own pace (decisions write straight back into the md) and can discuss any question with a read-only Claude. Use when planning/spec/PRD work surfaces ~6+ open decisions with real tradeoffs, when the user says "decision review" / "open questions review", or when the user returns to pick up answers from an existing *-questions.md file. For 1-5 quick questions use AskUserQuestion inline instead, unless the user explicitly wants the browser review or a durable decision log. If the user wants to be interviewed interactively right now, ask inline - this skill is for asynchronous, at-their-own-pace review.
---

# Decision Reviewer

Turn a pile of open decisions into a durable, agent-readable decision log,
answered asynchronously in the browser. The markdown file is the single source
of truth: the UI writes decisions straight into it, the server holds no state,
and the answered file becomes context for later work.

**Do not use this for fewer than ~6 questions** — AskUserQuestion is faster for
small batches. Do use it when answers need free-text nuance, out-of-order or
multi-sitting review, or when the decision log itself is a deliverable.

## Session workflow

1. **Research before asking.** Ground every question in the actual code/docs.
   Each Recommendation must state its basis; mark unchecked claims
   `unverified — `. Fewer well-grounded questions beat exhaustive coverage.
   The UI has a one-click "Use recommendation" button — never put an
   ungrounded recommendation behind it. Style rules: see REFERENCE.md.

2. **Write the questions file.** Copy `TEMPLATE.md` (same dir as this file) and
   fill it in — do not write the format from memory. One file per topic, named
   `<topic>-questions.md`, in the project's planning dir (`plans/` or `docs/`
   if they exist, else repo root). Include the `> Context:` preamble — it is
   what the per-question Discuss chat knows about the project.

3. **Validate — mandatory gate.** Count the questions you wrote (N), then:

   ```
   node <this-skill-dir>/scripts/review.mjs --file <file> --selftest --expect N
   ```

   Fix and rerun until `SELFTEST OK`. A count mismatch means a question
   silently failed to parse — never launch the server on a failing file.

4. **Launch** (run in background, capture the printed URL):

   ```
   node <this-skill-dir>/scripts/review.mjs --file <file>
   ```

   It picks a free port, prints `→ http://127.0.0.1:<port>`, and auto-opens
   the browser on macOS. Launch it with the Bash tool's `run_in_background`
   and read the URL from the background task's output (or pin `--port N` and
   build the URL yourself — a busy port exits with "Port N is busy"). Keep
   track of the process: it must be stopped before any later md edits.
   Then end your turn, telling the user:
   - the URL, and that every decision saves into `<file>` instantly;
   - nothing is lost if the server dies — relaunch and it resumes;
   - the 💬 Discuss button starts a per-question chat (each message is a real
     Claude API call);
   - to come back and say "done" (or "review my answers") when finished —
     partial is fine.

5. **Harvest.** When the user returns:

   ```
   node <this-skill-dir>/scripts/review.mjs --file <file> --summary
   ```

   Read the digest, not the whole md. Confirm how to proceed with any
   still-open questions, then carry the decisions into the work. Once any
   decision is recorded, treat existing question blocks as append-only —
   add new questions with fresh Qn ids; never renumber, retitle, or rewrite
   answered ones.

## Rules

- **Never edit the questions md while the server is running** — the server
  does read-modify-write on every save and will clobber concurrent edits.
  Stop the server (or finish the review) first.
- Decisions belong to the user. Never write a `- **Decision:**` line yourself
  unless the user explicitly dictated the decision to you.
- Chat threads live in `.oq/` next to the questions file. Offer to gitignore
  `.oq/` unless the user wants chat history versioned.
- Format grammar, CLI flags, and troubleshooting: see
  [REFERENCE.md](REFERENCE.md).
