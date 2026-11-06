#!/usr/bin/env python3
"""Install and run an optional local text model for FrameThrower tool experiments.

Weights download separately. Inference is offline and loopback-only, using native Metal on Apple Silicon;
there is no cloud fallback, model-provided executable code, or app/media access.
"""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

MODEL_REPOSITORY = "Qwen/Qwen3-4B-GGUF"
MODEL_REVISION = "bc640142c66e1fdd12af0bd68f40445458f3869b"
MODEL_FILENAME = "Qwen3-4B-Q4_K_M.gguf"
MODEL_BYTES = 2_497_280_256
MODEL_SHA256 = "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5"


def cache_directory() -> Path:
    return Path.home() / "Library/Caches/FrameThrower/LocalModel"


def default_model_path() -> Path:
    return cache_directory() / "models" / MODEL_FILENAME


def verify_model(path: Path) -> None:
    if path.stat().st_size != MODEL_BYTES:
        raise ValueError("Model size does not match the pinned official download")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(4 * 1024 * 1024):
            digest.update(chunk)
    if digest.hexdigest() != MODEL_SHA256:
        raise ValueError("Model checksum does not match the pinned official download")


def install_model() -> Path:
    target = default_model_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        verify_model(target)
        return target
    partial = target.with_suffix(".gguf.download")
    offset = partial.stat().st_size if partial.exists() else 0
    if offset > MODEL_BYTES:
        raise ValueError("Partial model exceeds the expected size")
    if offset < MODEL_BYTES:
        url = f"https://huggingface.co/{MODEL_REPOSITORY}/resolve/{MODEL_REVISION}/{MODEL_FILENAME}"
        headers = {"Range": f"bytes={offset}-"} if offset else {}
        request = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(request, timeout=90) as response:
            resumed = bool(offset and response.status == 206)
            if resumed and not response.headers.get("Content-Range", "").startswith(f"bytes {offset}-"):
                raise ValueError("Download returned a different byte range")
            if not resumed:
                offset = 0
            last_report = 0.0
            with partial.open("ab" if resumed else "wb") as output:
                while chunk := response.read(4 * 1024 * 1024):
                    output.write(chunk)
                    offset += len(chunk)
                    if offset > MODEL_BYTES:
                        raise ValueError("Download exceeds the expected model size")
                    if time.monotonic() - last_report > 10:
                        print(f"Model download: {offset / MODEL_BYTES:.0%}", flush=True)
                        last_report = time.monotonic()
                output.flush()
                os.fsync(output.fileno())
    verify_model(partial)
    partial.replace(target)
    (target.parent / "Qwen3-4B.manifest.json").write_text(json.dumps({
        "repository": MODEL_REPOSITORY, "revision": MODEL_REVISION,
        "filename": MODEL_FILENAME, "bytes": MODEL_BYTES, "sha256": MODEL_SHA256,
        "license": "Apache-2.0", "model_card": f"https://huggingface.co/{MODEL_REPOSITORY}",
    }, indent=2) + "\n")
    return target


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class LocalModelClient:
    """Small wire-format client: numeric loopback only, no proxies or redirects."""
    def __init__(self, endpoint: str, api_key: str = ""):
        parsed = urllib.parse.urlsplit(endpoint)
        try:
            address = ipaddress.ip_address(parsed.hostname or "")
            port = parsed.port
        except ValueError as error:
            raise ValueError("Use a numeric loopback model endpoint") from error
        if (parsed.scheme != "http" or not address.is_loopback or not port or
                parsed.username or parsed.password or parsed.query or parsed.fragment or
                parsed.path not in ("", "/")):
            raise ValueError("Only a plain HTTP loopback model endpoint is allowed")
        self.endpoint = endpoint.rstrip("/")
        self.api_key = api_key
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirects())

    def request(self, path: str, payload: dict | None = None) -> dict:
        if path not in ("/health", "/v1/chat/completions"):
            raise ValueError("Unsupported local model endpoint")
        data = json.dumps(payload).encode() if payload is not None else None
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = "Bearer " + self.api_key
        req = urllib.request.Request(self.endpoint + path, data=data, headers=headers)
        try:
            with self.opener.open(req, timeout=2 if path == "/health" else 120) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            error.close()
            raise

    def chat(self, messages: list, tools: list, max_tokens: int = 512) -> dict:
        return self.request("/v1/chat/completions", {
            "model": "framethrower-local", "messages": messages, "tools": tools,
            "tool_choice": "auto", "temperature": 0, "max_tokens": max_tokens,
            "chat_template_kwargs": {"enable_thinking": False},
        })


class LocalModelServer:
    """Own one temporary local process and clean it up after the experiment."""
    def __init__(self, model_path: Path, server_binary: str = "llama-server", backend: str = "metal"):
        if backend not in ("metal", "cpu"):
            raise ValueError("Choose the metal or cpu backend")
        self.backend = backend
        self.model_path = Path(model_path).expanduser().resolve()
        self.server_binary = shutil.which(server_binary)
        if self.server_binary is None:
            raise FileNotFoundError("Install llama.cpp to provide llama-server")
        runs = cache_directory() / "runs"
        runs.mkdir(parents=True, exist_ok=True)
        self.log_dir = Path(tempfile.mkdtemp(prefix="check-", dir=runs))
        os.chmod(self.log_dir, 0o700)
        self.process: subprocess.Popen | None = None
        self.log_file = None
        self.client: LocalModelClient
        self.command: list[str] = []

    def __enter__(self):
        verify_model(self.model_path)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        token = secrets.token_urlsafe(32)
        key_path = self.log_dir / "server.key"
        descriptor = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as key:
            key.write(token + "\n")
        self.client = LocalModelClient(f"http://127.0.0.1:{port}", token)
        self.command = [
            "/usr/bin/nice", "-n", "10", self.server_binary,
            "--model", str(self.model_path), "--alias", "framethrower-local",
            "--host", "127.0.0.1", "--port", str(port), "--api-key-file", str(key_path),
            "--offline", "--no-mmproj", "--fit", "off",
            "--threads", "4", "--threads-batch", "4", "--poll", "0",
            "--ctx-size", "4096", "--parallel", "1", "--cache-ram", "0",
            "--jinja", "--chat-template-kwargs", '{"enable_thinking":false}',
            "--no-webui", "--no-ui-mcp-proxy", "--no-warmup",
        ]
        if self.backend == "metal":
            self.command += ["--device", "MTL0", "--n-gpu-layers", "all", "--op-offload"]
        else:
            self.command += ["--device", "none", "--n-gpu-layers", "0", "--no-op-offload", "--no-kv-offload"]
        # Do not inherit configured remote tools, backends, or provider settings.
        environment = {k: v for k, v in os.environ.items()
                       if not k.startswith(("LLAMA_", "GGML_", "OPENAI_", "ANTHROPIC_"))}
        environment.update(HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", DO_NOT_TRACK="1")
        (self.log_dir / "runtime.json").write_text(json.dumps({
            "backend": self.backend, "model": MODEL_FILENAME, "model_sha256": MODEL_SHA256,
            "runtime": self.server_binary, "endpoint": self.client.endpoint,
            "threads": 4, "context_tokens": 4096, "offline": True,
            "gpu_layers": "all" if self.backend == "metal" else 0,
        }, indent=2) + "\n")
        self.log_file = (self.log_dir / "server.log").open("wb")
        try:
            self.process = subprocess.Popen(self.command, env=environment, stdin=subprocess.DEVNULL,
                stdout=self.log_file, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError(f"Local model exited; inspect {self.log_dir / 'server.log'}")
                try:
                    if self.client.request("/health").get("status") == "ok":
                        return self
                except (urllib.error.URLError, OSError):
                    pass
                time.sleep(0.2)
            raise TimeoutError(f"Local model did not become ready; inspect {self.log_dir / 'server.log'}")
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        if self.log_file is not None:
            self.log_file.close()

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "serve"))
    parser.add_argument("--model", type=Path, default=default_model_path())
    parser.add_argument("--backend", choices=("metal", "cpu"), default="metal")
    args = parser.parse_args()
    if args.action == "install":
        print(f"Verified local model: {install_model()}")
    else:
        with LocalModelServer(args.model, backend=args.backend) as server:
            print(f"Local model ({server.backend}): {server.client.endpoint}", flush=True)
            print(f"Local key and logs: {server.log_dir}", flush=True)
            try:
                while True:
                    time.sleep(1)
            except KeyboardInterrupt:
                pass


if __name__ == "__main__":
    main()
