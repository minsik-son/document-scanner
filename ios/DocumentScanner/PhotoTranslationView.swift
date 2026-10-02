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
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                VStack(alignment:.leading,spacing:8) {
                    Text(ready ? "Review translation" : "Review scan").font(.caption.weight(.semibold)).foregroundStyle(Design.blueInk)
                    Text(ready ? "Your translation preview" : "Keep the page.\nChange the language.").font(.system(size:28,weight:.bold))
                    Text(ready ? "Compare the page and check each text area before sharing." : "We'll replace the text in place, keeping the scanned page underneath.").font(.subheadline).foregroundStyle(.secondary)
                }.padding(22).frame(maxWidth:.infinity,alignment:.leading)
                    .background(OfficeHeaderPalette.word.gradient,in:RoundedRectangle(cornerRadius:24))
                if let notice = scan.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                if ready {
                    Picker("Page preview",selection:$original) { Text("Translated").tag(false);Text("Original scan").tag(true) }.pickerStyle(.segmented)
                }
                Button { zoom = true } label: {
                    Image(uiImage:displayed).resizable().scaledToFit().frame(maxWidth:.infinity).frame(maxHeight:470)
                        .padding(10).background(.white,in:RoundedRectangle(cornerRadius:18))
                }.buttonStyle(.plain).accessibilityLabel("Enlarge document preview").accessibilityIdentifier("translation-document-preview")
                HStack {
                    if !ready { Button { crop = true } label: { Label("Crop",systemImage:"crop") } }
                    Spacer()
                    Button { reviewIssuesOnly = false;editAreas = true } label: { Label("Review \(scan.regions.filter { !$0.isMarker }.count) text areas",systemImage:"text.viewfinder") }
                        .accessibilityIdentifier("translation-edit-areas")
                }.font(.subheadline)
                if let composition {
                    Text("\(composition.replaced) text areas replaced").font(.subheadline.weight(.semibold))
                    if !composition.issues.isEmpty {
                        VStack(alignment:.leading,spacing:10) {
                            Text("\(composition.issues.count) areas need review").font(.subheadline.weight(.semibold))
                                .accessibilityIdentifier("translation-partial")
                            ForEach(TranslationIssue.allCases,id:\.self) { reason in
                                let count = composition.reasons.values.filter { $0 == reason }.count
                                if count > 0 { Text("\(count) · \(reason.rawValue)").font(.footnote) }
                            }
                            Button("Review these areas") { reviewIssuesOnly = true;editAreas = true }
                                .accessibilityIdentifier("translation-review-issues")
                            Text("Available translations can be copied even when they don't fit on the page.").font(.footnote)
                            if composition.reasons.values.contains(.missing) {
                                Button("Retry missing translations") { translate() }.accessibilityIdentifier("translation-retry")
                            }
                        }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                            .background(Color.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:16))
                    }
                    if composition.kept > 0 { Text("\(composition.kept) kept by you").font(.footnote).foregroundStyle(.secondary) }
                    if composition.unclear > 0 {
                        Text("\(composition.unclear) small or unclear areas stayed in the original language, so no guessed translation was added. To translate one anyway, open Review and turn off Keep original.")
                            .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("translation-unclear")
                    }
                    if composition.unchanged > 0 { Text("\(composition.unchanged) translations match the original. Check names, numbers and any text still in the source language.").font(.footnote).foregroundStyle(.secondary) }
                    ShareLink(item:translationText) { Label("Share translation text",systemImage:"text.page") }
                        .accessibilityIdentifier("translation-share-text")
                    Text("Original fonts are approximated. Unrecognized text stays in the scan.").font(.footnote).foregroundStyle(.secondary)
                    Button(saved ? "Saved to Documents" : "Save PDF copy to Documents") { export(save:true) }.disabled(saved)
                        .accessibilityIdentifier("translation-save")
                } else {
                    HStack {
                        Picker("From",selection:$from) { ForEach(languages,id:\.self) { Text(Locale.current.localizedString(forIdentifier:$0) ?? $0).tag($0) } }
                        Image(systemName:"arrow.right")
                        Picker("To",selection:$to) { ForEach(languages,id:\.self) { Text(Locale.current.localizedString(forIdentifier:$0) ?? $0).tag($0) } }
                    }.frame(maxWidth:.infinity).tint(Design.blueInk)
                    if !scan.edgesDetected {
                        Text("Paper edges weren't found. Check the crop before translating.").font(.footnote).foregroundStyle(.orange)
                    }
                    if scan.regions.isEmpty { Text("No text found. Adjust the crop or retake a closer photo.").foregroundStyle(.secondary) }
                    Text("Works offline with installed languages on iOS 26+. Complex backgrounds and text that won't fit are kept in the original language for review.").font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(20)
        }.background(Design.muted).disabled(busy)
            .navigationTitle("Photo translation").navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) {
                    Button {
                        if ready { invalidate(); error = nil } else { onRetake() }
                    } label: { Label("Back",systemImage:"chevron.left") }.disabled(busy).accessibilityIdentifier("translation-back")
                }
                ToolbarItem(placement:.topBarTrailing) { Button("Close") { dismiss() }.disabled(busy) }
            }
            .safeAreaInset(edge:.bottom) {
                VStack(spacing:10) {
                    if let error { Text(error).font(.footnote).foregroundStyle(.red).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("text-tool-error") }
                    if busy { HStack { ProgressView();Text(phase).font(.subheadline);Spacer();Button("Cancel") { job?.cancel() } } }
                    else {
                        Button(ready ? (composition?.issues.isEmpty == false ? "Share PDF with original areas" : "Share translated PDF") : complete ? "Preview translation" : "Translate scan") {
                            if ready { export(save:false) } else { translate() }
                        }.buttonStyle(PrimaryButton()).disabled(scan.regions.isEmpty)
                            .accessibilityIdentifier(ready ? "translation-share" : "translation-run")
                    }
                }.padding().background(.regularMaterial)
            }
            .sheet(isPresented:$editAreas) {
                TranslationAreasEditor(regions:scan.regions,image:scan.image,issues:composition?.issues ?? [:],issuesOnly:reviewIssuesOnly) { changed in
                    scan.regions = changed; invalidate();error = nil
                }
            }
            .sheet(isPresented:$crop) {
                CropView(page:ScanPage(imageFile:"",crop:scan.crop),temporaryImage:scan.original) { quad in rescan(quad) }
            }
            .fullScreenCover(isPresented:$zoom) { EnlargedScanPreview(initialImage:displayed) { displayed } }
            .sheet(isPresented:$sharing) { if let files { ShareSheet(items:files.urls) } }
            .onChange(of:from) { _,_ in rereadSourceLanguage() }
            .onChange(of:to) { _,_ in rereadSourceLanguage() }
            .onAppear { if !scan.clarityChecked { scan = TranslationQuality.checked(scan,language:scan.recognitionLanguage ?? from) } }
            .task {
                let supported = await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier)
                languages = Array(Set(supported+[from,to])).sorted()
            }
            .onDisappear { if !zoom && !sharing && !crop && !editAreas { job?.cancel(); if let files { ExportFiles.remove(files.directory) } } }
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
        clearTranslations();busy = true;phase = "Reading the source language…"
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
