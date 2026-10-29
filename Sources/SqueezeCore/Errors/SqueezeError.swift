import AVFoundation
import Foundation

public enum SqueezeError: Error, Hashable, Sendable {
    /// Corrupt, truncated or not a video file.
    case unreadableFile(reason: String)
    case noVideoTrack
    case drmProtected
    case passthroughUnsupported(codec: String)
    case targetSizeTooSmall(minimumBytes: Int64)
    case invalidDuration
    /// Pre-flight check: the estimated output doesn't fit on the destination volume.
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    /// The volume filled up while writing.
    case diskFull
    case outputNotWritable(reason: String)
    case cancelled
    case encodingFailed(reason: String)
}

extension SqueezeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreadableFile:
            "O arquivo está corrompido ou não é um vídeo válido."
        case .noVideoTrack:
            "O arquivo não contém uma faixa de vídeo."
        case .drmProtected:
            "O vídeo é protegido por DRM e não pode ser convertido."
        case .passthroughUnsupported(let codec):
            "O codec \(codec) não pode ir para MP4 sem reencodar. Escolha outro preset."
        case .targetSizeTooSmall(let minimumBytes):
            "Tamanho alvo pequeno demais. O mínimo para este vídeo é \(Self.format(minimumBytes))."
        case .invalidDuration:
            "Não foi possível determinar a duração do vídeo."
        case let .insufficientDiskSpace(required, available):
            "Espaço insuficiente: são necessários \(Self.format(required)), há \(Self.format(available)) livres."
        case .diskFull:
            "O disco ficou cheio durante a conversão."
        case .outputNotWritable:
            "Não foi possível gravar na pasta de saída."
        case .cancelled:
            "Conversão cancelada."
        case .encodingFailed:
            "Falha ao codificar o vídeo."
        }
    }

    public var failureReason: String? {
        switch self {
        case .unreadableFile(let reason), .outputNotWritable(let reason), .encodingFailed(let reason): reason
        default: nil
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension SqueezeError {
    /// Maps errors from AVFoundation, Foundation and POSIX onto user-facing cases.
    /// Walks `NSUnderlyingErrorKey` because AVFoundation often wraps the real cause (e.g. ENOSPC).
    public static func classify(_ error: any Error) -> SqueezeError {
        if let squeezeError = error as? SqueezeError { return squeezeError }
        if error is CancellationError { return .cancelled }

        var current: NSError? = error as NSError
        while let nsError = current {
            if let mapped = classify(domain: nsError.domain, code: nsError.code) { return mapped }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .encodingFailed(reason: error.localizedDescription)
    }

    private static func classify(domain: String, code: Int) -> SqueezeError? {
        switch (domain, code) {
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
             (NSPOSIXErrorDomain, Int(ENOSPC)),
             (AVFoundationErrorDomain, AVError.Code.diskFull.rawValue):
            return .diskFull
        case (NSCocoaErrorDomain, NSUserCancelledError),
             (AVFoundationErrorDomain, AVError.Code.operationCancelled.rawValue):
            return .cancelled
        case (AVFoundationErrorDomain, AVError.Code.contentIsProtected.rawValue):
            return .drmProtected
        case (AVFoundationErrorDomain, AVError.Code.fileFormatNotRecognized.rawValue),
             (AVFoundationErrorDomain, AVError.Code.decodeFailed.rawValue),
             (AVFoundationErrorDomain, AVError.Code.fileFailedToParse.rawValue):
            return .unreadableFile(reason: "AVFoundation \(code)")
        case (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
             (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError),
             (NSPOSIXErrorDomain, Int(EACCES)),
             (NSPOSIXErrorDomain, Int(EROFS)):
            return .outputNotWritable(reason: "\(domain) \(code)")
        default:
            return nil
        }
    }

    /// Pre-flight space check with a safety margin for the encoder overshooting its target.
    public static func checkDiskSpace(estimatedBytes: Int64, availableBytes: Int64, margin: Double = 0.2) throws {
        let required = Int64(Double(estimatedBytes) * (1 + margin))
        guard availableBytes >= required else {
            throw SqueezeError.insufficientDiskSpace(requiredBytes: required, availableBytes: availableBytes)
        }
    }
}
