import Darwin
import Foundation

/// Watches one folder and hands over the videos that appear in it, once they're completely written.
///
/// The folder's change events only say that *something* changed, and say nothing while a file grows, so
/// each event triggers a look at the folder, repeated every `settleInterval` while a file is still growing.
@MainActor
public final class FolderWatcher {
    public let folder: URL
    private let settleInterval: Duration
    private let accept: @MainActor (URL) -> Bool
    private let found: @MainActor ([URL]) -> Void
    private let source: any DispatchSourceFileSystemObject
    private var detector: NewFileDetector
    private var recheck: Task<Void, Never>?

    /// - Parameters:
    ///   - accept: filters complete files further (e.g. only screen recordings).
    ///   - found: receives the accepted files, oldest first.
    /// - Returns: `nil` if the folder can't be opened.
    public init?(
        folder: URL,
        settleInterval: Duration = .seconds(1.5),
        accept: @escaping @MainActor (URL) -> Bool = { _ in true },
        found: @escaping @MainActor ([URL]) -> Void
    ) {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        self.folder = folder
        self.settleInterval = settleInterval
        self.accept = accept
        self.found = found
        detector = NewFileDetector(existing: Self.videos(in: folder).keys)
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.look() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    private func look() {
        let complete = detector.update(Self.videos(in: folder)).filter(accept)
        if !complete.isEmpty {
            found(complete)
        }
        recheck?.cancel()
        recheck = nil
        guard detector.isWaiting else { return }
        recheck = Task { [weak self, settleInterval] in
            try? await Task.sleep(for: settleInterval)
            guard !Task.isCancelled else { return }
            self?.look()
        }
    }

    /// The videos directly inside `folder`, with their sizes.
    private static func videos(in folder: URL) -> [URL: Int64] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        var videos: [URL: Int64] = [:]
        for url in contents where CompressionViewModel.isVideo(url) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            videos[url.standardizedFileURL] = Int64(values.fileSize ?? 0)
        }
        return videos
    }
}

/// Where macOS saves screen recordings, and how to tell them apart from other videos.
public enum ScreenRecordings {
    /// The folder chosen in the Screenshot app's Options (Desktop unless changed).
    public static var folder: URL {
        let defaults = UserDefaults(suiteName: "com.apple.screencapture")
        if let location = defaults?.string(forKey: "location"), !location.isEmpty {
            return URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// macOS tags its recordings with this extended attribute when it saves them. Unlike the file name it
    /// doesn't depend on the system language, and unlike Spotlight it's there as soon as the file is.
    public static func isRecording(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenRecording", nil, 0, 0, 0) >= 0
    }
}
