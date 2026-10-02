import UIKit
import ImageIO

/// Propagate cancellation into CPU work, and never publish a canceled result.
enum OfflineWork {
    static func perform<Value>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try operation()
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    /// Decode at native resolution with EXIF orientation applied. Refuse excessive
    /// allocations explicitly instead of quietly reducing export quality.
    static func photo(_ data: Data, remainingPixels: Int = 48_000_000) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 20000,
              width * height <= min(48_000_000, remainingPixels) else {
            throw ScannerError.message("These photos exceed the 48-megapixel editing budget. Choose fewer or smaller photos. Their resolution has not been reduced.")
        }
        try Task.checkCancellation()
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ScannerError.message("Could not open this photo.")
        }
        return UIImage(cgImage: image)
    }
}
