# claude-gpt-live-bridge

What this repository is, in one paragraph. Keep this file within its budgets — at most 300
lines and 3,000 words, and the status section below at most 50 lines — because it
is loaded into every session; detail belongs in the documents it links to.

## Current status

- Not started.
<!-- stayfixed:harness:begin -->
## stayfixed

This repository is initialised with stayfixed. `stayfixed.toml` names its document paths and
its note store. `docs/bug-reports.md` is a generated index over `docs/bugs/` — never edit it by hand;
`stayfixed bugs index` renders it. `docs/roadmap.md` carries the design-and-plan trail between its
markers, which `stayfixed docs trail` rewrites; specs live under `docs/specs/` and plans under
`docs/plans/`. Each gate runs advisory until it enforces: `stayfixed adopt promote` enforces the
gates that pass, and `stayfixed assess` says which would.
<!-- stayfixed:harness:end -->
