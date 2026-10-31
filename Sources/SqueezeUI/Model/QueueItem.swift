import CoreGraphics
import Foundation
import Observation
import SqueezeCore

/// One file in the window: its analysis, its plan for the current settings and its conversion state.
@MainActor
@Observable
public final class QueueItem: Identifiable {
    public enum Phase: Equatable {
        /// Reading tracks and sampling motion.
        case analyzing
        /// Analysed; `preview` holds the plan for the current settings.
        case ready
        /// Waiting for its turn in a running batch.
        case queued
        case converting(progress: Double)
        case completed(ConversionResult)
        case failed(SqueezeError)
        case cancelled
    }

    public let id = UUID()
    public let url: URL
    public internal(set) var phase: Phase = .analyzing
    public internal(set) var thumbnail: Thumbnail?
    /// Plan and estimate for the current settings.
    public internal(set) var preview: ConversionPreview?
    /// Why the current settings can't be applied to this file (e.g. target size too small).
    public internal(set) var planError: SqueezeError?
    /// Set when the user accepted "try a more aggressive preset" for this file only.
    public internal(set) var presetOverride: Preset?
    /// The original went to the Trash after a successful, smaller conversion.
    public internal(set) var originalTrashed = false

    /// Source facts gathered once; every settings change re-plans from here without reading the file.
    var analysis: ConversionPreview?
    /// Added by the Finder action: start converting as soon as analysis finishes.
    var convertsWhenReady = false
    var conversion: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    public var name: String { url.lastPathComponent }

    public var info: MediaInfo? { analysis?.info }

    public var canConvert: Bool {
        guard preview != nil, planError == nil else { return false }
        switch phase {
        case .ready, .failed, .cancelled: return true
        case .analyzing, .queued, .converting, .completed: return false
        }
    }

    public var isBusy: Bool {
        switch phase {
        case .queued, .converting: true
        default: false
        }
    }

    public var result: ConversionResult? {
        if case .completed(let result) = phase { return result }
        return nil
    }

    public var error: SqueezeError? {
        if case .failed(let error) = phase { return error }
        return planError
    }
}
