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
    @State private var forward = true
    private var stepIndex: Int { step == .scan ? 0 : step == .text ? 1 : step == .format ? 2 : 3 }
    var body: some View {
        StepStack(step: stepIndex, forward: forward) {
            switch step {
            case .scan:
                ToolPage(title: "Check the scan", subtitle: "We straightened the page. Crop it if the background shows.") { scanContent } actions: { primaryButton }
            case .text:
                ToolPage(title: "Check every symbol", subtitle: "Compare with the scan and fix anything we missed.") { textContent } actions: { primaryButton }
            case .format:
                ToolPage(title: "How will you use it?", subtitle: "Pick a file type for the reviewed text.") { formatContent } actions: { primaryButton }
            case .ready:
                ToolPage(title: "") { readyContent } actions: {
                    Button("Preview") { previewing = true }.buttonStyle(SecondaryCTAStyle()).accessibilityIdentifier("math-preview-file")
                    primaryButton
                }
            }
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement:.topBarLeading) {
                Button(action:back) { Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)) }
                    .disabled(busy).accessibilityLabel("Back").accessibilityIdentifier("math-back")
            }
            if step == .scan { ToolbarItem(placement:.topBarTrailing) { Button("Close") { dismiss() }.disabled(busy) } }
            ToolbarItemGroup(placement:.keyboard) { Spacer();Button("Done") { editing = false } }
        }
        .overlay { if busy { BusyOverlay(text: "Processing on this iPhone…") { job?.cancel() } } }
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
    private var primaryButton: some View {
        Button(primary,action:advance).buttonStyle(CTAButtonStyle())
            .disabled(busy || (step == .text && text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty))
            .accessibilityIdentifier("math-primary")
    }
    @ViewBuilder private var errorRow: some View {
        if let error {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(TK.red)
                Text(error).font(.system(size: 15, weight: .medium)).foregroundStyle(TK.grey800).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("math-error")
                Spacer(minLength: 0)
            }.padding(16).background(TK.grey100, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
    private func scanPreview(height:CGFloat) -> some View {
        Button { zoom = true } label: {
            Image(uiImage:displayed).resizable().scaledToFit().frame(maxWidth:.infinity).frame(maxHeight:height)
                .padding(10).background(TK.grey50,in:RoundedRectangle(cornerRadius:20, style: .continuous))
        }.buttonStyle(.plain).accessibilityLabel("Enlarge scanned page").accessibilityIdentifier("math-scan-preview")
    }
    private var scanContent: some View {
        Group {
            scanPreview(height:360)
            HStack(spacing: 8) {
                Button { original.toggle() } label: { Label(original ? "Show scan" : "Original", systemImage: "rectangle.on.rectangle") }.buttonStyle(ChipStyle(selected: original))
                Button { if text.isEmpty { cropping = true } else { confirmCrop = true } } label: { Label("Crop", systemImage: "crop") }.buttonStyle(ChipStyle(selected: false)).disabled(busy)
            }
            if !scan.detected {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TK.orange)
                    Text("Page edges weren't found. Crop to remove the background.").font(.system(size: 15, weight: .medium)).foregroundStyle(TK.grey800)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(TK.orangeSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if let notice = scan.notice { Text(notice).font(.system(size: 13)).foregroundStyle(TK.grey500) }
            errorRow
            Label("Works offline. Handwriting, fractions and matrices may need fixing.", systemImage: "lock.shield").font(.system(size: 13)).foregroundStyle(TK.grey500)
        }
    }
    private var textContent: some View {
        Group {
            scanPreview(height:170)
            TextEditor(text:$text).focused($editing).autocorrectionDisabled().textInputAutocapitalization(.never)
                .font(.system(size: 17, design: .monospaced)).scrollContentBackground(.hidden)
                .frame(minHeight:200).padding(12).background(TK.grey50,in:RoundedRectangle(cornerRadius:20, style: .continuous))
                .accessibilityLabel("Recognized math text").accessibilityIdentifier("math-text")
            HStack(spacing: 8) {
                Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(ChipStyle(selected: false)).disabled(text.isEmpty)
            }
            errorRow
            Text("Write fractions as (a+b)/(c+d), powers as x^2 and roots as sqrt(x).").font(.system(size: 13)).foregroundStyle(TK.grey500).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var formatContent: some View {
        Group {
            VStack(spacing: 10) {
                ForEach(MathDocumentEngine.Format.allCases) { item in
                    Button { format = item;clearFiles() } label: {
                        OptionCard(title: item.rawValue, detail: item.detail, selected: format == item) {
                            Text(item.extensionName.uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(format == item ? TK.blue : TK.grey500)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("math-format-\(item.extensionName)")
                }
            }
            if format == .pdf {
                Button { includeScan.toggle() } label: { Label("Add the scan as a reference page", systemImage: includeScan ? "checkmark.square.fill" : "square") }
                    .buttonStyle(ChipStyle(selected: includeScan))
            }
            errorRow
        }
    }
    private var readyContent: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(TK.blueSoft).frame(width: 132, height: 132)
                Circle().fill(TK.blue).frame(width: 84, height: 84)
                Image(systemName: "checkmark").font(.system(size: 38, weight: .bold)).foregroundStyle(.white)
            }.padding(.top, 24).accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Your document is ready").font(.system(size: 24, weight: .bold)).foregroundStyle(TK.grey900)
                Text("Math transcription.\(format.extensionName)").font(.system(size: 16)).foregroundStyle(TK.grey600)
            }
            Button("Scan another page") { clearFiles();onRetake() }.buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("math-another")
        }.frame(maxWidth: .infinity)
    }
    private func back() {
        editing = false;error = nil
        switch step {
        case .scan:onRetake()
        case .text:forward = false;step = .scan
        case .format:forward = false;step = .text
        case .ready:clearFiles();forward = false;step = .format
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
            if !text.isEmpty { original = false;forward = true;step = .text;return }
            work {
                let image = scan.image
                let recognized = try await OfflineWork.perform { try MathDocumentEngine.recognize(image) }
                try Task.checkCancellation();text = recognized;original = false;forward = true;step = .text
                if recognized.isEmpty { error = "No readable text found. You can type it here, or go back and crop or retake the page." }
            }
        case .text:forward = true;step = .format
        case .format:
            work {
                let body = text, selected = format, reference = includeScan && format == .pdf ? scan.image : nil
                let data = try await OfflineWork.perform { try MathDocumentEngine.export(body,format:selected,reference:reference) }
                try Task.checkCancellation();clearFiles()
                files = try ExportFiles.write([("Math transcription.\(selected.extensionName)",data)]);forward = true;step = .ready
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
