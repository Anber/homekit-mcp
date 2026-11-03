#!/usr/bin/env python3
"""Local HomeKit metadata CLI and MCP stdio relay. Python standard library only."""
import argparse
import json
import os
from pathlib import Path
import socket
import stat
import sys
import uuid

MAX_FRAME = 1_048_576
DEFAULT_SOCKET = Path.home() / "Library/Application Support/HomeKitMCP/server.sock"


class BridgeError(Exception):
    pass


def check_socket(path):
    path = Path(path).absolute()
    parent = path.parent.lstat()
    node = path.lstat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid() or parent.st_mode & 0o077:
        raise BridgeError("Socket directory must be owned and private (0700), without a symlink")
    if not stat.S_ISSOCK(node.st_mode) or node.st_uid != os.geteuid() or node.st_mode & 0o077:
        raise BridgeError("Expected an owned private Unix socket (0600)")
    return path


class Client:
    def __init__(self, path=DEFAULT_SOCKET, timeout=35, initialize=True):
        self.path, self.timeout, self.initialize = path, timeout, initialize
        self.socket = None
        self.reader = None

    def __enter__(self):
        path = check_socket(self.path)
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            connection.settimeout(self.timeout)
            connection.connect(str(path))
            self.socket = connection
            self.reader = connection.makefile("rb")
            if self.initialize:
                self.exchange({"jsonrpc": "2.0", "id": "cli-initialize", "method": "initialize",
                               "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                                          "clientInfo": {"name": "homekitctl", "version": "0.2.0"}}})
                self.exchange({"jsonrpc": "2.0", "method": "notifications/initialized"})
            return self
        except BaseException:
            connection.close()
            if self.reader:
                self.reader.close()
            raise

    def __exit__(self, *_):
        if self.reader:
            self.reader.close()
        if self.socket:
            self.socket.close()

    def exchange(self, request):
        encoded = json.dumps(request, separators=(",", ":"), allow_nan=False).encode()
        if len(encoded) > MAX_FRAME:
            raise BridgeError("MCP frame is too large")
        self.socket.sendall(encoded + b"\n")
        if "id" not in request:
            return None
        line = self.reader.readline(MAX_FRAME + 2)
        if not line.endswith(b"\n") or len(line) > MAX_FRAME + 1:
            raise BridgeError("Missing/oversized response; inspect the operation journal before retrying a write")
        response = json.loads(line)
        if response.get("jsonrpc") != "2.0" or response.get("id") != request["id"]:
            raise BridgeError("Unexpected response identity")
        return response

    def call(self, tool, arguments=None):
        response = self.exchange({"jsonrpc": "2.0", "id": str(uuid.uuid4()), "method": "tools/call",
                                  "params": {"name": tool, "arguments": arguments or {}}})
        if response.get("error"):
            raise BridgeError(response["error"].get("message", "Protocol error"))
        result = response["result"]
        if result.get("isError"):
            raise BridgeError("; ".join(v.get("text", "") for v in result.get("content", [])))
        return result["structuredContent"]


def relay(path, input_stream=None, output_stream=None):
    """No startup side effects: the user must explicitly start the native app."""
    source = input_stream or sys.stdin.buffer
    target = output_stream or sys.stdout.buffer
    with Client(path, initialize=False) as client:
        while True:
            line = source.readline(MAX_FRAME + 2)
            if not line:
                return 0
            if len(line) > MAX_FRAME + 1 or not line.endswith(b"\n"):
                raise BridgeError("Invalid or oversized input frame")
            if not line.strip():
                continue
            request = json.loads(line, parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Non-finite JSON")))
            if not isinstance(request, dict):
                raise BridgeError("JSON-RPC object required")
            response = client.exchange(request)
            if response is not None:
                target.write(json.dumps(response, separators=(",", ":"), allow_nan=False).encode() + b"\n")
                target.flush()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", type=Path, default=DEFAULT_SOCKET)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ["stdio", "homes", "accessories", "rooms"]:
        sub.add_parser(command)
    operation = sub.add_parser("operation")
    operation.add_argument("operation_uuid")
    call = sub.add_parser("call")
    call.add_argument("tool")
    call.add_argument("--arguments", type=json.loads, required=True, help="Exact UUID-based JSON arguments")
    args = parser.parse_args(argv)
    try:
        if args.command == "stdio":
            return relay(args.socket)
        with Client(args.socket) as client:
            if args.command == "call":
                result = client.call(args.tool, args.arguments)
            elif args.command == "operation":
                result = client.call("get_operation", {"operation_uuid": args.operation_uuid})
            else:
                result = client.call({"homes": "list_homes", "accessories": "get_all_accessories",
                                      "rooms": "get_all_rooms"}[args.command])
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (BridgeError, OSError, ValueError, KeyError) as error:
        # stdout belongs exclusively to the MCP protocol in relay mode.
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
