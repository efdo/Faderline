# Task NN — <task title>

<!--
  Author: cloud-planner
  Location: .ai-work/features/<feature-slug>/tasks/NN-<slug>/task.md
  Read by: local-implementer, cloud-reviewer.
  Immutable after status transitions past `planned` except via a new
  "Revision" appendix.
-->

## Parent plan

`.ai-work/features/<feature-slug>/plan.md`

## Goal (one sentence)

<What "done" means, in one sentence.>

## Approved scope

The implementer may modify **only** these files (create if absent):

- `path/to/File1.swift`
- `path/to/File2.swift`
- `Tests/.../SomeTests.swift`

Any file not listed here is **out of scope**. If the implementer discovers a
required change to a file not listed, they must stop and set status to
`blocked`.

## Exact changes required

Describe the change concretely enough that a weaker local model does not need
to invent architecture. Prefer:

- Named types, function signatures, property names.
- Where new code goes (file + insertion point / existing symbol to modify).
- Concrete algorithm steps for any non-trivial logic.
- Sample code snippets where they remove ambiguity.

Example:
> In `Sources/AudioMixer/Audio/DeviceManager.swift`, add
> `func addChangeListener(_ handler: @escaping (AudioDevice) -> Void)` that
> registers a `kAudioHardwarePropertyDevices` listener via
> `AudioObjectAddPropertyListenerBlock` on the main dispatch queue and
> invokes `handler` for each newly-connected device.

## Invariants that must be preserved

- <e.g. "no allocation inside `halInputCallback`">
- <e.g. "existing HAL unit lifecycle unchanged">

## Validation

The implementer must run **exactly** these commands and record their exit
status and relevant output in `implementation.md`:

- `<cmd 1>` — expected: <what a pass looks like>
- `<cmd 2>` — expected: <…>

If any command is not documented in `agents.md` or otherwise verifiable in
the repo, the planner must not list it.

## Non-goals for this task

- <explicit>

## Notes for the implementer

- If the plan appears to require an architectural decision that isn't spelled
  out above, **stop and set status to `blocked`** — do not guess.
- Do not edit files outside "Approved scope" even if it seems helpful.
- Do not run any git command that mutates history or the branch.
