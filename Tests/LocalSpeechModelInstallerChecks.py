#!/usr/bin/env python3
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile

spec = importlib.util.spec_from_file_location("speech_model", Path(__file__).parents[1] / "Tools/local_speech_model.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
weights = b"verified speech weights" * 100
module.FILENAME = "fixture.bin"
module.MODEL_BYTES = len(weights)
module.MODEL_SHA256 = hashlib.sha256(weights).hexdigest()
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    destination = root / "models" / "fixture.bin"
    module.install(io.BytesIO(weights), destination)
    assert destination.read_bytes() == weights
    for invalid in [weights[:-1], weights + b"x", b"x" * len(weights)]:
        try:
            module.install(io.BytesIO(invalid), destination)
            raise AssertionError("unverified weights accepted")
        except ValueError:
            pass
        assert destination.read_bytes() == weights
        assert not list(destination.parent.glob("*.partial"))
    class BrokenDownload:
        def read(self, count):
            raise OSError("interrupted source")
    try:
        module.install(BrokenDownload(), destination)
        raise AssertionError("interrupted source accepted")
    except OSError:
        pass
    assert destination.read_bytes() == weights
    assert not list(destination.parent.glob("*.partial"))
print("PASS: public model installer validates exact bytes/hash, preserves existing weights, and removes failed-download partials")
