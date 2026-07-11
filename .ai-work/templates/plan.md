# Plan: <feature title>

<!--
  Author: cloud-planner
  Location: .ai-work/features/<feature-slug>/plan.md
  Do not edit after publication except to append a "Revision" section.
-->

## Feature request (verbatim)

<Paste the human's request unchanged.>

## Repository context observed

- Relevant files inspected (paths + one-line role):
  - `Sources/.../Foo.swift` — <role>
- Build/test commands confirmed to exist in this repo:
  - `<cmd>` — source: `agents.md` line X / `Package.swift` / etc.
- Constraints from `agents.md` or other repo docs that apply:
  - <e.g. "real-time safety rules in HALMixerEngine callbacks">

## Design summary

<3–10 sentences. Every non-trivial architectural decision must be made *here*
so the local implementer never has to invent one. Name the exact types,
files, and functions that will be created or modified. Call out invariants
that must be preserved.>

## Out of scope

- <explicit non-goal>

## Open questions for the human

<Leave empty if none. If non-empty, planner must NOT emit task files yet.>

## Task breakdown

Each task must be:

- **Small** — ideally < ~150 changed lines, one conceptual change.
- **Independently verifiable** — has a concrete build/test command that
  passes iff the task is done.
- **Ordered** — later tasks may depend on earlier ones; state deps explicitly.

| #  | Slug                              | Depends on | Summary                       |
| -- | --------------------------------- | ---------- | ----------------------------- |
| 01 | `<kebab-slug>`                    | —          | <one line>                    |
| 02 | `<kebab-slug>`                    | 01         | <one line>                    |

Each row above must have a corresponding `tasks/NN-<slug>/task.md` created
from `.ai-work/templates/task.md`.
