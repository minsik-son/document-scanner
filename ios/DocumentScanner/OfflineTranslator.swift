import Foundation
import Translation

/// The one place that runs Apple's installed translation models. Every tool that
/// translates (text, document pages, photos) goes through it, so all of them get
/// the same install check, glossary and retry behavior. Nothing is downloaded.
enum OfflineTranslator {
    /// The app's language as a translation language: the default target, so
    /// nobody starts with a language they did not choose.
    static var appLanguage: String { Locale.Language(identifier: AppLanguage.current.rawValue).minimalIdentifier }
    /// Where a page in `source` is translated to by default: the app's language,
    /// else the person's next preferred language, else English (Spanish for English pages).
    static func defaultTarget(for source: String) -> String {
        let candidates = [appLanguage] + Locale.preferredLanguages.map { Locale.Language(identifier: $0).minimalIdentifier }
        if let pick = candidates.first(where: { $0 != source && !$0.isEmpty }) { return pick }
        return source == "en" ? "es" : "en"
    }
    /// Languages the system can translate, with the current pair, sorted by name.
    static func languages(including extra: [String]) async -> [String] {
        let supported = await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier)
        return Set(supported + extra).subtracting([""]).sorted {
            LanguageName.of($0).compare(LanguageName.of($1), options: [.caseInsensitive], locale: AppLanguage.locale) == .orderedAscending
        }
    }
    /// True when the pair is installed; otherwise shows the guide to installing it.
    @MainActor
    static func ensureInstalled(from source: String, to target: String) async -> Bool {
        guard source != target else { return true }
        let installed = await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)) == .installed
        if !installed { TranslationLanguageGuide.present(source: source, target: target) }
        return installed
    }
    /// One text. Headings with a fixed meaning come from the glossary.
    @available(iOS 26.0, *)
    static func translate(_ text: String, from source: String, to target: String) async throws -> String {
        if source == target { return text }
        if let fixed = TranslationGlossary.target(for: text, from: source, to: target) { return fixed }
        let session = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        return try await session.translate(text).targetText
    }
    /// Many texts (areas of a page), eight at a time. A failed batch keeps the
    /// translations already received and retries the rest one by one; areas still
    /// without a translation come back nil. `progress` sees the results so far
    /// after each batch.
    @available(iOS 26.0, *)
    static func translate(_ texts: [String], from source: String, to target: String,
                          progress: (@MainActor ([String?]) -> Void)? = nil) async throws -> [String?] {
        var out = [String?](repeating: nil, count: texts.count)
        var pending: [Int] = []
        for (i, text) in texts.enumerated() {
            if source == target { out[i] = text }
            else if let fixed = TranslationGlossary.target(for: text, from: source, to: target) { out[i] = fixed }
            else { pending.append(i) }
        }
        guard !pending.isEmpty else { await progress?(out); return out }
        let session = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        for start in stride(from: 0, to: pending.count, by: 8) {
            try Task.checkCancellation()
            let batch = Array(pending[start..<min(start + 8, pending.count)])
            let requests = batch.map { TranslationSession.Request(sourceText: texts[$0], clientIdentifier: String($0)) }
            do {
                for response in try await session.translations(from: requests) {
                    guard let id = response.clientIdentifier, let i = Int(id), batch.contains(i) else { continue }
                    out[i] = response.targetText
                }
            } catch { try Task.checkCancellation() }
            // A successful batch can still omit a response: retry those one by one.
            for i in batch where (out[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do { out[i] = try await session.translate(texts[i]).targetText } catch { try Task.checkCancellation() }
            }
            await progress?(out)
        }
        return out
    }
}
