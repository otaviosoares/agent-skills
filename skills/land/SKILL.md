---
name: land
description: >-
  Land a merged branch — remove its worktree, fast-forward the default branch, and delete the
  local branch. Use right after a PR/MR merges, e.g. "/land", "/land 76", "clean up the merged
  worktree".
---

# land — post-merge worktree cleanup (thin wrapper)

All logic lives in the bundled script `land.sh` (same directory as this
file: `~/.claude/skills/land/land.sh`); this skill only runs it and relays
the result. The script operates on whatever repo the current directory is
inside — GitHub (`gh`) or GitLab (`glab`), picked automatically from origin's
host.

## Run

From anywhere inside the repo (main checkout or a worktree), passing the
user's argument through verbatim — issue number, branch, or path; nothing =
the worktree the session is in. Add `-n` if the user asked for a dry run:

```sh
~/.claude/skills/land/land.sh [target] [-n]
```

## After

- Success: relay the script's "Done" summary. If it printed the NOTE about
  the shell being inside the removed worktree, `cd` to the main checkout
  before any further commands.
- Refusal (exit 1): show the reason verbatim and stop. The refusals are the
  safety model — never retry with `--force`, delete branches manually, or
  otherwise work around them. If the user wants to override, they do it by
  hand.
