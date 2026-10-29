@preconcurrency import AVFoundation
import Foundation

extension AssetRewriter {
    /// Wires reader outputs and writer inputs for `plan`, writing an MP4 to `outputURL`.
    static func make(for plan: EncodingPlan, source: MediaInfo, outputURL: URL) async throws -> AssetRewriter {
        let asset = AVURLAsset(url: source.url)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // Moves the moov atom to the front ("faststart") so players can start before the download ends.
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = await MetadataCopier.items(from: asset)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw SqueezeError.noVideoTrack
        }
        var lanes = [try await videoLane(plan.video, track: videoTrack, source: source, reader: reader, writer: writer)]

        if plan.audio != .none, let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            lanes.append(try await audioLane(plan.audio, track: audioTrack, reader: reader, writer: writer))
        }
        return AssetRewriter(reader: reader, writer: writer, lanes: lanes, duration: source.duration)
    }

    private static func videoLane(
        _ plan: EncodingPlan.Video,
        track: AVAssetTrack,
        source: MediaInfo,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws -> Lane {
        let (transform, formats) = try await track.load(.preferredTransform, .formatDescriptions)
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let context: LaneContext

        switch plan {
        case .passthrough:
            output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
            context = LaneContext()
        case .encode(let settings):
            let readerSettings = WriterSettings.videoReaderSettings(for: settings, source: source.video)
            let candidates = WriterSettings.videoWriterCandidates(for: settings, source: source.video)
            let accepted = candidates.first { writer.canApply(outputSettings: $0, forMediaType: .video) }
            guard let writerSettings = accepted else {
                throw SqueezeError.encodingFailed(reason: "Encoder recusou \(settings.codec) em \(settings.size)")
            }
            output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
            input = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
            context = LaneContext(frameRateLimit: settings.frameRateLimit)
        }
        // Rotation stays as metadata, exactly like the camera wrote it: no pixels are rotated.
        input.transform = transform

        let unsupported: SqueezeError = plan == .passthrough
            ? .passthroughUnsupported(codec: source.video.codec)
            : .encodingFailed(reason: "Faixa de vídeo não suportada")
        try connect(output, to: input, reader: reader, writer: writer, otherwise: unsupported)
        return Lane(output: output, input: input, reportsProgress: true, context: context)
    }

    private static func audioLane(
        _ plan: EncodingPlan.Audio,
        track: AVAssetTrack,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws -> Lane {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput

        switch plan {
        case .none:
            preconditionFailure("audioLane(_:) is only called when the plan keeps audio")
        case .passthrough:
            let formats = try await track.load(.formatDescriptions)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formats.first)
        case .encode(let settings):
            var writerSettings = WriterSettings.aacWriterSettings(for: settings)
            if !writer.canApply(outputSettings: writerSettings, forMediaType: .audio) {
                // Let the encoder pick its default bitrate rather than failing the whole job over audio.
                writerSettings[AVEncoderBitRateKey] = nil
            }
            let readerSettings = WriterSettings.pcmReaderSettings(for: settings)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: readerSettings)
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        }
        try connect(
            output, to: input, reader: reader, writer: writer,
            otherwise: .encodingFailed(reason: "Faixa de áudio não suportada")
        )
        return Lane(output: output, input: input, reportsProgress: false, context: LaneContext())
    }

    private static func connect(
        _ output: AVAssetReaderTrackOutput,
        to input: AVAssetWriterInput,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        otherwise error: SqueezeError
    ) throws {
        output.alwaysCopiesSampleData = false
        input.expectsMediaDataInRealTime = false
        guard reader.canAdd(output), writer.canAdd(input) else { throw error }
        reader.add(output)
        writer.add(input)
    }
}
