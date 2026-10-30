import CoreGraphics

/// Decides when the drop shelf under the menu bar icon should open during a file drag.
///
/// It opens only while videos are being dragged *towards the top of the screen*, so dragging a movie
/// into another app in the middle of the screen never pops anything up.
public struct DropShelfTrigger: Sendable {
    /// How close to the top edge (in points) the cursor must get.
    public var activationDistance: CGFloat

    public init(activationDistance: CGFloat = 140) {
        self.activationDistance = activationDistance
    }

    /// - Parameters:
    ///   - cursorY: cursor position in AppKit screen coordinates (origin at the bottom).
    ///   - screenTop: `maxY` of the screen the cursor is on.
    ///   - draggingVideos: whether the drag pasteboard holds something `CompressionViewModel.accepts`.
    public func shouldOpen(cursorY: CGFloat, screenTop: CGFloat, draggingVideos: Bool) -> Bool {
        draggingVideos && screenTop - cursorY <= activationDistance
    }
}
