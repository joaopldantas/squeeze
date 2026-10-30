import AVFoundation
import Foundation
import Testing
@testable import SqueezeCore

@Suite("Classificação de erros")
struct SqueezeErrorTests {
    @Test("disco cheio em qualquer domínio", arguments: [
        NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
        NSError(domain: AVFoundationErrorDomain, code: AVError.Code.diskFull.rawValue)
    ])
    func diskFull(error: NSError) {
        #expect(SqueezeError.classify(error) == .diskFull)
    }

    @Test("encontra a causa real em erros aninhados")
    func underlyingError() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.unknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: posix]
        )
        #expect(SqueezeError.classify(wrapped) == .diskFull)
    }

    @Test("cancelamento")
    func cancellation() {
        #expect(SqueezeError.classify(CancellationError()) == .cancelled)
        let avCancel = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.operationCancelled.rawValue)
        #expect(SqueezeError.classify(avCancel) == .cancelled)
    }

    @Test("DRM")
    func drm() {
        let error = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.contentIsProtected.rawValue)
        #expect(SqueezeError.classify(error) == .drmProtected)
    }

    @Test("arquivo corrompido ou truncado", arguments: [
        AVError.Code.fileFormatNotRecognized, .decodeFailed, .fileFailedToParse, .invalidSampleCursor
    ])
    func corrupted(code: AVError.Code) {
        let error = NSError(domain: AVFoundationErrorDomain, code: code.rawValue)
        guard case .unreadableFile = SqueezeError.classify(error) else {
            Issue.record("esperava unreadableFile")
            return
        }
    }

    @Test("SqueezeError passa direto; desconhecido vira falha de codificação")
    func passthroughAndFallback() {
        #expect(SqueezeError.classify(SqueezeError.noVideoTrack) == .noVideoTrack)
        let unknown = NSError(domain: "Other", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        #expect(SqueezeError.classify(unknown) == .encodingFailed(reason: "boom"))
    }

    @Test("checagem de espaço em disco com margem de 20%")
    func diskSpaceCheck() {
        #expect(throws: Never.self) {
            try SqueezeError.checkDiskSpace(estimatedBytes: 100, availableBytes: 120)
        }
        #expect(throws: SqueezeError.insufficientDiskSpace(requiredBytes: 120, availableBytes: 119)) {
            try SqueezeError.checkDiskSpace(estimatedBytes: 100, availableBytes: 119)
        }
    }

    @Test("toda mensagem de erro é legível em português")
    func descriptions() {
        let errors: [SqueezeError] = [
            .unreadableFile(reason: "x"), .noVideoTrack, .drmProtected, .passthroughUnsupported(codec: "apcn"),
            .targetSizeTooSmall(minimumBytes: 1_000_000), .invalidDuration,
            .insufficientDiskSpace(requiredBytes: 2, availableBytes: 1), .diskFull,
            .outputNotWritable(reason: "x"), .cancelled, .encodingFailed(reason: "x")
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }
}
