---
title: Set up the shared foundation module
labels: [wave:1, size:M]
milestone: Foundation
deps: []
---
## Goal
Create the shared module the rest of this scope's issues import from, so dependent slices have a
stable surface to build against.

## Acceptance criteria
- [ ] The module exists and exports the agreed public surface.
- [ ] It builds, typechecks, and has at least one test covering the public surface.
- [ ] No dependent issue's contract is broken (this is a new file, not an edit to a frozen shape).
