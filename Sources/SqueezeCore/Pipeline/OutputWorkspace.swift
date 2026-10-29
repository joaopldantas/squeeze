import Darwin
import Foundation

/// Owns the temporary file while encoding and claims the final name atomically at the end.
///
/// The output is written next to its destination (same volume), so the final step is a rename:
/// readers never see a half-written `_compressed.mp4`, and a cancelled or failed job leaves nothing behind.
struct OutputWorkspace {
    let temporaryFileURL: URL
    private let cleanupURL: URL

    /// Prefers a system-managed replacement directory on the destination volume (cleaned up by the OS
    /// even after a crash); falls back to a hidden file in the destination folder.
    init(near directory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "squeeze-\(UUID().uuidString).mp4"
        if let scratch = try? fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true
        ) {
            temporaryFileURL = scratch.appendingPathComponent(name)
            cleanupURL = scratch
        } else {
            temporaryFileURL = directory.appendingPathComponent(".\(name)")
            cleanupURL = temporaryFileURL
        }
    }

    func cleanUp(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: cleanupURL)
    }

    /// Renames the finished file to the first free `name_compressed[_N].mp4`.
    ///
    /// `renamex_np(RENAME_EXCL)` fails with `EEXIST` instead of replacing, so even two jobs finishing at
    /// the same instant for files with the same name can't overwrite each other — or anything else.
    func claimFinalURL(for source: URL, in directory: URL) throws -> URL {
        for candidate in OutputNamer.candidates(for: source, in: directory) {
            if renamex_np(temporaryFileURL.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                return candidate
            }
            let code = errno
            guard code == EEXIST else {
                throw SqueezeError.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
            }
        }
        preconditionFailure("OutputNamer.candidates(for:in:) is infinite")
    }
}
