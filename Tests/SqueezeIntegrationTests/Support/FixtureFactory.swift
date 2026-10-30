@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

/// Describes a synthetic movie written by `FixtureFactory`.
struct FixtureSpec: Sendable {
    enum Content: Sendable {
        /// Random 8×8 blocks that change every frame: hard to compress, like handheld camera footage.
        case noise
        /// The same frame repeated: what a screen recording of a static window looks like.
        case still
        /// A detailed image sliding sideways: compressible through motion vectors, like a camera pan.
        case panning
    }

    var name = "fixture"
    var width = 640
    var height = 360
    var frameRate = 30
    var duration = 2.0
    var codec: AVVideoCodecType = .h264
    var bitrate = 8_000_000
    var transform: CGAffineTransform = .identity
    var includesAudio = true
    /// Writes 10-bit HEVC tagged BT.2020/HLG, like an iPhone recording in HDR.
    var isHLG = false
    var content: Content = .noise
    var creationDate: Date?
    var locationISO6709: String?

    static let landscape = FixtureSpec(name: "landscape")
    static let hlg = FixtureSpec(name: "hlg", duration: 1, codec: .hevc, isHLG: true)
    /// Stored landscape with a 90° rotation, exactly how iPhones record portrait video.
    static let portrait = FixtureSpec(
        name: "portrait",
        transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
    )
}

enum FixtureFactory {
    static let audioSampleRate = 48_000.0
    static let audioChunkFrames = 4_800

    static func make(_ spec: FixtureSpec, in directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent(spec.name).appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = metadata(for: spec)
        // Puts the sample tables first, so cutting the end of the file only damages the last samples.
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(for: spec))
        videoInput.transform = spec.transform
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat(for: spec),
                kCVPixelBufferWidthKey as String: spec.width,
                kCVPixelBufferHeightKey as String: spec.height
            ]
        )
        writer.add(videoInput)

        let audioInput = spec.includesAudio ? makeAudioInput() : nil
        audioInput.map(writer.add)

        guard writer.startWriting() else { throw writer.error ?? FixtureError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        // Each track is fed on its own queue as the writer asks for it; feeding them from one loop
        // deadlocks when the writer holds video back waiting for audio to catch up (AAC priming).
        let frameCount = Int((spec.duration * Double(spec.frameRate)).rounded())
        let stillFrame = spec.content == .still ? try makeFrame(spec, index: 0, adaptor: adaptor) : nil
        var frameIndex = 0
        var feeders = [Feeder(input: videoInput, label: "video") {
            guard frameIndex < frameCount else { return false }
            let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(spec.frameRate))
            let frame = try stillFrame ?? makeFrame(spec, index: frameIndex, adaptor: adaptor)
            guard adaptor.append(frame, withPresentationTime: time) else { throw FixtureError.writerFailed }
            frameIndex += 1
            return true
        }]
        if let audioInput {
            feeders.append(audioFeeder(audioInput, duration: spec.duration))
        }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for feeder in feeders {
                    group.addTask { try await feeder.run() }
                }
                try await group.waitForAll()
            }
        } catch {
            throw writer.error ?? error
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FixtureError.writerFailed }
        return url
    }

    private static func makeAudioInput() -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ])
        input.expectsMediaDataInRealTime = false
        return input
    }

    private static func audioFeeder(_ input: AVAssetWriterInput, duration: Double) -> Feeder {
        let totalFrames = Int(duration * audioSampleRate)
        var written = 0
        return Feeder(input: input, label: "audio") {
            guard written < totalFrames else { return false }
            let count = min(audioChunkFrames, totalFrames - written)
            guard input.append(try sineBuffer(startFrame: written, frameCount: count)) else {
                throw FixtureError.writerFailed
            }
            written += count
            return true
        }
    }

    /// A valid movie whose last `fraction` of bytes was chopped off, like an interrupted copy.
    static func makeTruncated(_ spec: FixtureSpec, cutting fraction: Double, in directory: URL) async throws -> URL {
        let url = try await make(spec, in: directory)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size - UInt64(Double(size) * fraction))
        return url
    }

    /// Writes random bytes with a `.mov` extension.
    static func makeCorruptFile(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("corrompido.mov")
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<64_000).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: Video

    private static func videoSettings(for spec: FixtureSpec) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: spec.codec,
            AVVideoWidthKey: spec.width,
            AVVideoHeightKey: spec.height
        ]
        if spec.codec == .h264 || spec.codec == .hevc {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: spec.bitrate,
                AVVideoExpectedSourceFrameRateKey: spec.frameRate
            ]
            if spec.isHLG {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            }
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        if spec.isHLG {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        }
        return settings
    }

    private static func makeFrame(
        _ spec: FixtureSpec,
        index: Int,
        adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else { throw FixtureError.noPixelBufferPool }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw FixtureError.noPixelBufferPool }
        if spec.isHLG {
            fillHLG(buffer, spec: spec, index: index)
            return buffer
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw FixtureError.noPixelBufferPool }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let blockSize = 8
        let seed = spec.content == .noise ? UInt64(index) : 0
        let shift = spec.content == .panning ? index * 4 : 0

        for blockRow in stride(from: 0, to: spec.height, by: blockSize) {
            let firstRow = base.advanced(by: blockRow * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in 0..<spec.width {
                let color = blockColor(row: blockRow / blockSize, column: (column + shift) / blockSize, seed: seed)
                let pixel = firstRow.advanced(by: column * 4)
                pixel[0] = UInt8(truncatingIfNeeded: color)
                pixel[1] = UInt8(truncatingIfNeeded: color >> 8)
                pixel[2] = UInt8(truncatingIfNeeded: color >> 16)
                pixel[3] = 255
            }
            for row in (blockRow + 1)..<min(blockRow + blockSize, spec.height) {
                base.advanced(by: row * bytesPerRow).copyMemory(from: firstRow, byteCount: bytesPerRow)
            }
        }
        return buffer
    }

    private static func pixelFormat(for spec: FixtureSpec) -> OSType {
        spec.isHLG ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
    }

    /// 10-bit 4:2:0 (what HDR cameras produce): blocky luma, neutral chroma, tagged BT.2020/HLG.
    private static func fillHLG(_ buffer: CVPixelBuffer, spec: FixtureSpec, index: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let seed = spec.content == .noise ? UInt64(index) : 0
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let samplesPerRow = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            for row in 0..<height {
                let line = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt16.self)
                for sample in 0..<samplesPerRow {
                    // Video-range 10-bit values live in the top bits of each 16-bit sample.
                    let value = plane == 0
                        ? 64 + UInt16(blockColor(row: row / 8, column: sample / 8, seed: seed) % 876)
                        : 512
                    line[sample] = value << 6
                }
            }
        }
        let attachments: [(CFString, CFString)] = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        ]
        for (key, value) in attachments {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
    }

    /// Deterministic per-block colour (SplitMix64), identical across runs and machines.
    private static func blockColor(row: Int, column: Int, seed: UInt64) -> UInt64 {
        var value = UInt64(truncatingIfNeeded: row) &* 0x9E37_79B9_7F4A_7C15
            ^ UInt64(truncatingIfNeeded: column) &* 0xBF58_476D_1CE4_E5B9
            ^ seed &* 0x94D0_49BB_1331_11EB
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    // MARK: Audio

    /// 440 Hz stereo sine as interleaved 16-bit PCM; the writer encodes it to AAC.
    private static func sineBuffer(startFrame: Int, frameCount: Int) throws -> CMSampleBuffer {
        var samples = [Int16](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            let phase = 2 * Double.pi * 440 * Double(startFrame + frame) / audioSampleRate
            let value = Int16(sin(phase) * 8_000)
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }

        var description = AudioStreamBasicDescription(
            mSampleRate: audioSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        ))

        let byteCount = samples.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block
        ))
        guard let block, let format else { throw FixtureError.audioBufferFailed }
        try samples.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { throw FixtureError.audioBufferFailed }
            try check(CMBlockBufferReplaceDataBytes(
                with: address, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount
            ))
        }

        var sampleBuffer: CMSampleBuffer?
        try check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frameCount,
            presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(audioSampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer
        ))
        guard let sampleBuffer else { throw FixtureError.audioBufferFailed }
        return sampleBuffer
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw FixtureError.coreMedia(status) }
    }

    // MARK: Helpers

    private static func metadata(for spec: FixtureSpec) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        if let date = spec.creationDate {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.value = ISO8601DateFormatter().string(from: date) as NSString
            items.append(item)
        }
        if let location = spec.locationISO6709 {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataLocationISO6709
            item.value = location as NSString
            items.append(item)
        }
        return items
    }
}

/// Feeds one writer input from a producer closure on a private serial queue.
/// `@unchecked Sendable`: the input and the producer's captured state are only touched on `queue`.
private final class Feeder: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let queue: DispatchQueue
    /// Appends one sample; returns `false` when there is nothing left.
    private let appendNext: () throws -> Bool
    private var isDone = false

    init(input: AVAssetWriterInput, label: String, appendNext: @escaping () throws -> Bool) {
        self.input = input
        self.queue = DispatchQueue(label: "fixture.\(label)")
        self.appendNext = appendNext
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData, !isDone {
                    do {
                        if try !appendNext() {
                            isDone = true
                            input.markAsFinished()
                            continuation.resume()
                        }
                    } catch {
                        isDone = true
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}

enum FixtureError: Error {
    case writerFailed
    case noPixelBufferPool
    case audioBufferFailed
    case coreMedia(OSStatus)
}
