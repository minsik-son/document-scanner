import Foundation

/// Plain-text view of page layouts for review, and mapping of the reviewed
/// text back onto the layout so corrections keep their formatting.
/// Each paragraph line and each table row is one text line; segments and
/// table cells are separated by tabs; pages by form feeds.
enum LayoutText {
    enum Slot: Equatable {
        case line(item: Int, line: Int)
        case row(item: Int, row: Int)
    }

    static func lines(_ page: PageLayout) -> [(Slot, String)] {
        var result: [(Slot, String)] = []
        for (index, item) in page.items.enumerated() {
            switch item {
            case .paragraph(let p):
                for (n, line) in p.lines.enumerated() { result.append((.line(item: index, line: n), line.text)) }
            case .table(let t):
                for r in 0..<t.rowCount {
                    let cells = t.cells.filter { $0.row == r }.sorted { $0.column < $1.column }
                    result.append((.row(item: index, row: r), cells.map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")))
                }
            }
        }
        return result
    }

    /// True when edited text is still a revision of the recognized text
    /// (most lines survive), not something typed from scratch.
    static func related(_ edited: String, _ recognized: String) -> Bool {
        let original = Set(recognized.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: "\u{000c}"))).filter { !$0.isEmpty })
        guard !original.isEmpty else { return false }
        let kept = edited.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: "\u{000c}"))).filter { original.contains($0) }.count
        return Double(kept) >= Double(original.count) * 0.3
    }

    static func text(_ pages: [PageLayout]) -> String {
        pages.map { lines($0).map(\.1).joined(separator: "\n") }.joined(separator: "\u{000c}")
    }

    /// Applies reviewed text. Returns nil when the page structure no longer
    /// matches (for example a page separator was removed).
    static func apply(_ edited: String, to pages: [PageLayout]) -> [PageLayout]? {
        let editedPages = edited.components(separatedBy: "\u{000c}")
        guard editedPages.count == pages.count else { return nil }
        return zip(pages, editedPages).map { apply($1, to: $0) }
    }

    static func apply(_ edited: String, to page: PageLayout) -> PageLayout {
        let original = lines(page)
        let new = edited.components(separatedBy: "\n")
        if original.map(\.1) == new { return page }
        // Longest common subsequence of unchanged lines.
        let n = original.count, m = new.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for a in stride(from: n - 1, through: 0, by: -1) { for b in stride(from: m - 1, through: 0, by: -1) {
                dp[a][b] = original[a].1 == new[b] ? dp[a + 1][b + 1] + 1 : max(dp[a + 1][b], dp[a][b + 1])
            } }
        }
        var replacements: [(Slot, [String])] = [] // slot -> new lines (empty = removed)
        var a = 0, b = 0
        var removedSlots: [Slot] = [], added: [String] = []
        var lastSlot: Slot? = nil
        func flush() {
            // Pair changed lines with removed slots in order; extra lines join the last slot.
            for (k, slot) in removedSlots.enumerated() {
                if k < added.count {
                    let extra = k == removedSlots.count - 1 ? Array(added.dropFirst(k + 1)) : []
                    replacements.append((slot, [added[k]] + extra))
                } else { replacements.append((slot, [])) }
            }
            if removedSlots.isEmpty, !added.isEmpty, let slot = lastSlot ?? original.first?.0 {
                let current = original.first { $0.0 == slot }?.1 ?? ""
                replacements.append((slot, lastSlot == nil ? added + [current] : [current] + added))
            }
            removedSlots = []; added = []
        }
        while a < n || b < m {
            if a < n && b < m && original[a].1 == new[b] { flush(); lastSlot = original[a].0; a += 1; b += 1 }
            else if b < m && (a == n || dp[a][b + 1] >= dp[a + 1][b]) { added.append(new[b]); b += 1 }
            else { removedSlots.append(original[a].0); a += 1 }
        }
        flush()
        var result = page
        // Later slots first so inserted lines never shift a pending slot.
        func order(_ s: Slot) -> (Int, Int) { switch s { case .line(let i, let l): return (i, l); case .row(let i, let r): return (i, r) } }
        for (slot, texts) in replacements.sorted(by: { order($0.0) > order($1.0) }) { replace(&result, slot: slot, with: texts) }
        return compact(result)
    }

    static func styled(_ text: String, like runs: [LayoutRun]) -> [LayoutRun] {
        if runs.map(\.text).joined() == text { return runs }
        var run = runs.first(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) ?? runs.first ?? LayoutRun(text: "")
        // Keep the line's dominant weight rather than the first word's.
        let bold = runs.filter(\.bold).reduce(0) { $0 + $1.text.count } * 2 > runs.reduce(0) { $0 + $1.text.count }
        run.bold = bold; run.text = text
        return text.isEmpty ? [] : [run]
    }

    static func replace(_ page: inout PageLayout, slot: Slot, with texts: [String]) {
        switch slot {
        case .line(let index, let n):
            guard case .paragraph(var p) = page.items[index], p.lines.indices.contains(n) else { return }
            let old = p.lines[n]
            var newLines: [LayoutLine] = []
            for (k, text) in texts.enumerated() {
                var line = old
                let parts = text.components(separatedBy: "\t")
                if parts.count == old.segments.count {
                    for s in line.segments.indices { line.segments[s].runs = styled(parts[s], like: old.segments[s].runs) }
                } else {
                    var seg = old.segments[0]
                    seg.runs = styled(parts.joined(separator: " "), like: old.segments.flatMap(\.runs))
                    line.segments = [seg]
                }
                if k > 0 { line.wraps = false }
                if k < texts.count - 1 { line.wraps = false }
                newLines.append(line)
            }
            p.lines.replaceSubrange(n...n, with: newLines)
            // Paragraph line indices after this one shift; keep later slots valid by
            // marking removed lines instead of deleting when nothing replaces them.
            if newLines.isEmpty { p.lines.insert(LayoutLine(segments: [], box: old.box), at: n) }
            page.items[index] = .paragraph(p)
        case .row(let index, let r):
            guard case .table(var t) = page.items[index] else { return }
            let cells = t.cells.indices.filter { t.cells[$0].row == r }.sorted { t.cells[$0].column < t.cells[$1].column }
            let joined = texts.joined(separator: " ")
            var parts = joined.components(separatedBy: "\t")
            if parts.count > cells.count, !cells.isEmpty {
                let tail = parts[(cells.count - 1)...].joined(separator: " ")
                parts = Array(parts.prefix(cells.count - 1)) + [tail]
            }
            for (k, ci) in cells.enumerated() {
                let text = k < parts.count ? parts[k] : ""
                if t.cells[ci].text.replacingOccurrences(of: "\n", with: " ") == text { continue }
                let like = t.cells[ci].lines.flatMap { $0 }
                let runs = styled(text, like: like.isEmpty ? [LayoutRun(text: "")] : like)
                t.cells[ci].lines = runs.isEmpty ? [] : [runs]
            }
            page.items[index] = .table(t)
        }
    }

    /// Removes placeholder lines left by `replace` (called once all slots are applied).
    static func compact(_ page: PageLayout) -> PageLayout {
        var page = page
        page.items = page.items.compactMap { item in
            guard case .paragraph(var p) = item else { return item }
            p.lines = p.lines.filter { !$0.segments.isEmpty }
            return p.lines.isEmpty ? nil : .paragraph(p)
        }
        return page
    }
}
