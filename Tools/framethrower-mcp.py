#!/usr/bin/env python3
"""MCP stdio binding for the already-running FrameThrower GUI.

One UTF-8 JSON-RPC message per line is forwarded unchanged over an owner-only
Unix socket. No TCP/HTTP listener, app launch, model call, or filesystem tool.
Closing stdin closes this connection and cancels its outstanding app work.
"""
import argparse
import ctypes
import errno
import json
import os
import select
import socket
import stat
import sys
import time

MAX_LINE = 1_048_576
MAX_BUFFER = 2 * MAX_LINE
IO_TIMEOUT = 5.0


class ProxyError(Exception):
    pass


def connect(path):
    directory = os.path.dirname(path)
    try:
        d = os.lstat(directory)
        s = os.lstat(path)
    except FileNotFoundError as exc:
        raise ProxyError("FrameThrower control server is unavailable. Open FrameThrower normally and open a recording, then reconnect this MCP client.") from exc
    if not stat.S_ISDIR(d.st_mode) or d.st_uid != os.getuid() or stat.S_IMODE(d.st_mode) != 0o700:
        raise ProxyError("Unsafe control directory: expected an owned, non-symlink directory with mode 0700.")
    if not stat.S_ISSOCK(s.st_mode) or s.st_uid != os.getuid() or stat.S_IMODE(s.st_mode) != 0o600:
        raise ProxyError("Unsafe control socket: expected an owned, non-symlink socket with mode 0600.")
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.settimeout(IO_TIMEOUT)
        connection.connect(path)
        # Directory permissions protect the pathname; independently verify the
        # connected peer on macOS rather than trusting a self-reported identity.
        if sys.platform == "darwin":
            uid, gid = ctypes.c_uint(), ctypes.c_uint()
            libc = ctypes.CDLL(None, use_errno=True)
            if libc.getpeereid(connection.fileno(), ctypes.byref(uid), ctypes.byref(gid)) != 0 or uid.value != os.getuid():
                raise ProxyError("Control socket peer belongs to another user.")
        connection.setblocking(False)
        return connection
    except (OSError, ProxyError) as exc:
        connection.close()
        if isinstance(exc, ProxyError):
            raise
        raise ProxyError("FrameThrower control server is not accepting connections. Open FrameThrower normally and open a recording, then reconnect; the MCP proxy never launches it.") from exc


class Lines:
    def __init__(self):
        self.partial = bytearray()
        self.since = None

    def feed(self, chunk):
        self.partial.extend(chunk)
        lines = []
        while True:
            index = self.partial.find(b"\n")
            if index < 0:
                break
            if index > MAX_LINE:
                raise ProxyError("MCP message exceeds the 1 MiB line limit.")
            self.since = None
            lines.append(bytes(self.partial[:index + 1]))
            del self.partial[:index + 1]
        if len(self.partial) > MAX_LINE:
            raise ProxyError("MCP message exceeds the 1 MiB line limit.")
        self.since = (self.since or time.monotonic()) if self.partial else None
        return b"".join(lines)

    def check(self, now):
        if self.since is not None and now - self.since > IO_TIMEOUT:
            raise ProxyError("Incomplete MCP line timed out.")


class DocumentScope:
    """One native-agent MCP instance is bound to its recording's open handle."""
    def __init__(self, document_id):
        self.document_id = document_id
        self.requests = {}

    def client(self, data):
        forwarded, replies = [], []
        for line in data.splitlines():
            message = json.loads(line)
            if not isinstance(message, dict): raise ProxyError("Use one JSON-RPC object per line.")
            method = message.get("method")
            params = message.get("params", {})
            if not isinstance(params, dict): raise ProxyError("JSON-RPC parameters must be an object.")
            identifier = message.get("id")
            reason = None
            if method == "tools/call":
                name, args = params.get("name"), params.get("arguments", {})
                if not isinstance(args, dict): raise ProxyError("MCP tool arguments must be an object.")
                if name != "list_recordings" and args.get("document_id") != self.document_id:
                    reason = "This Director session controls only its bound recording. Use its current document_id."
            elif method == "resources/read":
                if not str(params.get("uri", "")).startswith("framethrower://recordings/" + self.document_id + "/"):
                    reason = "This Director session can read only its bound recording."
            if reason:
                if identifier is not None:
                    replies.append({"jsonrpc": "2.0", "id": identifier, "error": {"code": -32602, "message": reason}})
            else:
                if method == "notifications/cancelled":
                    self.requests.pop(json.dumps(params.get("requestId")), None)
                if identifier is not None:
                    if len(self.requests) >= 64: raise ProxyError("Too many scoped MCP requests are outstanding.")
                    self.requests[json.dumps(identifier)] = (method, params.get("name"))
                forwarded.append(message)
        return self.encode(forwarded), self.encode(replies)

    @staticmethod
    def encode(messages):
        return b"".join((json.dumps(value, separators=(",", ":")) + "\n").encode() for value in messages)

    def server(self, data):
        output = []
        for line in data.splitlines():
            message = json.loads(line)
            request = self.requests.pop(json.dumps(message.get("id")), None)
            result = message.get("result")
            if request and isinstance(result, dict):
                method, name = request
                if method == "tools/list":
                    for tool in result.get("tools", []):
                        field = tool.get("inputSchema", {}).get("properties", {}).get("document_id")
                        if isinstance(field, dict): field["enum"] = [self.document_id]
                elif method == "resources/list":
                    prefix = "framethrower://recordings/" + self.document_id + "/"
                    result["resources"] = [r for r in result.get("resources", []) if r.get("uri", "").startswith(prefix)]
                elif method == "tools/call" and name == "list_recordings":
                    value = result.get("structuredContent")
                    if isinstance(value, dict):
                        value["recordings"] = [r for r in value.get("recordings", []) if r.get("documentID") == self.document_id]
                        value["omitted"] = 0
                        result["content"] = [{"type": "text", "text": json.dumps(value, separators=(",", ":"))}]
            output.append(message)
        return self.encode(output)


def relay(connection, input_fd=0, output_fd=1, scope=None):
    incoming, outgoing = Lines(), Lines()
    to_app, to_client = bytearray(), bytearray()
    app_progress = client_progress = time.monotonic()
    old_input, old_output = os.get_blocking(input_fd), os.get_blocking(output_fd)
    os.set_blocking(input_fd, False)
    os.set_blocking(output_fd, False)
    try:
        while True:
            now = time.monotonic()
            incoming.check(now)
            outgoing.check(now)
            if to_app and now - app_progress > IO_TIMEOUT:
                raise ProxyError("FrameThrower socket write timed out.")
            if to_client and now - client_progress > IO_TIMEOUT:
                raise ProxyError("MCP client stopped reading responses.")
            readable, writable, _ = select.select(
                [input_fd, connection],
                ([connection] if to_app else []) + ([output_fd] if to_client else []), [], 0.25)
            if input_fd in readable:
                try:
                    chunk = os.read(input_fd, 16384)
                except BlockingIOError:
                    chunk = None
                if chunk == b"":
                    return  # EOF is graceful MCP shutdown, not an app Quit.
                if chunk:
                    if not to_app:
                        app_progress = time.monotonic()
                    data = incoming.feed(chunk)
                    if scope:
                        data, local_replies = scope.client(data)
                        if local_replies and not to_client: client_progress = time.monotonic()
                        to_client.extend(local_replies)
                    to_app.extend(data)
            if connection in readable:
                try:
                    chunk = connection.recv(16384)
                except BlockingIOError:
                    chunk = None
                if chunk == b"":
                    raise ProxyError("FrameThrower closed the control connection. Check that the app is still running, then reconnect this MCP client.")
                if chunk:
                    if not to_client:
                        client_progress = time.monotonic()
                    data = outgoing.feed(chunk)
                    to_client.extend(scope.server(data) if scope else data)
            if len(to_app) > MAX_BUFFER or len(to_client) > MAX_BUFFER:
                raise ProxyError("MCP output queue exceeded its bounded buffer.")
            if connection in writable and to_app:
                try:
                    count = connection.send(to_app)
                    del to_app[:count]
                    app_progress = time.monotonic()
                except BlockingIOError:
                    pass
            if output_fd in writable and to_client:
                try:
                    count = os.write(output_fd, to_client)
                    del to_client[:count]
                    client_progress = time.monotonic()
                except BlockingIOError:
                    pass
    finally:
        os.set_blocking(input_fd, old_input)
        os.set_blocking(output_fd, old_output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default=f"/tmp/framethrower-{os.getuid()}/control.sock",
                        help="Private app socket path (normally leave at the default).")
    parser.add_argument("--document-id", help="Bind this native Director MCP instance to one open recording.")
    args = parser.parse_args()
    connection = None
    try:
        connection = connect(args.socket)
        relay(connection, scope=DocumentScope(args.document_id) if args.document_id else None)
        return 0
    except (ProxyError, OSError, ValueError) as exc:
        print(json.dumps({"error": {"code": "framethrower_mcp_unavailable", "message": str(exc)}}), file=sys.stderr, flush=True)
        return 2
    finally:
        if connection is not None:
            connection.close()


if __name__ == "__main__":
    sys.exit(main())
