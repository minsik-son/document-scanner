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
    static func recognize(_ image: CGImage, languageCorrection: Bool = true) throws -> [TextBlock] {
        var passes = languagePasses(supported: try supportedLanguages())
        if let passFilter { passes = passes.filter(passFilter) }
        var readings: [Reading] = []
        var lastError: Error?
        var successfulPasses = 0
        for (pass, languages) in passes.enumerated() {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.minimumTextHeight = 0
            request.usesLanguageCorrection = languageCorrection
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = languages
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                successfulPasses += 1
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
        var perPass: [Int: [Script: Double]] = [:]
        for reading in readings {
            let confidence = Double(reading.candidate.confidence)
            for (script, count) in reading.scripts where script != .latin && confidence >= 0.4 {
                perPass[reading.pass, default: [:]][script, default: 0] += Double(min(12, count)) * confidence * confidence
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
            if let support = native.map({ (evidence[$0.key] ?? 0) / strongest }).max(), reading.candidate.confidence >= 0.4 {
                value += 0.46 * support
            }
            // When models agree on a Latin/code line, prefer the Latin model.
            if native.isEmpty && reading.pass == 0 { value += 0.025 }
            return value
        }
        let ordered = readings.sorted {
            let a = score($0), b = score($1)
            return a == b ? $0.pass < $1.pass : a > b
        }
        var chosen: [Reading] = []
        for reading in ordered {
            let box = reading.observation.boundingBox
            let conflicts = chosen.contains { other in
                let otherBox = other.observation.boundingBox
                let overlap = box.intersection(otherBox)
                guard !overlap.isNull else { return false }
                let vertical = overlap.height / max(0.00001, min(box.height, otherBox.height))
                let area = overlap.width * overlap.height
                return vertical > 0.65 && area / max(0.00001, min(box.width * box.height, otherBox.width * otherBox.height)) > 0.65
            }
            if !conflicts { chosen.append(reading) }
        }
        chosen.sort {
            let a = $0.observation.boundingBox, b = $1.observation.boundingBox
            if abs(a.midY - b.midY) < min(a.height, b.height) * 0.45 { return a.minX < b.minX }
            return a.midY > b.midY
        }
        return chosen.map { reading in
            let candidate = reading.candidate, bounds = reading.observation.boundingBox
            let ranges = selectionRanges(in: candidate.string)
            let words = ranges.compactMap { range -> TextWord? in
                guard let geometry = try? candidate.boundingBox(for: range), geometry.boundingBox.width > 0 else { return nil }
                let box = geometry.boundingBox
                return TextWord(text: String(candidate.string[range]), x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            }
            return TextBlock(text: candidate.string, x: bounds.minX, y: 1 - bounds.maxY,
                             width: bounds.width, height: bounds.height,
                             words: !words.isEmpty && words.count == ranges.count ? words : nil)
        }
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
