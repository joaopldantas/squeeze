@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Reads the facts the planner needs from a movie file.
public struct MediaInspector: Sendable {
    public init() {}

    public func inspect(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        do {
            let (duration, isReadable, isProtected) = try await asset.load(.duration, .isReadable, .hasProtectedContent)
            if isProtected { throw SqueezeError.drmProtected }
            guard isReadable else { throw SqueezeError.unreadableFile(reason: "AVAsset.isReadable == false") }

            let seconds = duration.seconds
            guard seconds.isFinite, seconds > 0 else { throw SqueezeError.invalidDuration }
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw SqueezeError.noVideoTrack
            }

            return MediaInfo(
                url: url,
                fileSize: Self.fileSize(of: url),
                duration: seconds,
                video: try await Self.videoInfo(videoTrack),
                audio: try await asset.loadTracks(withMediaType: .audio).first.asyncMap(Self.audioInfo),
                creationDate: try await asset.load(.creationDate)?.load(.dateValue)
            )
        } catch {
            throw SqueezeError.classify(error)
        }
    }

    private static func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func videoInfo(_ track: AVAssetTrack) async throws -> VideoTrackInfo {
        let (naturalSize, transform, frameRate, dataRate, formats) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions
        )
        guard let format = formats.first else {
            throw SqueezeError.unreadableFile(reason: "Faixa de vídeo sem descrição de formato")
        }
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let color = ColorDescription(
            primaries: format.stringExtension(kCMFormatDescriptionExtension_ColorPrimaries),
            transferFunction: format.stringExtension(kCMFormatDescriptionExtension_TransferFunction),
            yCbCrMatrix: format.stringExtension(kCMFormatDescriptionExtension_YCbCrMatrix)
        )
        return VideoTrackInfo(
            codec: format.fourCC,
            naturalSize: PixelSize(width: Int(naturalSize.width.rounded()), height: Int(naturalSize.height.rounded())),
            displaySize: PixelSize(
                width: Int(abs(displayRect.width).rounded()),
                height: Int(abs(displayRect.height).rounded())
            ),
            frameRate: Double(frameRate),
            bitrate: Int(dataRate),
            dynamicRange: dynamicRange(format: format, color: color),
            color: color
        )
    }

    private static func audioInfo(_ track: AVAssetTrack) async throws -> AudioTrackInfo? {
        let (dataRate, formats) = try await track.load(.estimatedDataRate, .formatDescriptions)
        guard let format = formats.first, let asbd = format.audioStreamBasicDescription else { return nil }
        return AudioTrackInfo(
            format: format.fourCC,
            bitrate: Int(dataRate),
            sampleRate: asbd.mSampleRate,
            channelCount: Int(asbd.mChannelsPerFrame)
        )
    }

    /// Dolby Vision is signalled by its own codec tag (`dvh1`/`dvhe`) or by a `dvcC`/`dvvC`
    /// configuration box next to a regular `hvc1` sample description, as iPhones write it.
    static func dynamicRange(format: CMFormatDescription, color: ColorDescription) -> DynamicRange {
        let codec = format.fourCC
        let atoms = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) as? [String: Any] ?? [:]
        let dolbyVisionBoxes: Set<String> = ["dvcC", "dvvC", "dvwC"]
        if ["dvh1", "dvhe"].contains(codec) || !dolbyVisionBoxes.isDisjoint(with: atoms.keys) {
            return .dolbyVision
        }
        switch color.transferFunction {
        case TransferFunction.pq.rawValue: return .hdr10
        case TransferFunction.hlg.rawValue: return .hlg
        default: return .sdr
        }
    }
}

extension CMFormatDescription {
    /// Media subtype as text, e.g. `hvc1` or `aac ` (trailing space included, as in the spec).
    var fourCC: String {
        let code = CMFormatDescriptionGetMediaSubType(self)
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(code)
    }

    fileprivate func stringExtension(_ key: CFString) -> String? {
        CMFormatDescriptionGetExtension(self, extensionKey: key) as? String
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T?) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
