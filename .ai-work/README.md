# `.ai-work/` — Hybrid Cloud/Local Coding Workflow

This directory is the **handoff surface** between three specialized Copilot CLI
custom agents. Every artifact here is authored by exactly one role and read by
the others, so no cloud/local Copilot session ever needs to share conversation
history with another.

## Roles

| Role                    | Custom agent                       | Runs where                         | May edit                              |
| ----------------------- | ---------------------------------- | ---------------------------------- | ------------------------------------- |
| **Cloud planner**       | `.github/agents/cloud-planner.md`  | Cloud Copilot CLI (strong model)   | `.ai-work/features/**/plan.md` and `.ai-work/features/**/tasks/*/task.md` |
| **Local implementer**   | `.github/agents/local-implementer.md` | Local Copilot CLI (Ollama, weaker model) | Production/test source **within the current task's scope** + `.ai-work/features/**/tasks/*/implementation.md` and its own `status.md` transitions |
| **Cloud reviewer**      | `.github/agents/cloud-reviewer.md` | Cloud Copilot CLI (strong model)   | `.ai-work/features/**/tasks/*/review.md` and its own `status.md` transitions |

**Only the cloud reviewer may mark a task `approved`.** Planners never touch
production code. Implementers never approve their own work.

## Directory layout

```
.ai-work/
├── README.md                 # this file
├── templates/                # canonical templates (copy, don't edit in place)
│   ├── plan.md
│   ├── task.md
│   ├── implementation-report.md
│   ├── review.md
│   └── status.md
└── features/
    └── <feature-slug>/
        ├── plan.md           # planner (one per feature)
        └── tasks/
            └── NN-<task-slug>/
                ├── task.md              # planner (spec for one bounded task)
                ├── implementation.md    # implementer (post-work report)
                ├── review.md            # reviewer (findings)
                └── status.md            # append-only state log
```

- `<feature-slug>`: short kebab-case, e.g. `2025-07-hotplug-recovery`.
- `NN`: two-digit task ordinal (`01`, `02`, ...).
- `<task-slug>`: kebab-case, e.g. `add-device-change-listener`.

## Task lifecycle & status vocabulary

`status.md` uses an append-only log. Each entry is:

```
## <ISO-8601 timestamp> — <role> — <state>
<optional short note>
```

Allowed states, in the order they may appear:

1. `planned` — planner has finished writing `task.md`; ready for implementer.
2. `in-progress` — implementer has started (writes this before editing code).
3. `blocked` — implementer stopped because the plan is materially ambiguous or
   preconditions are wrong. Must include a note explaining what is missing.
4. `implemented` — implementer wrote `implementation.md`; ready for reviewer.
5. `changes-requested` — reviewer wrote `review.md` with blocking findings.
6. `approved` — reviewer accepted the work. **Terminal. Only the reviewer may
   write this state.**

Legal transitions:

```
planned → in-progress → { blocked, implemented }
blocked → in-progress                 (planner or human addresses ambiguity)
implemented → { approved, changes-requested }
changes-requested → in-progress
```

The current state of a task is the last entry in its `status.md`.

## Handoff protocol (deterministic, no shared memory)

Each agent, on invocation, is expected to:

1. Scan `.ai-work/features/**/tasks/*/status.md` files.
2. Find work in its own **ready queue**:
   - Planner: features with no `plan.md`, or explicitly-requested new features.
   - Implementer: tasks whose last status is `planned` or `changes-requested`.
     Pick exactly **one** (lowest ordinal within the earliest feature) and stop
     after finishing it.
   - Reviewer: tasks whose last status is `implemented`.
3. Do its role's work, then append the appropriate `status.md` entry.

## Hard rules for every agent

- **Do not** run `git commit`, `git push`, `git reset`, `git rebase`,
  `git clean`, `git checkout <branch>`, `git switch`, `git stash drop`,
  `git branch -d`, or any other command that mutates commit history, discards
  uncommitted work, or changes the current branch — **unless the human
  operator explicitly asks in that turn**.
- Preserve any pre-existing uncommitted work. If `git status` shows unrelated
  changes at start, note them in your artifact and do not touch them.
- Never invent build/test commands. If a command is not documented in
  `agents.md`, `README.md`, or discoverable via `swift package …` / project
  metadata, say so and stop instead of guessing.
- Never overwrite an existing artifact belonging to another role.
