import SwiftUI
import PhotosUI
import UIKit

struct QRCodeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var image: UIImage?
    @State private var results: [String] = []
    @State private var photo: PhotosPickerItem?
    @State private var camera = false
    @State private var busy = false
    @State private var message: String?
    @State private var share: ExportedFiles?
    @State private var job: Task<Void, Never>?
    @State private var qrFile: ExportedFiles?
    @State private var qrSaved = false
    var body: some View {
        NavigationStack {
            ToolPage(title: "QR code", subtitle: "Read a code with the camera or from a picture, or make your own.") {
                IconHero(icon: "tool-qr", tint: TK.teal, colors: (Color(light: 0xE6F8F3, dark: 0x153729), Color(light: 0xF3FBF9, dark: 0x13281F)))
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Read a QR code")
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { camera = true } label: {
                            ChoiceRow(symbol: "camera.fill", title: "Scan with camera", detail: "Point the camera at a code", tint: TK.blue, soft: TK.blueSoft)
                        }.buttonStyle(.plain).accessibilityIdentifier("qr-camera")
                    }
                    PhotosPicker(selection: $photo, matching: .images) {
                        ChoiceRow(symbol: "photo.fill", title: "Choose QR image", detail: "From your photo library", tint: TK.orange, soft: TK.orangeSoft)
                    }.buttonStyle(.plain).accessibilityIdentifier("qr-photo")
                }
                if !results.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(results, id: \.self) { value in
                            HStack(alignment: .top, spacing: 12) {
                                Text(verbatim: value).font(.system(size: 16)).foregroundStyle(TK.grey900).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                                Button("Copy result") { UIPasteboard.general.string = value }
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(TK.blue)
                            }
                        }
                    }
                    .padding(16).background(TK.grey50, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if let message {
                    ToastMessage(text: message, symbol: results.isEmpty ? "exclamationmark.circle.fill" : "checkmark.circle.fill", tint: results.isEmpty ? TK.red : TK.teal)
                        .accessibilityIdentifier("qr-result")
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Create a QR code")
                    TextField("Text or URL", text: $text, axis: .vertical)
                        .font(.system(size: 16)).foregroundStyle(TK.grey900).lineLimit(1...4)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .padding(.horizontal, 14).padding(.vertical, 13)
                        .background(TK.grey100, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityIdentifier("qr-text")
                    if let image {
                        // A code needs its white quiet zone in dark mode too.
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 220)
                            .padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .frame(maxWidth: .infinity).accessibilityLabel("Generated QR code")
                    }
                }
                Label("Codes are read on this iPhone. Links are not opened automatically.", systemImage: "lock.shield")
                    .font(.system(size: 13)).foregroundStyle(TK.grey500)
            } actions: {
                if image != nil {
                    SaveFirstButton(urls: qrFile?.urls, saved: $qrSaved, photos: true, shareTitle: "Share QR image", shareID: "qr-share", share: { share = qrFile }, finish: { dismiss() })
                } else if !text.isEmpty {
                    Button("Generate QR code") { generate() }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("qr-generate")
                }
            }
            .disabled(busy)
            .overlay { if busy { BusyOverlay(text: "Reading the QR code…") } }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("tool-close") } }
            .sheet(isPresented: $camera) { LocalPhotoCamera { value in camera = false; if let value { read(value) } } }
            .sheet(item: $share, onDismiss: { ExportFiles.cleanExpired() }) { files in
                ShareSheet(items: files.urls)
            }
            .onChange(of: text) { _, _ in image = nil; qrSaved = false; if let qrFile { ExportFiles.remove(qrFile.directory) }; qrFile = nil }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                busy = true; message = nil
                job = Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw ScannerError.message("This image couldn't be read.") }
                        let source = try await Task.detached { try LocalDocumentTools.thumbnail(data) }.value
                        try Task.checkCancellation(); read(source)
                    } catch { busy = false; message = error.localizedDescription }
                }
            }
            .onDisappear { job?.cancel(); if let qrFile { ExportFiles.remove(qrFile.directory) } }
        }
    }
    private func generate() {
        do {
            let made = try LocalDocumentTools.qrImage(text)
            guard let data = made.pngData() else { throw ScannerError.message("Could not encode the result.") }
            if let qrFile { ExportFiles.remove(qrFile.directory) }
            qrFile = try ExportFiles.write([("QR-code.png", data)]); qrSaved = false
            image = made; message = nil
        }
        catch { image = nil; message = error.localizedDescription }
    }
    private func read(_ image: UIImage) {
        busy = true; message = nil; results = []
        job = Task {
            defer { busy = false }
            do {
                let found = try await Task.detached { try LocalDocumentTools.readQR(image) }.value
                try Task.checkCancellation(); results = found
                message = found.isEmpty ? "No QR code found. Try a clearer, closer image." : "\(found.count) QR code(s) read on this iPhone."
            } catch { message = error.localizedDescription }
        }
    }
}
struct LocalPhotoCamera: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let view = UIImagePickerController(); view.sourceType = .camera; view.delegate = context.coordinator; return view
    }
    func updateUIViewController(_ view: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (UIImage?) -> Void
        init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) { completion(info[.originalImage] as? UIImage) }
    }
}

struct ScreenshotStitchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: [PhotosPickerItem] = []
    @State private var pages: [StitchPage] = []
    @State private var selected = 0
    @State private var output: ExportedFiles?
    @State private var share: ExportedFiles?
    @State private var busy = false
    @State private var working = "Opening screenshots…"
    @State private var outputSaved = false
    @State private var message: String?
    @State private var job: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Group {
                if output == nil && pages.isEmpty { landing } else { editor }
            }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy).accessibilityIdentifier("tool-close") } }
                .interactiveDismissDisabled(busy)
                .sheet(item: $share) { files in ShareSheet(items: files.urls) }
                .onAppear { seedUITestScreenshots() }
                .onChange(of: selection) { _, items in load(items) }
                .onDisappear { job?.cancel(); if let output { ExportFiles.remove(output.directory) } }
        }
    }
    /// First screen, laid out like the other tools: hero, one way in, and the promise.
    private var landing: some View {
        ToolPage(title: "Stitch screenshots", subtitle: "Join screenshots of a long chat or page into one tall picture.") {
            IconHero(icon: "tool-stitch", tint: TK.purple, colors: (Color(light: 0xF1EEFF, dark: 0x2E2650), Color(light: 0xF8F6FF, dark: 0x231E3B)))
            PhotosPicker(selection: $selection, maxSelectionCount: 12, selectionBehavior: .ordered, matching: .images) {
                ChoiceRow(symbol: "photo.on.rectangle", title: "Choose screenshots", detail: "Choose 2–12 screenshots from top to bottom. Trim fixed headers and footers, then check each overlap.", tint: TK.purple, soft: TK.purpleSoft)
            }
            .buttonStyle(.plain).accessibilityLabel(L("Choose screenshots")).accessibilityIdentifier("stitch-choose")
            if let message { ToastMessage(text: message) }
            Label("Joined on this iPhone. Nothing is uploaded.", systemImage: "lock.shield")
                .font(.system(size: 13)).foregroundStyle(TK.grey500)
        } actions: { EmptyView() }
        .disabled(busy)
        .overlay { if busy { BusyOverlay(text: working) } }
    }
    /// After choosing: order, trim and overlap, then the long image — on the tool page design.
    private var editor: some View {
        ToolPage(title: output == nil ? "Stitch screenshots" : "Check the long image",
                 subtitle: output == nil ? "Tap a screenshot to see it below, then trim it and check the overlap." : nil) {
            if let output {
                VStack(spacing: 0) {
                    ForEach(output.urls, id: \.self) { url in
                        if let image = LocalDocumentTools.previewImage(url) { Image(uiImage: image).resizable().scaledToFit() }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(TK.grey200, lineWidth: 1))
                Text("\(output.urls.count) PNG file(s). Long results are split into numbered parts.").font(.system(size: 13)).foregroundStyle(TK.grey500)
            } else {
                PhotosPicker(selection: $selection, maxSelectionCount: 12, selectionBehavior: .ordered, matching: .images) {
                    HStack(spacing: 16) {
                        Image("tool-stitch").resizable().interpolation(.high).scaledToFit().frame(width: 34, height: 34)
                            .frame(width: 48, height: 48).background(TK.purpleSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Choose screenshots").font(.system(size: 17, weight: .semibold)).foregroundStyle(TK.grey900)
                            Text("Choose 2–12 screenshots from top to bottom. Trim fixed headers and footers, then check each overlap.")
                                .font(.system(size: 14)).foregroundStyle(TK.grey600).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(TK.grey400)
                    }
                    .padding(.vertical, 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(L("Choose screenshots"))
                if !pages.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Order")
                        VStack(spacing: 8) {
                            ForEach(Array(pages.enumerated()), id: \.element.id) { i, page in orderRow(i, page) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "Crop and overlap")
                        HStack {
                            Text("Screenshot").font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey700)
                            Spacer()
                            Picker("Screenshot", selection: $selected) { ForEach(pages.indices, id: \.self) { Text("Screenshot \($0+1)").tag($0) } }
                                .pickerStyle(.menu).tint(TK.blue).accessibilityIdentifier("stitch-selected")
                        }
                        if pages.indices.contains(selected) {
                            Image(uiImage: pages[selected].image).resizable().scaledToFit().frame(maxHeight: 260)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .frame(maxWidth: .infinity)
                                .id(pages[selected].id)
                            trimSlider("Trim top", label: "Trim screenshot top", value: $pages[selected].top, range: 0...0.3)
                            trimSlider("Trim bottom", label: "Trim screenshot bottom", value: $pages[selected].bottom, range: 0...0.3)
                            if selected > 0 {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("Overlap with previous").font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey700)
                                        Spacer()
                                        Text("\(Int(pages[selected].overlap*100))%").font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.blue).monospacedDigit()
                                    }
                                    Slider(value: $pages[selected].overlap, in: 0...0.8, step: 0.001).tint(TK.blue).accessibilityLabel("Screenshot overlap")
                                }
                                Button("Find overlap") { detectOverlap() }.buttonStyle(ChipStyle(selected: false))
                            }
                        }
                    }
                    .padding(16).background(TK.grey50, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
            }
        } actions: {
            if let message { Text(L(message)).font(.system(size: 13)).foregroundStyle(TK.grey600).multilineTextAlignment(.center).accessibilityIdentifier("stitch-status") }
            if let output {
                HStack(spacing: 10) {
                    Button("Change seams") { ExportFiles.remove(output.directory); self.output = nil; message = nil; outputSaved = false }
                        .buttonStyle(SecondaryCTAStyle())
                    SaveFirstButton(urls: output.urls, saved: $outputSaved, photos: true, shareTitle: "Share long image", shareID: "stitch-share", share: { share = output }, finish: { dismiss() })
                }
            } else if !pages.isEmpty {
                Button("Preview long image") { export() }.buttonStyle(CTAButtonStyle()).disabled(pages.count < 2)
            }
        }
        .disabled(busy)
        .overlay { if busy { BusyOverlay(text: working) } }
    }
    /// One screenshot in the order list: tapping it shows it in the trim preview below.
    private func orderRow(_ i: Int, _ page: StitchPage) -> some View {
        let chosen = i == selected
        return HStack(spacing: 12) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { selected = i } } label: {
                HStack(spacing: 12) {
                    Image(uiImage: page.image).resizable().scaledToFill().frame(width: 34, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("Screenshot \(i+1)").font(.system(size: 16, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? TK.blue : TK.grey900)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("stitch-row-\(i+1)")
            .accessibilityAddTraits(chosen ? .isSelected : [])
            Button { pages.swapAt(i, i-1); if selected == i { selected = i-1 } else if selected == i-1 { selected = i }; resetSeams() } label: {
                Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).frame(width: 36, height: 36)
            }.disabled(i == 0).accessibilityLabel("Move screenshot \(i+1) earlier")
            Button { pages.swapAt(i, i+1); if selected == i { selected = i+1 } else if selected == i+1 { selected = i }; resetSeams() } label: {
                Image(systemName: "arrow.down").font(.system(size: 16, weight: .semibold)).frame(width: 36, height: 36)
            }.disabled(i == pages.count-1).accessibilityLabel("Move screenshot \(i+1) later")
        }
        .buttonStyle(.borderless).tint(TK.blue)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(chosen ? TK.blueSoft : TK.grey50, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(chosen ? TK.blue.opacity(0.45) : .clear, lineWidth: 1.5))
    }
    private func trimSlider(_ title: String, label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L(title)).font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey700)
                Spacer()
                Text("\(Int(value.wrappedValue*100))%").font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.blue).monospacedDigit()
            }
            Slider(value: value, in: range, step: 0.001).tint(TK.blue).accessibilityLabel(L(label))
                .onChange(of: value.wrappedValue) { _, _ in resetSeams() }
        }
    }
    private func seedUITestScreenshots() {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard pages.isEmpty, args.contains("--seed-screenshots"),
              let flag = args.firstIndex(of: "--ui-test-session"), args.indices.contains(flag+1), UUID(uuidString: args[flag+1]) != nil else { return }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 1600), format: format).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 400, height: 1600))
            for row in 0..<32 {
                UIColor(hue: CGFloat(row)/32, saturation: 0.4, brightness: 0.8, alpha: 1).setFill()
                c.fill(CGRect(x: 20, y: row*50, width: 40+row*7, height: 20))
                ("ROW \(row) • Offline stitching" as NSString).draw(at: CGPoint(x: 20, y: row*50+22), withAttributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.black])
            }
        }
        if let a = image.cgImage?.cropping(to: CGRect(x: 0,y: 0,width: 400,height: 1000)),
           let b = image.cgImage?.cropping(to: CGRect(x: 0,y: 600,width: 400,height: 1000)) {
            pages = [StitchPage(image: UIImage(cgImage: a)), StitchPage(image: UIImage(cgImage: b))]
        }
#endif
    }
    private func resetSeams() { for i in pages.indices { pages[i].overlap = 0 } }
    private func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        busy = true; message = nil; working = "Opening screenshots…"
        job = Task {
            defer { busy = false }
            do {
                var loaded: [StitchPage] = []
                for item in items {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw ScannerError.message("A screenshot couldn't be opened. Your previous selection was kept.") }
                    let image = try await Task.detached { try LocalDocumentTools.thumbnail(data, maxPixels: 2400) }.value
                    try Task.checkCancellation(); loaded.append(StitchPage(image: image))
                }
                pages = loaded; selected = 0
            } catch { message = error.localizedDescription }
        }
    }
    private func detectOverlap() {
        guard selected > 0 else { return }
        busy = true; message = nil; working = "Finding the overlap…"
        let index = selected, before = pages[index-1], after = pages[index]
        job = Task {
            defer { busy = false }
            do {
                let value = try await Task.detached { ScreenshotStitcher.suggestedOverlap(previous: try ScreenshotStitcher.cropped(before), next: try ScreenshotStitcher.cropped(after)) }.value
                try Task.checkCancellation()
                if let value { pages[index].overlap = value; message = "Overlap suggested. Check the full preview before sharing." }
                else { pages[index].overlap = 0; message = "No reliable overlap found. Adjust it manually; no content was removed." }
            } catch { message = error.localizedDescription }
        }
    }
    private func export() {
        busy = true; message = nil; working = "Joining the screenshots…"; let snapshot = pages
        job = Task {
            defer { busy = false }
            do {
                let result = try await Task.detached { try ScreenshotStitcher.export(snapshot) }.value
                if Task.isCancelled { ExportFiles.remove(result.directory); throw CancellationError() }
                output = result
            } catch { message = error.localizedDescription }
        }
    }
}
