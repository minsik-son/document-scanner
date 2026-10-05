import SwiftUI
import Translation

struct PhotoTranslationView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State var scan: TranslationScan
    @State var from: String
    @State var to: String
    let onRetake: () -> Void
    @State private var languages = ["en","ko","ja","zh-Hans","fr","de","es"]
    @State private var composition: TranslationComposition?
    @State private var original = false
    @State private var editAreas = false
    @State private var reviewIssuesOnly = false
    @State private var crop = false
    @State private var zoom = false
    @State private var busy = false
    @State private var phase = "Translating…"
    @State private var error: String?
    @State private var job: Task<Void,Never>?
    @State private var files: ExportedFiles?
    @State private var sharing = false
    @State private var saved = false
    private var ready:Bool { composition != nil }
    private var complete:Bool { !scan.regions.isEmpty && scan.regions.allSatisfy { $0.keepOriginal || !$0.target.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty } }
    private var displayed:UIImage { original ? scan.image : composition?.image ?? scan.image }
    @State private var choosing: LanguageSide?
    private enum LanguageSide: String, Identifiable { case from, to; var id: String { rawValue } }
    private func name(_ code: String) -> String { Locale.current.localizedString(forIdentifier: code) ?? code }
    private var areaCount: Int { scan.regions.filter { !$0.isMarker }.count }
    var body: some View {
        StepStack(step: ready ? 1 : 0, forward: ready) {
            if ready {
                ToolPage(title: "Translated to \(name(to))", subtitle: resultSummary) { resultContent } actions: {
                    Button(composition?.issues.isEmpty == false ? "Share PDF" : "Share translated PDF") { export(save: false) }
                        .buttonStyle(CTAButtonStyle()).disabled(busy).accessibilityIdentifier("translation-share")
                }
            } else {
                ToolPage(title: "Which language?", subtitle: "We'll replace the text in place and keep the page as it is.") { languageContent } actions: {
                    Button(complete ? "Preview translation" : "Translate to \(name(to))") { translate() }
                        .buttonStyle(CTAButtonStyle()).disabled(busy || scan.regions.isEmpty || from == to)
                        .accessibilityIdentifier("translation-run")
                }
            }
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if ready { invalidate(); error = nil } else { onRetake() }
                } label: { Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)) }
                    .disabled(busy).accessibilityLabel("Back").accessibilityIdentifier("translation-back")
            }
            if !ready { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.disabled(busy) } }
        }
        .overlay { if busy { BusyOverlay(text: phase) { job?.cancel() } } }
        .sheet(isPresented: $editAreas) {
            TranslationAreasEditor(regions: scan.regions, image: scan.image, issues: composition?.issues ?? [:], issuesOnly: reviewIssuesOnly) { changed in
                scan.regions = changed; invalidate(); error = nil
            }
        }
        .sheet(isPresented: $crop) {
            CropView(page: ScanPage(imageFile: "", crop: scan.crop), temporaryImage: scan.original) { quad in rescan(quad) }
        }
        .sheet(item: $choosing) { side in
            TranslationLanguageList(title: side == .from ? "Translate from" : "Translate to", languages: languages,
                                    selected: side == .from ? from : to) { code in
                if side == .from { if code == to { to = from }; from = code } else { if code == from { from = to }; to = code }
                choosing = nil
            }
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $zoom) { EnlargedScanPreview(initialImage: displayed) { displayed } }
        .sheet(isPresented: $sharing) { if let files { ShareSheet(items: files.urls) } }
        .onChange(of: from) { _, _ in rereadSourceLanguage() }
        .onChange(of: to) { _, _ in rereadSourceLanguage() }
        .onAppear { if !scan.clarityChecked { scan = TranslationQuality.checked(scan, language: scan.recognitionLanguage ?? from) } }
        .task {
            let supported = await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier)
            languages = Array(Set(supported + [from, to])).sorted { name($0) < name($1) }
        }
        .onDisappear { if !zoom && !sharing && !crop && !editAreas { job?.cancel(); if let files { ExportFiles.remove(files.directory) } } }
    }

    @ViewBuilder private var errorRow: some View {
        if let error {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(TK.red)
                Text(error).font(.system(size: 15, weight: .medium)).foregroundStyle(TK.grey800).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("text-tool-error")
                Spacer(minLength: 0)
            }.padding(16).background(TK.grey100, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
    private var resultSummary: String {
        guard let composition else { return "" }
        let replaced = composition.replaced == 1 ? "1 text area replaced" : "\(composition.replaced) text areas replaced"
        return replaced + (composition.issues.isEmpty ? "" : " · \(composition.issues.count) to check")
    }

    // MARK: Page 1 — pick the languages

    private var languageContent: some View {
        Group {
            VStack(spacing: 0) {
                languageRow(label: "From", code: from, side: .from)
                ZStack {
                    Rectangle().fill(TK.grey100).frame(height: 1)
                    Button { let a = from; from = to; to = a } label: {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 15, weight: .bold)).foregroundStyle(TK.blue)
                            .frame(width: 40, height: 40).background(Color.white, in: Circle())
                            .overlay(Circle().strokeBorder(TK.grey200, lineWidth: 1))
                    }
                    .accessibilityLabel("Swap languages").accessibilityIdentifier("translation-swap")
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 20)
                }
                languageRow(label: "To", code: to, side: .to)
            }
            .background(TK.grey50, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(TK.grey100, lineWidth: 1))
            if from == to {
                Text("Pick two different languages.").font(.footnote).foregroundStyle(TK.orange)
            }
            HStack(alignment: .top, spacing: 14) {
                Button { zoom = true } label: {
                    Image(uiImage: scan.image).resizable().scaledToFit().frame(width: 96, height: 128)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(TK.grey200, lineWidth: 1))
                        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                }
                .buttonStyle(.plain).accessibilityLabel("Enlarge document preview").accessibilityIdentifier("translation-document-preview")
                VStack(alignment: .leading, spacing: 6) {
                    Text(scan.regions.isEmpty ? "No text found" : (areaCount == 1 ? "1 text area found" : "\(areaCount) text areas found"))
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(TK.grey900)
                    Text(scan.regions.isEmpty ? "Adjust the crop or retake a closer photo." : "Tap the page to look closer.")
                        .font(.system(size: 14)).foregroundStyle(TK.grey600)
                    if !scan.edgesDetected {
                        Label("Check the crop", systemImage: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(TK.orange)
                    }
                    if let notice = scan.notice { Text(notice).font(.system(size: 13)).foregroundStyle(TK.grey500) }
                    HStack(spacing: 8) {
                        Button { crop = true } label: { Label("Crop", systemImage: "crop") }.buttonStyle(ChipStyle(selected: false))
                        Button { reviewIssuesOnly = false; editAreas = true } label: { Label("Text", systemImage: "text.viewfinder") }
                            .buttonStyle(ChipStyle(selected: false)).disabled(scan.regions.isEmpty)
                            .accessibilityLabel("Review \(areaCount) text areas").accessibilityIdentifier("translation-edit-areas")
                    }.padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(TK.grey50, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            errorRow
            Label("Offline with languages installed in Apple's Translate app.", systemImage: "lock.shield")
                .font(.system(size: 13)).foregroundStyle(TK.grey500)
        }
    }
    private func languageRow(label: String, code: String, side: LanguageSide) -> some View {
        Button { choosing = side } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(TK.grey500)
                    Text(name(code)).font(.system(size: 22, weight: .bold)).foregroundStyle(TK.grey900)
                }
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 14, weight: .semibold)).foregroundStyle(TK.grey400)
                    .padding(.trailing, side == .from ? 0 : 0)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) \(name(code))").accessibilityHint("Choose a language")
        .accessibilityIdentifier("translation-" + side.rawValue)
    }

    // MARK: Page 2 — the translated page

    private var resultContent: some View {
        Group {
            Picker("Page preview", selection: $original) { Text("Translated").tag(false); Text("Original").tag(true) }.pickerStyle(.segmented)
            Button { zoom = true } label: {
                Image(uiImage: displayed).resizable().scaledToFit().frame(maxWidth: .infinity).frame(maxHeight: 440)
                    .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(TK.grey200, lineWidth: 1))
            }.buttonStyle(.plain).accessibilityLabel("Enlarge document preview").accessibilityIdentifier("translation-document-preview")
            if let composition, !composition.issues.isEmpty {
                Button { reviewIssuesOnly = true; editAreas = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TK.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(composition.issues.count) areas need a look").font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey900)
                                .accessibilityIdentifier("translation-partial")
                            Text(issueSummary(composition)).font(.system(size: 13)).foregroundStyle(TK.grey600).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(TK.grey400)
                    }
                    .padding(16).background(TK.orangeSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain).accessibilityIdentifier("translation-review-issues")
                if composition.reasons.values.contains(.missing) {
                    Button("Retry missing translations") { translate() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.blue)
                        .accessibilityIdentifier("translation-retry")
                }
            }
            HStack(spacing: 8) {
                Button { export(save: true) } label: { Label(saved ? "Saved" : "Save PDF", systemImage: saved ? "checkmark" : "tray.and.arrow.down") }
                    .buttonStyle(ChipStyle(selected: saved)).disabled(saved).accessibilityIdentifier("translation-save")
                ShareLink(item: translationText) { Label("Text only", systemImage: "text.page") }
                    .buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("translation-share-text")
                Button { reviewIssuesOnly = false; editAreas = true } label: { Label("Edit", systemImage: "pencil") }
                    .buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("translation-edit-areas")
            }
            errorRow
            Text("Fonts are approximated. Text we couldn't read stays as in the scan.").font(.system(size: 13)).foregroundStyle(TK.grey500)
        }
    }
    private func issueSummary(_ composition: TranslationComposition) -> String {
        TranslationIssue.allCases.compactMap { reason in
            let count = composition.reasons.values.filter { $0 == reason }.count
            return count > 0 ? "\(count) \(reason.rawValue.lowercased())" : nil
        }.joined(separator: " · ")
    }
    private var translationText:String {
        scan.regions.filter { !$0.isMarker }.map { region in
            if region.keepOriginal { return "[Original kept] " + region.source }
            if region.target.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return "[Translation missing] " + region.source }
            return region.target
        }.joined(separator:"\n\n")
    }
    private func invalidate() { composition = nil;original = false;saved = false;if let files { ExportFiles.remove(files.directory) };files = nil }
    private func clearTranslations() { for i in scan.regions.indices { scan.regions[i].target = "" };invalidate();error = nil }
    private func report(_ failure:Error) { error = failure is CancellationError ? "Canceled. Your original scan is unchanged." : failure.localizedDescription }
    private func rescan(_ quad:ScanQuad) {
        busy = true;error = nil;phase = "Preparing scan…";let source = scan.original,language = from,target = to
        job = Task { defer { busy = false }; do {
            let prepared = try await OfflineWork.perform { try PhotoTranslation.scan(source,crop:quad,sourceLanguage:language,targetLanguage:target) }
            try Task.checkCancellation();scan = TranslationQuality.checked(prepared,language:language);invalidate()
        } catch { report(error) } }
    }
    private func rereadSourceLanguage() {
        job?.cancel();clearTranslations();busy = true;phase = "Reading the source language…"
        let image = scan.reading ?? scan.image,language = from,target = to
        job = Task { defer { busy = false };do {
            let regions = try await OfflineWork.perform {
                guard let cg = image.cgImage else { throw ScannerError.message("The scan couldn't be read.") }
                let blocks = try PhotoTranslationRecognition.recognize(cg,language:language,secondaryLanguage:target)
                return TranslationParagraphs.group(blocks,raster:try TranslationRaster(cg))
            }
            try Task.checkCancellation()
            scan.regions = TranslationQuality.review(regions,language:language,imageHeight:image.size.height*image.scale)
            scan.recognitionLanguage = language;scan.clarityChecked = true
        } catch { report(error) } }
    }
    private func translate() {
        busy = true;error = nil;phase = "Translating text areas…"
        let source = from,target = to,input = scan.image,regions = scan.regions
        job = Task { defer { busy = false }; do {
            if let recognized = scan.recognitionLanguage,recognized != source {
                throw ScannerError.message("Read this page in the selected source language before translating. Select the source language again or adjust the crop to retry.")
            }
            var translated = regions
            var pending = regions.indices.filter { !regions[$0].keepOriginal && regions[$0].target.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
            // Headings and interface labels with a fixed meaning are filled from the glossary.
            for i in pending { if let fixed = TranslationGlossary.target(for:regions[i].source,from:source,to:target) { translated[i].target = fixed } }
            pending = pending.filter { translated[$0].target.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
            if !pending.isEmpty {
                guard pending.reduce(0,{ $0+regions[$1].source.count }) <= 20000 else { throw ScannerError.message("Use a smaller section with up to 20,000 characters.") }
                if source == target { for i in pending { translated[i].target = regions[i].source } }
                else {
                    guard #available(iOS 26.0,*) else { throw ScannerError.message("Offline translation requires iOS 26 or later. You can enter translations in Review text areas.") }
                    let a = Locale.Language(identifier:source),b = Locale.Language(identifier:target)
                    guard await LanguageAvailability().status(from:a,to:b) == .installed else {
                        throw ScannerError.message("Install these languages in Apple's Translate app, then try again. Your scan is kept here. No download was started.")
                    }
                    let session = TranslationSession(installedSource:a,target:b)
                    // Keep successful batches even when one paragraph fails. Retrying only fills missing targets.
                    for start in stride(from:0,to:pending.count,by:8) {
                        try Task.checkCancellation()
                        let batch = Array(pending[start..<min(start+8,pending.count)])
                        let requests = batch.map { TranslationSession.Request(sourceText:regions[$0].source,clientIdentifier:String($0)) }
                        do {
                            let responses = try await session.translations(from:requests)
                            for response in responses {
                                guard let id = response.clientIdentifier,let i = Int(id),batch.contains(i) else { continue }
                                translated[i].target = response.targetText
                            }
                        } catch {
                            try Task.checkCancellation()
                        }
                        // A successful batch can still omit a response. Retry those areas too.
                        for i in batch where translated[i].target.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                                do { translated[i].target = try await session.translate(regions[i].source).targetText }
                                catch { try Task.checkCancellation() }
                        }
                        scan.regions = translated
                    }
                }
            }
            try Task.checkCancellation();phase = "Rebuilding your page…"
            let completed = translated
            scan.regions = completed
            let rendered = try await OfflineWork.perform { try PhotoTranslation.compose(input,regions:completed) }
            try Task.checkCancellation();scan.regions = completed;composition = rendered;original = false
        } catch { report(error) } }
    }
    private func export(save:Bool) {
        guard let composition else { return }
        busy = true;error = nil;phase = "Preparing translated PDF…"
        let name = composition.issues.isEmpty ? "Translated document" : "Partially translated document"
        job = Task { defer { busy = false }; do {
            let data = try await OfflineWork.perform { try OfflineImageEngine.pdf([composition.image],text:[composition.text]) }
            try Task.checkCancellation()
            if save { _ = try await store.saveGeneratedPDF(data,title:name);saved = true }
            else { if let files { ExportFiles.remove(files.directory) };files = try ExportFiles.write([(name+".pdf",data)]);sharing = true }
        } catch { report(error) } }
    }
}

private struct TranslationAreasEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var regions:[TranslationRegion]
    let image:UIImage
    let issues:[Int:String]
    let apply:([TranslationRegion])->Void
    @State private var selected = 0
    @State var issuesOnly:Bool = false
    private var indices:[Int] { regions.indices.filter { !regions[$0].isMarker && (!issuesOnly || issues[regions[$0].id] != nil) } }
    private var snippet:UIImage? {
        guard regions.indices.contains(selected),let cg = image.cgImage else { return nil }
        let b = regions[selected].box
        let rect = CGRect(x:b.minX*CGFloat(cg.width),y:b.minY*CGFloat(cg.height),width:b.width*CGFloat(cg.width),height:b.height*CGFloat(cg.height)).insetBy(dx:-8,dy:-8).integral.intersection(CGRect(x:0,y:0,width:cg.width,height:cg.height))
        return cg.cropping(to:rect).map { UIImage(cgImage:$0) }
    }
    var body: some View {
        NavigationStack {
            Form {
                if regions.indices.contains(selected) {
                    Section {
                        if !issues.isEmpty {
                            Toggle("Only areas needing review",isOn:$issuesOnly).accessibilityIdentifier("translation-issues-filter")
                        }
                        Picker("Text area",selection:$selected) { ForEach(indices,id:\.self) { Text("\($0+1). \(regions[$0].source.prefix(36))").tag($0) } }
                        Text("Edit one area at a time. Empty translations will be filled when you translate the scan.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Original text") {
                        if let snippet = snippet {
                            Image(uiImage:snippet).resizable().scaledToFit().frame(maxWidth:.infinity,maxHeight:160)
                                .padding(8).background(.white,in:RoundedRectangle(cornerRadius:8))
                                .accessibilityLabel("Original scanned text for this area")
                        }
                        TextEditor(text:Binding(get:{ regions[selected].source },set:{ regions[selected].source = $0;regions[selected].target = "" }))
                            .frame(minHeight:100).accessibilityIdentifier("translation-source-text")
                    }
                    Section("Translation") {
                        TextEditor(text:$regions[selected].target).frame(minHeight:120).accessibilityIdentifier("translation-target-text")
                        Button("Copy translation") { UIPasteboard.general.string = regions[selected].target }
                            .disabled(regions[selected].target.isEmpty).accessibilityIdentifier("translation-copy-area")
                        Toggle("Keep original in this area",isOn:$regions[selected].keepOriginal)
                        if regions[selected].unclear {
                            Text("This text was small or hard to read, so it was kept in the original. Check the recognized text above before translating it.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let issue = issues[regions[selected].id] { Text(issue).font(.footnote).foregroundStyle(.orange) }
                    }
                } else { Text("No text areas found. Return to the scan and adjust its crop.") }
            }.onAppear { selected = indices.first ?? 0 }
                .onChange(of:issuesOnly) { _,_ in if !indices.contains(selected) { selected = indices.first ?? 0 } }
                .navigationTitle("Review text areas").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) { Button("Apply") { apply(regions);dismiss() }.accessibilityIdentifier("translation-apply-areas") }
                }
        }
    }
}

/// Full-height language list with search; installed system languages first.
private struct TranslationLanguageList: View {
    let title: String
    let languages: [String]
    let selected: String
    let pick: (String) -> Void
    @State private var query = ""
    private func name(_ code: String) -> String { Locale.current.localizedString(forIdentifier: code) ?? code }
    private var preferred: [String] {
        let mine = Locale.preferredLanguages.map { Locale.Language(identifier: $0).minimalIdentifier }
        return languages.filter { code in mine.contains { $0 == code || $0.hasPrefix(code + "-") || code.hasPrefix($0 + "-") } }
    }
    private func matches(_ code: String) -> Bool { query.isEmpty || name(code).localizedCaseInsensitiveContains(query) }
    var body: some View {
        NavigationStack {
            List {
                let suggested = preferred.filter(matches)
                if !suggested.isEmpty {
                    Section("Your languages") { ForEach(suggested, id: \.self) { row($0) } }
                }
                Section("All languages") { ForEach(languages.filter(matches), id: \.self) { row($0) } }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search languages")
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        }
    }
    private func row(_ code: String) -> some View {
        Button { pick(code) } label: {
            HStack {
                Text(name(code)).font(.system(size: 17)).foregroundStyle(TK.grey900)
                Spacer()
                if code == selected { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(TK.blue) }
            }
        }
        .accessibilityAddTraits(code == selected ? .isSelected : [])
    }
}
