#!/usr/bin/env python3
"""Install the pinned local speech weights; never downloads a runtime or sends audio."""
import argparse
import hashlib
import os
from pathlib import Path
import tempfile
import urllib.request

FILENAME = "ggml-large-v3-turbo-q5_0.bin"
MODEL_BYTES = 574_041_195
MODEL_SHA256 = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
MODEL_REVISION = "5359861c739e955e79d9a303bcbc70fb988958b1"
MODEL_URL = f"https://huggingface.co/ggerganov/whisper.cpp/resolve/{MODEL_REVISION}/{FILENAME}"
CACHE = Path.home() / "Library/Caches/FrameThrower"


def install(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=f".{FILENAME}.", suffix=".partial", dir=destination.parent, delete=False) as output:
            temporary = Path(output.name)
            digest = hashlib.sha256()
            total = 0
            while block := source.read(1024 * 1024):
                total += len(block)
                if total > MODEL_BYTES:
                    raise ValueError("Speech weights exceed the pinned model size")
                digest.update(block)
                output.write(block)
            if total != MODEL_BYTES or digest.hexdigest() != MODEL_SHA256:
                raise ValueError("Speech weights failed the pinned size/checksum check")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, destination)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=CACHE / "ASRBenchmark" / FILENAME)
    parser.add_argument("--download", action="store_true", help="Download and verify the official pinned model instead of importing a local copy")
    args = parser.parse_args()
    destination = CACHE / "LocalSpeech/models" / FILENAME
    if args.download:
        print("Downloading official local speech weights (547 MiB)…", flush=True)
        with urllib.request.urlopen(MODEL_URL, timeout=60) as source:
            install(source, destination)
    else:
        print("Verifying and installing local speech weights…", flush=True)
        with args.source.open("rb") as source:
            install(source, destination)
    print(f"Installed verified speech weights: {destination}")


if __name__ == "__main__":
    main()
