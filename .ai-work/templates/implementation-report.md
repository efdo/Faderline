# Implementation report — Task NN

<!--
  Author: local-implementer
  Location: .ai-work/features/<feature-slug>/tasks/NN-<slug>/implementation.md
  Read by: cloud-reviewer.
-->

## Summary

<2–5 sentences: what changed and why, in the implementer's own words.>

## Files changed

List every file touched (exactly matches `git diff --name-only` for this
task's changes). Flag anything that was **not** in the task's Approved scope
— such files should not appear here; if they do, explain in Deviations.

- `path/to/File1.swift` — <one-line summary>
- `path/to/File2.swift` — <one-line summary>

## Commands run

Every command executed during this task, in order, with exit code and a short
result. Include the validation commands from `task.md` verbatim.

| Command                          | Exit | Result                          |
| -------------------------------- | ---- | ------------------------------- |
| `swift build`                    | 0    | Build succeeded, 0 warnings     |
| `swift test`                     | 0    | 13 tests passed                 |
| `xcodebuild … build`             | 0    | Build succeeded                 |

If any command failed, include the tail of its output verbatim (fenced code
block) so the reviewer can diagnose without re-running.

## Deviations from the plan

- **None**, OR list each deviation with (a) what the plan said, (b) what was
  done instead, (c) why. Any deviation touching a file outside Approved scope
  requires a `blocked` transition instead of an `implemented` transition.

## Unresolved issues / follow-ups

- <e.g. "existing `LegacyMixerEngine.swift` has a pre-existing warning not
  addressed by this task">

## Confirmation

- [ ] Changes stayed within Approved scope in `task.md`.
- [ ] All validation commands in `task.md` were run and passed.
- [ ] No git history-mutating commands were executed.
- [ ] Pre-existing uncommitted work (if any at start) is untouched.
