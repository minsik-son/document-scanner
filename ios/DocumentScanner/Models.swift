import Foundation
import CoreGraphics

struct ScanPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var cg: CGPoint { CGPoint(x: x, y: y) }
}
struct ScanQuad: Codable, Equatable {
    // Top-left-origin normalized coordinates; clockwise.
    var points: [ScanPoint]
    static let full = ScanQuad(points: [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)])
    var valid: Bool {
        guard points.count == 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
        let cross = (0..<4).map { i -> Double in
            let a = points[i], b = points[(i+1)%4], c = points[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        return cross.allSatisfy { $0 > 0.002 }
    }
}
enum Enhancement: String, Codable, CaseIterable { case original = "Original", document = "Document", mono = "Black & white" }
struct PageAdjustments: Codable, Equatable {
    var brightness: Double = 0
    var contrast: Double = 1
    var sharpness: Double = 0
    var bounded: PageAdjustments {
        func limit(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        return PageAdjustments(brightness: limit(brightness, -0.25...0.25, fallback: 0),
                               contrast: limit(contrast, 0.7...1.6, fallback: 1),
                               sharpness: limit(sharpness, -1...1, fallback: 0))
    }
}
enum PaperSize: String, Codable, CaseIterable {
    case a4 = "A4", letter = "US Letter", original = "Original"
    var size: CGSize { self == .letter ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89) }
}
enum PageMargin: String, Codable, CaseIterable {
    case none = "None", small = "Small", standard = "Standard"
    var points: CGFloat { self == .none ? 0 : (self == .small ? 18 : 36) }
}
struct TextBlock: Codable, Equatable {
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    // Word bounds keep selections on the photographed words, including mixed scripts
    // and table columns. Optional so earlier local libraries still decode.
    var words: [TextWord]?
    // Recognition confidence (0...1) when the reader reported one; not persisted by older builds.
    var confidence: Float? = nil
}
struct TextWord: Codable, Equatable {
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}
struct PageTrim: Codable, Equatable {
    var top: Double = 0
    var right: Double = 0
    var bottom: Double = 0
    var left: Double = 0
    static let zero = PageTrim()
    var valid: Bool { [top,right,bottom,left].allSatisfy { $0.isFinite && (0...0.45).contains($0) } && top+bottom < 0.9 && left+right < 0.9 }
    func rect(in size: CGSize) -> CGRect {
        CGRect(x:left*size.width,y:top*size.height,width:(1-left-right)*size.width,height:(1-top-bottom)*size.height)
    }
    func rotatedClockwise() -> PageTrim { PageTrim(top:left,right:top,bottom:right,left:bottom) }
}
/// Spots painted out with Smart erase in the page editor. Strokes are
/// normalized to the finished page, so they only apply while the crop, rotation
/// and margins they were painted on are unchanged.
struct PageErasure: Codable, Equatable {
    struct Stroke: Codable, Equatable { var points: [CGPoint]; var width: Double }
    var strokes: [Stroke]
    var crop: ScanQuad
    var turns: Int
    var trim: PageTrim?
}
struct ScanPage: Codable, Identifiable, Equatable {
    var id = UUID()
    var imageFile: String
    var crop: ScanQuad = .full
    var edgeTrim: PageTrim?
    var trimming: PageTrim {
        get { edgeTrim ?? .zero }
        set { edgeTrim = newValue == .zero ? nil : newValue }
    }
    var turns = 0
    var enhancement: Enhancement = .original
    // Optional fields preserve decoding of libraries created by 0.1.0.
    var enhancementAmount: Double?
    var adjustments: PageAdjustments?
    var appearance: PageAdjustments {
        get { (adjustments ?? PageAdjustments()).bounded }
        set { adjustments = newValue.bounded }
    }
    var cropReviewNeeded: Bool?
    var identityBackgroundCleanup: Bool?
    var enhancementStrength: Double {
        get { enhancementAmount ?? 1 }
        set { enhancementAmount = newValue }
    }
    var textBlocks: [TextBlock] = []
    var ocrComplete = false
    // OCR coordinates are valid only for the processing pipeline that produced them.
    var ocrProcessingVersion: Int?
    var sourcePDF: String?
    var sourcePDFPage: Int?
    var annotations: [PageAnnotation]?
    var correctedText: Bool?
    var erasures: [PageErasure]?
    /// Erasures painted on the current crop, rotation and margins.
    var activeErasures: [PageErasure] { (erasures ?? []).filter { $0.crop == crop && $0.turns == turns && ($0.trim ?? .zero) == trimming } }
    var preservesPDF: Bool { sourcePDF != nil && correctedText != true && crop == .full && enhancement == .original && appearance == PageAdjustments() && activeErasures.isEmpty }
    var plainText: String { textBlocks.map(\.text).joined(separator: "\n") }
}
struct ScanDocument: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var folder = "Scans"
    var createdAt = Date()
    var updatedAt = Date()
    var favorite = false
    var deletedAt: Date?
    var isDraft = true
    var pages: [ScanPage] = []
    var pdfFile: String?
    var paper: PaperSize = .letter
    var margin: PageMargin = .small
    var searchable = false
    var editingOriginalID: UUID?
    var landscape: Bool?
    var captureStyle: CaptureStyle?
    var outputSize: CGSize { landscape == true ? CGSize(width: paper.size.height, height: paper.size.width) : paper.size }
    var assetNames: [String] { pages.map(\.imageFile) + pages.compactMap(\.sourcePDF) + [pdfFile].compactMap { $0 } }
    mutating func applyAppearance(from page: ScanPage) {
        for i in pages.indices {
            pages[i].enhancement = page.enhancement; pages[i].appearance = page.appearance; pages[i].enhancementStrength = page.enhancementStrength
            pages[i].ocrComplete = false; pages[i].correctedText = nil
        }
        searchable = false
    }
    var text: String { pages.map(\.plainText).joined(separator: "\n") }
    var textStatus: String {
        let n = pages.filter { $0.ocrComplete && !$0.textBlocks.isEmpty }.count
        if searchable { return n == pages.count ? "Searchable PDF" : "Selectable text on \(n) of \(pages.count) pages" }
        return "Image only"
    }
}
struct LibraryManifest: Codable {
    var version = 1
    var documents: [ScanDocument] = []
    var folders = ["Scans", "Home", "Receipts", "School"]
    var lastBackupCreated: Date?
    var signatures: [PageAnnotation]?
}

enum AnnotationKind: String, Codable, CaseIterable { case signature = "Signature", text = "Text", pen = "Pen", highlight = "Highlight" }
struct PageAnnotation: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: AnnotationKind
    var x: Double = 0.1
    var y: Double = 0.1
    var width: Double = 0.4
    var height: Double = 0.12
    var text: String = ""
    var strokes: [[ScanPoint]] = []
    var imageData: Data?
    var color: String = "black"
    var lineWidth: Double = 2
    var valid: Bool {
        [x,y,width,height,lineWidth].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x+width <= 1.001 && y+height <= 1.001 && (0.1...100).contains(lineWidth) &&
        strokes.allSatisfy { $0.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) } }
    }
}
enum ScannerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
