@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import SqueezeCore

extension Tag {
    @Tag static var integration: Self
}

/// A fresh directory per test, removed when the test ends.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SqueezeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Visible file names, sorted.
    func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Includes hidden files, to prove nothing temporary was left behind.
    func allContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}

/// What a test needs to know about an output file.
struct OutputProbe {
    let info: MediaInfo
    let transform: CGAffineTransform
    let majorBrand: String
    let creationDate: Date?
    let location: String?

    static func probe(_ url: URL) async throws -> OutputProbe {
        let info = try await MediaInspector().inspect(url)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        let location = try await asset.load(.commonMetadata).first { $0.commonKey == .commonKeyLocation }
        return OutputProbe(
            info: info,
            transform: try await track.load(.preferredTransform),
            majorBrand: String(bytes: header.dropFirst(4), encoding: .ascii) ?? "",
            creationDate: try await asset.load(.creationDate)?.load(.dateValue),
            location: try await location?.load(.stringValue)
        )
    }

    /// `ftyp` box with an MP4 brand — QuickTime files use `qt  `.
    var isMP4: Bool {
        majorBrand.hasPrefix("ftyp") && !majorBrand.hasSuffix("qt  ")
    }
}

/// Lets a progress callback (on an encoder queue) cancel the task that started the job.
final class TaskCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<ConversionResult, any Error>?
    private var pending = false

    func attach(_ task: Task<ConversionResult, any Error>) {
        lock.withLock {
            self.task = task
            if pending { task.cancel() }
        }
    }

    func cancel() {
        lock.withLock {
            if let task { task.cancel() } else { pending = true }
        }
    }
}
