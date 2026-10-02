import SwiftUI

struct MathDocumentView: View {
    @Environment(\.dismiss) private var dismiss
    @State var scan: MathScan
    let onRetake: () -> Void
    private enum Step { case scan, text, format, ready }
    @State private var step = Step.scan
    @State private var text = ""
    @State private var format = MathDocumentEngine.Format.txt
    @State private var includeScan = true
    @State private var original = false
    @State private var zoom = false
    @State private var cropping = false
    @State private var confirmCrop = false
    @State private var sharing = false
    @State private var previewing = false
    @State private var files: ExportedFiles?
    @State private var busy = false
    @State private var error: String?
    @State private var job: Task<Void,Never>?
    @FocusState private var editing: Bool
    private var displayed: UIImage { original ? scan.original : scan.image }
    private var primary: String {
        switch step {
        case .scan:return text.isEmpty ? "Extract text" : "Review text"
        case .text:return "Choose export format"
        case .format:return "Create \(format.extensionName.uppercased())"
        case .ready:return "Share document"
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                header
                switch step {
                case .scan: scanContent
                case .text: textContent
                case .format: formatContent
                case .ready: readyContent
                }
            }.padding(20)
        }
        .background(Color.white).scrollDismissesKeyboard(.interactively).disabled(busy)
        .navigationTitle("Math scan").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement:.topBarLeading) {
                Button(action:back) { Label("Back",systemImage:"chevron.left") }
                    .disabled(busy).accessibilityIdentifier("math-back")
            }
            ToolbarItem(placement:.topBarTrailing) { Button("Close") { dismiss() }.disabled(busy) }
            ToolbarItemGroup(placement:.keyboard) { Spacer();Button("Done") { editing = false } }
        }
        .safeAreaInset(edge:.bottom) {
            VStack(spacing:10) {
                if let error { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("math-error") }
                if busy { HStack { ProgressView();Text("Processing on this iPhone…").font(.subheadline);Spacer();Button("Cancel") { job?.cancel() } } }
                else {
                    Button(primary,action:advance).buttonStyle(PrimaryButton())
                        .disabled(step == .text && text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("math-primary")
                }
            }.padding().background(.regularMaterial)
        }
        .sheet(isPresented:$cropping) {
            NavigationStack {
                CropView(page:ScanPage(imageFile:"",crop:scan.crop),temporaryImage:scan.original) { quad in
                    cropping = false;reprocess(quad)
                }
            }
        }
        .confirmationDialog("Changing the crop will reset your transcription.",isPresented:$confirmCrop,titleVisibility:.visible) {
            Button("Change crop",role:.destructive) { cropping = true }
        }
        .fullScreenCover(isPresented:$zoom) { EnlargedScanPreview(initialImage:displayed) { displayed } }
        .sheet(isPresented:$sharing) { if let files { ShareSheet(items:files.urls) } }
        .sheet(isPresented:$previewing) { if let url = files?.urls.first { OfficeQuickLook(url:url) } }
        .onChange(of:text) { _,_ in clearFiles() }
        .onDisappear {
            if !zoom && !cropping && !sharing && !previewing { job?.cancel();clearFiles() }
        }
    }
    private var header: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text(step == .scan ? "1 · SCAN" : step == .text ? "2 · REVIEW" : step == .format ? "3 · EXPORT" : "DOCUMENT READY")
                    .font(.caption.weight(.semibold)).foregroundStyle(Design.blueInk)
                Spacer();Image(systemName:"function").font(.title2.bold()).foregroundStyle(Design.blueInk)
            }
            Text(step == .scan ? "A clearer page.\nA better starting point." : step == .text ? "Check every symbol." : step == .format ? "Your math, ready to use." : "Your document is ready.")
                .font(.system(size:27,weight:.bold))
            Text(step == .scan ? "Review the corrected scan before extracting text." : step == .text ? "Compare with the scan and correct anything that was missed." : step == .format ? "Choose how you want to use the reviewed text." : "Preview the file, then share or save it to Files.")
                .font(.subheadline).foregroundStyle(.secondary)
        }.padding(22).frame(maxWidth:.infinity,alignment:.leading)
            .background(OfficeHeaderPalette.word.gradient,in:RoundedRectangle(cornerRadius:24))
    }
    private func scanPreview(height:CGFloat) -> some View {
        Button { zoom = true } label: {
            Image(uiImage:displayed).resizable().scaledToFit().frame(maxWidth:.infinity).frame(maxHeight:height)
                .padding(12).background(Design.muted,in:RoundedRectangle(cornerRadius:20))
                .overlay(alignment:.bottomTrailing) { Image(systemName:"arrow.up.left.and.arrow.down.right").padding(14).foregroundStyle(Design.blueInk) }
        }.buttonStyle(.plain).accessibilityLabel("Enlarge scanned page").accessibilityIdentifier("math-scan-preview")
    }
    private var scanContent: some View {
        VStack(alignment:.leading,spacing:18) {
            scanPreview(height:380)
            HStack {
                Button(original ? "Show scan" : "Compare original") { original.toggle() }
                Spacer()
                Button("Crop",systemImage:"crop") { if text.isEmpty { cropping = true } else { confirmCrop = true } }.disabled(busy)
            }.font(.subheadline)
            if !scan.detected { Text("Page edges weren't found. Use Crop to remove the background.").font(.footnote).foregroundStyle(.secondary) }
            if let notice = scan.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            Text("Works offline. Recognition is a draft: handwriting, fractions, powers and matrices may need manual correction.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var textContent: some View {
        VStack(alignment:.leading,spacing:16) {
            scanPreview(height:180)
            HStack { Text("Recognized text").font(.headline);Spacer();Button("Copy") { UIPasteboard.general.string = text }.disabled(text.isEmpty) }
            TextEditor(text:$text).focused($editing).autocorrectionDisabled().textInputAutocapitalization(.never)
                .frame(minHeight:190).padding(12).background(Design.muted,in:RoundedRectangle(cornerRadius:16))
                .accessibilityLabel("Recognized math text").accessibilityIdentifier("math-text")
            Text("Check missing lines, + / − signs and 0 / O. Write fractions as (a+b)/(c+d), powers as x^2 and roots as sqrt(x). Exports keep this text; they do not rebuild equation layout.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var formatContent: some View {
        VStack(alignment:.leading,spacing:12) {
            ForEach(MathDocumentEngine.Format.allCases) { item in
                Button { format = item;clearFiles() } label: {
                    HStack(spacing:14) {
                        Image(systemName:format == item ? "checkmark.circle.fill" : "circle").foregroundStyle(Design.blueInk)
                        VStack(alignment:.leading,spacing:5) {
                            Text(item.rawValue).font(.headline).foregroundStyle(.primary)
                            Text(item.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.extensionName.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Design.blueInk)
                    }.padding(16).background(format == item ? Color.blue.opacity(0.06) : Design.muted,in:RoundedRectangle(cornerRadius:18))
                }.buttonStyle(.plain).accessibilityIdentifier("math-format-\(item.extensionName)")
            }
            if format == .pdf {
                Toggle("Include the scan as a reference page",isOn:$includeScan).font(.subheadline).padding(.vertical,8)
                Text("Recognized text is selectable. The reference page preserves the scanned equation layout as an image.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    private var readyContent: some View {
        VStack(spacing:20) {
            Image(systemName:"doc.text.fill").font(.system(size:64)).foregroundStyle(Design.blueInk).padding(20)
            Text("Math transcription.\(format.extensionName)").font(.headline)
            Text("Contains your reviewed text. Nothing was added to your library automatically.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Preview document",systemImage:"doc.text.magnifyingglass") { previewing = true }.buttonStyle(.bordered).accessibilityIdentifier("math-preview-file")
            Button("Scan another page") { clearFiles();onRetake() }.accessibilityIdentifier("math-another")
        }.frame(maxWidth:.infinity).padding(20)
    }
    private func back() {
        editing = false;error = nil
        switch step {
        case .scan:onRetake()
        case .text:step = .scan
        case .format:step = .text
        case .ready:clearFiles();step = .format
        }
    }
    private func clearFiles() { if let files { ExportFiles.remove(files.directory) };files = nil }
    private func reprocess(_ quad:ScanQuad) {
        work {
            let source = scan.original, notice = scan.notice
            let updated = try await OfflineWork.perform { try MathDocumentEngine.prepare(source,crop:quad) }
            try Task.checkCancellation();scan = updated;scan.notice = notice;text = "";original = false;clearFiles()
        }
    }
    private func advance() {
        editing = false;error = nil
        switch step {
        case .scan:
            if !text.isEmpty { original = false;step = .text;return }
            work {
                let image = scan.image
                let recognized = try await OfflineWork.perform { try MathDocumentEngine.recognize(image) }
                try Task.checkCancellation();text = recognized;original = false;step = .text
                if recognized.isEmpty { error = "No readable text found. You can type it here, or go back and crop or retake the page." }
            }
        case .text:step = .format
        case .format:
            work {
                let body = text, selected = format, reference = includeScan && format == .pdf ? scan.image : nil
                let data = try await OfflineWork.perform { try MathDocumentEngine.export(body,format:selected,reference:reference) }
                try Task.checkCancellation();clearFiles()
                files = try ExportFiles.write([("Math transcription.\(selected.extensionName)",data)]);step = .ready
            }
        case .ready:sharing = true
        }
    }
    private func work(_ action:@escaping @MainActor () async throws -> Void) {
        job?.cancel();busy = true;error = nil
        job = Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { self.error = error is CancellationError ? "Canceled. Your scan is still here." : error.localizedDescription }
        }
    }
}
