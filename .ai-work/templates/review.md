# Review — Task NN

<!--
  Author: cloud-reviewer
  Location: .ai-work/features/<feature-slug>/tasks/NN-<slug>/review.md
  Read by: local-implementer (on `changes-requested`), humans.
-->

## Sources inspected

- `task.md` — parent plan requirements.
- `implementation.md` — implementer's self-report.
- `git diff <merge-base>...HEAD -- <scope files>` — the **actual** change set
  (must be inspected; do not rely solely on the implementer's report).
- Surrounding code in touched files and their immediate callers.

## Verdict

One of:

- `approved` — no blocking issues; all important issues resolved or waived.
- `changes-requested` — at least one blocking issue, or important issues the
  implementer must address.

## Findings

Every finding is classified. Use the exact labels below.

### Blocking (must fix before approval)

- **[file:line]** — <what is wrong> — <what to change>

### Important (should fix; reviewer may waive with justification)

- **[file:line]** — <…>

### Optional (suggestions; implementer may ignore)

- **[file:line]** — <…>

If a section has no items, write `- none`.

## Scope check

- [ ] Every changed file is listed in `task.md` "Approved scope".
- [ ] No production/test file outside scope was touched.
- [ ] Invariants from `task.md` are preserved (state which ones you verified
      and how).

## Validation check

- [ ] Implementer ran every command from `task.md` "Validation".
- [ ] All commands reported exit 0 (or documented, justified deviations).
- [ ] Reviewer spot-checked at least one command's output for plausibility.

## Notes for the implementer (only on `changes-requested`)

<Concise, actionable guidance for the next implementation pass. Reference
findings by their [file:line] anchors.>
