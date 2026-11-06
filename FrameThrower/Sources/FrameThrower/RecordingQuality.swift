@preconcurrency import AVFoundation
import Foundation

/// Originals and exported copies have independent encoding policies. Changing
/// this preference only affects future captures, never an existing recording.
enum RecordingQuality: String, CaseIterable, Sendable {
    case highQuality
    case compact

    var fileExtension: String { self == .highQuality ? "mov" : "mp4" }
    var videoCodec: AVVideoCodecType { self == .highQuality ? .proRes422LT : .h264 }

    func videoSettings(width: Int, height: Int) -> [String: Any] {
        [AVVideoCodecKey: videoCodec, AVVideoWidthKey: width, AVVideoHeightKey: height]
    }

    /// System and microphone audio stay on separate uncompressed tracks. The
    /// writer converts native microphone sample rates/channel layouts to this
    /// common editing format without an intermediate AAC generation.
    static var masterAudioSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM,
         AVSampleRateKey: 48_000,
         AVNumberOfChannelsKey: 2,
         AVLinearPCMBitDepthKey: 32,
         AVLinearPCMIsFloatKey: true,
         AVLinearPCMIsBigEndianKey: false,
         AVLinearPCMIsNonInterleaved: false]
    }
}
