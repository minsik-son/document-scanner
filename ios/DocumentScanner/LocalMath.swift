import Foundation

enum LocalMath {
    static func evaluate(_ input:String) throws -> Double {
        guard input.count <= 1000 else { throw ScannerError.message("Use a shorter expression.") }
        // "2 57" is two numbers (often an item number and the sum), not 257.
        if input.range(of: "\\d\\s+\\.?\\d", options: .regularExpression) != nil { throw ScannerError.message("Check the expression and its domain.") }
        var parser = Parser(chars:Array(input.replacingOccurrences(of:"−",with:"-").replacingOccurrences(of:"×",with:"*").replacingOccurrences(of:"÷",with:"/").filter { !$0.isWhitespace }))
        let result = try parser.expression(); guard parser.i == parser.chars.count, result.isFinite else { throw ScannerError.message("Check the expression and its domain.") }; return result
    }
    private struct Parser {
        let chars:[Character]; var i = 0; var depth = 0
        mutating func consume(_ c:Character) -> Bool { if i < chars.count && chars[i] == c { i += 1; return true }; return false }
        mutating func expression() throws -> Double { var x = try term(); while i < chars.count { if consume("+") { x += try term() } else if consume("-") { x -= try term() } else { break } }; return x }
        mutating func term() throws -> Double { var x = try unary(); while i < chars.count { if consume("*") { x *= try unary() } else if consume("/") { let d = try unary();guard d != 0 else { throw ScannerError.message("Division by zero.") };x /= d } else { break } };return x }
        mutating func unary() throws -> Double { depth += 1; defer { depth -= 1 };guard depth < 64 else { throw ScannerError.message("Expression is too deeply nested.") }; if consume("+") { return try unary() };if consume("-") { return -(try unary()) };var x = try primary();if consume("^") { x = pow(x,try unary()) };return x }
        mutating func primary() throws -> Double {
            if consume("(") { let x = try expression();guard consume(")") else { throw ScannerError.message("Missing closing parenthesis.") };return x }
            let begin = i
            while i < chars.count && (chars[i].isNumber || chars[i] == ".") { i += 1 }
            if i > begin,let x = Double(String(chars[begin..<i])) { return x }
            while i < chars.count && chars[i].isLetter { i += 1 }
            let name = String(chars[begin..<i]).lowercased()
            if name == "pi" || name == "π" { return .pi };if name == "e" { return M_E }
            guard !name.isEmpty,consume("(") else { throw ScannerError.message("Use numbers, + − × ÷ ^, parentheses, sqrt, sin, cos, tan, ln, log or abs.") }
            let x = try expression();guard consume(")") else { throw ScannerError.message("Missing closing parenthesis.") }
            switch name { case "sqrt":return sqrt(x);case "sin":return sin(x);case "cos":return cos(x);case "tan":return tan(x);case "ln":return log(x);case "log":return log10(x);case "abs":return abs(x);default:throw ScannerError.message("Unsupported function: \(name).") }
        }
    }
}

extension LocalMath {
    /// Answers what was photographed or typed: one expression gives its value; an
    /// exercise sheet gives "expression = value" for every line that is a sum.
    /// Numbering ("Q1.", "③", "2)"), the "=" with its answer blank, superscript
    /// powers, √ and the × or x a camera reads are understood.
    static func solve(_ text: String) throws -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw ScannerError.message("Use numbers, + − × ÷ ^, parentheses, sqrt, sin, cos, tan, ln, log or abs.") }
        if lines.count == 1 { return format(try evaluate(expression(lines[0]) ?? lines[0])) }
        var answers: [String] = []
        var firstError: Error?
        for line in numbered(lines) {
            guard let e = expression(line) else { continue }
            do { answers.append("\(e.replacingOccurrences(of: "*", with: "×").replacingOccurrences(of: "/", with: "÷")) = \(format(try evaluate(e)))") }
            catch { if firstError == nil { firstError = error } }
        }
        if answers.isEmpty { throw firstError ?? ScannerError.message("Use numbers, + − × ÷ ^, parentheses, sqrt, sin, cos, tan, ln, log or abs.") }
        return answers.joined(separator: "\n")
    }

    /// Items numbered 1. 2. 3. … down a sheet: the camera often drops the space
    /// after the number ("2.18×151" for "2. 18×151"), so the run of consecutive
    /// numbers is removed even when it touches the sum.
    static func numbered(_ lines: [String]) -> [String] {
        let pattern = "^\\s*(\\d{1,2})[.)]"
        let numbers = lines.map { line -> Int? in
            guard let r = line.range(of: pattern, options: .regularExpression) else { return nil }
            return Int(line[r].filter(\.isNumber))
        }
        let found = numbers.compactMap { $0 }
        guard found.count >= 3 else { return lines }
        let steps = zip(found, found.dropFirst()).filter { $1 == $0 + 1 }.count
        guard Double(steps) >= Double(found.count - 1) * 0.6 else { return lines }
        // Each number is expected to follow the one before it.
        var expected: Int? = nil
        return zip(lines, numbers).map { line, n in
            guard let n, expected == nil || n == expected! || n == (expected! + 1) || n == found.first else { return line }
            expected = n + 1
            guard let r = line.range(of: pattern, options: .regularExpression) else { return line }
            return String(line[r.upperBound...])
        }
    }

    /// The bare expression in one line of an exercise, or nil when the line is
    /// not a sum (a title, a name field).
    static func expression(_ line: String) -> String? {
        var s = line
        for (a, b) in [("−", "-"), ("–", "-"), ("—", "-"), ("＋", "+"), ("（", "("), ("）", ")"), ("＝", "=")] { s = s.replacingOccurrences(of: a, with: b) }
        // The answer side: "= ____", "= 42" or a lone "=".
        if let eq = s.firstIndex(of: "=") { s = String(s[..<eq]) }
        s = s.trimmingCharacters(in: .whitespaces)
        // Numbering in front: circled numbers, "Q1.", "(3)", "4)", "5.", "a)".
        let marks = ["^[\\u2460-\\u2473\\u2776-\\u277F\\u24EA]\\s*", "^[Qq]\\s?\\d{1,2}\\s*[.):]?\\s*", "^\\(\\d{1,2}\\)\\s*", "^\\d{1,2}[).]\\s+", "^\\d{1,2}\\)\\s*", "^[a-hA-H][).]\\s+", "^\\(?[a-hA-H]\\)\\s*"]
        for m in marks { if let r = s.range(of: m, options: .regularExpression) { s.removeSubrange(r); break } }
        // A circled number misread as a symbol or letter ("@", "•", "I") before the sum.
        if let r = s.range(of: "^[^\\d\\s(√V.\\-+]{1,2}\\s+(?=[\\d(√V])", options: .regularExpression) { s.removeSubrange(r) }
        // "2 57 × 30": a lone number before a space is the item number, never
        // part of the first operand.
        if let r = s.range(of: "^\\d{1,2}\\s+(?=[\\d(√])", options: .regularExpression),
           s[r.upperBound...].range(of: "^[\\d.]+\\s+[\\d(]", options: .regularExpression) == nil { s.removeSubrange(r) }
        // Superscript powers.
        let sup: [Character: Character] = ["⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9"]
        var out = ""; var inSup = false
        for c in s {
            if let d = sup[c] { if !inSup { out += "^(" ; inSup = true }; out.append(d) }
            else { if inSup { out += ")"; inSup = false }; out.append(c) }
        }
        if inSup { out += ")" }
        s = out
        func re(_ p: String, _ t: String) { s = s.replacingOccurrences(of: p, with: t, options: .regularExpression) }
        // Decimal commas ("12,5") and thousands separators ("1,250").
        re("(?<=\\d),(?=\\d{3}(?!\\d))", ""); re("(?<=\\d),(?=\\d)", ".")
        // Square roots: √ or a V read in its place.
        re("(?<![A-Za-z])[√V]\\s*\\(", "sqrt("); re("(?<![A-Za-z])[√V]\\s*(\\d+(?:\\.\\d+)?)", "sqrt($1)")
        // Multiplication and division signs as printed or read.
        re("(?<=[\\d)])\\s*[xX×·∙•]\\s*(?=[\\d(s])", "*"); re("(?<=[\\d)])\\s*[÷:]\\s*(?=[\\d(s])", "/")
        // Implied multiplication: 2(3+4), (1+2)(3+4), 2√3.
        re("(?<=[\\d)])\\s*(?=\\(|sqrt)", "*"); re("(?<=\\))\\s*(?=\\d)", "*")
        // Two numbers side by side are a misreading, never one number.
        if s.range(of: "\\d\\s+\\.?\\d", options: .regularExpression) != nil { return nil }
        let compact = s.filter { !$0.isWhitespace }
        guard compact.contains(where: \.isNumber),
              compact.range(of: "[-+*/^]|sqrt", options: .regularExpression) != nil,
              compact.replacingOccurrences(of: "sqrt|sin|cos|tan|ln|log|abs|pi", with: "", options: .regularExpression).allSatisfy({ $0.isNumber || "+-*/^().".contains($0) }) else { return nil }
        return compact
    }

    /// A value as people write it: no "9.0", no floating point noise.
    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.usesSignificantDigits = true; f.maximumSignificantDigits = 10; f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}
