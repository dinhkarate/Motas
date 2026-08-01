#!/usr/bin/env python3
"""CLI workflow for the thatnghiepdev/Motas GitHub Project.

Requires:
  - gh authenticated with org/project scope
  - jq is not required by this script

Examples:
  python3 scripts/motas_board.py ready kasuganodesu
  python3 scripts/motas_board.py show P1.10
  python3 scripts/motas_board.py start P1.10 kyoukadesu
  python3 scripts/motas_board.py report P1.10 kyoukadesu --file report.txt
  python3 scripts/motas_board.py submit P1.10 kyoukadesu
  python3 scripts/motas_board.py review-pass P1.10 kasuganodesu
  python3 scripts/motas_board.py approve P1.10 dinhkarate
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

OWNER = "thatnghiepdev"
PROJECT_NUMBER = "1"
PROJECT_URL = "https://github.com/orgs/thatnghiepdev/projects/1"
VALID_ACTORS = {"dinhkarate", "kasuganodesu", "kyoukadesu"}
IMPLEMENTATION_AGENTS = {"kasuganodesu", "kyoukadesu"}
CODE_RE = re.compile(r"\[(P\d+\.\d+)\]")
DEP_RE = re.compile(r"P\d+\.\d+")


def run_gh(*args: str, capture: bool = True) -> str:
    command = ["gh", *args]
    try:
        result = subprocess.run(
            command,
            check=True,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
    except FileNotFoundError:
        fail("`gh` was not found. Install GitHub CLI first.")
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or error.stdout or str(error)).strip()
        fail(f"GitHub CLI failed: {detail}")
    return result.stdout if capture else ""


def fail(message: str, exit_code: int = 1) -> None:
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(exit_code)


def load_board() -> dict[str, Any]:
    project = json.loads(
        run_gh(
            "project",
            "view",
            PROJECT_NUMBER,
            "--owner",
            OWNER,
            "--format",
            "json",
        )
    )
    fields_payload = json.loads(
        run_gh(
            "project",
            "field-list",
            PROJECT_NUMBER,
            "--owner",
            OWNER,
            "--limit",
            "100",
            "--format",
            "json",
        )
    )
    items_payload = json.loads(
        run_gh(
            "project",
            "item-list",
            PROJECT_NUMBER,
            "--owner",
            OWNER,
            "--limit",
            "300",
            "--format",
            "json",
        )
    )
    fields = {field["name"]: field for field in fields_payload["fields"]}
    return {
        "project": project,
        "fields": fields,
        "items": items_payload["items"],
    }


def item_code(item: dict[str, Any]) -> str | None:
    match = CODE_RE.match(item.get("title", ""))
    return match.group(1) if match else None


def field_value(item: dict[str, Any], display_name: str) -> Any:
    # `gh project item-list` lowercases the first character of custom field names.
    key = display_name[0].lower() + display_name[1:]
    return item.get(key)


def find_item(board: dict[str, Any], code: str) -> dict[str, Any]:
    normalized = code.strip().upper()
    for item in board["items"]:
        if item_code(item) == normalized:
            return item
    fail(f"Task {normalized} was not found in {PROJECT_URL}.")


def option_id(board: dict[str, Any], field_name: str, option_name: str) -> str:
    field = board["fields"].get(field_name)
    if not field:
        fail(f"Project field `{field_name}` does not exist.")
    for option in field.get("options", []):
        if option["name"] == option_name:
            return option["id"]
    fail(f"Option `{option_name}` does not exist in `{field_name}`.")


def update_select(
    board: dict[str, Any], item: dict[str, Any], field_name: str, option_name: str
) -> None:
    field = board["fields"][field_name]
    run_gh(
        "project",
        "item-edit",
        "--id",
        item["id"],
        "--project-id",
        board["project"]["id"],
        "--field-id",
        field["id"],
        "--single-select-option-id",
        option_id(board, field_name, option_name),
        capture=False,
    )


def update_text(
    board: dict[str, Any], item: dict[str, Any], field_name: str, value: str
) -> None:
    field = board["fields"][field_name]
    run_gh(
        "project",
        "item-edit",
        "--id",
        item["id"],
        "--project-id",
        board["project"]["id"],
        "--field-id",
        field["id"],
        "--text",
        value,
        capture=False,
    )


def validate_actor(actor: str) -> None:
    if actor not in VALID_ACTORS:
        fail(f"Unknown actor `{actor}`. Expected one of: {', '.join(sorted(VALID_ACTORS))}.")


def dependency_codes(item: dict[str, Any]) -> list[str]:
    value = field_value(item, "Depends On") or ""
    return DEP_RE.findall(value)


def unresolved_dependencies(
    item: dict[str, Any], by_code: dict[str, dict[str, Any]]
) -> list[str]:
    unresolved: list[str] = []
    for code in dependency_codes(item):
        dependency = by_code.get(code)
        if not dependency or dependency.get("status") != "Done":
            unresolved.append(code)
    return unresolved


def task_summary(item: dict[str, Any], blocked: list[str] | None = None) -> dict[str, Any]:
    return {
        "code": item_code(item),
        "title": item.get("title"),
        "status": item.get("status"),
        "agentStatus": field_value(item, "Agent Status"),
        "phase": item.get("phase"),
        "priority": item.get("priority"),
        "area": item.get("area"),
        "estimateDays": field_value(item, "Estimate (days)"),
        "primaryOwner": field_value(item, "Primary Owner"),
        "peerReviewer": field_value(item, "Peer Reviewer"),
        "approvalOwner": field_value(item, "Approval Owner"),
        "approvalStatus": field_value(item, "Approval Status"),
        "dependsOn": field_value(item, "Depends On"),
        "blockedBy": blocked or [],
    }


def print_table(rows: list[dict[str, Any]]) -> None:
    if not rows:
        print("No matching tasks.")
        return
    headers = ["Code", "State", "Pri", "Days", "Owner", "Reviewer", "Task"]
    values = []
    for row in rows:
        values.append(
            [
                row.get("code") or "-",
                row.get("agentStatus") or row.get("status") or "-",
                (row.get("priority") or "-").split(" ")[0],
                str(row.get("estimateDays") or "-"),
                row.get("primaryOwner") or "-",
                row.get("peerReviewer") or "-",
                row.get("title") or "-",
            ]
        )
    widths = [max(len(headers[i]), *(len(row[i]) for row in values)) for i in range(len(headers))]
    print("  ".join(headers[i].ljust(widths[i]) for i in range(len(headers))))
    print("  ".join("-" * widths[i] for i in range(len(headers))))
    for row in values:
        print("  ".join(row[i].ljust(widths[i]) for i in range(len(headers))))


def command_list(args: argparse.Namespace) -> None:
    board = load_board()
    rows = []
    for item in board["items"]:
        if not item_code(item):
            continue
        if args.owner and field_value(item, "Primary Owner") != args.owner:
            continue
        if args.reviewer and field_value(item, "Peer Reviewer") != args.reviewer:
            continue
        if args.phase and item.get("phase") != args.phase:
            continue
        if args.status and item.get("status") != args.status:
            continue
        if args.agent_status and field_value(item, "Agent Status") != args.agent_status:
            continue
        rows.append(task_summary(item))
    rows.sort(key=lambda row: row["code"] or "")
    if args.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
    else:
        print_table(rows)


def phase_number(item: dict[str, Any]) -> int:
    value = item.get("phase") or ""
    match = re.fullmatch(r"Phase (\d+)", value)
    return int(match.group(1)) if match else 999


def command_ready(args: argparse.Namespace) -> None:
    validate_actor(args.owner)
    board = load_board()
    by_code = {item_code(item): item for item in board["items"] if item_code(item)}
    open_items = [item for item in by_code.values() if item.get("status") != "Done"]
    active_phase = min((phase_number(item) for item in open_items), default=999)
    rows = []
    for code, item in by_code.items():
        if not args.all_phases and phase_number(item) != active_phase:
            continue
        if field_value(item, "Primary Owner") != args.owner:
            continue
        if item.get("status") != "Todo" or field_value(item, "Agent Status") != "Ready":
            continue
        blocked = unresolved_dependencies(item, by_code)
        if not blocked:
            rows.append(task_summary(item, blocked))
    rows.sort(key=lambda row: (row["phase"] or "", row["priority"] or "", row["code"] or ""))
    if args.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
    else:
        if not args.all_phases and active_phase != 999:
            print(f"Active phase: Phase {active_phase}")
        print_table(rows)


def command_review_queue(args: argparse.Namespace) -> None:
    validate_actor(args.reviewer)
    board = load_board()
    rows = [
        task_summary(item)
        for item in board["items"]
        if item_code(item)
        and field_value(item, "Peer Reviewer") == args.reviewer
        and field_value(item, "Agent Status") == "In Review"
    ]
    rows.sort(key=lambda row: row["code"] or "")
    if args.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
    else:
        print_table(rows)


def command_approval_queue(args: argparse.Namespace) -> None:
    validate_actor(args.approver)
    board = load_board()
    rows = [
        task_summary(item)
        for item in board["items"]
        if item_code(item)
        and field_value(item, "Approval Owner") == args.approver
        and field_value(item, "Agent Status") == "Waiting Approval"
    ]
    rows.sort(key=lambda row: row["code"] or "")
    if args.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
    else:
        print_table(rows)


def command_show(args: argparse.Namespace) -> None:
    board = load_board()
    item = find_item(board, args.code)
    by_code = {item_code(entry): entry for entry in board["items"] if item_code(entry)}
    payload = task_summary(item, unresolved_dependencies(item, by_code))
    payload["projectItemId"] = item["id"]
    payload["draftIssueId"] = (item.get("content") or {}).get("id")
    payload["body"] = (item.get("content") or {}).get("body", "")
    payload["progressReport"] = field_value(item, "Progress Report")
    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return
    print(f"{payload['code']} — {payload['title']}")
    print(f"Project: {PROJECT_URL}")
    for label, key in [
        ("Status", "status"),
        ("Agent status", "agentStatus"),
        ("Phase", "phase"),
        ("Priority", "priority"),
        ("Area", "area"),
        ("Estimate", "estimateDays"),
        ("Primary", "primaryOwner"),
        ("Reviewer", "peerReviewer"),
        ("Approval owner", "approvalOwner"),
        ("Approval status", "approvalStatus"),
        ("Depends on", "dependsOn"),
        ("Blocked by", "blockedBy"),
    ]:
        print(f"{label}: {payload.get(key) or '-'}")
    print("\n" + payload["body"])
    if payload["progressReport"]:
        print("\n## Current progress report\n" + payload["progressReport"])


def command_start(args: argparse.Namespace) -> None:
    validate_actor(args.actor)
    board = load_board()
    item = find_item(board, args.code)
    primary = field_value(item, "Primary Owner")
    if primary != args.actor:
        fail(f"{args.code} belongs to `{primary}`, not `{args.actor}`.")
    by_code = {item_code(entry): entry for entry in board["items"] if item_code(entry)}
    blocked = unresolved_dependencies(item, by_code)
    if blocked and not args.force:
        fail(f"{args.code} is blocked by: {', '.join(blocked)}. Use --force only with PM approval.")
    update_select(board, item, "Status", "In Progress")
    update_select(board, item, "Agent Status", "Working")
    update_text(
        board,
        item,
        "Progress Report",
        f"Summary: {args.actor} started {args.code}.\n"
        "Evidence: none yet\nVerification: pending\nRisks or blockers: none reported\n"
        "Next action: implement the task acceptance criteria",
    )
    print(f"Started {args.code} as {args.actor}.")


def read_report(args: argparse.Namespace) -> str:
    if args.file:
        return Path(args.file).read_text(encoding="utf-8").strip()
    if args.message:
        return args.message.strip()
    fail("Provide --file REPORT.md or --message '...'.")


def command_report(args: argparse.Namespace) -> None:
    validate_actor(args.actor)
    board = load_board()
    item = find_item(board, args.code)
    allowed = {
        field_value(item, "Primary Owner"),
        field_value(item, "Peer Reviewer"),
        field_value(item, "Approval Owner"),
    }
    if args.actor not in allowed:
        fail(f"{args.actor} is not an owner, reviewer, or approver for {args.code}.")
    update_text(board, item, "Progress Report", read_report(args))
    print(f"Updated progress report for {args.code}.")


def command_handoff(args: argparse.Namespace) -> None:
    validate_actor(args.actor)
    validate_actor(args.to)
    if args.actor not in IMPLEMENTATION_AGENTS or args.to not in IMPLEMENTATION_AGENTS:
        fail("Only Kasugano and Kyouka can hand implementation tasks to each other.")
    if args.actor == args.to:
        fail("Handoff target must be the other implementation agent.")
    board = load_board()
    item = find_item(board, args.code)
    primary = field_value(item, "Primary Owner")
    reviewer = field_value(item, "Peer Reviewer")
    agent_status = field_value(item, "Agent Status")
    if primary == "dinhkarate" or reviewer == "None":
        fail(f"{args.code} is a manual/PM task and cannot be handed off by agents.")
    if args.actor not in {primary, reviewer}:
        fail(f"{args.actor} is neither primary owner nor peer reviewer for {args.code}.")
    if agent_status in {"In Review", "Waiting Approval", "Done"} or item.get("status") == "Done":
        fail(f"{args.code} cannot be handed off while state is `{agent_status}`.")
    if args.to not in {primary, reviewer}:
        fail(f"Handoff target must be the paired agent `{reviewer if args.actor == primary else primary}`.")
    if not args.reason.strip():
        fail("A handoff reason is required.")

    new_primary = args.to
    new_reviewer = args.actor
    update_select(board, item, "Primary Owner", new_primary)
    update_select(board, item, "Peer Reviewer", new_reviewer)
    if item.get("status") == "In Progress":
        update_select(board, item, "Agent Status", "Working")
    else:
        update_select(board, item, "Agent Status", "Ready")
    existing_report = field_value(item, "Progress Report") or ""
    handoff_report = (
        f"Handoff: {args.actor} -> {new_primary}\n"
        f"Reason: {args.reason.strip()}\n"
        f"New reviewer: {new_reviewer}\n"
        f"Previous progress:\n{existing_report or 'No previous report.'}"
    )
    update_text(board, item, "Progress Report", handoff_report)
    print(f"Handed off {args.code}: primary={new_primary}, reviewer={new_reviewer}.")


def command_submit(args: argparse.Namespace) -> None:
    validate_actor(args.actor)
    board = load_board()
    item = find_item(board, args.code)
    if field_value(item, "Primary Owner") != args.actor:
        fail(f"Only primary owner `{field_value(item, 'Primary Owner')}` can submit {args.code}.")
    update_select(board, item, "Status", "In Progress")
    update_select(board, item, "Agent Status", "In Review")
    print(f"Submitted {args.code} for review by {field_value(item, 'Peer Reviewer')}.")


def command_review_pass(args: argparse.Namespace) -> None:
    validate_actor(args.actor)
    board = load_board()
    item = find_item(board, args.code)
    reviewer = field_value(item, "Peer Reviewer")
    if reviewer != args.actor:
        fail(f"Only peer reviewer `{reviewer}` can pass review for {args.code}.")
    approval_owner = field_value(item, "Approval Owner")
    if approval_owner and approval_owner != "None":
        update_select(board, item, "Agent Status", "Waiting Approval")
        print(f"Peer review passed. {args.code} is waiting for approval from {approval_owner}.")
    else:
        update_select(board, item, "Status", "Done")
        update_select(board, item, "Agent Status", "Done")
        print(f"Peer review passed. {args.code} is Done.")


def command_request_changes(args: argparse.Namespace) -> None:
    validate_actor(args.actor)
    board = load_board()
    item = find_item(board, args.code)
    allowed = {field_value(item, "Peer Reviewer"), field_value(item, "Approval Owner")}
    if args.actor not in allowed:
        fail(f"{args.actor} cannot request changes for {args.code}.")
    update_select(board, item, "Agent Status", "Working")
    if field_value(item, "Approval Owner") != "None":
        update_select(board, item, "Approval Status", "Changes Requested")
    update_text(board, item, "Progress Report", read_report(args))
    print(f"Changes requested on {args.code}; returned to Working.")


def command_approve(args: argparse.Namespace) -> None:
    validate_actor(args.actor)
    board = load_board()
    item = find_item(board, args.code)
    approval_owner = field_value(item, "Approval Owner")
    primary = field_value(item, "Primary Owner")
    if approval_owner != args.actor and not (primary == args.actor == "dinhkarate"):
        fail(f"Only approval owner `{approval_owner}` can approve {args.code}.")
    if args.file or args.message:
        update_text(board, item, "Progress Report", read_report(args))
    update_select(board, item, "Approval Status", "Approved")
    update_select(board, item, "Status", "Done")
    update_select(board, item, "Agent Status", "Done")
    print(f"Approved and completed {args.code}.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Operate the Motas GitHub Project workflow.")
    sub = parser.add_subparsers(dest="command", required=True)

    list_parser = sub.add_parser("list", help="List project tasks with optional filters.")
    list_parser.add_argument("--owner")
    list_parser.add_argument("--reviewer")
    list_parser.add_argument("--phase")
    list_parser.add_argument("--status", choices=["Todo", "In Progress", "Done"])
    list_parser.add_argument(
        "--agent-status",
        choices=["Ready", "Working", "In Review", "Blocked", "Waiting Approval", "Done"],
    )
    list_parser.add_argument("--json", action="store_true")
    list_parser.set_defaults(func=command_list)

    ready_parser = sub.add_parser("ready", help="List dependency-free tasks ready for an owner.")
    ready_parser.add_argument("owner")
    ready_parser.add_argument("--all-phases", action="store_true", help="Include later phases; PM use only.")
    ready_parser.add_argument("--json", action="store_true")
    ready_parser.set_defaults(func=command_ready)

    review_queue_parser = sub.add_parser("review-queue", help="List tasks waiting for a peer reviewer.")
    review_queue_parser.add_argument("reviewer")
    review_queue_parser.add_argument("--json", action="store_true")
    review_queue_parser.set_defaults(func=command_review_queue)

    approval_queue_parser = sub.add_parser("approval-queue", help="List tasks waiting for final approval.")
    approval_queue_parser.add_argument("approver")
    approval_queue_parser.add_argument("--json", action="store_true")
    approval_queue_parser.set_defaults(func=command_approval_queue)

    show_parser = sub.add_parser("show", help="Show the complete task description and workflow.")
    show_parser.add_argument("code")
    show_parser.add_argument("--json", action="store_true")
    show_parser.set_defaults(func=command_show)

    start_parser = sub.add_parser("start", help="Claim/start a ready task as its primary owner.")
    start_parser.add_argument("code")
    start_parser.add_argument("actor")
    start_parser.add_argument("--force", action="store_true")
    start_parser.set_defaults(func=command_start)

    report_parser = sub.add_parser("report", help="Replace a task progress report.")
    report_parser.add_argument("code")
    report_parser.add_argument("actor")
    report_parser.add_argument("--file")
    report_parser.add_argument("--message")
    report_parser.set_defaults(func=command_report)

    handoff_parser = sub.add_parser("handoff", help="Hand an implementation task to the paired agent.")
    handoff_parser.add_argument("code")
    handoff_parser.add_argument("actor", help="Current primary owner or reviewer initiating the handoff.")
    handoff_parser.add_argument("--to", required=True, help="New primary owner: kasuganodesu or kyoukadesu.")
    handoff_parser.add_argument("--reason", required=True, help="Reason recorded in Progress Report.")
    handoff_parser.set_defaults(func=command_handoff)

    submit_parser = sub.add_parser("submit", help="Submit implementation for peer review.")
    submit_parser.add_argument("code")
    submit_parser.add_argument("actor")
    submit_parser.set_defaults(func=command_submit)

    review_parser = sub.add_parser("review-pass", help="Record a successful peer review.")
    review_parser.add_argument("code")
    review_parser.add_argument("actor")
    review_parser.set_defaults(func=command_review_pass)

    changes_parser = sub.add_parser("request-changes", help="Return a task to Working with a report.")
    changes_parser.add_argument("code")
    changes_parser.add_argument("actor")
    changes_parser.add_argument("--file")
    changes_parser.add_argument("--message")
    changes_parser.set_defaults(func=command_request_changes)

    approve_parser = sub.add_parser("approve", help="Approve and complete a task as dinhkarate.")
    approve_parser.add_argument("code")
    approve_parser.add_argument("actor")
    approve_parser.add_argument("--file")
    approve_parser.add_argument("--message")
    approve_parser.set_defaults(func=command_approve)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
