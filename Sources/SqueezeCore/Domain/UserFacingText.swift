import Foundation

// Portuguese copy shared by the CLI and the app, kept next to the types it describes.

extension Preset {
    private static let megabyteStyle = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))

    public var displayName: String {
        switch self {
        case .highQuality: "Alta qualidade"
        case .balanced: "Equilibrado"
        case .smallest: "Tamanho mínimo"
        case .web(let resolution): "Web/WhatsApp \(resolution.rawValue)p"
        case .targetSize(let megabytes): "Tamanho alvo \(megabytes.formatted(Self.megabyteStyle)) MB"
        case .original: "Manter qualidade original"
        }
    }
}

extension VideoCodec {
    public var displayName: String {
        switch self {
        case .hevc: "HEVC"
        case .h264: "H.264"
        }
    }
}

extension MotionLevel {
    public var displayName: String {
        switch self {
        case .low: "pouco movimento"
        case .normal: "movimento normal"
        case .high: "muito movimento"
        }
    }
}

extension ConversionWarning {
    public var message: String {
        switch self {
        case .hdrConvertedToSDR:
            "H.264 não suporta HDR: as cores foram convertidas para SDR. Use HEVC para manter o HDR."
        case .dolbyVisionMetadataDropped(let base):
            "Os metadados Dolby Vision foram descartados; o vídeo continua em HDR "
                + "(\(base == .hdr10 ? "HDR10" : "HLG"))."
        case .audioReencodedForMP4:
            "O áudio original não é aceito em MP4 e foi convertido para AAC."
        case let .highFrameRateReduced(source, output):
            "Vídeo em \(source) fps (câmera lenta) reduzido para \(output) fps. Use FPS \"manter\" para preservar."
        case .damagedEndSkipped(let seconds):
            "Os últimos \(seconds.formatted(.number.precision(.fractionLength(0...2)))) s do original "
                + "estão danificados e foram descartados."
        }
    }
}
