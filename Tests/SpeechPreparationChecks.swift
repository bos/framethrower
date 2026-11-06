import Foundation
import Speech
import AVFoundation

private enum PreparationFailure: Error { case failed(String) }

@main @MainActor
struct SpeechPreparationChecks {
    static func main() async throws {
        try await checkInstalled()
        try await checkNilRequest()
        try await checkInstallation()
        try await checkReportedStates()
        try await checkCancellation()
        if CommandLine.arguments.contains("--native") { try await checkNativePreparation() }
        print("Speech preparation checks passed (existing assets, nil installation requests, reported states, real errors, cancellation; no microphone opened).")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw PreparationFailure.failed(message) }
    }

    private static func checkInstalled() async throws {
        var installationCalls = 0
        try await SpeechAssetReadiness.prepare(status: { .installed }, installation: {
            installationCalls += 1
            return nil
        })
        try require(installationCalls == 0, "ready assets never request installation")
    }

    private static func checkNilRequest() async throws {
        var statusCalls = 0
        var installationCalls = 0
        try await SpeechAssetReadiness.prepare(status: {
            statusCalls += 1
            return statusCalls == 1 ? .supported : .installed
        }, installation: {
            installationCalls += 1
            return nil
        })
        try require(statusCalls == 2 && installationCalls == 1,
                    "nil installation request rechecks assets because reserving existing assets can make them ready")
        try await SpeechAssetReadiness.prepare(status: { .supported }, installation: { nil })
        // Some versions update readiness metadata after the request completes.
        // Preparing the analyzer remains the authoritative readiness check.
    }

    private static func checkInstallation() async throws {
        for initial in [SpeechAssetReadiness.supported, .downloading] {
            var installed = false
            var installationCalls = 0
            try await SpeechAssetReadiness.prepare(status: { installed ? .installed : initial }, installation: {
                { installationCalls += 1; installed = true }
            })
            try require(installed && installationCalls == 1, "real installation request is awaited once")
        }
        let actual = NSError(domain: "FixtureAssetService", code: 42,
                             userInfo: [NSLocalizedDescriptionKey: "The asset service rejected this configuration."])
        do {
            try await SpeechAssetReadiness.prepare(status: { .supported }, installation: { throw actual })
            throw PreparationFailure.failed("asset service failure was swallowed")
        } catch let error as NSError {
            try require(error.domain == actual.domain && error.code == actual.code && error.localizedDescription == actual.localizedDescription,
                        "asset failures preserve actual system reason instead of inventing an internet failure")
        }
    }

    private static func checkReportedStates() async throws {
        var installationCalls = 0
        do {
            try await SpeechAssetReadiness.prepare(status: { .unsupported }, installation: {
                installationCalls += 1; return nil
            })
            throw PreparationFailure.failed("unsupported configuration accepted")
        } catch LocalSpeechError.unsupportedConfiguration { }
        try require(installationCalls == 0, "unsupported module configuration never attempts a download")
        do {
            try await SpeechAssetReadiness.prepare(status: { .downloading }, installation: { nil })
            throw PreparationFailure.failed("in-progress assets silently accepted")
        } catch LocalSpeechError.assetsPreparing { }
        var reads = 0
        do {
            try await SpeechAssetReadiness.prepare(status: { reads += 1; return reads == 1 ? .supported : .unsupported },
                                                 installation: { nil })
            throw PreparationFailure.failed("changed unsupported status ignored")
        } catch LocalSpeechError.unsupportedConfiguration { }
        for error in [LocalSpeechError.assetsPreparing, .unsupportedConfiguration] {
            try require(!error.localizedDescription.localizedCaseInsensitiveContains("internet"),
                        "these states provide no evidence of an internet failure")
        }
    }

    private static func checkCancellation() async throws {
        var continuation: CheckedContinuation<Void, Never>?
        var didInstall = false
        let task = Task { @MainActor in
            try await SpeechAssetReadiness.prepare(status: { .supported }, installation: {
                await withCheckedContinuation { continuation = $0 }
                return { didInstall = true }
            })
        }
        while continuation == nil { await Task.yield() }
        task.cancel()
        continuation?.resume()
        do { try await task.value; throw PreparationFailure.failed("cancelled setup succeeded") }
        catch is CancellationError { }
        try require(!didInstall, "cancel during installation lookup cannot start a later download")
    }

    private static func checkNativePreparation() async throws {
        guard #available(macOS 26, *) else { throw PreparationFailure.failed("native setup needs macOS 26") }
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw PreparationFailure.failed("native speech configuration unavailable")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier == locale.identifier }
        guard installed else { throw PreparationFailure.failed("native check requires preinstalled assets; no download started") }
        print("Native on-device setup: locale=\(locale.identifier), initial asset status=\(await AssetInventory.status(forModules: [transcriber]))")
        try await AppleSpeechAssetPreparation.prepare(transcriber, locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
            considering: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)) else {
            throw PreparationFailure.failed("native analyzer has no compatible audio format")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await analyzer.prepareToAnalyze(in: format)
            await analyzer.cancelAndFinishNow()
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
        print("Native on-device analyzer preparation passed using installed assets; no microphone, recording, or audio input.")
    }
}
