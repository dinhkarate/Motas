# Motas GitHub Project Agent Workflow

## Project

```text
Owner: thatnghiepdev
Project: Motas Roadmap
Number: 1
URL: https://github.com/orgs/thatnghiepdev/projects/1
```

## Roles

| Role | GitHub account | Responsibility |
|---|---|---|
| PM / final approver | `dinhkarate` | Manual actions, purchases, external accounts, product decisions, launch gates and final approval of critical work. |
| Implementation agent | `kasuganodesu` | Primary implementation on assigned tasks and independent review of Kyouka's tasks. |
| Implementation agent | `kyoukadesu` | Primary implementation on assigned tasks and independent review of Kasugano's tasks. |

Kasugano and Kyouka are paired on implementation tasks:

- One is `Primary Owner`.
- The other is `Peer Reviewer`.
- Critical/manual tasks use `Approval Owner = dinhkarate`.
- Manual PM tasks use `Primary Owner = dinhkarate` and `Peer Reviewer = None`.

Because the project currently uses GitHub **Draft Issues**, ownership is represented with project fields instead of repository issue assignees.

## Project fields

Core planning fields:

```text
Status
Phase
Priority
Area
Work Type
Estimate (days)
Depends On
```

Agent workflow fields:

```text
Primary Owner
Peer Reviewer
Approval Owner
Approval Status
Agent Status
Progress Report
```

## Status workflow

GitHub project status:

```text
Todo -> In Progress -> Done
```

Agent workflow status:

```text
Ready -> Working -> In Review -> Waiting Approval -> Done
```

When changes are requested:

```text
In Review / Waiting Approval -> Working
```

## Recommended CLI wrapper

Use the repository helper:

```bash
./scripts/motas-board --help
```

It wraps `gh project` and enforces ownership/dependency checks.

### List ready tasks for an agent

```bash
./scripts/motas-board ready kasuganodesu
./scripts/motas-board ready kyoukadesu
./scripts/motas-board ready dinhkarate
```

By default, `ready` only returns work from the earliest unfinished phase. This prevents agents from jumping ahead. PM-only cross-phase view:

```bash
./scripts/motas-board ready kasuganodesu --all-phases
```

Machine-readable output:

```bash
./scripts/motas-board ready kasuganodesu --json
```

### Fetch peer-review and approval queues

Kasugano's review queue:

```bash
./scripts/motas-board review-queue kasuganodesu
```

Kyouka's review queue:

```bash
./scripts/motas-board review-queue kyoukadesu
```

Tasks waiting for dinhkarate:

```bash
./scripts/motas-board approval-queue dinhkarate
```

All support `--json` for agent automation.

### Show complete task information

```bash
./scripts/motas-board show P1.10
```

JSON:

```bash
./scripts/motas-board show P1.10 --json
```

Output includes:

- Outcome
- Done/acceptance criteria
- Phase and priority
- Estimate
- Dependencies and unresolved blockers
- Primary owner
- Peer reviewer
- Approval owner/status
- Execution plan
- Current progress report

### Start a task

```bash
./scripts/motas-board start P1.10 kyoukadesu
```

The command refuses to start if:

- The actor is not the primary owner.
- A dependency is not Done.

Only use `--force` with explicit PM approval:

```bash
./scripts/motas-board start P1.10 kyoukadesu --force
```

### Handoff/reassign giữa Kasugano và Kyouka

Primary owner hoặc peer reviewer hiện tại có thể chuyển một implementation task cho người còn lại:

```bash
./scripts/motas-board handoff P1.10 kyoukadesu \
  --to kasuganodesu \
  --reason 'Kasugano đang phụ trách API research liên quan và có đủ context để hoàn thành nhanh hơn.'
```

Sau handoff:

```text
Primary Owner = kasuganodesu
Peer Reviewer = kyoukadesu
```

Workflow luôn hoán đổi primary/reviewer để giữ nguyên audit chéo.

Handoff bị từ chối nếu:

- Task thuộc `dinhkarate` hoặc là manual/PM task.
- Người gọi không phải primary/reviewer hiện tại.
- Target không phải agent còn lại trong cặp.
- Task đang `In Review`, `Waiting Approval` hoặc `Done`.
- Không cung cấp lý do.

Mọi handoff được ghi vào `Progress Report`, bao gồm owner cũ, owner mới, lý do và progress trước đó.

### Submit a progress report

Create a report file:

```text
Summary: Implemented 9Router reachability and status mapping.
Evidence: commit abc123; PR URL
Verification: swift test; manual check against localhost:20128
Risks or blockers: quota endpoint is not available in older 9Router versions
Next action: peer review by kasuganodesu
```

Upload it:

```bash
./scripts/motas-board report P1.10 kyoukadesu --file /tmp/P1.10-report.txt
```

For short updates:

```bash
./scripts/motas-board report P1.10 kyoukadesu \
  --message 'Summary: endpoint research complete; Evidence: docs URL; Verification: curl succeeded; Risks: none; Next action: implementation'
```

### Submit for peer review

```bash
./scripts/motas-board submit P1.10 kyoukadesu
```

This sets:

```text
Status = In Progress
Agent Status = In Review
```

### Pass peer review

```bash
./scripts/motas-board review-pass P1.10 kasuganodesu
```

If final approval is required:

```text
Agent Status = Waiting Approval
```

Otherwise the task becomes Done.

### Request changes

```bash
./scripts/motas-board request-changes P1.10 kasuganodesu \
  --file /tmp/P1.10-review.txt
```

This returns the task to:

```text
Agent Status = Working
Approval Status = Changes Requested  # when applicable
```

### Final approval by dinhkarate

```bash
./scripts/motas-board approve P1.10 dinhkarate \
  --message 'Approved after peer review and clean verification.'
```

This sets:

```text
Approval Status = Approved
Status = Done
Agent Status = Done
```

## Raw `gh` commands

The helper is recommended, but agents can query the board directly.

### Fetch all project items

```bash
gh project item-list 1 \
  --owner thatnghiepdev \
  --limit 300 \
  --format json
```

### Fetch a task by stable code

```bash
gh project item-list 1 \
  --owner thatnghiepdev \
  --limit 300 \
  --format json \
| jq '.items[] | select(.title | startswith("[P1.10]"))'
```

### Fetch tasks owned by Kasugano

```bash
gh project item-list 1 \
  --owner thatnghiepdev \
  --limit 300 \
  --format json \
| jq '.items[] | select(."primary Owner" == "kasuganodesu")'
```

### Fetch ready tasks owned by Kyouka

This raw command filters the field state, but it does not evaluate dependency completion. Use `motas-board ready` for proper dependency checking.

```bash
gh project item-list 1 \
  --owner thatnghiepdev \
  --limit 300 \
  --format json \
| jq '.items[]
      | select(."primary Owner" == "kyoukadesu")
      | select(.status == "Todo")
      | select(."agent Status" == "Ready")'
```

### Fetch tasks waiting for dinhkarate

```bash
gh project item-list 1 \
  --owner thatnghiepdev \
  --limit 300 \
  --format json \
| jq '.items[]
      | select(."approval Owner" == "dinhkarate")
      | select(."agent Status" == "Waiting Approval")'
```

### Fetch tasks that need peer review

For Kasugano:

```bash
gh project item-list 1 \
  --owner thatnghiepdev \
  --limit 300 \
  --format json \
| jq '.items[]
      | select(."peer Reviewer" == "kasuganodesu")
      | select(."agent Status" == "In Review")'
```

For Kyouka:

```bash
gh project item-list 1 \
  --owner thatnghiepdev \
  --limit 300 \
  --format json \
| jq '.items[]
      | select(."peer Reviewer" == "kyoukadesu")
      | select(."agent Status" == "In Review")'
```

## Agent operating prompt

Use this as the base prompt when configuring Kasugano or Kyouka:

```text
You are an implementation and review agent for Motas.

GitHub Project:
https://github.com/orgs/thatnghiepdev/projects/1

Your GitHub role account is <kasuganodesu|kyoukadesu>.

Workflow:
1. Run `./scripts/motas-board ready <your-account> --json`.
2. Select the lowest-code P0 task, otherwise the lowest-code P1 task.
3. Run `./scripts/motas-board show <task-code>` and read the full body and dependencies.
4. Start it with `./scripts/motas-board start <task-code> <your-account>`.
5. If the other agent should own the task due to context, use `handoff` before review and record a clear reason.
6. Implement only the requested scope and satisfy every Done-when criterion.
7. Run relevant verification.
8. Upload a structured Progress Report.
9. Submit the task for peer review.
10. When acting as reviewer, independently inspect the diff and rerun critical verification before passing review.
11. Never mark a task Done if tests fail, blockers remain, or dinhkarate approval is required.
```

## PM rules

- Keep only 1–3 implementation tasks in `Working` at once.
- Agents must not bypass unresolved dependencies without PM approval.
- Peer reviewer must not merely trust the primary agent's report.
- P0 and security/release/billing tasks require `dinhkarate` approval.
- Manual tasks must include evidence before Done.
- The stable task code (`P1.10`, `P5.6`, etc.) should appear in branch names, commits, PRs, and reports.

Suggested branch names:

```text
kasugano/P1.10-9router-health
kyouka/P2.3-keychain-storage
```

Suggested commit subject:

```text
[P1.10] Add basic 9Router health connector
```
