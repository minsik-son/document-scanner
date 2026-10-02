import Foundation

enum LocalMath {
    static func evaluate(_ input:String) throws -> Double {
        guard input.count <= 1000 else { throw ScannerError.message("Use a shorter expression.") }
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
