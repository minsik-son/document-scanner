import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Picture formats for saving pages as images. All are written by iOS itself
/// (ImageIO); WebP is left out because iOS can read it but not write it.
enum ImageExportFormat: String, CaseIterable, Identifiable {
    case jpg, png, heic, tiff, gif, bmp
    var id: String { rawValue }
    var title: String { rawValue == "jpg" ? "JPG" : rawValue.uppercased() }
    var fileExtension: String { rawValue }
    var type: UTType {
        switch self {
        case .jpg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        case .gif: return .gif
        case .bmp: return .bmp
        }
    }
    /// One line on what the format is for.
    var detail: String {
        switch self {
        case .jpg: return "Smaller files. Best for sharing and chat."
        case .png: return "No compression. Sharpest text, larger files."
        case .heic: return "iPhone's photo format. About half the size of JPG at the same quality."
        case .tiff: return "Lossless, for printing and archives. All pages can go in one file."
        case .gif: return "256 colours. Only for older systems that need it."
        case .bmp: return "Uncompressed, for older Windows programs. Very large files."
        }
    }
    /// HEIC needs the hardware encoder; check before offering a broken choice.
    var available: Bool {
        guard self == .heic else { return true }
        return (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier)
    }

    /// Writes one picture, or several as pages of one file (TIFF, GIF).
    static func write(_ images: [CGImage], format: ImageExportFormat, to url: URL) throws {
        guard !images.isEmpty, let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, images.count, nil) else {
            throw ScannerError.message(format == .heic ? "This iPhone can't make HEIC files. Choose JPG instead." : "Image export failed.")
        }
        var options: [CFString: Any] = [:]
        switch format {
        case .jpg: options[kCGImageDestinationLossyCompressionQuality] = 0.94
        case .heic: options[kCGImageDestinationLossyCompressionQuality] = 0.85
        case .tiff: options[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] // LZW, lossless
        default: break
        }
        for image in images {
            // GIF and BMP have no alpha worth keeping; flatten pages onto white.
            let picture = (format == .bmp || format == .gif || format == .jpg) ? opaque(image) : image
            CGImageDestinationAddImage(destination, picture, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ScannerError.message("Image export failed.") }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var file = url; try? file.setResourceValues(values)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
    }
    private static func opaque(_ image: CGImage) -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.setFillColor(UIColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }
}
