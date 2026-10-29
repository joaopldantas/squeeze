@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// Estimates how much the picture moves by comparing small greyscale frames a fraction of a second apart.
///
/// Screen recordings are mostly static, so they compress very well and deserve a lower bitrate.
/// Analysis is best-effort: any failure yields `.normal`, which is always a safe choice.
public struct MotionAnalyzer: Sendable {
    public var samplePairs: Int
    /// Seconds between the two frames of a pair.
    public var pairSpacing: Double
    /// Thumbnails are rendered to `side × side` greyscale; enough to see motion, cheap to decode.
    public var side: Int

    public init(samplePairs: Int = 6, pairSpacing: Double = 0.2, side: Int = 64) {
        self.samplePairs = samplePairs
        self.pairSpacing = pairSpacing
        self.side = side
    }

    public func analyze(_ url: URL, duration: Double) async -> MotionLevel {
        guard duration > pairSpacing * 2, samplePairs > 0 else { return .normal }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: side * 4, height: side * 4)
        // Zero tolerance: otherwise both frames of a pair can snap to the same keyframe and look identical.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var fractions: [Double] = []
        for time in sampleTimes(duration: duration) {
            guard !Task.isCancelled,
                  let first = try? await luma(at: time, generator: generator),
                  let second = try? await luma(at: time + pairSpacing, generator: generator)
            else { continue }
            fractions.append(MotionLevel.changedFraction(first, second))
        }
        return MotionLevel.classify(changedFractions: fractions)
    }

    /// Pair start times spread evenly over the video, leaving room for the second frame.
    func sampleTimes(duration: Double) -> [Double] {
        let usable = duration - pairSpacing
        return (0..<samplePairs).map { usable * (Double($0) + 0.5) / Double(samplePairs) }
    }

    private func luma(at seconds: Double, generator: AVAssetImageGenerator) async throws -> [UInt8] {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let (image, _) = try await generator.image(at: time)
        return try Self.greyscale(image, side: side)
    }

    static func greyscale(_ image: CGImage, side: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { throw SqueezeError.encodingFailed(reason: "CGContext indisponível") }
        return pixels
    }
}
