import Foundation
import SqueezeCore

/// Prints human-readable progress. Results go to stdout; the live progress bar goes to stderr,
/// and only when stderr is a terminal, so piping the output stays clean.
struct Reporter: Sendable {
    var format = Formatting()
    let showsProgressBar = isatty(STDERR_FILENO) == 1

    func start(_ request: ConversionRequest, index: Int, count: Int) {
        print("[\(index)/\(count)] \(request.source.lastPathComponent)")
    }

    func preview(_ preview: ConversionPreview) {
        line("origem", format.source(preview.info))
        line("plano", "\(preview.request.preset.displayName) → \(format.plan(preview.plan, source: preview.info))")
        if preview.motion != .normal, preview.plan.videoSettings != nil {
            line("conteúdo", preview.motion.displayName)
        }
        line("estimado", sizes(preview.estimate))
        preview.plan.warnings.forEach(warn)
    }

    func progress(_ fraction: Double) {
        guard showsProgressBar else { return }
        FileHandle.standardError.write(Data("\r  \(format.progressBar(fraction))".utf8))
    }

    func finished(_ result: ConversionResult) {
        clearProgress()
        let comparison = result.comparison
        print(
            "  ✓ \(format.bytes(comparison.outputBytes)) (\(format.change(comparison))) "
                + "em \(format.elapsed(result.elapsed)) → \(result.outputURL.path)"
        )
        let newWarnings = result.warnings.filter { !result.plan.warnings.contains($0) }
        newWarnings.forEach(warn)
        if result.outputGrewUnexpectedly {
            let hint = result.suggestedPreset.flatMap(PresetChoice.init).map { " Tente --preset \($0.rawValue)." } ?? ""
            warn("O arquivo ficou maior que o original.\(hint)")
        }
    }

    func failed(_ error: SqueezeError) {
        clearProgress()
        let reason = error.failureReason.map { " (\($0))" } ?? ""
        print("  ✗ \(error.localizedDescription)\(reason)")
    }

    func summary(_ summary: BatchSummary) {
        var parts = ["\(summary.succeeded) convertido(s)"]
        if summary.failed > 0 { parts.append("\(summary.failed) com erro") }
        if summary.cancelled { parts.append("lote cancelado") }
        if summary.total.originalBytes > 0, summary.succeeded > 0 {
            parts.append(sizes(summary.total))
        }
        print("\nResumo: " + parts.joined(separator: " · "))
    }

    private func sizes(_ comparison: SizeComparison) -> String {
        let before = format.bytes(comparison.originalBytes)
        let after = format.bytes(comparison.outputBytes)
        return "\(before) → \(after) (\(format.change(comparison)))"
    }

    private func warn(_ warning: ConversionWarning) {
        warn(warning.message)
    }

    private func warn(_ message: String) {
        print("  ! \(message)")
    }

    private func line(_ label: String, _ value: String) {
        print("  " + "\(label):".padding(toLength: 10, withPad: " ", startingAt: 0) + value)
    }

    private func clearProgress() {
        guard showsProgressBar else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
    }
}
