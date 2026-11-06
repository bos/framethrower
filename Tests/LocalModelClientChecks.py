#!/usr/bin/env python3
"""Network-boundary checks using only a temporary loopback HTTP server."""
import http.server
import json
from pathlib import Path
import sys
import threading
import unittest
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
from local_model import LocalModelClient


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(302)
        self.send_header("Location", "https://example.invalid/never-contact-this-host")
        self.end_headers()

    def do_POST(self):
        self.server.payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.authorization = self.headers.get("Authorization")
        data = b'{"choices":[{"message":{"content":"local result"}}]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class LocalModelClientChecks(unittest.TestCase):
    def test_only_numeric_loopback(self):
        for endpoint in ("http://example.invalid:1234", "http://localhost:1234", "https://127.0.0.1:1234",
                         "http://192.168.1.2:1234", "http://127.0.0.1", "http://u:p@127.0.0.1:1234",
                         "http://127.0.0.1:1234/v1", "http://127.0.0.1:1234?remote=x"):
            with self.subTest(endpoint=endpoint), self.assertRaises(ValueError):
                LocalModelClient(endpoint)
        LocalModelClient("http://127.0.0.1:1234")
        LocalModelClient("http://[::1]:1234")

    def test_requests_and_redirects(self):
        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            client = LocalModelClient(f"http://127.0.0.1:{server.server_port}", "test-local-key")
            # An invalid proxy would break this if ambient proxy settings were used.
            import os
            from unittest.mock import patch
            with patch.dict(os.environ, {"HTTP_PROXY": "http://example.invalid:9999", "NO_PROXY": ""}):
                response = client.chat([{"role": "user", "content": "synthetic input"}], [], max_tokens=4)
            self.assertEqual(response["choices"][0]["message"]["content"], "local result")
            self.assertEqual(server.payload["max_tokens"], 4)
            self.assertEqual(server.authorization, "Bearer test-local-key")
            with self.assertRaises(urllib.error.HTTPError) as rejected:
                client.request("/health")
            self.assertEqual(rejected.exception.code, 302)
            rejected.exception.close()
            with self.assertRaises(ValueError):
                client.request("https://example.invalid")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
