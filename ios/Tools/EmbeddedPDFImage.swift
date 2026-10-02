import Foundation
import CoreGraphics
import ImageIO

// Local quality checks on our image-only exported PDFs should use the embedded
// full-resolution photo rather than a reduced page thumbnail.
enum EmbeddedPDFImage {
    private final class Images { var values: [CGImage] = [] }
    static func singlePhoto(_ page: CGPDFPage) -> CGImage? {
        guard let dictionary = page.dictionary else { return nil }
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return nil }
        let box = Images()
        CGPDFDictionaryApplyFunction(objects, { _, value, pointer in
            guard let pointer else { return }
            let box = Unmanaged<Images>.fromOpaque(pointer).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" else { return }
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format) else { return }
            if format != .raw {
                if let source = CGImageSourceCreateWithData(data, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { box.values.append(image) }
                return
            }
            var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bits: CGPDFInteger = 0
            var colorName: UnsafePointer<CChar>?
            let colorSpace: CGColorSpace?
            if CGPDFDictionaryGetName(dictionary, "ColorSpace", &colorName), let colorName, String(cString: colorName) == "DeviceRGB" {
                colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            } else {
                var array: CGPDFArrayRef?, profile: CGPDFStreamRef?, name: UnsafePointer<CChar>?
                var profileFormat = CGPDFDataFormat.raw
                if CGPDFDictionaryGetArray(dictionary, "ColorSpace", &array), let array,
                   CGPDFArrayGetName(array, 0, &name), let name, String(cString: name) == "ICCBased",
                   CGPDFArrayGetStream(array, 1, &profile), let profile,
                   let icc = CGPDFStreamCopyData(profile, &profileFormat) { colorSpace = CGColorSpace(iccData: icc) }
                else { colorSpace = nil }
            }
            guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
                  CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits), bits == 8,
                  width > 0, height > 0, width <= 12000, height <= 12000,
                  let colorSpace, colorSpace.model == .rgb,
                  CFDataGetLength(data) == width*height*3,
                  let provider = CGDataProvider(data: data),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width*3, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
            box.values.append(image)
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.values.count == 1 ? box.values[0] : nil
    }
}
