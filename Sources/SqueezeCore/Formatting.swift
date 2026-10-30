import Foundation

/// Pure pt-BR text formatting shared by the CLI and the app, testable without running a conversion.
public struct Formatting: Sendable {
    public var locale: Locale

    public init(locale: Locale = Locale(identifier: "pt_BR")) {
        self.locale = locale
    }

    /// Decimal units, like Finder: "120,3 MB".
    public func bytes(_ count: Int64) -> String {
        let units: [(String, Double)] = [("GB", 1e9), ("MB", 1e6), ("KB", 1e3)]
        let value = Double(count)
        for (unit, size) in units where value >= size {
            return "\(number(value / size)) \(unit)"
        }
        return "\(count) B"
    }

    /// "−82%" when smaller, "+15%" when the output grew; one decimal below 1% so "+0,4%" never reads "−0%".
    public func change(_ comparison: SizeComparison) -> String {
        guard comparison.savedBytes != 0 else { return "0%" }
        let magnitude = abs(comparison.savedFraction * 100)
        let digits = magnitude < 1 ? 1 : 0
        let text = magnitude.formatted(.number.precision(.fractionLength(digits)).locale(locale))
        return (comparison.savedBytes > 0 ? "−" : "+") + text + "%"
    }

    public func bitrate(_ bitsPerSecond: Int) -> String {
        bitsPerSecond >= 1_000_000
            ? "\(number(Double(bitsPerSecond) / 1e6)) Mbps"
            : "\(bitsPerSecond / 1_000) kbps"
    }

    /// "0:42", "12:05", "1:02:03".
    public func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    public func elapsed(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return "\(number(seconds)) s"
    }

    /// "HEVC", "H.264", "ProRes"… from the four-character code; unknown codes are shown as-is.
    public func codec(_ fourCC: String) -> String {
        switch fourCC {
        case "hvc1", "hev1": "HEVC"
        case "dvh1", "dvhe": "Dolby Vision"
        case "avc1", "avc3": "H.264"
        case "apcn", "apch", "apcs", "apco", "ap4h", "ap4x": "ProRes"
        default: fourCC.trimmingCharacters(in: .whitespaces)
        }
    }

    public func frameRate(_ fps: Double) -> String {
        fps.formatted(.number.precision(.fractionLength(0...2)).locale(locale)) + " fps"
    }

    public func plan(_ plan: EncodingPlan, source: MediaInfo) -> String {
        let video: String = switch plan.video {
        case .passthrough:
            "vídeo copiado sem reencodar (\(source.video.codec))"
        case .encode(let settings):
            [
                settings.codec.displayName,
                settings.size.description,
                bitrate(settings.bitrate),
                settings.frameRateLimit.map { "até \($0) fps" },
                settings.dynamicRange.isHDR ? "HDR" : nil
            ].compactMap { $0 }.joined(separator: " · ")
        }
        let audio: String = switch plan.audio {
        case .none: "sem áudio"
        case .passthrough: "áudio copiado"
        case .encode(let settings): "áudio AAC \(bitrate(settings.bitrate))"
        }
        return "\(video) · \(audio)"
    }

    public func source(_ info: MediaInfo) -> String {
        [
            info.video.displaySize.description,
            duration(info.duration),
            frameRate(info.video.frameRate),
            info.video.codec,
            info.video.dynamicRange.isHDR ? "HDR" : nil,
            bytes(info.fileSize)
        ].compactMap { $0 }.joined(separator: " · ")
    }

    public func progressBar(_ fraction: Double, width: Int = 30) -> String {
        let clamped = min(max(fraction, 0), 1)
        let filled = Int((clamped * Double(width)).rounded())
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
        return "[\(bar)] \(String(format: "%3d", Int(clamped * 100)))%"
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }
}
