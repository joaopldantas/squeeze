import Foundation
@testable import SqueezeCore

extension AudioTrackInfo {
    static let stereoAAC = AudioTrackInfo(format: "aac ", bitrate: 256_000, sampleRate: 48_000, channelCount: 2)
    static let stereoPCM = AudioTrackInfo(format: "lpcm", bitrate: 1_536_000, sampleRate: 48_000, channelCount: 2)
}

extension MediaInfo {
    static func sample(
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Double = 30,
        videoBitrate: Int = 40_000_000,
        duration: Double = 60,
        codec: String = "hvc1",
        dynamicRange: DynamicRange = .sdr,
        transferFunction: String? = nil,
        audio: AudioTrackInfo? = .stereoAAC
    ) -> MediaInfo {
        let size = PixelSize(width: width, height: height)
        let video = VideoTrackInfo(
            codec: codec,
            naturalSize: size,
            frameRate: frameRate,
            bitrate: videoBitrate,
            dynamicRange: dynamicRange,
            color: ColorDescription(transferFunction: transferFunction)
        )
        let audioBytes = Double(audio?.bitrate ?? 0) * duration / 8
        let fileSize = Int64(Double(videoBitrate) * duration / 8 + audioBytes)
        return MediaInfo(
            url: URL(fileURLWithPath: "/tmp/sample.mov"),
            fileSize: fileSize,
            duration: duration,
            video: video,
            audio: audio
        )
    }
}
