#!/usr/bin/env python3
"""Reviewable UUID room plans; no HA tokens, external commands or name matching."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import time
import uuid

from homekitctl import BridgeError, Client, DEFAULT_SOCKET


def private_directory(path):
    path = Path(path)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    mode = path.lstat()
    if not stat.S_ISDIR(mode.st_mode) or mode.st_uid != os.geteuid() or mode.st_mode & 0o077:
        raise BridgeError("Output directory must be an owned private directory (0700)")
    return path


def private_json(path, value):
    path = Path(path)
    private_directory(path.parent)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as target:
        json.dump(value, target, ensure_ascii=False, indent=2)
        target.write("\n")
        target.flush()
        os.fsync(target.fileno())
        if sys.platform == "darwin":
            fcntl.fcntl(target.fileno(), fcntl.F_FULLFSYNC)
        directory_fd = os.open(str(path.parent), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory_fd)
            if sys.platform == "darwin":
                fcntl.fcntl(target.fileno(), fcntl.F_FULLFSYNC)
        finally:
            os.close(directory_fd)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def inventory(client):
    accessories = client.call("get_all_accessories")
    rooms = client.call("get_all_rooms")
    if accessories["home_uuid"] != rooms["home_uuid"]:
        raise BridgeError("Inventory home mismatch")
    return {"home_uuid": accessories["home_uuid"], "accessories": accessories["accessories"], "rooms": rooms["rooms"]}


def validate_plan(plan, current):
    if set(plan) != {"schema_version", "home_uuid", "moves"} or plan["schema_version"] != 1:
        raise BridgeError("Unsupported plan")
    if uuid.UUID(plan["home_uuid"]) != uuid.UUID(current["home_uuid"]) or not isinstance(plan["moves"], list):
        raise BridgeError("Plan belongs to another home")
    accessories = {uuid.UUID(x["uuid"]): x for x in current["accessories"]}
    rooms = {uuid.UUID(x["uuid"]) for x in current["rooms"]}
    seen = set()
    requests = set()
    for move in plan["moves"]:
        if set(move) != {"accessory_uuid", "room_uuid", "expected_name", "expected_room_uuid", "request_uuid"}:
            raise BridgeError("Exact UUID-based move fields required")
        identifiers = {key: uuid.UUID(move[key]) for key in
                       ["accessory_uuid", "room_uuid", "expected_room_uuid", "request_uuid"]}
        key = identifiers["accessory_uuid"]
        if key in seen:
            raise BridgeError("Duplicate accessory in plan")
        if identifiers["request_uuid"] in requests:
            raise BridgeError("Duplicate request UUID in plan")
        seen.add(key)
        requests.add(identifiers["request_uuid"])
        actual = accessories.get(key)
        if actual is None or actual["name"] != move["expected_name"] or uuid.UUID(actual["room_uuid"]) != identifiers["expected_room_uuid"]:
            raise BridgeError("Stale plan or accessory outside policy; regenerate the whole plan")
        if identifiers["room_uuid"] not in rooms:
            raise BridgeError("Target room is not in the selected home")
    return plan


def make_plan(current, desired):
    if not isinstance(desired, list):
        raise BridgeError("Desired mapping must be a list of accessory_uuid/room_uuid objects")
    by_id = {uuid.UUID(x["uuid"]): x for x in current["accessories"]}
    moves = []
    seen = set()
    for entry in desired:
        if set(entry) != {"accessory_uuid", "room_uuid"} or uuid.UUID(entry["accessory_uuid"]) not in by_id:
            raise BridgeError("Mapping must use allowed accessory UUIDs and room UUIDs")
        accessory = uuid.UUID(entry["accessory_uuid"])
        if accessory in seen:
            raise BridgeError("Duplicate accessory in desired mapping")
        seen.add(accessory)
        actual = by_id[accessory]
        if uuid.UUID(actual["room_uuid"]) != uuid.UUID(entry["room_uuid"]):
            moves.append({"accessory_uuid": actual["uuid"], "room_uuid": str(uuid.UUID(entry["room_uuid"])).upper(),
                          "expected_name": actual["name"], "expected_room_uuid": actual["room_uuid"],
                          "request_uuid": str(uuid.uuid4())})
    return validate_plan({"schema_version": 1, "home_uuid": current["home_uuid"], "moves": moves}, current)


def apply_plan(client, plan, expected_hash, output, wait_seconds=20):
    if digest(plan) != expected_hash:
        raise BridgeError("Plan hash changed after review")
    before = inventory(client)
    validate_plan(plan, before)  # Check every row before the first mutation.
    output = private_directory(output)
    snapshot = output / ("before-" + str(uuid.uuid4()) + ".json")
    private_json(snapshot, before)  # Failure here prevents all writes.
    results = []
    for move in plan["moves"]:
        arguments = dict(move, home_uuid=plan["home_uuid"])
        operation = client.call("set_accessory_room", arguments)
        deadline = time.monotonic() + wait_seconds
        while operation["status"] == "pending" and time.monotonic() < deadline:
            time.sleep(0.05)
            operation = client.call("get_operation", {"operation_uuid": operation["operation_uuid"]})
        results.append(operation)
        private_json(output / ("result-" + str(uuid.uuid4()) + ".json"), operation)
        if operation["status"] != "succeeded":
            raise BridgeError("Operation pending/unconfirmed; stop and inspect its journal and inventory. Do not re-submit with a new request_uuid.")
    after = inventory(client)
    actual_rooms = {uuid.UUID(x["uuid"]): uuid.UUID(x["room_uuid"]) for x in after["accessories"]}
    if any(actual_rooms.get(uuid.UUID(move["accessory_uuid"])) != uuid.UUID(move["room_uuid"]) for move in plan["moves"]):
        raise BridgeError("Final room assignments do not match the plan")
    return {"snapshot": str(snapshot), "verified_moves": len(results), "operations": results}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", type=Path, default=DEFAULT_SOCKET)
    sub = parser.add_subparsers(dest="command", required=True)
    plan_parser = sub.add_parser("plan")
    plan_parser.add_argument("--desired", type=Path, required=True)
    plan_parser.add_argument("--output", type=Path, required=True)
    apply_parser = sub.add_parser("apply")
    apply_parser.add_argument("--plan", type=Path, required=True)
    apply_parser.add_argument("--plan-sha256", required=True)
    apply_parser.add_argument("--output-directory", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        with Client(args.socket) as client:
            if args.command == "plan":
                value = make_plan(inventory(client), json.loads(args.desired.read_text()))
                private_json(args.output, value)
                result = {"plan": str(args.output), "sha256": digest(value), "moves": len(value["moves"])}
            else:
                result = apply_plan(client, json.loads(args.plan.read_text()), args.plan_sha256, args.output_directory)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (BridgeError, OSError, ValueError, KeyError, TypeError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
