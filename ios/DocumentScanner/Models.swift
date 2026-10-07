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
    /// What kind of paper this is, found from its text on this iPhone.
    var kind: DocumentKind?
    /// The user picked the kind themselves; automatic sorting leaves it alone.
    var kindChosen: Bool?
    /// The name was made automatically, so a better one can replace it on save.
    var autoTitled: Bool?
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


// MARK: - Smart naming and sorting (on-device rules, no network)

enum DocumentKind: String, Codable, CaseIterable, Identifiable {
    case receipt, invoice, idCard, businessCard, contract, form, letter, book, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .receipt: return "Receipt"
        case .invoice: return "Invoice"
        case .idCard: return "ID card"
        case .businessCard: return "Business card"
        case .contract: return "Contract"
        case .form: return "Form"
        case .letter: return "Letter"
        case .book: return "Book"
        case .other: return "Other"
        }
    }
    var plural: String {
        switch self {
        case .receipt: return "Receipts"
        case .invoice: return "Invoices"
        case .idCard: return "IDs"
        case .businessCard: return "Business cards"
        case .contract: return "Contracts"
        case .form: return "Forms"
        case .letter: return "Letters"
        case .book: return "Books"
        case .other: return "Other"
        }
    }
    var symbol: String {
        switch self {
        case .receipt: return "receipt"
        case .invoice: return "doc.text.below.ecg"
        case .idCard: return "person.text.rectangle"
        case .businessCard: return "person.crop.rectangle"
        case .contract: return "signature"
        case .form: return "list.bullet.clipboard"
        case .letter: return "envelope"
        case .book: return "book"
        case .other: return "doc"
        }
    }
}

/// Sorts a document into a kind and suggests a name from its recognized text.
/// Everything runs locally with keyword rules and Apple's data detectors.
enum DocumentInsight {
    private static let keywords: [DocumentKind: [String]] = [
        .receipt: ["receipt", "subtotal", "sub total", "total", "tax", "gst", "pst", "hst", "visa", "mastercard", "debit", "change due", "cash", "approved", "auth", "thank you for shopping", "영수증", "합계", "부가세", "승인번호", "카드번호", "받을금액", "결제"],
        .invoice: ["invoice", "bill to", "billed to", "due date", "amount due", "balance due", "payment due", "statement", "account number", "청구서", "세금계산서", "납부", "고지서", "청구금액", "납기"],
        .idCard: ["driver", "licence", "license", "passport", "date of birth", "dob", "expiry", "expires", "nationality", "identification", "주민등록증", "운전면허", "여권", "생년월일"],
        .contract: ["agreement", "contract", "terms and conditions", "hereby", "party", "parties", "signature", "signed", "witness", "lease", "tenant", "landlord", "계약서", "계약", "갑", "을", "서명", "임대인", "임차인"],
        .form: ["application", "form", "please print", "check one", "applicant", "office use only", "consent", "신청서", "서식", "신청인", "작성"],
        .letter: ["dear ", "sincerely", "regards", "yours truly", "to whom it may concern", "귀하", "드림", "올림"],
    ]

    static func classify(_ doc: ScanDocument) -> DocumentKind {
        let text = doc.text
        let lower = text.lowercased()
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let contacts = contactCount(text)
        var scores: [DocumentKind: Int] = [:]
        for (kind, words) in keywords { scores[kind] = words.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) } }
        if doc.captureStyle == .card {
            // Card camera: an ID unless it reads like a business card.
            if (scores[.idCard] ?? 0) == 0 && contacts >= 2 { return .businessCard }
            return .idCard
        }
        if lines.count <= 14 && text.count < 420 && contacts >= 2 && (scores[.idCard] ?? 0) == 0 { return .businessCard }
        if doc.pages.count >= 2 && lines.count / max(1, doc.pages.count) > 25 && scores.values.max() ?? 0 <= 1 { return .book }
        // Money words weigh more on short receipts than on long invoices.
        if text.count < 2500 { scores[.receipt, default: 0] += currencyHits(text) >= 3 ? 1 : 0 }
        guard let best = scores.max(by: { $0.value < $1.value }), best.value >= 2 else { return .other }
        return best.key
    }

    /// e.g. "Costco Receipt 2026-10-06", "Payment Plan Agreement 2026-10-06".
    static func suggestTitle(_ doc: ScanDocument, kind: DocumentKind) -> String? {
        let text = doc.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let lines = (doc.pages.first?.plainText ?? text).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let date = firstDate(text) ?? doc.createdAt
        let day = Self.dayFormat.string(from: date)
        var parts: [String] = []
        switch kind {
        case .businessCard:
            if let name = personName(lines) { parts = ["Business card", name] } else { parts = ["Business card"] }
            return clip(parts.joined(separator: " · "))
        case .idCard:
            parts = [lower(text).contains("passport") || text.contains("여권") ? "Passport" : "ID card"]
        case .receipt, .invoice:
            if let org = heading(lines) { parts.append(org) }
            parts.append(kind.label)
        case .contract, .form, .letter, .book, .other:
            if let head = heading(lines) { parts.append(head) } else { parts.append(kind == .other ? "Scan" : kind.label) }
        }
        parts.append(day)
        return clip(parts.joined(separator: " "))
    }

    /// Fills in kind and, for automatic names, a better name. Leaves user choices alone.
    static func apply(_ doc: ScanDocument) -> ScanDocument {
        var d = doc
        guard !d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || d.captureStyle == .card else {
            if d.kind == nil && d.kindChosen != true { d.kind = .other }
            return d
        }
        if d.kindChosen != true { d.kind = classify(d) }
        if d.autoTitled == true, let kind = d.kind, let name = suggestTitle(d, kind: kind) { d.title = name }
        return d
    }

    /// Fields read from a business card for a new contact.
    struct CardFields { var name = "", organization = "", jobTitle = "", phones: [String] = [], emails: [String] = [], urls: [String] = [], address = "" }
    static func cardFields(_ doc: ScanDocument) -> CardFields {
        let text = doc.text
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var f = CardFields()
        f.name = personName(lines) ?? ""
        let types: NSTextCheckingResult.CheckingType = [.phoneNumber, .link, .address]
        if let detector = try? NSDataDetector(types: types.rawValue) {
            for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                switch m.resultType {
                case .phoneNumber: if let p = m.phoneNumber, !f.phones.contains(p) { f.phones.append(p) }
                case .link:
                    if let url = m.url {
                        if url.scheme == "mailto" { let e = url.absoluteString.replacingOccurrences(of: "mailto:", with: ""); if !f.emails.contains(e) { f.emails.append(e) } }
                        else if !f.urls.contains(url.absoluteString) { f.urls.append(url.absoluteString) }
                    }
                case .address: if f.address.isEmpty, let r = Range(m.range, in: text) { f.address = String(text[r]).replacingOccurrences(of: "\n", with: ", ") }
                default: break
                }
            }
        }
        let orgWords = ["inc", "ltd", "llc", "corp", "co.", "company", "group", "bank", "university", "주식회사", "(주)", "㈜", "회사"]
        let jobWords = ["manager", "director", "engineer", "ceo", "cto", "cfo", "president", "founder", "officer", "consultant", "designer", "developer", "agent", "advisor", "sales", "대표", "이사", "부장", "차장", "과장", "대리", "팀장", "실장", "사원", "매니저"]
        for line in lines where !line.contains("@") && line != f.name {
            let l = line.lowercased()
            if f.organization.isEmpty, orgWords.contains(where: { l.contains($0) }) { f.organization = line; continue }
            if f.jobTitle.isEmpty, line.count <= 40, jobWords.contains(where: { l.contains($0) }) { f.jobTitle = line }
        }
        if f.organization.isEmpty, let head = heading(lines.filter { $0 != f.name && $0 != f.jobTitle }) { f.organization = head }
        return f
    }

    // MARK: helpers
    private static let dayFormat: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
    private static func lower(_ s: String) -> String { s.lowercased() }
    private static func clip(_ s: String) -> String { s.count <= 60 ? s : String(s.prefix(60)).trimmingCharacters(in: .whitespaces) }
    /// Phone numbers (up to two), an email and a website each count once.
    private static func contactCount(_ text: String) -> Int {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue | NSTextCheckingResult.CheckingType.link.rawValue) else { return 0 }
        var phones = 0, email = 0, web = 0
        for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if m.resultType == .phoneNumber { phones += 1 }
            else if let url = m.url { if url.scheme == "mailto" { email = 1 } else { web = 1 } }
        }
        return min(phones, 2) + email + web
    }
    private static func currencyHits(_ text: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: #"(\$|₩|€|£)\s?\d|\d+[.,]\d{2}\b|\d{1,3}(,\d{3})+원"#) else { return 0 }
        return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func firstDate(_ text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let now = Date()
        // Only plausible paper dates: within 30 years back and a year ahead.
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.date)
            .first { $0 < now.addingTimeInterval(366 * 86400) && $0 > now.addingTimeInterval(-30 * 366 * 86400) }
    }
    private static let generic: Set<String> = ["receipt", "invoice", "tax invoice", "statement", "page", "date", "welcome", "thank you", "customer copy", "merchant copy", "original", "copy", "영수증", "청구서", "고객용", "가맹점용"]
    /// A short, word-like line near the top: a store, company or document title.
    private static func heading(_ lines: [String]) -> String? {
        for raw in lines.prefix(8) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " *#-_=|:.,"))
            guard (3...40).contains(line.count), !generic.contains(line.lowercased()) else { continue }
            let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            let digits = line.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
            guard Double(letters) / Double(line.count) > 0.6, digits <= 2, !line.contains("@"), !line.lowercased().contains("www") else { continue }
            return titleCase(line)
        }
        return nil
    }
    private static func personName(_ lines: [String]) -> String? {
        for line in lines.prefix(10) {
            let words = line.split(separator: " ")
            let hangul = line.unicodeScalars.allSatisfy { (0xAC00...0xD7A3).contains($0.value) || $0 == " " }
            if hangul && (2...5).contains(line.replacingOccurrences(of: " ", with: "").count) { return line }
            guard (2...4).contains(words.count), !line.contains("@"), line.rangeOfCharacter(from: .decimalDigits) == nil else { continue }
            if words.allSatisfy({ $0.first?.isUppercase == true && $0.count > 1 }) { return titleCase(line) }
        }
        return nil
    }
    private static func titleCase(_ s: String) -> String {
        let letters = s.filter(\.isLetter)
        guard !letters.isEmpty, letters == letters.uppercased(), letters != letters.lowercased() else { return s }
        return s.lowercased().capitalized
    }
}
