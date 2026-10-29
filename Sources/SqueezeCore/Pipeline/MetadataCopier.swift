@preconcurrency import AVFoundation
import Foundation

/// Carries the metadata Photos and Finder care about (capture date, location, device) into the output.
enum MetadataCopier {
    static let preservedIdentifiers: Set<AVMetadataIdentifier> = [
        .quickTimeMetadataCreationDate,
        .quickTimeMetadataLocationISO6709,
        .quickTimeMetadataMake,
        .quickTimeMetadataModel,
        .quickTimeMetadataSoftware,
        .commonIdentifierCreationDate,
        .commonIdentifierLocation,
        .commonIdentifierMake,
        .commonIdentifierModel
    ]

    static func items(from asset: AVAsset) async -> [AVMetadataItem] {
        guard let metadata = try? await asset.load(.metadata) else { return [] }
        var items = metadata.filter { item in
            item.identifier.map(preservedIdentifiers.contains) ?? false
        }
        let hasCreationDate = items.contains {
            $0.identifier == .quickTimeMetadataCreationDate || $0.identifier == .commonIdentifierCreationDate
        }
        // Screen recordings only have the date in the movie header, which the writer would replace with "now".
        if !hasCreationDate, let date = try? await asset.load(.creationDate)?.load(.dateValue) {
            items.append(creationDateItem(date))
        }
        return items
    }

    static func creationDateItem(_ date: Date) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataCreationDate
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = ISO8601DateFormatter().string(from: date) as NSString
        return item
    }
}
