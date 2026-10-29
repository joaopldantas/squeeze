import Foundation

public enum BitrateCalculator {
    /// Share of the file taken by the MP4 container (moov atom, sample tables, padding).
    public static let containerOverhead = 0.02
    /// Below this, HEVC/H.264 output is mostly blocks regardless of resolution.
    public static let minimumVideoBitrate = 150_000

    static let referencePixels = Double(1920 * 1080)
    static let referenceFrameRate = 30.0

    /// Video bitrate that makes the whole file (video + audio + container) fit `targetBytes`.
    public static func videoBitrate(targetBytes: Int64, duration: Double, audioBitrate: Int) throws -> Int {
        guard duration.isFinite, duration > 0 else { throw SqueezeError.invalidDuration }
        let payloadBits = Double(targetBytes) * 8 * (1 - containerOverhead)
        let videoBitrate = payloadBits / duration - Double(audioBitrate)
        guard videoBitrate >= Double(minimumVideoBitrate) else {
            throw SqueezeError.targetSizeTooSmall(
                minimumBytes: minimumTargetBytes(duration: duration, audioBitrate: audioBitrate)
            )
        }
        return Int(videoBitrate)
    }

    /// Smallest target size `videoBitrate(targetBytes:…)` accepts.
    public static func minimumTargetBytes(duration: Double, audioBitrate: Int) -> Int64 {
        let bits = Double(minimumVideoBitrate + audioBitrate) * duration
        return Int64((bits / 8 / (1 - containerOverhead)).rounded(.up))
    }

    /// Scales a 1080p30 reference bitrate to the output resolution, frame rate, codec and motion.
    ///
    /// Bitrate grows sub-linearly with pixels (exponent 0.75) and frame rate (0.5): larger frames and
    /// shorter frame intervals are more redundant, so 4K60 needs ~4× the bits of 1080p30, not 8×.
    public static func adaptiveBitrate(
        referenceBitrate: Int,
        size: PixelSize,
        frameRate: Double,
        codec: VideoCodec,
        motion: MotionLevel
    ) -> Int {
        let pixelScale = pow(Double(size.pixelCount) / referencePixels, 0.75)
        let fps = frameRate > 0 ? frameRate : referenceFrameRate
        let frameRateScale = pow(fps / referenceFrameRate, 0.5)
        let bitrate = Double(referenceBitrate) * pixelScale * frameRateScale
            * codec.bitrateFactor * motion.bitrateFactor
        return max(minimumVideoBitrate, Int(bitrate))
    }
}
