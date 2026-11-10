#!/usr/bin/env python3
"""Static live-capture boundary checks. Never creates media, devices, or sessions."""
from pathlib import Path
import re

SOURCES = Path(__file__).resolve().parents[1] / "FrameThrower/Sources/FrameThrower"


def read(name):
    return (SOURCES / name).read_text()


def before(source, function, guard, operation):
    start = source.index(function)
    guard_at = source.index(guard, start)
    operation_at = source.index(operation, start)
    assert guard_at < operation_at, f"{function}: {guard} must precede {operation}"


def main():
    policy = read("MediaProcessing.swift")
    assert re.search(r"static\s+let\s+isCaptureSuspended\s*=\s*true\b", policy), "Live capture must remain disabled in source"
    assert "requireCaptureEnabled" in policy and "CaptureSuspended" in policy

    screen = read("ScreenRecorder.swift")
    before(screen, "func start(filter:", "MediaProcessing.requireCaptureEnabled()", "SCStream(filter:")
    before(screen, "func firstVideoPresentationTime", "MediaProcessing.requireEnabled()", "AVURLAsset(url:")

    camera = read("CameraRecorder.swift")
    assert "private let engine: CameraCaptureEngine? = MediaProcessing.isCaptureSuspended ? nil : CameraCaptureEngine()" in camera, "Suspension must prevent eager camera session construction"
    before(camera, "func configure(id:", "MediaProcessing.requireCaptureEnabled()", "queue.async")
    before(camera, "func startRecording(to", "MediaProcessing.requireCaptureEnabled()", "engine.startRecording")
    before(camera, "func append(_ sample:", "MediaProcessing.requireCaptureEnabled()", "AVAssetWriter(outputURL:")
    assert "guard !MediaProcessing.isCaptureSuspended else { return [] }" in camera, "Camera device discovery also stays off"
    assert "guard !MediaProcessing.isCaptureSuspended" in read("CameraPreview.swift")
    assert "MediaProcessing.isCaptureSuspended" in read("CameraSetupView.swift")

    for filename in ["CapturePreview.swift", "DisplayCarousel.swift"]:
        source = read(filename)
        assert "MediaProcessing.isCaptureSuspended" in source
        assert "MediaProcessing.captureStatusMessage" in source
        for match in re.finditer(r"SCScreenshotManager\.(?:captureImage|captureSampleBuffer)\(", source):
            assert "MediaProcessing.requireCaptureEnabled()" in source[max(0, match.start() - 160):match.start()], f"{filename}: screenshot calls need an immediate capture guard"
    master = read("ScreenMasterWriter.swift")
    before(master, "init(url:", "MediaProcessing.requireCaptureEnabled()", "AVAssetWriter(outputURL:")
    scene = read("RecordedScene.swift")
    before(scene, "static func collect(source:", "MediaProcessing.requireCaptureEnabled()", "CGWindowListCopyWindowInfo(")
    assert "injectedCollector != nil || !MediaProcessing.isCaptureSuspended" in scene, "Pure injected metadata fixtures stay permitted"

    # New native capture call sites must be reviewed rather than inheriting the
    # recorded-file switch accidentally. This allowlist does not launch them.
    entrypoints = re.compile(r"\b(?:SCStream|AVCaptureSession|CGDisplayStream)\(|\bSCScreenshotManager\.(?:captureImage|captureSampleBuffer)\(|\b(?:CGWindowListCreateImage|CGDisplayCreateImage)\(")
    allowed = {"ScreenRecorder.swift", "CameraRecorder.swift", "CapturePreview.swift", "DisplayCarousel.swift"}
    for path in SOURCES.glob("*.swift"):
        if entrypoints.search(path.read_text()):
            assert path.name in allowed, f"New native capture entry point needs a live-policy audit: {path.name}"
    cache = read("CaptureSourcePreviews.swift")
    assert not entrypoints.search(cache), "The source preview cache must remain inert"
    print("Live capture policy checks passed: screen/camera starts, screenshot previews, writers, scene observation, and inert cache.")


if __name__ == "__main__":
    main()
