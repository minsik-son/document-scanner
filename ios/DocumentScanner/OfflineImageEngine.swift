import UIKit
import CoreImage
import Vision

enum OfflineImageEngine {
    static let context = CIContext(options: [.cacheIntermediates:false])
    static func output(_ image: CIImage) throws -> UIImage {
        guard let cg = context.createCGImage(image, from:image.extent) else { throw ScannerError.message("Image processing failed.") }; return UIImage(cgImage:cg)
    }
    static func restored(_ image: UIImage, amount: Double) throws -> UIImage {
        guard let input = CIImage(image:image), amount.isFinite, (0...1).contains(amount) else { throw ScannerError.message("Invalid restoration strength.") }
        let denoise = input.applyingFilter("CINoiseReduction",parameters:["inputNoiseLevel":0.025*amount,"inputSharpness":0.4])
        let tonal = denoise.applyingFilter("CIColorControls",parameters:[kCIInputContrastKey:1+0.18*amount,kCIInputSaturationKey:1+0.12*amount])
        return try output(tonal.applyingFilter("CIUnsharpMask",parameters:[kCIInputRadiusKey:1.5,kCIInputIntensityKey:amount*0.7]).cropped(to:input.extent))
    }
    struct Raster { var bytes:[UInt8]; let width:Int; let height:Int }
    static func raster(_ image: UIImage, maxSide:Int? = nil) throws -> Raster {
        guard let cg = image.cgImage else { throw ScannerError.message("Image unavailable.") }
        try Task.checkCancellation()
        guard cg.width <= 20000, cg.height <= 20000, cg.width * cg.height <= 48_000_000 else { throw ScannerError.message("This image exceeds the 48-megapixel editing budget.") }
        let scale = min(1,Double(maxSide ?? max(cg.width,cg.height))/Double(max(cg.width,cg.height)))
        let w = max(1,Int(Double(cg.width)*scale)), h = max(1,Int(Double(cg.height)*scale))
        var bytes = [UInt8](repeating:255,count:w*h*4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data:buffer.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg,in:CGRect(x:0,y:0,width:w,height:h)); return true
        }
        guard ok else { throw ScannerError.message("Not enough memory to edit this image.") }; return Raster(bytes:bytes,width:w,height:h)
    }
    static func image(_ raster: Raster) throws -> UIImage {
        let data = Data(raster.bytes)
        guard let provider = CGDataProvider(data:data as CFData), let cg = CGImage(width:raster.width,height:raster.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:raster.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { throw ScannerError.message("Could not save the edited image.") }
        return UIImage(cgImage:cg)
    }
    static func removeColoredMarks(_ input: UIImage, strength: Double) throws -> UIImage {
        var r = try raster(input)
        guard strength.isFinite, (0...1).contains(strength) else { throw ScannerError.message("Invalid cleanup strength.") }
        for i in stride(from:0,to:r.bytes.count,by:4) {
            if i % 16384 == 0 { try Task.checkCancellation() }
            let red = Double(r.bytes[i])/255, green = Double(r.bytes[i+1])/255, blue = Double(r.bytes[i+2])/255
            let high = max(red,green,blue), low = min(red,green,blue)
            let saturation = high-low
            // Dark ink is protected; this targets colored ink/highlighter, not black handwriting.
            if saturation > 0.12 && high > 0.4 {
                let whiten = strength*min(1,saturation*3)*min(1,(high-0.4)*4)
                for c in 0..<3 { r.bytes[i+c] = UInt8(min(255,Double(r.bytes[i+c])*(1-whiten)+255*whiten)) }
            }
        }
        return try image(r)
    }
    static func erase(_ input: UIImage, rect: CGRect) throws -> UIImage {
        guard rect.minX.isFinite,rect.minY.isFinite,rect.width.isFinite,rect.height.isFinite,rect.width > 0.002,rect.height > 0.002,CGRect(x:0,y:0,width:1,height:1).contains(rect) else { throw ScannerError.message("Drag a rectangle over the mark to erase.") }
        var r = try raster(input)
        let x0 = max(1,Int(rect.minX*Double(r.width))), x1 = min(r.width-2,Int(rect.maxX*Double(r.width)))
        let y0 = max(1,Int(rect.minY*Double(r.height))), y1 = min(r.height-2,Int(rect.maxY*Double(r.height)))
        guard x1 > x0,y1 > y0 else { throw ScannerError.message("Select a larger area away from the image edge.") }
        let source = r.bytes
        for y in y0...y1 { try Task.checkCancellation(); for x in x0...x1 {
            let tx = Double(x-x0)/Double(x1-x0), ty = Double(y-y0)/Double(y1-y0)
            let feather = min(1,Double(min(x-x0+1,x1-x+1,y-y0+1,y1-y+1))/3)
            for c in 0..<3 {
                let horizontal = Double(source[(y*r.width+x0-1)*4+c])*(1-tx)+Double(source[(y*r.width+x1+1)*4+c])*tx
                let vertical = Double(source[((y0-1)*r.width+x)*4+c])*(1-ty)+Double(source[((y1+1)*r.width+x)*4+c])*ty
                let i = (y*r.width+x)*4+c
                r.bytes[i] = UInt8(min(255,max(0,Double(source[i])*(1-feather)+(horizontal+vertical)*0.5*feather)))
            }
        } }
        return try image(r)
    }
    // A user-controlled cylindrical page model, followed by separate left/right pages.
    static func book(_ image: UIImage, split: Double, curve: Double, twoPages: Bool) throws -> [UIImage] {
        guard let cg = image.cgImage, (0.2...0.8).contains(split), (-0.2...0.2).contains(curve), split.isFinite,curve.isFinite else { throw ScannerError.message("Invalid book settings.") }
        let ranges: [CGRect] = twoPages ? [CGRect(x:0,y:0,width:Double(cg.width)*split,height:Double(cg.height)),CGRect(x:Double(cg.width)*split,y:0,width:Double(cg.width)*(1-split),height:Double(cg.height))] : [CGRect(x:0,y:0,width:cg.width,height:cg.height)]
        return try ranges.map { rect in
            try Task.checkCancellation()
            guard let part = cg.cropping(to:rect.integral) else { throw ScannerError.message("Could not split the book.") }
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
            return UIGraphicsImageRenderer(size:CGSize(width:part.width,height:part.height),format:f).image { ctx in
                UIColor.white.setFill();ctx.fill(CGRect(x:0,y:0,width:part.width,height:part.height))
                let strips = min(128,part.width)
                for i in 0..<strips {
                    if Task.isCancelled { return }
                    let left = i*part.width/strips, right = (i+1)*part.width/strips
                    let arch = sin(Double(i)/Double(max(1,strips-1))*Double.pi)*abs(curve)*Double(part.height)
                    // Move and compress the complete stripe; never crop away edge content.
                    let top = curve >= 0 ? arch : 0
                    if let stripe = part.cropping(to:CGRect(x:left,y:0,width:right-left,height:part.height)) {
                        UIImage(cgImage:stripe).draw(in:CGRect(x:Double(left),y:top,width:Double(right-left),height:Double(part.height)-arch))
                    }
                }
            }
        }
    }
    static func portrait(_ image: UIImage, blue: Bool, widthMM:Double, heightMM:Double) throws -> UIImage {
        guard let cg = image.cgImage, (20...60).contains(widthMM),(20...70).contains(heightMM) else { throw ScannerError.message("Invalid photo dimensions.") }
        let handler = VNImageRequestHandler(cgImage:cg), foreground = VNGenerateForegroundInstanceMaskRequest()
        try Task.checkCancellation()
        try handler.perform([foreground])
        try Task.checkCancellation()
        guard let observation = foreground.results?.first, !observation.allInstances.isEmpty else { throw ScannerError.message("No clear subject found. Use a portrait with a plain background.") }
        let mask = try observation.generateScaledMaskForImage(forInstances:observation.allInstances,from:handler)
        let base = CIImage(cgImage:cg), background = CIImage(color:CIColor(color:blue ? UIColor(red:0.35,green:0.62,blue:0.95,alpha:1) : .white)).cropped(to:base.extent)
        let composite = base.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:background,kCIInputMaskImageKey:CIImage(cvPixelBuffer:mask)])
        let faces = VNDetectFaceRectanglesRequest(); try handler.perform([faces])
        guard let face = faces.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })?.boundingBox else { throw ScannerError.message("No face found. Choose a front-facing portrait.") }
        let aspect = widthMM/heightMM
        var h = min(base.extent.height,max(face.height*base.extent.height/0.48,face.width*base.extent.width/aspect/0.65))
        var w = h*aspect
        if w > base.extent.width { w = base.extent.width; h = w/aspect }
        let x = min(base.extent.width-w,max(0,face.midX*base.extent.width-w/2))
        let y = min(base.extent.height-h,max(0,face.midY*base.extent.height-h*0.62))
        let cropped = composite.cropped(to:CGRect(x:x,y:y,width:w,height:h))
        let normalized = cropped.transformed(by:CGAffineTransform(translationX:-x,y:-y)).transformed(by:CGAffineTransform(scaleX:widthMM/25.4*300/w,y:heightMM/25.4*300/h))
        return try output(normalized)
    }
    static func count(_ image: UIImage, threshold:Double, minimumArea:Double, lightObjects:Bool) throws -> [CGPoint] {
        let r = try raster(image,maxSide:600)
        guard threshold.isFinite,minimumArea.isFinite,(0...1).contains(threshold),(0.0001...0.1).contains(minimumArea) else { throw ScannerError.message("Invalid counting settings.") }
        let n = r.width*r.height
        var marked = [Bool](repeating:false,count:n), result:[CGPoint] = []
        func active(_ i:Int) -> Bool { let l = (Double(r.bytes[i*4])+Double(r.bytes[i*4+1])+Double(r.bytes[i*4+2]))/765; return lightObjects ? l > threshold : l < threshold }
        for start in 0..<n where !marked[start] {
            if start % 4096 == 0 { try Task.checkCancellation() }
            marked[start] = true; guard active(start) else { continue }
            var queue = [start], head = 0, sx = 0, sy = 0
            while head < queue.count {
                if head % 4096 == 0 { try Task.checkCancellation() }
                let i = queue[head]; head += 1; sx += i%r.width; sy += i/r.width
                let neighbors = [(i%r.width > 0 ? i-1 : -1),(i%r.width+1 < r.width ? i+1 : -1),i-r.width,i+r.width]
                for j in neighbors where j >= 0 && j < n && !marked[j] { marked[j] = true; if active(j) { queue.append(j) } }
            }
            if Double(queue.count) >= Double(n)*minimumArea && Double(queue.count) < Double(n)*0.5 {
                result.append(CGPoint(x:Double(sx)/Double(queue.count)/Double(r.width),y:Double(sy)/Double(queue.count)/Double(r.height)))
                if result.count >= 500 { break }
            }
        }
        return result
    }
    static func alignment(reference:UIImage, floating:UIImage) throws -> CGPoint {
        guard let a = reference.cgImage,let b = floating.cgImage else { throw ScannerError.message("Images unavailable.") }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage:b,options:[:])
        try VNImageRequestHandler(cgImage:a,options:[:]).perform([request])
        guard let observation = request.results?.first,observation.confidence > 0.3 else { throw ScannerError.message("No reliable alignment. Match the overlap with the position sliders.") }
        let t = observation.alignmentTransform
        let p = CGPoint(x:t.tx,y:CGFloat(a.height-b.height)-t.ty)
        guard p.x.isFinite,p.y.isFinite,abs(p.x) < CGFloat(a.width)*0.9,abs(p.y) < CGFloat(a.height)*0.9 else { throw ScannerError.message("Use photos with more overlap or adjust the position manually.") }
        guard a.width == b.width,a.height == b.height else { throw ScannerError.message("Automatic alignment needs images of the same size. Use the position sliders for these photos.") }
        let left = try raster(reference,maxSide:600),right = try raster(floating,maxSide:600)
        let scale = Double(left.width)/Double(a.width),dx = Int((p.x*scale).rounded()),dy = Int((p.y*scale).rounded())
        var count = 0.0,sx = 0.0,sy = 0.0,sxx = 0.0,syy = 0.0,sxy = 0.0
        for y in stride(from:max(0,dy),to:min(left.height,right.height+dy),by:3) {
            for x in stride(from:max(0,dx),to:min(left.width,right.width+dx),by:3) {
                let i = (y*left.width+x)*4,j = ((y-dy)*right.width+x-dx)*4
                let u = Double(left.bytes[i])+Double(left.bytes[i+1])+Double(left.bytes[i+2]),v = Double(right.bytes[j])+Double(right.bytes[j+1])+Double(right.bytes[j+2])
                count += 1;sx += u;sy += v;sxx += u*u;syy += v*v;sxy += u*v
            }
        }
        let variance = max(0,(count*sxx-sx*sx)*(count*syy-sy*sy))
        guard count > 100,variance > 1,(count*sxy-sx*sy)/sqrt(variance) > 0.65 else { throw ScannerError.message("The overlap could not be verified. Adjust the position manually.") }
        return p
    }
    static func mega(_ images:[UIImage], offsets:[CGPoint]) throws -> UIImage {
        guard (2...8).contains(images.count),offsets.count == images.count,offsets.allSatisfy({$0.x.isFinite && $0.y.isFinite && abs($0.x)<20000 && abs($0.y)<20000}) else { throw ScannerError.message("Choose 2–8 images and check their positions.") }
        let rects = zip(images,offsets).map { CGRect(origin:$0.1,size:$0.0.size) }
        let bounds = rects.reduce(CGRect.null) { $0.union($1) }.integral
        guard bounds.width*bounds.height <= 32_000_000 else { throw ScannerError.message("The combined image is too large. Reduce the offsets or number of images.") }
        let format = UIGraphicsImageRendererFormat();format.scale = 1;format.opaque = true
        return UIGraphicsImageRenderer(size:bounds.size,format:format).image { ctx in
            UIColor.white.setFill();ctx.fill(CGRect(origin:.zero,size:bounds.size))
            for (i,image) in images.enumerated() { if Task.isCancelled { return }; image.draw(in:rects[i].offsetBy(dx:-bounds.minX,dy:-bounds.minY)) }
        }
    }
    static func pdf(_ images:[UIImage], millimeters:CGSize? = nil, text:[[TextBlock]] = []) throws -> Data {
        guard !images.isEmpty else { throw ScannerError.message("No images to save.") }
        return UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:612,height:792)).pdfData { ctx in
            for (index,image) in images.enumerated() {
                if Task.isCancelled { return }
                let size = millimeters.map { CGSize(width:$0.width/25.4*72,height:$0.height/25.4*72) } ?? CGSize(width:image.size.width*0.24,height:image.size.height*0.24)
                ctx.beginPage(withBounds:CGRect(origin:.zero,size:size),pageInfo:[:]); PDFJPEG.draw(image,quality:0.9,in:CGRect(origin:.zero,size:size),context:ctx.cgContext)
                if text.indices.contains(index) { PDFTextLayer.draw(blocks:text[index],in:ctx.cgContext,imageRect:CGRect(origin:.zero,size:size)) }
            }
        }
    }
}
