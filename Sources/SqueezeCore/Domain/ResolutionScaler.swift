import Foundation

public enum ResolutionScaler {
    /// Shrinks `size` so its long edge fits `maxLongEdge`, keeping the aspect ratio.
    ///
    /// Never upscales. Both dimensions are rounded to even numbers because 4:2:0 chroma
    /// subsampling (used by every H.264/HEVC hardware encoder) works on 2×2 blocks.
    /// Working on the long edge makes the result independent of the track's rotation.
    public static func fit(_ size: PixelSize, maxLongEdge: Int?) -> PixelSize {
        guard size.width > 0, size.height > 0 else { return size }
        guard let maxLongEdge, maxLongEdge > 0, size.longEdge > maxLongEdge else {
            return PixelSize(width: evenFloor(size.width), height: evenFloor(size.height))
        }
        let scale = Double(maxLongEdge) / Double(size.longEdge)
        return PixelSize(
            width: evenRounded(Double(size.width) * scale),
            height: evenRounded(Double(size.height) * scale)
        )
    }

    private static func evenRounded(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }

    private static func evenFloor(_ value: Int) -> Int {
        max(2, value - value % 2)
    }
}
