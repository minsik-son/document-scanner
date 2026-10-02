import CoreImage.CIFilterBuiltins

// Restore photographed stroke contrast locally. This filter never retypes,
// reconstructs or invents letters; all detail comes from neighboring image pixels.
enum DocumentClarity {
    private static let kernel = CIColorKernel(source: """
    kernel vec4 documentClarity(__sample source, __sample blurred,
                                __sample localWhite, __sample localLow,
                                float amount) {
        vec3 weights = vec3(0.2126, 0.7152, 0.0722);
        // Core Image keeps extended (including negative) channels between filters.
        // Clip the analysis range so a contrast-adjusted black cannot invert white.
        vec3 sourceRGB = clamp(source.rgb,0.0,1.0);
        vec3 softRGB = clamp(blurred.rgb,0.0,1.0);
        float y = dot(sourceRGB, weights);
        float softY = dot(softRGB, weights);
        float whiteY = max(0.001, dot(clamp(localWhite.rgb,0.0,1.0), weights));
        float lowY = dot(clamp(localLow.rgb,0.0,1.0), weights);
        float contrast = max(0.0, (whiteY-y)/whiteY);
        float range = whiteY-lowY;

        // Gentle smoothing is confined to surfaces without appreciable local
        // strokes. A faint pencil line has range, even if its core is not dark.
        float surface = (1.0-smoothstep(0.035, 0.10, range));
        vec3 base = mix(sourceRGB, softRGB, surface*0.65);
        float baseY = dot(base, weights);

        // Sharpen within the neighboring luminance bounds, then reinforce only
        // convincing dark strokes. This avoids bright outlines around glyphs.
        float stroke = smoothstep(0.18, 0.55, contrast);
        float sharpened = clamp(baseY+(y-softY)*1.35*amount*stroke, lowY, whiteY);
        float high = max(sourceRGB.r, max(sourceRGB.g, sourceRGB.b));
        float low = min(sourceRGB.r, min(sourceRGB.g, sourceRGB.b));
        float saturation = (high-low)/max(0.001,high);
        float neutral = 1.0-smoothstep(0.12, 0.5, saturation);
        float dark = 1.0-smoothstep(0.35, 0.65, high);
        float ink = stroke*max(neutral,dark);
        float target = sharpened*(1.0-min(0.94,0.86*amount)*ink);
        vec3 enhancedRGB = base*target/max(0.001,baseY);
        return vec4(clamp(enhancedRGB,0.0,1.0),source.a);
    }
    """)

    static func enhance(_ image: CIImage, strength: CGFloat = 1) throws -> CIImage {
        guard let kernel else { throw ScannerError.message("Text clarity enhancement couldn't be loaded. Try the Original filter.") }
        let extent = image.extent
        let amount = min(1.5,max(0.5,strength))
        let clamped = image.clampedToExtent()
        // Radius follows capture resolution, with a cap so a high-resolution scan
        // never interprets a whole colored cell as the background of a letter.
        let scale = min(1.6,max(0.8,max(extent.width,extent.height)/2200))
        let smooth = clamped.applyingFilter("CIGaussianBlur",parameters: [kCIInputRadiusKey: 0.65*scale]).cropped(to: extent)
        let white = clamped.applyingFilter("CIMorphologyMaximum",parameters: [kCIInputRadiusKey: 4.5*scale]).cropped(to: extent)
        let low = clamped.applyingFilter("CIMorphologyMinimum",parameters: [kCIInputRadiusKey: 1.5*scale]).cropped(to: extent)
        guard let result = kernel.apply(extent: extent,arguments: [image,smooth,white,low,amount]) else {
            throw ScannerError.message("Text clarity enhancement couldn't be applied. Try the Original filter.")
        }
        return result.cropped(to: extent)
    }
}
