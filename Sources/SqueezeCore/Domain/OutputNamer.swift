import Foundation

/// Builds `name_compressed.mp4`, `name_compressed_2.mp4`, … for a source file.
public enum OutputNamer {
    public static let suffix = "_compressed"
    public static let fileExtension = "mp4"

    /// Endless sequence of candidate URLs in `directory`, in the order they should be tried.
    public static func candidates(for source: URL, in directory: URL) -> some Sequence<URL> {
        let stem = source.deletingPathExtension().lastPathComponent
        return (1...).lazy.map { index in
            let name = index == 1 ? "\(stem)\(suffix)" : "\(stem)\(suffix)_\(index)"
            return directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
        }
    }

    /// First candidate that doesn't exist yet. Only a hint for display: the file is created later,
    /// so the final name is claimed atomically when the output is moved into place.
    public static func availableURL(
        for source: URL,
        in directory: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        for candidate in candidates(for: source, in: directory) where !fileExists(candidate) {
            return candidate
        }
        preconditionFailure("candidates(for:in:) is infinite")
    }
}
