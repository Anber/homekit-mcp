import copy
import base64
import io
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from homekitctl import BridgeError, Client, relay, check_socket
from manage_homekit_rooms import apply_plan, digest, inventory, make_plan, validate_plan, private_json

HOME = "11111111-1111-1111-1111-111111111111"
ROOM = "22222222-2222-2222-2222-222222222222"
NEXT = "33333333-3333-3333-3333-333333333333"
ACCESSORY = "44444444-4444-4444-4444-444444444444"
OTHER = "55555555-5555-5555-5555-555555555555"


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="hk-", dir="/private/tmp"))
        self.directory.chmod(0o700)
        self.socket = self.directory / "server.sock"
        self.policy = {"home_uuid": HOME, "accessory_uuids": [ACCESSORY],
                       "editable_room_uuids": [ROOM], "allow_metadata_writes": True}
        private_json(self.directory / "policy.json", self.policy)
        self.log = open(self.directory / "fixture.log", "w")
        executable = os.environ.get("HOMEKIT_FIXTURE", str(ROOT / ".build/debug/homekit-mcp-fixture"))
        self.process = subprocess.Popen([executable, str(self.directory)], stdout=self.log, stderr=self.log)
        until = time.monotonic() + 5
        while not self.socket.exists() and time.monotonic() < until and self.process.poll() is None:
            time.sleep(0.02)
        self.assertTrue(self.socket.exists(), (self.directory / "fixture.log").read_text())

    def restart(self):
        self.process.terminate()
        self.process.wait(timeout=5)
        executable = os.environ.get("HOMEKIT_FIXTURE", str(ROOT / ".build/debug/homekit-mcp-fixture"))
        self.process = subprocess.Popen([executable, str(self.directory)], stdout=self.log, stderr=self.log)
        until = time.monotonic() + 5
        while not self.socket.exists() and time.monotonic() < until and self.process.poll() is None:
            time.sleep(0.02)
        return self.socket.exists()

    def tearDown(self):
        self.process.terminate()
        self.process.wait(timeout=5)
        self.log.close()
        shutil.rmtree(self.directory)

    def test_private_permissions_and_scope(self):
        self.assertEqual(stat.S_IMODE(self.socket.stat().st_mode), 0o600)
        with Client(self.socket) as client:
            state = inventory(client)
            self.assertEqual([x["uuid"] for x in state["accessories"]], [ACCESSORY])
            with self.assertRaises(BridgeError):
                client.call("list_homes")
            with self.assertRaises(BridgeError):
                client.call("accessory_on", {"accessory_uuid": OTHER})

    def test_fragmented_and_coalesced_frames(self):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(3)
            connection.connect(str(self.socket))
            message = b'{"jsonrpc":"2.0","id":"fragment","method":"ping"}\n'
            for chunk in [message[:7], message[7:19], message[19:]]:
                connection.sendall(chunk)
            reader = connection.makefile("rb")
            self.assertEqual(json.loads(reader.readline())["id"], "fragment")
            connection.sendall(message + message.replace(b"fragment", b"second"))
            self.assertEqual(json.loads(reader.readline())["id"], "fragment")
            self.assertEqual(json.loads(reader.readline())["id"], "second")
            reader.close()

    def test_oversized_frame_is_disconnected(self):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(3)
            connection.connect(str(self.socket))
            try:
                connection.sendall(b"x" * 1_048_578)
                self.assertEqual(connection.recv(1), b"")
            except (BrokenPipeError, ConnectionResetError):
                pass

    def test_stdio_relay_preserves_notifications_and_string_ids(self):
        requests = [
            {"jsonrpc": "2.0", "id": "init", "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": "list", "method": "tools/list"},
        ]
        output = io.BytesIO()
        self.assertEqual(relay(self.socket, io.BytesIO(b"".join(json.dumps(x).encode() + b"\n" for x in requests)), output), 0)
        responses = [json.loads(x) for x in output.getvalue().splitlines()]
        self.assertEqual([x["id"] for x in responses], ["init", "list"])

    def test_socket_symlink_and_public_directory_are_rejected(self):
        link = self.directory / "link.sock"
        link.symlink_to(self.socket)
        with self.assertRaises(BridgeError):
            check_socket(link)
        self.directory.chmod(0o755)
        try:
            with self.assertRaises(BridgeError):
                check_socket(self.socket)
        finally:
            self.directory.chmod(0o700)

    def test_second_server_cannot_replace_active_socket(self):
        executable = os.environ.get("HOMEKIT_FIXTURE", str(ROOT / ".build/debug/homekit-mcp-fixture"))
        second = subprocess.run([executable, str(self.directory)], capture_output=True, timeout=5)
        self.assertNotEqual(second.returncode, 0)
        with Client(self.socket) as client:
            self.assertEqual(inventory(client)["home_uuid"], HOME)

    def test_stop_releases_socket_and_connections(self):
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(3)
        connection.connect(str(self.socket))
        self.process.terminate()
        self.process.wait(timeout=5)
        self.assertFalse(self.socket.exists())
        self.assertEqual(connection.recv(1), b"")
        connection.close()

    def test_bulk_plan_snapshots_before_apply_and_verifies(self):
        with Client(self.socket) as client:
            current = inventory(client)
            plan = make_plan(current, [{"accessory_uuid": ACCESSORY, "room_uuid": NEXT}])
            result = apply_plan(client, plan, digest(plan), self.directory / "results")
            snapshot = json.loads(Path(result["snapshot"]).read_text())
            self.assertEqual(snapshot["accessories"][0]["room_uuid"], ROOM)
            self.assertEqual(result["verified_moves"], 1)
            self.assertEqual(inventory(client)["accessories"][0]["room_uuid"], NEXT)
            journal = list((self.directory / "journal").glob("*.json"))
            self.assertEqual(len(journal), 1)
            record = json.loads(journal[0].read_text())
            self.assertEqual(record["before"]["accessories"][0]["room_uuid"], ROOM)
            self.assertEqual(record["operation"]["status"], "succeeded")
            self.assertEqual(stat.S_IMODE(journal[0].stat().st_mode), 0o600)

    def test_stale_and_tampered_plans_make_no_writes(self):
        with Client(self.socket) as client:
            state = inventory(client)
            plan = make_plan(state, [{"accessory_uuid": ACCESSORY, "room_uuid": NEXT}])
            original_hash = digest(plan)
            changed = copy.deepcopy(plan)
            changed["moves"][0]["expected_name"] = "Stale name"
            with self.assertRaises(BridgeError):
                apply_plan(client, changed, original_hash, self.directory / "results")
            with self.assertRaises(BridgeError):
                apply_plan(client, changed, digest(changed), self.directory / "results")
            self.assertEqual(list((self.directory / "journal").glob("*.json")), [])
            self.assertEqual(inventory(client), state)

    def test_snapshot_failure_makes_no_writes(self):
        with Client(self.socket) as client:
            state = inventory(client)
            plan = make_plan(state, [{"accessory_uuid": ACCESSORY, "room_uuid": NEXT}])
            public = self.directory / "public"
            public.mkdir(mode=0o755)
            with self.assertRaises(BridgeError):
                apply_plan(client, plan, digest(plan), public)
            self.assertEqual(inventory(client), state)

    def test_plan_rejects_unapproved_targets_and_duplicates(self):
        with Client(self.socket) as client:
            state = inventory(client)
            with self.assertRaises(BridgeError):
                make_plan(state, [{"accessory_uuid": OTHER, "room_uuid": NEXT}])
            with self.assertRaises(BridgeError):
                make_plan(state, [{"accessory_uuid": ACCESSORY, "room_uuid": str(uuid.uuid4())}])
            plan = make_plan(state, [{"accessory_uuid": ACCESSORY, "room_uuid": NEXT}])
            plan["moves"].append(dict(plan["moves"][0]))
            with self.assertRaises(BridgeError):
                validate_plan(plan, state)

    def test_completed_request_is_not_reapplied_after_process_restart(self):
        with Client(self.socket) as client:
            plan = make_plan(inventory(client), [{"accessory_uuid": ACCESSORY, "room_uuid": NEXT}])
            arguments = dict(plan["moves"][0], home_uuid=HOME)
            first = client.call("set_accessory_room", arguments)
            while first["status"] == "pending":
                time.sleep(0.01)
                first = client.call("get_operation", {"operation_uuid": first["operation_uuid"]})
            self.assertEqual(first["status"], "succeeded")
        self.assertTrue(self.restart())
        with Client(self.socket) as client:
            # Fixture backend starts in its original state. Replay must return
            # the old operation, not mutate this new backend a second time.
            replay = client.call("set_accessory_room", arguments)
            self.assertEqual(replay["operation_uuid"], first["operation_uuid"])
            self.assertEqual(inventory(client)["accessories"][0]["room_uuid"], ROOM)

    def test_policy_is_read_only_even_for_direct_unlisted_calls(self):
        self.policy["allow_metadata_writes"] = False
        (self.directory / "policy.json").write_text(json.dumps(self.policy))
        self.assertTrue(self.restart())
        with Client(self.socket) as client:
            plan = make_plan(inventory(client), [{"accessory_uuid": ACCESSORY, "room_uuid": NEXT}])
            with self.assertRaises(BridgeError):
                client.call("set_accessory_room", dict(plan["moves"][0], home_uuid=HOME))
        self.assertEqual(list((self.directory / "journal").glob("*.json")), [])

    def test_pending_durable_journal_blocks_write_mode_restart(self):
        with Client(self.socket) as client:
            before = inventory(client)
            plan = make_plan(before, [{"accessory_uuid": ACCESSORY, "room_uuid": NEXT}])
        self.process.terminate(); self.process.wait(timeout=5)
        arguments = dict(plan["moves"][0], home_uuid=HOME)
        operation_id = str(uuid.uuid4()).upper()
        fingerprint = base64.b64encode(json.dumps({"tool": "set_accessory_room", "arguments": arguments}).encode()).decode()
        record = {"operation_uuid": operation_id, "request_uuid": arguments["request_uuid"],
                  "home_uuid": HOME, "request_fingerprint": fingerprint, "tool": "set_accessory_room",
                  "status": "pending", "message": "Fixture pending"}
        private_json(self.directory / "journal" / ("operation-" + operation_id + ".json"),
                     {"operation": record, "before": before})
        self.assertFalse(self.restart())
        self.assertIsNotNone(self.process.poll())
        self.policy["allow_metadata_writes"] = False
        (self.directory / "policy.json").write_text(json.dumps(self.policy))
        self.assertTrue(self.restart())
        with Client(self.socket) as client:
            self.assertEqual(client.call("get_operation", {"operation_uuid": operation_id})["status"], "pending")

    def test_duplicate_request_uuid_variants_fail_whole_plan_preflight(self):
        with Client(self.socket) as client:
            state = inventory(client)
        state["accessories"].append({"uuid": OTHER, "name": "Other", "room_uuid": ROOM, "category": "light"})
        plan = make_plan(state, [{"accessory_uuid": ACCESSORY, "room_uuid": NEXT},
                                 {"accessory_uuid": OTHER, "room_uuid": NEXT}])
        plan["moves"][0]["request_uuid"] = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        plan["moves"][1]["request_uuid"] = "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}"
        with self.assertRaises(BridgeError):
            validate_plan(plan, state)


if __name__ == "__main__":
    unittest.main()
