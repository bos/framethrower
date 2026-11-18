import CoreGraphics
import Darwin
import Foundation
import FoundationModels

@available(macOS 27.0, *)
@Generable
private struct AppleEditingIntent {
    @Generable enum Target { case camera, screen }
    @Guide(description: "Subject being edited: camera means the picture-in-picture feed; screen means the main recording. Full screen describes size, not the target.")
    var target: Target
    @Guide(description: "Duration in seconds", .range(0...30)) var duration: Double
    @Guide(description: "Source start time in seconds", .range(0...60)) var start: Double
}

@available(macOS 27.0, *)
@Generable
private struct AppleImageObservation {
    @Generable enum Side { case left, right }
    var redSide: Side
}

@main @MainActor
struct AppleFoundationModelsChecks {
    enum Failure: Error { case failed(String) }
    static func main() async {
        guard ProcessInfo.processInfo.environment["RUN_APPLE_FOUNDATION_MODELS"] == "1" else {
            print("Opt in with RUN_APPLE_FOUNDATION_MODELS=1. This runs Apple's existing on-device model; no account, network provider, or capture is used.")
            exit(2)
        }
        guard #available(macOS 27.0, *) else { print("This prototype evaluation requires macOS 27."); exit(77) }
        do { try await run() }
        catch { print("Apple Foundation Models check failed: \(error)"); exit(1) }
    }

    @available(macOS 27.0, *)
    static func run() async throws {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { print("Apple Intelligence unavailable: \(model.availability)"); exit(77) }
        let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/AppleDirectorPrototype/basics")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var results: [[String: Any]] = []
        var failures = 0
        func record(_ value: [String: Any]) throws {
            results.append(value)
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("results.json"), options: .atomic)
            print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)); fflush(stdout)
        }
        let cases: [(String, AppleEditingIntent.Target, Double, Double)] = [
            ("At source time 9 seconds, expand the camera to full screen over two seconds.", .camera, 2, 9),
            ("At source time 4 seconds, zoom the main screen recording in over one second.", .screen, 1, 4),
            ("At source time 3 seconds, fade out the camera over half a second.", .camera, 0.5, 3)
        ]
        for (index, item) in cases.enumerated() {
            let intent = LanguageModelSession(instructions: "Extract only the literal target, duration, and start time from the editing request. Do not invent details or perform edits.")
            let began = Date()
            let parsed = try await intent.respond(to: item.0, generating: AppleEditingIntent.self,
                options: .init(samplingMode: .greedy, maximumResponseTokens: 128))
            let passed = parsed.content.target == item.1 && parsed.content.duration == item.2 && parsed.content.start == item.3
            if !passed { failures += 1 }
            try record(["case": "guided_edit_intent_\(index + 1)", "passed": passed, "prompt": item.0,
                "seconds": Date().timeIntervalSince(began), "generated": parsed.rawContent.jsonString,
                "input_tokens": parsed.usage.input.totalTokenCount, "output_tokens": parsed.usage.output.totalTokenCount,
                "context_tokens": try await model.tokenCount(for: intent.transcript)])
        }
        let plainIntent = LanguageModelSession(instructions: "Identify the subject being edited. Reply with exactly camera or screen. Full screen describes size, not the subject.")
        let plain = try await plainIntent.respond(to: cases[0].0, options: .init(samplingMode: .greedy, maximumResponseTokens: 32))
        let plainPassed = plain.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "camera"
        if !plainPassed { failures += 1 }
        try record(["case": "plain_camera_target", "passed": plainPassed, "text": plain.content,
            "input_tokens": plain.usage.input.totalTokenCount, "output_tokens": plain.usage.output.totalTokenCount])

        // A generated test image, never pixels from the person's desktop.
        guard let canvas = CGContext(data: nil, width: 640, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.failed("CGContext") }
        canvas.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
        canvas.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); canvas.fill(CGRect(x: 320, y: 0, width: 320, height: 320))
        guard let image = canvas.makeImage() else { throw Failure.failed("CGImage") }
        let vision = LanguageModelSession()
        let visionStart = Date()
        do {
            let observed = try await vision.respond(generating: AppleImageObservation.self, options: .init(samplingMode: .greedy, maximumResponseTokens: 64)) {
                "Which half of this image is red?"; Attachment(image)
            }
            let visionPassed = observed.content.redSide == .left
            try record(["case": "native_image_input", "passed": visionPassed, "seconds": Date().timeIntervalSince(visionStart),
                "generated": observed.rawContent.jsonString, "input_tokens": observed.usage.input.totalTokenCount,
                "output_tokens": observed.usage.output.totalTokenCount, "context_tokens": try await model.tokenCount(for: vision.transcript)])
            if !visionPassed { failures += 1 }
        } catch {
            failures += 1
            try record(["case": "native_image_input", "passed": false, "seconds": Date().timeIntervalSince(visionStart), "error": error.localizedDescription])
        }
        do {
            let plainVision = LanguageModelSession()
            let answer = try await plainVision.respond(options: .init(samplingMode: .greedy, maximumResponseTokens: 64)) {
                "Which half of this image is red, left or right? Reply briefly."; Attachment(image)
            }
            let passed = answer.content.lowercased().contains("left")
            if !passed { failures += 1 }
            try record(["case": "native_image_plain_response", "passed": passed, "text": answer.content,
                "input_tokens": answer.usage.input.totalTokenCount, "output_tokens": answer.usage.output.totalTokenCount])
        } catch {
            failures += 1
            try record(["case": "native_image_plain_response", "passed": false, "error": error.localizedDescription])
        }

        let full = LanguageModelSession(instructions: "Reply briefly. Preserve the conversation.")
        full.transcriptErrorHandlingPolicy = .preserveTranscript
        let large = String(repeating: "The recording contains a camera overlay, a screen, pointer motion, audio, and timed edits. ", count: 900)
        let promptTokens = try await model.tokenCount(for: Prompt(large))
        guard promptTokens > model.contextSize else { throw Failure.failed("Overflow fixture is too small") }
        do {
            _ = try await full.respond(to: large, options: .init(samplingMode: .greedy, maximumResponseTokens: 32))
            throw Failure.failed("Oversized history was silently accepted")
        } catch LanguageModelError.contextSizeExceeded(let detail) {
            try record(["case": "context_overflow", "passed": true, "capacity": model.contextSize,
                "prompt_tokens": promptTokens, "reported_tokens": detail.tokenCount,
                "retained_transcript_tokens": try await model.tokenCount(for: full.transcript),
                "policy": "preserveTranscript; no app trimming, summaries, reset, or cloud fallback"])
        } catch {
            failures += 1
            try record(["case": "context_overflow", "passed": false, "capacity": model.contextSize,
                "prompt_tokens": promptTokens, "error": error.localizedDescription])
        }
        guard failures == 0 else { throw Failure.failed("\(failures) evaluation cases failed; raw results retained") }
        print("Apple Foundation Models basic checks passed: real on-device guided intent, generated-image input, and explicit context overflow; no devices or provider accounts.")
    }
}
