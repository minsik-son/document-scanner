import Foundation
import CoreGraphics
import NaturalLanguage

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
/// Raw values are stored in saved libraries; add new cases, never rename.
enum Enhancement: String, Codable, CaseIterable {
    case original = "Original", document = "Document", enhanced = "Enhanced", noShadow = "No shadows", gray = "Grayscale", mono = "Black & white"
}
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
/// Spots painted out with Spot eraser in the page editor. Strokes are
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
    /// Opening it in the app needs Face ID, Touch ID or the device passcode.
    var appLocked: Bool?
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
    /// Folders whose documents need Face ID, Touch ID or the passcode to open.
    var lockedFolders: [String]?
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
/// Tells real phone numbers apart from other digit runs (order, business, ISBN,
/// reference numbers) that the system data detector also reads as phones.
enum PhoneCheck {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
    private static let label = try! NSRegularExpression(pattern: #"(?i)(\b(tel|tél|phone|telephone|mobile|mob|cell|cellular|fax|hp|h\.p|direct|office|ph|whatsapp|call)\b|(^|[\s|])[TMPFHCO]\s?[.:]\s*[+(\d]|전화|휴대|연락처|핸드폰|팩스|대표번호|직통)"#)
    private static let loose = try! NSRegularExpression(pattern: #"\+?\(?\d[\d ().-]{6,}\d"#)
    private static let dateLike = try! NSRegularExpression(pattern: #"^\s*(\d{4}[-./]\d{1,2}[-./]\d{1,2}|\d{1,2}[-./]\d{1,2}[-./]\d{2,4})\s*$"#)
    static func hasLabel(_ text: String) -> Bool { label.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
    static func plausible(_ raw: String, labelled: Bool) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let d = String(s.unicodeScalars.filter { (48...57).contains($0.value) }.map(Character.init))
        let groups = s.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).map(\.count)
        guard d.count >= 7, d.count <= 16 else { return false }
        if dateLike.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { return false }
        if s.hasPrefix("+") { return d.count >= 8 }
        if d.hasPrefix("00") { return d.count >= 10 }
        // Korean numbers written internationally without the plus: 82-10-1234-5678.
        if d.hasPrefix("82"), (10...13).contains(d.count), labelled || (groups.count > 1 && groups[0] <= 4) { return true }
        if d.hasPrefix("0"), (9...11).contains(d.count) {
            if groups.count >= 2, groups.last == 4, groups.dropLast().allSatisfy({ (2...4).contains($0) }) { return true }
            if labelled || (groups.count == 1 && d.hasPrefix("01")) { return true }
        }
        // 1588-1234 style service numbers.
        if d.count == 8, groups == [4, 4], ["15", "16", "18"].contains(String(d.prefix(2))) { return true }
        // North American numbers.
        let area: (Character?) -> Bool = { c in c.map { "23456789".contains($0) } ?? false }
        if d.count == 10, area(d.first), groups == [3, 3, 4] || (groups == [10] && labelled) { return true }
        if d.count == 11, d.hasPrefix("1"), area(d.dropFirst().first), groups == [1, 3, 3, 4] || (groups == [11] && labelled) { return true }
        return labelled && d.count <= 15
    }
    /// Phone numbers in one line. `context` is the line plus the labels next to it.
    static func find(in text: String, context: String? = nil) -> [NSRange] {
        let ns = text as NSString, full = NSRange(location: 0, length: ns.length)
        let labelled = hasLabel(context ?? text)
        var out: [NSRange] = []
        for m in detector?.matches(in: text, range: full) ?? [] where plausible(ns.substring(with: m.range), labelled: labelled) { out.append(m.range) }
        if labelled {
            for m in loose.matches(in: text, range: full) where !out.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) && plausible(ns.substring(with: m.range), labelled: true) {
                out.append(m.range)
            }
        }
        return out
    }
}

enum DocumentInsight {
    private static let receiptWords = ["receipt", "cashier", "change due", "visa", "mastercard", "debit", "auth code", "thank you", "thanks for", "subtotal", "sub total",
                                       "sub-total", "sous-total", "tender", "qty", "rounding", "tunai", "kembali", "struk", "merchant copy", "customer copy", "transaction",
                                       "factura simplificada", "ticket", "kassenbon", "summe", "server", "table", "guests", "service charge",
                                       "영수증", "합계", "부가세", "승인번호", "카드번호", "받을금액", "결제금액", "거스름돈", "과세물품", "판매", "감사합니다"]
    /// Words that also appear in budgets and reports: half weight.
    private static let weakReceiptWords = ["cash", "change", "approved", "total", "tax", "gst", "vat", "tva", "btw", "iva", "tps"]
    private static let invoiceWords = ["invoice", "bill to", "billed to", "ship to", "sold to", "due date", "amount due", "balance due", "payment due", "payment terms", "remit", "invoice no",
                                       "invoice number", "invoice date", "purchase order", "p.o. number", "seller", "client", "net worth", "gross worth", "statement", "account number", "customer no",
                                       "청구서", "세금계산서", "납부", "고지서", "청구금액", "납기", "공급가액", "공급받는자", "청구기간"]
    private static let idWords = ["driver", "licence", "license", "passport", "date of birth", "dob", "expiry", "expires", "nationality", "identification", "id card", "issued",
                                  "주민등록증", "운전면허", "여권", "외국인등록증", "발급일"]
    private static let contractWords = ["agreement", "contract", "hereby", "whereas", "party", "parties", "terms and conditions", "witness", "lease", "tenant", "landlord", "governing law",
                                        "in witness whereof", "indemnif", "effective date", "termination", "obligations", "계약서", "계약", "임대인", "임차인", "갑과 을", "이하 \"갑\"", "이하 “갑”", "특약", "제1조", "제 1 조"]
    private static let formWords = ["application", "form", "please print", "print name", "check one", "check all", "applicant", "office use only", "for office use", "consent", "date of birth",
                                    "signature", "registration", "신청서", "서식", "신청인", "성명", "생년월일", "연락처", "서명 또는 인", "(인)", "작성일", "신청일", "기재"]
    private static let letterWords = ["dear ", "sincerely", "regards", "yours truly", "very truly", "truly yours", "cordially", "to whom it may concern", "enclosure", "enclosed",
                                      "귀하", "드림", "올림", "배상", "안녕하십니까", "님께"]
    /// Label words that end a short line on a form ("Name:", "Phone ____").
    private static let fieldLabels: Set<String> = ["name", "full name", "first name", "last name", "address", "city", "state", "province", "zip", "zip code", "postal code", "phone", "telephone",
                                                   "email", "e-mail", "date", "signature", "date of birth", "occupation", "employer", "company", "title", "sex", "gender", "age",
                                                   "성명", "이름", "주소", "연락처", "전화번호", "휴대폰", "이메일", "생년월일", "소속", "직업", "서명", "날짜", "일자", "우편번호", "성별"]
    private static let memoLabels: Set<String> = ["to", "from", "re", "subject", "cc", "date", "bcc", "attn"]

    private static func words(_ lower: String) -> Set<Substring> { Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })) }
    private static func hits(_ list: [String], _ lower: String, _ tokens: Set<Substring>) -> Int {
        list.reduce(0) { n, w in
            let latinWord = w.allSatisfy { ($0.isASCII && $0.isLetter) || $0 == "-" }
            return n + ((latinWord ? tokens.contains(Substring(w)) : lower.contains(w)) ? 1 : 0)
        }
    }
    /// Short lines that read like empty form fields.
    private static func labelLines(_ lines: [String]) -> Int {
        lines.filter { line in
            var l = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " _.…"))
            let colon = l.hasSuffix(":") || l.hasSuffix("：")
            l = l.trimmingCharacters(in: CharacterSet(charactersIn: " :：*"))
            guard l.count >= 2, l.count <= 32, l.split(separator: " ").count <= 5, !memoLabels.contains(l) else { return false }
            if fieldLabels.contains(l) { return true }
            return colon && l.rangeOfCharacter(from: .decimalDigits) == nil
        }.count
    }

    static func classify(_ doc: ScanDocument) -> DocumentKind {
        let text = doc.text
        let lower = text.lowercased(), tokens = words(lower)
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let contacts = contactCount(text)
        let rrn = text.range(of: #"\d{6}\s?-\s?[1-8]\d{6}"#, options: .regularExpression) != nil
        let idScore = hits(idWords, lower, tokens) + (rrn ? 2 : 0)
        let money = currencyHits(text)
        if doc.captureStyle == .card {
            // Card camera: an ID unless it reads like a business card.
            let business = contacts + (jobLine(lines) != nil ? 1 : 0) + (lower.contains("@") ? 1 : 0)
            if business >= 2 && idScore <= (rrn ? 0 : 1) { return .businessCard }
            return .idCard
        }
        if lines.count <= 16 && text.count < 520 && contacts >= 2 && idScore == 0 && money < 2 { return .businessCard }
        if doc.pages.count >= 2 && lines.count / max(1, doc.pages.count) > 25 && hits(contractWords, lower, tokens) <= 1 && hits(formWords, lower, tokens) <= 1 { return .book }
        var scores: [DocumentKind: Double] = [:]
        // "Total" with cash or change is a till receipt even when nothing else is legible.
        let till = tokens.contains("total") && !tokens.isDisjoint(with: ["cash", "tunai", "kembalian", "kembali"]) && money >= 2 && text.count < 1500 ? 1 : 0
        let strongReceipt = hits(receiptWords, lower, tokens) + till
        scores[.receipt] = Double(strongReceipt) + 0.5 * Double(hits(weakReceiptWords, lower, tokens))
            + (money >= 4 && text.count < 1500 && strongReceipt >= 1 ? 1 : 0) + (tokens.contains("receipt") || lower.contains("영수증") ? 1 : 0)
        scores[.invoice] = Double(hits(invoiceWords, lower, tokens)) + (tokens.contains("invoice") || lower.contains("청구서") || lower.contains("고지서") ? 1 : 0)
        let labels = labelLines(lines)
        scores[.form] = Double(hits(formWords, lower, tokens)) + (labels >= 8 ? 3 : labels >= 4 ? 2 : labels >= 2 ? 1 : 0)
        scores[.letter] = Double(hits(letterWords, lower, tokens)) + (lower.contains("dear ") ? 1 : 0)
        scores[.contract] = Double(hits(contractWords, lower, tokens)) + (text.count > 1500 && (tokens.contains("agreement") || lower.contains("계약서")) ? 1 : 0)
        if text.count < 900 { scores[.idCard] = Double(idScore) - 1 }
        // Ties go to the more specific kind.
        let order: [DocumentKind] = [.contract, .invoice, .receipt, .idCard, .form, .letter]
        guard let best = order.max(by: { (scores[$0] ?? 0) < (scores[$1] ?? 0) }), (scores[best] ?? 0) >= 2 else { return .other }
        return best
    }

    /// e.g. "Costco Receipt 2026-10-06", "Payment Plan Agreement 2026-10-06".
    static func suggestTitle(_ doc: ScanDocument, kind: DocumentKind) -> String? {
        let text = doc.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let lines = (doc.pages.first?.plainText ?? text).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // An ambiguous date (10/05/2026 with no way to tell the order) is left out.
        let found = paperDate(text)
        let day: String? = found.ambiguous ? nil : Self.dayFormat.string(from: found.date ?? doc.createdAt)
        var parts: [String] = []
        switch kind {
        case .businessCard:
            if let name = personName(lines) { parts = ["Business card", name] } else { parts = ["Business card"] }
            return clip(parts.joined(separator: " · "))
        case .idCard:
            parts = [lower(text).contains("passport") || text.contains("여권") ? "Passport" : "ID card"]
        case .receipt, .invoice:
            if let org = organization(lines) ?? heading(lines) { parts.append(org) }
            parts.append(kind.label)
        case .contract, .form, .letter, .book, .other:
            if let head = heading(lines) { parts.append(head) } else { parts.append(kind == .other ? "Scan" : kind.label) }
        }
        if let day { parts.append(day) }
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
    static func cardFields(_ doc: ScanDocument) -> CardFields { cardFields(text: doc.text) }
    static func cardFields(text: String) -> CardFields {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var f = CardFields()
        f.name = personName(lines) ?? ""
        let types: NSTextCheckingResult.CheckingType = [.link, .address]
        if let detector = try? NSDataDetector(types: types.rawValue) {
            for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                switch m.resultType {
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
        // Phones line by line, so labels such as "M" or "HP" count for the number next to them.
        for line in lines where !line.contains("@") {
            let ns = line as NSString
            for r in PhoneCheck.find(in: line) {
                let p = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
                let key = String(p.filter(\.isNumber).suffix(8))
                if !f.phones.contains(where: { String($0.filter(\.isNumber).suffix(8)) == key }) { f.phones.append(p) }
            }
        }
        // A website that is just the email's domain is still worth keeping; drop links that are the email itself.
        f.urls.removeAll { u in f.emails.contains { u.contains($0) } }
        f.jobTitle = jobLine(lines.filter { $0 != f.name }) ?? ""
        // Korean cards print a short title right next to the name; take it even when OCR blurs the word.
        if f.jobTitle.isEmpty, let i = lines.firstIndex(of: f.name) {
            for j in [i + 1, i - 1] where lines.indices.contains(j) {
                let c = lines[j].replacingOccurrences(of: " ", with: "")
                if (2...6).contains(c.count), c.unicodeScalars.allSatisfy({ (0xAC00...0xD7A3).contains($0.value) }), !hasOrgMarker(lines[j]) { f.jobTitle = lines[j]; break }
            }
        }
        let rest = lines.filter { $0 != f.name && $0 != f.jobTitle && !$0.contains("@") && PhoneCheck.find(in: $0).isEmpty && !addressLike($0) }
        f.organization = organization(rest) ?? heading(rest) ?? ""
        return f
    }

    // MARK: helpers
    private static let dayFormat: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
    private static func lower(_ s: String) -> String { s.lowercased() }
    private static func clip(_ s: String) -> String { s.count <= 60 ? s : String(s.prefix(60)).trimmingCharacters(in: .whitespaces) }
    /// Phone numbers (up to two), an email and a website each count once.
    private static func contactCount(_ text: String) -> Int {
        var phones = 0, email = 0, web = 0
        for line in text.split(whereSeparator: \.isNewline) { phones += PhoneCheck.find(in: String(line)).count }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = m.url { if url.scheme == "mailto" { email = 1 } else { web = 1 } }
            }
        }
        return min(phones, 2) + email + web
    }
    private static func currencyHits(_ text: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: #"(\$|₩|€|£|rp\.?|rm)\s?\d|\d+[.,]\d{2}\b|\d{1,3}(,\d{3})+원?"#, options: [.caseInsensitive]) else { return 0 }
        return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    /// The first plausible date printed on the paper. Numeric dates with both
    /// parts ≤ 12 ("10/05/2026") are read month-first or day-first from the
    /// document's language, then the iPhone's region; if neither decides, the
    /// date is reported as ambiguous.
    static func paperDate(_ text: String, region: String? = Locale.current.region?.identifier) -> (date: Date?, ambiguous: Bool) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return (nil, false) }
        let now = Date(), ns = text as NSString
        func plausible(_ d: Date) -> Bool { d < now.addingTimeInterval(366 * 86400) && d > now.addingTimeInterval(-30 * 366 * 86400) }
        let numeric = try! NSRegularExpression(pattern: #"^\s*(\d{1,2})\s*[/.\-]\s*(\d{1,2})\s*[/.\-]\s*(\d{4})\s*$"#)
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let detected = match.date else { continue }
            let piece = ns.substring(with: match.range)
            if let m = numeric.firstMatch(in: piece, range: NSRange(location: 0, length: (piece as NSString).length)) {
                let p = piece as NSString
                let a = Int(p.substring(with: m.range(at: 1))) ?? 0, b = Int(p.substring(with: m.range(at: 2))) ?? 0, y = Int(p.substring(with: m.range(at: 3))) ?? 0
                var monthFirst: Bool?
                if a > 12 && b <= 12 { monthFirst = false } else if b > 12 && a <= 12 { monthFirst = true }
                else if a <= 12 && b <= 12 { monthFirst = Self.monthFirst(text, region: region) }
                guard let first = monthFirst else { return (nil, true) }
                var c = DateComponents(); c.year = y; c.month = first ? a : b; c.day = first ? b : a; c.hour = 12
                guard let d = Calendar(identifier: .gregorian).date(from: c), plausible(d) else { continue }
                return (d, false)
            }
            if plausible(detected) { return (detected, false) }
        }
        return (nil, false)
    }
    /// nil when neither the document's language nor the region settles the order.
    static func monthFirst(_ text: String, region: String?) -> Bool? {
        let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
        if let lang = recognizer.dominantLanguage, lang != .english, lang != .undetermined {
            // Languages written day-first; East Asian dates are year-first and never reach here ambiguous.
            let dayFirst: Set<NLLanguage> = [.french, .german, .spanish, .italian, .portuguese, .dutch, .polish, .turkish, .vietnamese, .indonesian, .russian, .thai]
            if dayFirst.contains(lang) { return false }
        }
        switch region {
        case "US", "PH", "PR", "GU", "FM", "MH": return true
        case nil: return nil
        default:
            return ["GB", "IE", "AU", "NZ", "IN", "ZA", "SG", "MY", "FR", "DE", "ES", "IT", "BR", "PT", "PL", "TR", "VN", "ID", "TH", "NL", "BE", "CH", "AT", "MX"].contains(region!) ? false : nil
        }
    }
    private static let generic: Set<String> = ["receipt", "invoice", "tax invoice", "statement", "page", "date", "welcome", "thank you", "customer copy", "merchant copy", "original", "copy",
                                               "cash bill", "bill", "official receipt", "simplified tax invoice", "영수증", "청구서", "고객용", "가맹점용", "카드영수증", "현금영수증"]
    private static let orgMarkers = ["sdn bhd", "sdn. bhd", "sdn.bhd", "bhd", "s/b", "sdn", "pte", "inc", "inc.", "ltd", "ltd.", "llc", "corp", "corp.", "co.", "company", "group", "enterprise", "trading", "restaurant",
                                     "cafe", "café", "mart", "store", "market", "supermarket", "bakery", "pharmacy", "hardware", "station", "hotel", "bank", "university", "studio",
                                     "주식회사", "(주)", "㈜", "(유)", "유한회사", "그룹", "회사", "은행"]
    private static func hasOrgMarker(_ line: String) -> Bool {
        let l = line.lowercased(), tokens = Set(l.split(whereSeparator: { !$0.isLetter && $0 != "." && $0 != "(" && $0 != ")" }).map(String.init))
        return orgMarkers.contains { m in m.contains(" ") || m.contains("(") || m.contains("/") || m.contains(".") || !m.allSatisfy({ $0.isASCII }) || m == "bhd" ? l.contains(m) : tokens.contains(m) }
    }
    private static let addressWords: Set<String> = ["street", "st", "road", "rd", "avenue", "ave", "blvd", "drive", "dr", "lane", "jalan", "jln", "taman", "lot", "no", "suite", "unit",
                                                    "floor", "fl", "box", "highway", "hwy", "way", "court", "ct", "place", "pl"]
    private static func addressLike(_ line: String) -> Bool {
        let l = line.lowercased()
        let tokens = Set(l.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let hasDigit = l.rangeOfCharacter(from: .decimalDigits) != nil
        if hasDigit && (!tokens.isDisjoint(with: addressWords) || l.contains(",")) { return true }
        if !tokens.isDisjoint(with: ["jalan", "jln", "taman", "lorong", "persiaran", "kawasan", "bandar", "avenue", "boulevard", "street", "road"]) { return true }
        // Korean addresses: 시/도/구/로/길/동/층 with a number.
        return hasDigit && ["시 ", "구 ", "로 ", "길 ", "동 ", "층", "번지", "광역시", "특별시"].contains { l.contains($0) }
    }
    /// The store or company line near the top of a receipt or invoice.
    private static func organization(_ lines: [String]) -> String? {
        let top = Array(lines.prefix(10))
        for (i, raw) in top.enumerated() {
            // Drop registration numbers in brackets: "99 SPEED MART S/B (519537-X)".
            var line = raw.replacingOccurrences(of: #"\([^)]*\d[^)]*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " *#-_=|:.,‹›•"))
            // A marker on its own line ("SDN BHD") belongs to the name above it.
            if i > 0, line.split(separator: " ").count <= 4, hasOrgMarker(line), !hasOrgMarker(top[i - 1]),
               top[i - 1].rangeOfCharacter(from: .decimalDigits) == nil, line.lowercased().range(of: #"^(co\.?|\(m\)|sdn|bhd|inc|ltd|llc|s/b|pte)"#, options: .regularExpression) != nil {
                line = top[i - 1].trimmingCharacters(in: CharacterSet(charactersIn: " *#-_=|:.,‹›•")) + " " + line
            }
            guard (3...48).contains(line.count), hasOrgMarker(line), !line.contains("@"), !addressLike(line) else { continue }
            let digits = line.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
            guard digits <= 2 else { continue }
            return titleCase(line)
        }
        return nil
    }
    /// A short, word-like line near the top: a store, company or document title.
    private static func heading(_ lines: [String]) -> String? {
        for raw in lines.prefix(8) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " *#-_=|:.,"))
            let low = line.lowercased()
            guard (3...40).contains(line.count), !generic.contains(low),
                  !["invoice", "receipt", "tax ", "gst", "date", "tel", "fax", "no.", "no:", "bill", "order", "table", "page"].contains(where: { low.hasPrefix($0) }) else { continue }
            let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            let digits = line.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
            guard Double(letters) / Double(line.count) > 0.6, digits <= 2, !line.contains("@"), !line.lowercased().contains("www"), !addressLike(line), !PhoneCheck.hasLabel(line) else { continue }
            return titleCase(line)
        }
        return nil
    }
    private static let jobWords = ["manager", "director", "engineer", "ceo", "cto", "cfo", "coo", "president", "founder", "officer", "consultant", "designer", "developer", "agent", "advisor",
                                   "adviser", "sales", "partner", "associate", "specialist", "analyst", "coordinator", "therapist", "lawyer", "solicitor", "barrister", "attorney", "dentist",
                                   "doctor", "physician", "photographer", "architect", "accountant", "broker", "realtor", "representative", "executive", "head of", "lead", "vp",
                                   "vice president", "chief", "owner", "principal", "administrator", "nurse", "teacher", "professor", "producer", "editor", "writer", "planner", "assistant",
                                   "대표", "이사", "부장", "차장", "과장", "대리", "팀장", "실장", "사원", "매니저", "연구원", "전무", "상무", "본부장", "사장", "회장", "주임", "수석", "책임",
                                   "선임", "디자이너", "개발자", "변호사", "세무사", "회계사", "교수", "원장", "센터장", "지점장", "점장", "위원", "고문", "컨설턴트", "엔지니어"]
    private static func isJob(_ line: String) -> Bool {
        let l = line.lowercased()
        guard line.count <= 40, !line.contains("@"), l.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        let tokens = Set(l.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return jobWords.contains { w in w.contains(" ") || !w.allSatisfy({ $0.isASCII }) ? l.contains(w) : tokens.contains(w) }
    }
    private static func jobLine(_ lines: [String]) -> String? { lines.prefix(12).first { isJob($0) && !hasOrgMarker($0) } }
    private static let surnames: Set<Character> = Set("김이박최정강조윤장임한오서신권황안송류전홍고문양손배백허유남심노하곽성차주우구민진나지엄변채원천방공현함염여추도소석선설마길연위표명기반왕금옥육인맹제모탁국어은편용예경봉사부")
    private static let orgNameWords: Set<String> = ["inc", "ltd", "llc", "corp", "co", "company", "group", "bank", "university", "studio", "photography", "law", "legal", "dental", "dentistry",
                                                    "realty", "estate", "partners", "wealth", "consulting", "solutions", "services", "design", "media", "labs", "technologies", "tech",
                                                    "systems", "clinic", "health", "insurance", "financial", "capital", "holdings", "associates", "agency", "and", "the", "of", "pine",
                                                    "harbour", "harbor", "leaf", "lane", "summit", "studios", "creative", "global", "international", "industries", "foods", "motors"]
    /// The person's name on a card: a short name-shaped line, preferably next to a job title.
    private static func personName(_ lines: [String]) -> String? {
        var best: (String, Int)?
        let top = Array(lines.prefix(10))
        for (i, line) in top.enumerated() {
            let near = [i > 0 ? top[i - 1] : "", i + 1 < top.count ? top[i + 1] : ""].contains { isJob($0) }
            var score: Int
            let compact = line.replacingOccurrences(of: " ", with: "")
            let hangul = !compact.isEmpty && compact.unicodeScalars.allSatisfy { (0xAC00...0xD7A3).contains($0.value) }
            if hangul {
                guard (2...5).contains(compact.count), !hasOrgMarker(line), !isJob(line) else { continue }
                score = (surnames.contains(compact.first!) ? 3 : 0) + ((2...4).contains(compact.count) ? 1 : 0)
            } else {
                let words = line.split(separator: " ")
                guard (2...4).contains(words.count), !line.contains("@"), line.rangeOfCharacter(from: .decimalDigits) == nil, !isJob(line),
                      words.allSatisfy({ $0.first?.isUppercase == true && $0.count > 1 && $0.allSatisfy { $0.isLetter || "-.'".contains($0) } }) else { continue }
                score = 2
                let tokens = Set(line.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
                if !tokens.isDisjoint(with: orgNameWords) || hasOrgMarker(line) || line.contains("&") { score -= 5 }
            }
            if near { score += 2 }
            if best == nil || score > best!.1 { best = (line, score) }
        }
        guard let best, best.1 >= 1 else { return nil }
        return titleCase(best.0)
    }
    private static func titleCase(_ s: String) -> String {
        let letters = s.filter(\.isLetter)
        guard !letters.isEmpty, letters == letters.uppercased(), letters != letters.lowercased() else { return s }
        return s.lowercased().capitalized
    }
}
