@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

/// Builds AVFoundation output-settings dictionaries from an `EncodingPlan`.
enum WriterSettings {
    static let keyframeInterval = 2.0

    // MARK: Video

    /// Decoded pixel format: 10-bit when HDR is kept, so the encoder doesn't band gradients.
    /// Asking for BT.709 on an HDR source makes VideoToolbox tone-map while decoding.
    static func videoReaderSettings(for settings: VideoEncodingSettings, source: VideoTrackInfo) -> [String: Any] {
        let pixelFormat = settings.dynamicRange.isHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var result: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        if source.dynamicRange.isHDR, !settings.dynamicRange.isHDR {
            result[AVVideoColorPropertiesKey] = sdrColorProperties
        }
        return result
    }

    /// Full encoder settings, plus a reduced fallback without optional keys for encoders that reject them.
    static func videoWriterCandidates(for settings: VideoEncodingSettings, source: VideoTrackInfo) -> [[String: Any]] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitrate,
            AVVideoMaxKeyFrameIntervalDurationKey: keyframeInterval,
            AVVideoAllowFrameReorderingKey: true
        ]
        let frameRate = settings.frameRateLimit.map(Double.init) ?? source.frameRate
        if frameRate > 0 {
            compression[AVVideoExpectedSourceFrameRateKey] = frameRate
        }
        if settings.isBitrateCeiling {
            // Average bitrate alone lets the encoder overshoot on hard content (and on the first keyframe).
            // A one-second byte budget makes it raise quantisation instead of breaking the promised size.
            compression[kVTCompressionPropertyKey_DataRateLimits as String] = [settings.bitrate / 8, 1] as [Int]
        }
        var full = baseVideoSettings(for: settings)
        full[AVVideoColorPropertiesKey] = colorProperties(for: settings, source: source)
        full[AVVideoCompressionPropertiesKey] = compression.merging(
            optionalCompressionProperties(for: settings), uniquingKeysWith: { current, _ in current }
        )

        var minimal = baseVideoSettings(for: settings)
        minimal[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: settings.bitrate]
        return [full, minimal]
    }

    private static func baseVideoSettings(for settings: VideoEncodingSettings) -> [String: Any] {
        [
            AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: settings.size.width,
            AVVideoHeightKey: settings.size.height,
            // The writer scales in hardware when the decoded frames are larger than the output.
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            // Prefer the media engine, but let VideoToolbox fall back to software on machines without one (CI VMs).
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
            ]
        ]
    }

    private static func optionalCompressionProperties(for settings: VideoEncodingSettings) -> [String: Any] {
        switch settings.codec {
        case .h264:
            return [AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]
        case .hevc where settings.dynamicRange.isHDR:
            return [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                kVTCompressionPropertyKey_HDRMetadataInsertionMode as String:
                    kVTHDRMetadataInsertionMode_Auto as String
            ]
        case .hevc:
            return [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String]
        }
    }

    // MARK: Colour

    static let sdrColorProperties: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
    ]

    private static let supportedPrimaries: Set<String> = [
        AVVideoColorPrimaries_ITU_R_709_2, AVVideoColorPrimaries_P3_D65, AVVideoColorPrimaries_ITU_R_2020
    ]
    private static let supportedMatrices: Set<String> = [
        AVVideoYCbCrMatrix_ITU_R_709_2, AVVideoYCbCrMatrix_ITU_R_601_4, AVVideoYCbCrMatrix_ITU_R_2020
    ]

    /// Keeps the source's tags when the encoder supports them (e.g. Display P3 screen recordings),
    /// and writes BT.2020 + PQ/HLG when HDR is preserved.
    static func colorProperties(for settings: VideoEncodingSettings, source: VideoTrackInfo) -> [String: String] {
        switch settings.dynamicRange {
        case .hdr10, .hlg, .dolbyVision:
            let transfer = settings.dynamicRange == .hdr10
                ? AVVideoTransferFunction_SMPTE_ST_2084_PQ
                : AVVideoTransferFunction_ITU_R_2100_HLG
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        case .sdr where source.dynamicRange.isHDR:
            return sdrColorProperties
        case .sdr:
            let primaries = source.color.primaries.flatMap { supportedPrimaries.contains($0) ? $0 : nil }
            let matrix = source.color.yCbCrMatrix.flatMap { supportedMatrices.contains($0) ? $0 : nil }
            return [
                AVVideoColorPrimariesKey: primaries ?? AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: matrix ?? AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        }
    }

    // MARK: Audio

    static func pcmReaderSettings(for settings: AACSettings) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: settings.sampleRate,
            AVNumberOfChannelsKey: settings.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    static func aacWriterSettings(for settings: AACSettings) -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = settings.channelCount == 1
            ? kAudioChannelLayoutTag_Mono
            : kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: settings.sampleRate,
            AVNumberOfChannelsKey: settings.channelCount,
            AVEncoderBitRateKey: settings.bitrate,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        ]
    }
}
