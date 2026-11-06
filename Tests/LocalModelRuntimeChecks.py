#!/usr/bin/env python3
"""Loopback-only HTTP fixture for the native model transport; no inference by default."""
import http.server
import json
import os
import subprocess
import sys
import threading


class Fixture(http.server.BaseHTTPRequestHandler):
    redirected_requests = 0
    requests = []

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/redirect-destination':
            Fixture.redirected_requests += 1
        self.respond({'status': 'ok'})

    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        payload = json.loads(self.rfile.read(length))
        Fixture.requests.append((self.path, self.headers.get('Authorization'), payload))
        if payload.get('redirect'):
            self.send_response(302)
            self.send_header('Location', f'http://127.0.0.1:{self.server.server_port}/redirect-destination')
            self.send_header('Content-Length', '0')
            self.end_headers()
        else:
            self.respond({'accepted': True})

    def respond(self, value):
        content = json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        self.wfile.write(content)


with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    environment = dict(os.environ, http_proxy='http://127.0.0.1:1', https_proxy='http://127.0.0.1:1',
                       HTTP_PROXY='http://127.0.0.1:1', HTTPS_PROXY='http://127.0.0.1:1')
    try:
        subprocess.run([sys.argv[1], str(server.server_port), *sys.argv[2:]], env=environment,
                       check=True, timeout=180)
        assert Fixture.redirected_requests == 0, 'redirect destination was contacted'
        assert len(Fixture.requests) == 2, 'expected two loopback POSTs'
        assert all(path == '/v1/chat/completions' and auth == 'Bearer fixture-token'
                   for path, auth, _ in Fixture.requests), 'local auth and path retained'
    finally:
        server.shutdown()
        thread.join(timeout=3)
