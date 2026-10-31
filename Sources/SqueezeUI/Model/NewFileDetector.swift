import Foundation

/// Spots files that appear in a folder and reports each one once it has stopped growing, so a recording
/// still being written is never picked up half-way.
public struct NewFileDetector: Sendable {
    /// Files present when watching began, or already reported.
    private var known: Set<URL>
    /// Files seen growing, with their size at the last look.
    private var pending: [URL: Int64] = [:]

    public init(existing: some Sequence<URL>) {
        known = Set(existing)
    }

    /// Whether some file is still being written, so the folder must be looked at again soon.
    public var isWaiting: Bool { !pending.isEmpty }

    /// Takes the folder's current files with their sizes and returns the new ones that are complete:
    /// those with the same, non-zero size as on the previous look.
    public mutating func update(_ files: [URL: Int64]) -> [URL] {
        // Forget what's gone, so a file deleted and created again under the same name counts as new.
        known.formIntersection(files.keys)
        pending = pending.filter { files[$0.key] != nil }

        var complete: [URL] = []
        for (url, size) in files where !known.contains(url) {
            if size > 0, pending[url] == size {
                pending[url] = nil
                known.insert(url)
                complete.append(url)
            } else {
                pending[url] = size
            }
        }
        return complete.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
