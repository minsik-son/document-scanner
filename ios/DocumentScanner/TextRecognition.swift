import Foundation
import CoreGraphics
import Vision

// Shared by the app and the local quality checker. All recognition is on-device.
enum TextRecognition {
    private enum Script: Hashable {
        case latin, hangul, kana, han, cyrillic, arabic, thai, other
    }
    private struct Reading {
        let observation: VNRecognizedTextObservation
        let candidate: VNRecognizedText
        let pass: Int
        let scripts: [Script: Int]
    }

    static func supportedLanguages() throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return try request.supportedRecognitionLanguages()
    }

    // Vision's language array is a priority list, not a union of script models.
    // The same Korean image can produce Latin gibberish with English first, even
    // with automatic language detection. Run the available script models separately.
    static func languagePasses(supported: [String]) -> [[String]] {
        let groups: [[String]] = [
            ["en", "fr", "it", "de", "es", "pt", "vi", "tr", "id", "cs", "da", "nl", "no", "nn", "nb", "ms", "pl", "ro", "sv", "fi", "hu", "hr", "sk", "sl", "ca"],
            ["ko"], ["ja"], ["zh", "yue"], ["ru", "uk", "bg", "sr", "be"], ["ar", "ars", "fa", "ur"], ["th"]
        ]
        let english = supported.filter { $0.hasPrefix("en-") }
        var remaining = Set(supported)
        var passes: [[String]] = []
        for prefixes in groups {
            let languages = supported.filter { prefixes.contains(String($0.split(separator: "-")[0])) }
            guard !languages.isEmpty else { continue }
            passes.append(languages + english.filter { !languages.contains($0) })
            // Simplified/traditional Chinese have separate preferences. Include
            // both models without forcing the spelling of one onto the other.
            if let traditional = languages.first(where: { $0.contains("Hant") }) {
                passes.append([traditional] + languages.filter { $0 != traditional } + english)
            }
            remaining.subtract(languages)
        }
        // Future OS languages are included automatically rather than silently
        // excluded by a fixed whitelist in the app.
        for language in supported where remaining.contains(language) {
            passes.append([language] + english.filter { $0 != language })
        }
        return passes
    }

    /// Tests can limit the passes to the scripts in a sample set; the app always runs them all.
    nonisolated(unsafe) static var passFilter: (([String]) -> Bool)?
    /// Tests set this to see every pass's raw readings; nil in the app.
    nonisolated(unsafe) static var log: ((String) -> Void)?
    /// Keep words only a losing reading made out (tests turn it off to compare).
    nonisolated(unsafe) static var keepsUncoveredWords = true
    static func recognize(_ image: CGImage, languageCorrection: Bool = true) throws -> [TextBlock] {
        try recognize([image], languageCorrection: languageCorrection)
    }
    /// Reads several renderings of the same page (same geometry) and merges
    /// them: each line comes from the reading that scores best, and words only
    /// one rendering made out are kept as well.
    static func recognize(_ images: [CGImage], languageCorrection: Bool = true) throws -> [TextBlock] {
        var passes = languagePasses(supported: try supportedLanguages())
        if let passFilter { passes = passes.filter(passFilter) }
        var readings: [Reading] = []
        var lastError: Error?
        var successfulPasses = 0
        for (pass, languages, image) in images.enumerated().flatMap({ k, image in passes.enumerated().map { (k * passes.count + $0.offset, $0.element, image) } }) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.minimumTextHeight = 0
            request.usesLanguageCorrection = languageCorrection
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = languages
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                successfulPasses += 1
                log?("pass \(languages.first ?? "") \(image.width)x\(image.height): " + (request.results ?? []).map { "[\($0.topCandidates(1).first?.string ?? "")|\(String(format: "%.2f", $0.topCandidates(1).first?.confidence ?? 0))]" }.joined(separator: " "))
                readings += (request.results ?? []).compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first,
                          !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    var scripts: [Script: Int] = [:]
                    for scalar in candidate.string.unicodeScalars where CharacterSet.letters.contains(scalar) {
                        scripts[script(scalar), default: 0] += 1
                    }
                    return Reading(observation: observation, candidate: candidate, pass: pass, scripts: scripts)
                }
            } catch { lastError = error }
        }
        if successfulPasses == 0, let lastError { throw lastError }

        // Estimate script evidence per pass, then take the strongest pass for each
        // script. Repeated Chinese passes must not gain votes just from duplication.
        // A page written in a CJK script (or another non-Latin one): one pass
        // reads many of its characters, even if each line only at low confidence
        // (small print in a photo). Then that pass's low-confidence lines still
        // beat the Latin model's letter-and-digit soup for the same lines.
        var nativeChars: [Int: [Script: Int]] = [:]
        for reading in readings where reading.candidate.confidence >= 0.25 {
            for (script, count) in reading.scripts where script != .latin && script != .other { nativeChars[reading.pass, default: [:]][script, default: 0] += count }
        }
        let dominant = nativeChars.values.flatMap { $0 }.filter { $0.value >= 80 }.max { $0.value < $1.value }?.key
        let floor: Double = dominant != nil && prefersPageScript ? 0.25 : 0.4
        var perPass: [Int: [Script: Double]] = [:]
        for reading in readings {
            let confidence = Double(reading.candidate.confidence)
            for (script, count) in reading.scripts where script != .latin && confidence >= floor {
                perPass[reading.pass, default: [:]][script, default: 0] += Double(min(12, count)) * max(confidence, 0.4) * max(confidence, 0.4)
            }
        }
        var evidence: [Script: Double] = [:]
        for scores in perPass.values {
            for (script, score) in scores { evidence[script] = max(evidence[script] ?? 0, score) }
        }
        let strongest = max(1, evidence.values.max() ?? 1)
        func score(_ reading: Reading) -> Double {
            var value = Double(reading.candidate.confidence) * 0.55
            let native = reading.scripts.filter { $0.key != .latin }
            if let support = native.map({ (evidence[$0.key] ?? 0) / strongest }).max(), Double(reading.candidate.confidence) >= floor {
                value += 0.46 * support
            }
            if dominant != nil, prefersPageScript, native.isEmpty, junk(reading.candidate.string) { value -= 0.3 }
            // A script the page hardly has (kana a Japanese pass sprinkles into
            // Chinese print) marks a misreading of the page's own script.
            if dominant != nil, prefersPageScript {
                let total = native.values.reduce(0, +)
                let stray = native.filter { (evidence[$0.key] ?? 0) / strongest < 0.35 }.values.reduce(0, +)
                if total > 0, stray > 0 { value -= 0.25 * Double(stray) / Double(total) }
            }
            // When models agree on a Latin/code line, prefer the Latin model.
            if native.isEmpty && reading.pass % max(1, passes.count) == 0 { value += 0.025 }
            return value
        }
        let ordered = readings.sorted {
            let a = score($0), b = score($1)
            return a == b ? $0.pass < $1.pass : a > b
        }
        // Boxes already taken, in Vision's normalized coordinates.
        var taken: [CGRect] = []
        func conflicts(_ box: CGRect) -> Bool {
            taken.contains { otherBox in
                let overlap = box.intersection(otherBox)
                guard !overlap.isNull else { return false }
                let vertical = overlap.height / max(0.00001, min(box.height, otherBox.height))
                let area = overlap.width * overlap.height
                return vertical > 0.65 && area / max(0.00001, min(box.width * box.height, otherBox.width * otherBox.height)) > 0.65
            }
        }
        func wordBox(_ candidate: VNRecognizedText, _ range: Range<String.Index>) -> CGRect? {
            guard let geometry = try? candidate.boundingBox(for: range), geometry.boundingBox.width > 0 else { return nil }
            return geometry.boundingBox
        }
        var blocks: [(CGRect, TextBlock)] = []
        for reading in ordered {
            let candidate = reading.candidate, bounds = reading.observation.boundingBox
            let ranges = selectionRanges(in: candidate.string)
            if !conflicts(bounds) {
                taken.append(bounds)
                let words = ranges.compactMap { range -> TextWord? in
                    guard let box = wordBox(candidate, range) else { return nil }
                    return TextWord(text: String(candidate.string[range]), x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                }
                blocks.append((bounds, TextBlock(text: candidate.string, x: bounds.minX, y: 1 - bounds.maxY, width: bounds.width, height: bounds.height,
                                                 words: !words.isEmpty && words.count == ranges.count ? words : nil)))
                continue
            }
            // A reading that lost to another one may still hold words nobody else
            // read: one pass reads a whole table row ("종로구 Jongno 165,344 23.91"),
            // another only "23.91". Keep the row's other words.
            guard keepsUncoveredWords, candidate.confidence >= 0.3 else { continue }
            var run: [(Range<String.Index>, CGRect)] = []
            func flush() {
                guard let first = run.first, let last = run.last else { return }
                let text = String(candidate.string[first.0.lowerBound..<last.0.upperBound])
                let box = run.map(\.1).reduce(first.1) { $0.union($1) }
                let words = run.map { item -> TextWord in
                    let (r, b) = item
                    return TextWord(text: String(candidate.string[r]), x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                }
                blocks.append((box, TextBlock(text: text, x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height, words: words)))
                taken.append(box)
                run = []
            }
            for range in ranges {
                guard let box = wordBox(candidate, range) else { flush(); continue }
                // Covered: mostly read already, or holding something already read
                // (a long run of CJK text with no spaces is one "word").
                let covered = taken.contains { other in
                    let overlap = box.intersection(other)
                    guard !overlap.isNull else { return false }
                    let area = overlap.width * overlap.height
                    return area > box.width * box.height * 0.3 || area > other.width * other.height * 0.5
                }
                if covered { flush() } else { run.append((range, box)) }
            }
            flush()
        }
        blocks.sort {
            let a = $0.0, b = $1.0
            if abs(a.midY - b.midY) < min(a.height, b.height) * 0.45 { return a.minX < b.minX }
            return a.midY > b.midY
        }
        return blocks.map(\.1)
    }

    /// Prefer the page's own script on low-confidence lines (tests turn it off).
    nonisolated(unsafe) static var prefersPageScript = true
    /// Letters and digits run together the way a Latin model misreads CJK print:
    /// most longer tokens mix letters with digits or symbols, or have no vowel.
    static func junk(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count >= 3 }
        guard !tokens.isEmpty else { return false }
        let bad = tokens.filter { t in
            let letters = t.filter(\.isLetter), digits = t.filter(\.isNumber)
            let odd = t.filter { !$0.isLetter && !$0.isNumber && !".,-'’:;()%/".contains($0) }
            if !letters.isEmpty && !digits.isEmpty { return true }
            if odd.count >= 1 { return true }
            if letters.count >= 4 && !letters.lowercased().contains(where: { "aeiouy".contains($0) }) { return true }
            return false
        }
        return Double(bad.count) / Double(tokens.count) >= 0.5
    }

    private static func script(_ scalar: Unicode.Scalar) -> Script {
        switch scalar.value {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF: return .hangul
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D: return .kana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F: return .han
        case 0x0400...0x052F: return .cyrillic
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x0E00...0x0E7F: return .thai
        case 0...0x024F, 0x1E00...0x1EFF: return .latin
        default: return .other
        }
    }

    // Use separate boxes for Latin and Korean/CJK inside "Toronto(토론토)".
    // Otherwise Latin font proportions shift the Korean selection away from ink.
    // Keep composed characters and joined Arabic/Thai words intact.
    private static func selectionRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var currentScript: Script?
        for index in text.indices {
            let character = text[index]
            let bracket = "()[]{}（）".contains(character)
            let nextScript = character.unicodeScalars.first(where: { CharacterSet.letters.contains($0) }).map(script)
            if character.isWhitespace || bracket || (nextScript != nil && currentScript != nil && nextScript != currentScript) {
                if let lower = start { ranges.append(lower..<index); start = nil }
                currentScript = nil
            }
            if bracket {
                ranges.append(index..<text.index(after: index))
            } else if !character.isWhitespace {
                if start == nil { start = index }
                if let nextScript { currentScript = nextScript }
            }
        }
        if let lower = start { ranges.append(lower..<text.endIndex) }
        return ranges
    }
}
