---
title: Build the first feature on the foundation
labels: [wave:1, size:S]
milestone: Features
deps: [example-foundation]
---
## Goal
Implement the first user-facing slice on top of the shared foundation, proving the foundation's
surface is usable end to end.

## Acceptance criteria
- [ ] The slice consumes the foundation module's public surface (does not reach around it).
- [ ] It builds, typechecks, and tests green.
- [ ] Acceptance is observable from the outside (a user-visible behavior or an API response).

<!--
  Note: do NOT hand-write a `## Dependencies` section here. Dependencies come from the frontmatter
  `deps:` list above (slugs of other issues in this source tree); `loop-kit plan compile` renders the
  `## Dependencies` section the runtime PICK step reads. Use `#N` in deps only for an issue created in
  an EARLIER wave that already has a tracker id.
-->
