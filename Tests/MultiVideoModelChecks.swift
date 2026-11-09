import Foundation
import CoreGraphics

@main
@MainActor
struct MultiVideoModelChecks {
    static func main() throws {
        try legacyAndCoding()
        try sourceClockAutomation()
        try layerSampling()
        try validation()
        try immutableFilesAndHistory()
        try multipleSourceTransaction()
        print("Multi-video model checks passed: legacy identity, source clocks, independent automation, crossdissolves, validation, immutable paths, and durable history.")
    }

    static func require(_ value: Bool, _ message: String) {
        precondition(value, message)
    }
    static func near(_ a: Double, _ b: Double, _ message: String) {
        require(abs(a - b) < 1e-8, "\(message): \(a) != \(b)")
    }
    static func rejected(_ project: RecordingProject, _ message: String) {
        do { try project.validate(); preconditionFailure(message) } catch {}
    }
    static func source(name: String = "Phone", duration: Double = 30) -> VideoSource {
        VideoSource(name: name, kind: .testPattern, duration: duration, pixelWidth: 1080,
                    pixelHeight: 1920, hasAudio: false, patternSeed: 5)
    }
    static func fixture() -> RecordingProject {
        let asset = source()
        let clip = VideoClip(sourceID: asset.id, start: 1, end: 9, sourceStart: 2)
        return RecordingProject(screenFilename: "screen-original.txt", cameraFilename: "camera-original.txt",
            duration: 12, state: EditState(trimStart: 0, trimEnd: 12, pipKeyframes: [PIPKeyframe(time: 0, placement: PIPPlacement())],
                videoLayers: [VideoLayer(name: "Phone", clips: [clip])]), videoAssets: [asset])
    }

    static func legacyAndCoding() throws {
        var project = RecordingProject(screenFilename: "screen.txt", cameraFilename: "camera.txt", cameraOffset: -2, duration: 10)
        let first = project.effectiveVideoLayers()
        require(first.map(\.id) == project.effectiveVideoLayers().map(\.id), "Legacy identities must be deterministic")
        require(Set(project.videoSources.map(\.id)).count == 2, "Screen/camera have distinct source identities")
        near(first[1].clips[0].sourceStart, 2, "Negative camera offset trims source")
        near(first[1].clips[0].start, 0, "Early camera begins at authoring zero")
        near(project.videoSamples(at: 3).last!.sourceTime, 5, "Camera offset sampled once")
        project.cameraOffset = 3
        require(project.videoSamples(at: 2).count == 1, "Late camera not sampled early")
        near(project.videoSamples(at: 4).last!.sourceTime, 1, "Positive camera offset maps source")
        project.cameraOffset = 20
        require(project.effectiveVideoLayers()[1].clips.isEmpty, "Camera beyond duration has no invalid occurrence")
        project.undoHistory = [NamedEditSnapshot(name: "Legacy", state: project.state)]
        let decoded = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(project))
        require(decoded.state.videoLayers == nil && decoded.undoHistory[0].state.videoLayers == nil,
                "Legacy states remain implicit across persistence")
        var empty = project.state
        empty.videoLayers = []
        require(project.effectiveVideoLayers(in: empty).isEmpty && project.videoSamples(at: 2, state: empty).isEmpty,
                "Explicit empty layers must not resurrect legacy video")
        var materialized = project.state
        materialized.materializeVideoLayers(project: project)
        require(materialized.videoLayers == project.effectiveVideoLayers(), "Materialization preserves identities")
        let minimal = "{\"sourceID\":\"\(VideoSource.legacyScreenID)\",\"start\":0,\"end\":2}"
        let clip = try JSONDecoder().decode(VideoClip.self, from: Data(minimal.utf8))
        require(clip.layout == .custom && clip.opacity == 1 && clip.volumeKeyframes.isEmpty,
                "New fields have decode defaults")
    }

    static func sourceClockAutomation() throws {
        var project = fixture()
        var clip = project.state.videoLayers![0].clips[0]
        let crop = VideoGeometry(rect: .init(x: 0.1, y: 0.2, width: 0.6, height: 0.7),
            crop: .init(x: 0.2, y: 0.1, width: 0.5, height: 0.6), fit: .fill)
        clip.geometryKeyframes = [.init(time: 5, geometry: crop, duration: 2)]
        clip.opacityKeyframes = [.init(time: 8, opacity: 0.3, duration: 2)]
        clip.volumeKeyframes = [.init(time: 4, gain: 0.25, duration: 1), .init(time: 20, gain: 0.8)]
        clip.volume = 0.8
        clip.rate = 2
        clip.end = 5
        project.state.videoLayers![0].clips[0] = clip
        try project.validate()
        near(clip.sourceTime(at: 2.5), 5, "Occurrence rate maps authoring to original source")
        require(clip.geometry(atSourceTime: 5) == crop, "Geometry arrives on source clock")
        near(clip.opacity(atSourceTime: 5), 1, "Geometry does not introduce opacity targets")
        near(clip.envelopeGain(atSourceTime: 5), 0.25, "Volume envelope independent of geometry/opacity")
        let before = try JSONEncoder().encode(clip.volumeKeyframes)
        clip.start = 2; clip.end = 7; clip.sourceStart = 3; clip.rate = 1
        require(try JSONEncoder().encode(clip.volumeKeyframes) == before, "Move/trim/rate preserve automation bytes")
        near(clip.envelopeGain(atSourceTime: 20), 0.8, "Hidden points survive outside occurrence trim")
        let portrait = CGSize(width: 1080, height: 1920), canvas = CGSize(width: 1920, height: 1080)
        let contained = VideoGeometry().frame(in: canvas, sourceSize: portrait)
        near(contained.height, 1080, "Portrait fits height")
        near(contained.width, 607.5, "Portrait preserves aspect ratio")
        let fill = VideoGeometry(fit: .fill).viewport(in: portrait, canvas: canvas)
        near(fill.width / fill.height, canvas.width / canvas.height, "Fill crops to target aspect")
        clip.opacity = 0; clip.opacityKeyframes = []; clip.isMuted = false
        project.state.videoLayers![0].clips[0] = clip
        let sample = project.videoSamples(at: 4).first!
        near(sample.opacity, 0, "Invisible video")
        near(sample.audioGain, 0.2, "Opacity does not mute audio")
        clip.isMuted = true
        project.state.videoLayers![0].clips[0] = clip
        near(project.videoSamples(at: 4).first!.audioGain, 0, "Mute preserves automation but silences audio")
        clip.opacity = 1; clip.fadeIn = 2; clip.fadeOut = 2; clip.isMuted = false
        near(clip.alpha(at: clip.start), 0, "Fade starts transparent")
        require(clip.alpha(at: clip.end - 0.01) < 0.001, "Fade settles toward transparent")
    }

    static func layerSampling() throws {
        let asset = source()
        let a = VideoClip(sourceID: asset.id, start: 0, end: 6)
        var b = VideoClip(sourceID: asset.id, start: 4, end: 10, sourceStart: 10)
        let overlay = VideoClip(sourceID: asset.id, start: 0, end: 10, opacity: 0.5)
        var project = RecordingProject(screenFilename: "screen.txt", duration: 10,
            state: .init(trimStart: 0, trimEnd: 10, pipKeyframes: [PIPKeyframe(time: 0, placement: PIPPlacement())], videoLayers: [
                VideoLayer(name: "Sequence", clips: [b, a]), VideoLayer(name: "Overlay", clips: [overlay])]), videoAssets: [asset])
        try project.validate()
        let mid = project.videoSamples(at: 5)
        require(mid.count == 3, "Two sequence branches plus independent overlay")
        near(mid[0].weight, 0.5, "Outgoing weight")
        near(mid[1].weight, 0.5, "Incoming weight")
        near(mid[0].weight + mid[1].weight, 1, "Weighted sum avoids source-over dark dip")
        near(mid[2].weight, 1, "Separate layers never normalized together")
        near(mid[1].sourceTime, 11, "Source reused independently")
        require(project.videoSamples(at: 10).isEmpty, "Occurrence end is half-open")
        require(project.videoSamples(at: .nan).isEmpty, "Nonfinite query safe")
        b.transition = .cut
        project.state.videoLayers![0].clips = [a, b]
        require(project.videoSamples(at: 5).first!.clipID == b.id, "Incoming cut switches immediately")
        b.start = 6
        project.state.videoLayers![0].clips = [a, b]
        require(project.videoSamples(at: 6).first!.clipID == b.id, "Adjacent clips make clean cut")
    }

    static func validation() throws {
        let valid = fixture()
        try valid.validate()
        func bad(_ message: String, _ change: (inout RecordingProject) -> Void) {
            var project = valid; change(&project); rejected(project, message)
        }
        bad("Unknown sources rejected") { $0.state.videoLayers![0].clips[0].sourceID = UUID() }
        bad("Duplicate source identities rejected") { $0.videoAssets.append($0.videoAssets[0]) }
        bad("Invalid rate rejected") { $0.state.videoLayers![0].clips[0].rate = 0 }
        bad("Source bounds respected") { $0.state.videoLayers![0].clips[0].sourceStart = 29 }
        bad("No silent project extension") { $0.state.videoLayers![0].clips[0].end = 13 }
        bad("Invalid geometry rejected") { $0.state.videoLayers![0].clips[0].geometry.crop.width = 2 }
        bad("Nonfinite alpha rejected") { $0.state.videoLayers![0].clips[0].opacity = .nan }
        bad("Animation outside asset rejected") { $0.state.videoLayers![0].clips[0].volumeKeyframes = [.init(time: 31, gain: 0.5)] }
        bad("Sorted source keys required") { $0.state.videoLayers![0].clips[0].volumeKeyframes = [.init(time: 5, gain: 0.2), .init(time: 4, gain: 1)] }
        bad("Animation channel IDs unique") {
            let id = UUID()
            $0.state.videoLayers![0].clips[0].volumeKeyframes = [.init(id: id, time: 5, gain: 0.2)]
            $0.state.videoLayers![0].clips[0].opacityKeyframes = [.init(id: id, time: 5, opacity: 0.2)]
        }
        bad("Triples rejected") {
            let sourceID = $0.videoAssets[0].id
            $0.state.videoLayers![0].clips = [VideoClip(sourceID: sourceID, start: 0, end: 8),
                VideoClip(sourceID: sourceID, start: 1, end: 9), VideoClip(sourceID: sourceID, start: 2, end: 10)]
        }
        bad("Contained crossfade rejected") {
            $0.state.videoLayers![0].clips.append(VideoClip(sourceID: $0.videoAssets[0].id, start: 2, end: 3))
        }
        bad("Historical clips validated") {
            var state = $0.state; state.videoLayers![0].clips[0].end = 100
            $0.undoHistory = [NamedEditSnapshot(name: "Bad", state: state)]
        }
        for path in ["/tmp/outside", "../outside", "a/../outside", "a//b", "a/./b", "a\\b", "a\nb"] {
            require(!VideoSource.isSafeRelativePath(path), "Unsafe path rejected: \(path)")
        }
        require(VideoSource.isSafeRelativePath("recording.media/id/original.txt"), "Managed subpaths supported")
    }

    static func multipleSourceTransaction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("multivideo-batch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("TEXT ONLY: original bytes for a multi-source transaction".utf8)
        for name in ["first.txt", "second.txt"] { try bytes.write(to: directory.appendingPathComponent(name)) }
        let sources = [VideoSource(name: "First", kind: .file, relativePath: "first.txt", duration: 10, hasAudio: true),
                       VideoSource(name: "Second", kind: .file, relativePath: "second.txt", duration: 10, hasAudio: false)]
        let original = RecordingProject(screenFilename: "screen.txt", duration: 10)
        let editor = ProjectEditor(project: original, url: directory.appendingPathComponent("batch.framethrower"))
        var state = original.state
        state.videoLayers = original.effectiveVideoLayers() + sources.enumerated().map { index, source in
            VideoLayer(name: source.name, clips: [VideoClip(sourceID: source.id, start: Double(index), end: 9)])
        }
        require(editor.registerVideoSources(sources, state: state, name: "Import two videos"), "Register the complete multi-file batch")
        require(editor.project.undoHistory.count == 1 && editor.project.videoAssets == sources, "One source batch produces one Undo entry")
        require(editor.undo() && editor.project.state == original.state && editor.project.videoAssets == sources,
                "One Undo removes every occurrence while retaining all originals")
        require(editor.redo() && editor.project.state == state, "One Redo restores the complete batch")
        let baseline = editor.project
        let good = source(name: "Third")
        var invalid = source(name: "Invalid"); invalid.duration = -1
        require(!editor.registerVideoSources([good, invalid], state: state), "Any invalid source rejects the entire batch")
        require(editor.project == baseline, "Failed multi-source registration publishes neither partial assets nor history")
        require(!editor.registerVideoSources([good, good], state: state), "Duplicate identities reject the entire batch")
        require(editor.project == baseline, "A duplicate source cannot partially register")
        for name in ["first.txt", "second.txt"] {
            require(try Data(contentsOf: directory.appendingPathComponent(name)) == bytes, "Batch history never changes original bytes")
        }
    }

    static func immutableFilesAndHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("multivideo-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = Data("TEXT ONLY: immutable original metadata fixture".utf8)
        let sourceURL = directory.appendingPathComponent("sources/phone.txt")
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: sourceURL)
        let url = directory.appendingPathComponent("edit.framethrower")
        let original = RecordingProject(screenFilename: "screen.txt", duration: 10)
        let editor = ProjectEditor(project: original, url: url)
        let asset = VideoSource(name: "Phone", kind: .file, relativePath: "sources/phone.txt", duration: 20, hasAudio: true)
        var state = original.state
        state.videoLayers = original.effectiveVideoLayers() + [VideoLayer(name: "Phone", clips: [VideoClip(sourceID: asset.id, start: 2, end: 8)])]
        require(editor.registerVideoSource(asset, state: state), "Atomic source + occurrence registration")
        require(editor.project.undoHistory.count == 1, "One operation, one undo")
        require(editor.undo() && editor.project.state.videoLayers == nil && editor.project.videoAssets == [asset], "Undo preserves source and legacy nil")
        require(editor.redo() && editor.project.state.videoLayers == state.videoLayers, "Redo restores occurrence")
        near(editor.historyNavigationTime!, 2, "History navigates to affected occurrence")
        let reopened = try ProjectEditor.open(url: url)
        require(reopened.project == editor.project, "Layered project persists exactly")
        require(try Data(contentsOf: sourceURL) == text, "No original source writes")
        require(try editor.videoSourceURL(for: asset.id) == sourceURL.standardizedFileURL.resolvingSymlinksInPath(), "Managed source resolver")
        let outside = directory.deletingLastPathComponent().appendingPathComponent("outside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape"), withDestinationURL: outside)
        var escaped = asset; escaped.relativePath = "escape/source.txt"
        do { _ = try escaped.resolvedURL(in: directory); preconditionFailure("Symlink escape must fail") } catch {}
        var collision = original
        collision.videoAssets = [VideoSource(name: "Protected", kind: .file, relativePath: "protected.framethrower", duration: 20, hasAudio: false)]
        let protectedURL = directory.appendingPathComponent("protected.framethrower")
        try text.write(to: protectedURL)
        require(!ProjectEditor(project: collision, url: protectedURL).save(), "Project never replaces extra source")
        require(try Data(contentsOf: protectedURL) == text, "Protected source bytes unchanged")
        collision.videoAssets[0].relativePath = "journal.framethrower.recovery"
        let journalEditor = ProjectEditor(project: collision, url: directory.appendingPathComponent("journal.framethrower"))
        require(journalEditor.save(), "Save baseline before recovery collision")
        var draft = collision.state; draft.trimStart = 1
        require(journalEditor.updateDraft(draft, at: 1), "Prepare metadata draft")
        require(!journalEditor.flushRecovery(), "Recovery never replaces registered source")
    }
}
