import UIKit

// Used only by PhotoTranslation. Coordinates are pixels, with a top-left origin.
struct TranslationRaster {
    let width:Int
    let height:Int
    var pixels:[UInt8]
    var bounds:CGRect { CGRect(x:0,y:0,width:width,height:height) }
    init(_ image:CGImage) throws {
        width = image.width;height = image.height
        var data = [UInt8](repeating:0,count:width*height*4)
        let ok = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let c = CGContext(data:bytes.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return true
        }
        guard ok else { throw ScannerError.message("The scan couldn't be read.") }
        pixels = data
    }
    func color(_ x:Int,_ y:Int) -> [UInt8] { let i = (y*width+x)*4;return Array(pixels[i..<i+3]) }
    static func median(_ values:[[UInt8]]) -> [UInt8] {
        guard !values.isEmpty else { return [255,255,255] }
        return (0..<3).map { c in values.map { $0[c] }.sorted()[values.count/2] }
    }
    static func distance(_ a:[UInt8],_ b:[UInt8]) -> Int { (0..<3).map { abs(Int(a[$0])-Int(b[$0])) }.max() ?? 0 }
    func pixelBox(_ box:CGRect) -> CGRect {
        CGRect(x:box.minX*CGFloat(width),y:box.minY*CGFloat(height),width:box.width*CGFloat(width),height:box.height*CGFloat(height))
    }
    /// Empty strips may be used for paragraph reflow; rules, pictures and unrecognized ink block expansion.
    func empty(_ region:CGRect,background:[UInt8]? = nil) -> Bool {
        let rect = region.integral.intersection(bounds)
        guard rect.width >= 1,rect.height >= 1 else { return true }
        var samples:[[UInt8]] = []
        for y in stride(from:Int(rect.minY),to:Int(rect.maxY),by:2) {
            for x in stride(from:Int(rect.minX),to:Int(rect.maxX),by:2) { samples.append(color(x,y)) }
        }
        let bg = background ?? Self.median(samples)
        return samples.filter { Self.distance($0,bg) > 35 }.count <= samples.count/100
    }
    struct Ink {
        var mask:[Int]
        let rows:[[UInt8]]
        let y:Int
        let foreground:UIColor
        let background:[UInt8]
        let rect:CGRect
        let glyphHeight:CGFloat
    }
    /// Find connected ink, protect long rules, and reconstruct only the ink pixels.
    /// Per-row paper estimates tolerate illumination gradients without flattening the whole rectangle.
    func ink(core:CGRect,lineHeight:CGFloat) -> Ink? {
        let rect = core.insetBy(dx:-2,dy:-2).integral.intersection(bounds)
        let x0 = Int(rect.minX),y0 = Int(rect.minY),rw = Int(rect.width),rh = Int(rect.height)
        guard rw >= 6,rh >= 6 else { return nil }
        var border:[[UInt8]] = []
        for x in x0..<(x0+rw) { border.append(color(x,y0));border.append(color(x,y0+rh-1)) }
        for y in y0..<(y0+rh) { border.append(color(x0,y));border.append(color(x0+rw-1,y)) }
        let bg = Self.median(border)
        let top = Self.median((0..<rw).map { color(x0+$0,y0) })
        let bottom = Self.median((0..<rw).map { color(x0+$0,y0+rh-1) })
        let topPaper = Self.distance(top,bg) < 42 ? top : bg
        let bottomPaper = Self.distance(bottom,bg) < 42 ? bottom : bg
        var rows:[[UInt8]] = [], candidates = [Bool](repeating:false,count:rw*rh)
        for y in 0..<rh {
            var samples:[[UInt8]] = []
            for x in 0..<rw { samples.append(color(x+x0,y+y0)) }
            let fraction = Double(y)/Double(max(1,rh-1))
            // Interpolate clean border paper, never the ink-heavy interior row (which creates stripes).
            rows.append((0..<3).map { UInt8((Double(topPaper[$0])*(1-fraction)+Double(bottomPaper[$0])*fraction).rounded()) })
            for x in 0..<rw { candidates[y*rw+x] = Self.distance(samples[x],rows[y]) > 22 }
        }
        var seen = [Bool](repeating:false,count:rw*rh), mask = Set<Int>(),dark:[[UInt8]] = [],protected = Set<Int>()
        var safeRect = rect
        var glyphHeights:[CGFloat] = []
        for start in candidates.indices where candidates[start] && !seen[start] {
            if Task.isCancelled { return nil }
            var component = [start],head = 0;seen[start] = true
            var minX = rw,maxX = 0,minY = rh,maxY = 0
            while head < component.count {
                let at = component[head];head += 1;let x = at%rw,y = at/rw
                minX = min(minX,x);maxX = max(maxX,x);minY = min(minY,y);maxY = max(maxY,y)
                for (dx,dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                    let xx = x+dx,yy = y+dy
                    if xx >= 0 && xx < rw && yy >= 0 && yy < rh {
                        let n = yy*rw+xx
                        if candidates[n] && !seen[n] { seen[n] = true;component.append(n) }
                    }
                }
            }
            let box = CGRect(x:x0+minX,y:y0+minY,width:maxX-minX+1,height:maxY-minY+1)
            let horizontal = box.width > max(lineHeight*2.5,CGFloat(rw)*0.65) && box.height < max(4,lineHeight*0.2)
            let vertical = minY == 0 && maxY == rh-1 && box.width < max(4,lineHeight*0.2)
            if horizontal || vertical || !box.intersects(core) {
                protected.formUnion(component)
                if horizontal && box.midY < core.minY+lineHeight*0.2 { safeRect.origin.y = box.maxY+1;safeRect.size.height = rect.maxY-safeRect.minY }
                else if horizontal && box.midY > core.maxY-lineHeight*0.2 { safeRect.size.height = box.minY-1-safeRect.minY }
                else if vertical && box.midX < core.minX+lineHeight*0.2 { safeRect.origin.x = box.maxX+1;safeRect.size.width = rect.maxX-safeRect.minX }
                else if vertical && box.midX > core.maxX-lineHeight*0.2 { safeRect.size.width = box.minX-1-safeRect.minX }
                else if box.intersects(core) { return nil }
                continue
            }
            // Large filled components are illustrations, not removable glyphs.
            if component.count > rw*rh/3 { return nil }
            if component.count >= 5,box.height >= max(3,lineHeight*0.18),box.width < lineHeight*2 { glyphHeights.append(box.height) }
            for local in component {
                let x = local%rw,y = local/rw,c = color(x+x0,y+y0)
                if Self.distance(c,rows[y]) > 60 { dark.append(c) }
                mask.insert(local)
            }
        }
        guard dark.count > 3,dark.count < rw*rh*55/100,safeRect.width > 5,safeRect.height > 5 else { return nil }
        let fg = (0..<3).map { c in dark.map { $0[c] }.sorted()[dark.count/5] }
        let direction = (0..<3).map { Double(fg[$0])-Double(bg[$0]) }
        let length = max(1,direction.reduce(0) { $0+$1*$1 })
        let varied = dark.filter { c in
            let fraction = min(1,max(0,(0..<3).reduce(0.0) { $0+(Double(c[$1])-Double(bg[$1]))*direction[$1] }/length))
            return (0..<3).contains { abs(Double(c[$0])-(Double(bg[$0])+direction[$0]*fraction)) > 38 }
        }.count
        guard varied < dark.count/4+1 else { return nil }
        var expanded = mask
        for i in mask {
            let x = i%rw,y = i/rw
            for dy in -1...1 { for dx in -1...1 {
                let xx = x+dx,yy = y+dy,n = yy*rw+xx
                if xx >= 0 && xx < rw && yy >= 0 && yy < rh && !protected.contains(n) { expanded.insert(n) }
            } }
        }
        let global = expanded.map { (($0/rw+y0)*width+($0%rw+x0))*4 }
        return Ink(mask:global,rows:rows,y:y0,foreground:UIColor(red:CGFloat(fg[0])/255,green:CGFloat(fg[1])/255,blue:CGFloat(fg[2])/255,alpha:1),background:bg,rect:safeRect,glyphHeight:glyphHeights.isEmpty ? lineHeight*0.7 : glyphHeights.sorted()[min(glyphHeights.count-1,glyphHeights.count*3/4)])
    }
    mutating func erase(_ ink:Ink) {
        for i in ink.mask {
            let row = ink.rows[i/4/width-ink.y]
            pixels[i] = row[0];pixels[i+1] = row[1];pixels[i+2] = row[2];pixels[i+3] = 255
        }
    }
}

enum TranslationParagraphs {
    private static func sameScript(_ a:String,_ b:String) -> Bool {
        func script(_ text:String) -> Int {
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            let counts = letters.reduce(into:[Int:Int]()) { counts,c in
                let v = c.value
                let group = (0xAC00...0xD7FF).contains(v) ? 1 : (0x3040...0x30FF).contains(v) ? 2 : (0x3400...0x9FFF).contains(v) ? 3 : (0x0600...0x08FF).contains(v) ? 4 : 0
                counts[group,default:0] += 1
            }
            return counts.max { $0.value < $1.value }?.key ?? 0
        }
        return script(a) == script(b)
    }
    // Vision can join a paragraph with a distant label on the same baseline. Recover
    // columns from word geometry while slicing the original string (including punctuation).
    static func splitColumns(_ block:TextBlock,raster:TranslationRaster) -> [TextBlock] {
        guard let words = block.words,words.count > 1 else { return [block] }
        var ranges:[Range<String.Index>] = [],cursor = block.text.startIndex
        for word in words {
            guard let range = block.text.range(of:word.text,range:cursor..<block.text.endIndex) else { return [block] }
            ranges.append(range);cursor = range.upperBound
        }
        func rect(_ word:TextWord) -> CGRect { raster.pixelBox(CGRect(x:word.x,y:word.y,width:word.width,height:word.height)) }
        var starts = [0]
        for i in 1..<words.count {
            let a = rect(words[i-1]),b = rect(words[i]),h = max(1,min(a.height,b.height))
            let gap = max(b.minX-a.maxX,a.minX-b.maxX)
            let vertical = max(0,min(a.maxY,b.maxY)-max(a.minY,b.minY))/h
            if gap > h*2 || (gap > h*0.6 && max(a.height,b.height) > h*1.8) || vertical < 0.25 { starts.append(i) }
        }
        guard starts.count > 1 else { return [block] }
        starts.append(words.count)
        return zip(starts,starts.dropFirst()).map { start,end in
            let group = Array(words[start..<end])
            let box = group.map { CGRect(x:$0.x,y:$0.y,width:$0.width,height:$0.height) }.reduce(CGRect.null) { $0.union($1) }
            let lower = start == 0 ? block.text.startIndex : ranges[start].lowerBound
            let upper = end == words.count ? block.text.endIndex : ranges[end].lowerBound
            return TextBlock(text:String(block.text[lower..<upper]).trimmingCharacters(in:.whitespacesAndNewlines),x:box.minX,y:box.minY,width:box.width,height:box.height,words:group,confidence:block.confidence)
        }
    }
    /// A leading list marker (•, ①, "1.") is kept as photographed pixels, and the item
    /// text starts after it, so continuation lines indented under the text align with it.
    /// Vision often reads a circled numeral as "I", "Q", "@" or "1"; a single, roughly
    /// square glyph followed by a gap is treated as a marker too (a real word "I" is narrow).
    static func splitMarker(_ block:TextBlock,raster:TranslationRaster) -> (marker:TextBlock?,body:TextBlock) {
        guard let words = block.words,words.count >= 2 else { return (nil,block) }
        let first = words[0],second = words[1]
        let a = raster.pixelBox(CGRect(x:first.x,y:first.y,width:first.width,height:first.height))
        let b = raster.pixelBox(CGRect(x:second.x,y:second.y,width:second.width,height:second.height))
        let h = max(1,max(a.height,b.height))
        let token = first.text
        let explicit = token.range(of:"^([•●■◆▶▪·*-]|[①-⑳]|[0-9]{1,2}[.)])$",options:.regularExpression) != nil
        let misread = token.count == 1 && "IlQ@O0123456789".contains(token) && a.width >= a.height*0.6
        guard explicit || misread,b.minX-a.maxX >= h*0.2,
              let tokenRange = block.text.range(of:token),
              let range = block.text.range(of:second.text,range:tokenRange.upperBound..<block.text.endIndex) else { return (nil,block) }
        let rest = Array(words.dropFirst())
        let box = rest.map { CGRect(x:$0.x,y:$0.y,width:$0.width,height:$0.height) }.reduce(CGRect.null) { $0.union($1) }
        let body = TextBlock(text:String(block.text[range.lowerBound...]).trimmingCharacters(in:.whitespacesAndNewlines),
                             x:box.minX,y:box.minY,width:box.width,height:box.height,words:rest,confidence:block.confidence)
        let marker = TextBlock(text:token,x:first.x,y:first.y,width:first.width,height:first.height,words:[first],confidence:block.confidence)
        return (marker,body)
    }
    /// Only join aligned continuation lines. Buttons, headings, columns and ruled cells remain separate.
    static func group(_ input:[TextBlock],raster:TranslationRaster) -> [TranslationRegion] {
        var blocks:[TextBlock] = [],markers:[TextBlock] = [],itemStarts:[TextBlock] = []
        for block in input.flatMap({ splitColumns($0,raster:raster) }) {
            let split = splitMarker(block,raster:raster)
            if let marker = split.marker { markers.append(marker);itemStarts.append(split.body) }
            blocks.append(split.body)
        }
        let obstacles = blocks+markers
        var groups:[[TextBlock]] = []
        for block in blocks.sorted(by:{ $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }) {
            let current = raster.pixelBox(CGRect(x:block.x,y:block.y,width:block.width,height:block.height))
            let index = groups.indices.reversed().first { i in
                guard let last = groups[i].last else { return false }
                let previous = raster.pixelBox(CGRect(x:last.x,y:last.y,width:last.width,height:last.height))
                let h = min(previous.height,current.height),gap = current.minY-previous.maxY
                guard gap >= -h*0.3,gap < h*0.9,
                      max(previous.height,current.height) < h*1.28,
                      abs(current.minX-previous.minX) < h*0.75,
                      previous.width > h*5,current.width > h*4,
                      sameScript(last.text,block.text),
                      !last.text.trimmingCharacters(in:.whitespaces).hasSuffix(":"),
                      !last.text.trimmingCharacters(in:.whitespaces).hasSuffix("."),
                      !itemStarts.contains(block),
                      block.text.range(of:"^[•●■①②③④⑤]|^[0-9]+[.)]\\s",options:.regularExpression) == nil else { return false }
                let union = previous.union(current)
                // Never merge around another column/cell/label.
                guard !obstacles.contains(where:{ other in
                    if other == last || other == block { return false }
                    let b = raster.pixelBox(CGRect(x:other.x,y:other.y,width:other.width,height:other.height))
                    let overlap = b.intersection(union)
                    return overlap.width > h*0.2 && overlap.height > h*0.2 && !groups[i].contains(other)
                }) else { return false }
                let between = CGRect(x:union.minX,y:previous.maxY+1,width:union.width,height:max(0,gap-2))
                return raster.empty(between)
            }
            if let index { groups[index].append(block) } else { groups.append([block]) }
        }
        var regions = groups.enumerated().map { id,lines -> TranslationRegion in
            let boxes = lines.map { CGRect(x:$0.x,y:$0.y,width:$0.width,height:$0.height) }
            let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
            return TranslationRegion(id:id,source:lines.map(\.text).joined(separator:" "),box:union,sourceBoxes:boxes,
                                     confidence:lines.compactMap(\.confidence).min() ?? 1)
        }
        for marker in markers {
            regions.append(TranslationRegion(id:regions.count,source:marker.text,
                                             box:CGRect(x:marker.x,y:marker.y,width:marker.width,height:marker.height),
                                             keepOriginal:true,isMarker:true))
        }
        return regions.sorted { $0.box.minY == $1.box.minY ? $0.box.minX < $1.box.minX : $0.box.minY < $1.box.minY }
    }
}
