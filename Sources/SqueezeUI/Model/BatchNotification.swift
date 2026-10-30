import Foundation
import SqueezeCore

/// Text for the end-of-batch notification. Kept out of the app target so it can be unit-tested.
public struct BatchNotification: Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    /// `nil` when there is nothing worth notifying: the user cancelled everything themselves.
    public init?(_ report: BatchReport, format: Formatting = Formatting()) {
        guard report.completed > 0 || report.failed > 0 else { return nil }
        let failures = report.failed > 0 ? "\(report.failed) com erro" : nil

        if report.completed > 0 {
            title = report.completed == 1 ? "1 vídeo comprimido" : "\(report.completed) vídeos comprimidos"
            let sizes = "\(format.bytes(report.sizes.originalBytes)) → \(format.bytes(report.sizes.outputBytes))"
                + " (\(format.change(report.sizes)))"
            body = [sizes, failures].compactMap { $0 }.joined(separator: " · ")
        } else {
            title = "Nenhum vídeo comprimido"
            body = failures ?? ""
        }
    }
}
