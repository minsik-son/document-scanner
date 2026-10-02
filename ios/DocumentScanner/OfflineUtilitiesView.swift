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
    var body: some View {
        NavigationStack {
            Form {
                Section("Read a QR code") {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) { Button("Scan with camera") { camera = true } }
                    PhotosPicker("Choose QR image", selection: $photo, matching: .images)
                    ForEach(results, id: \.self) { value in
                        Text(value).textSelection(.enabled)
                        Button("Copy result") { UIPasteboard.general.string = value }
                    }
                    Text("Codes are read on this iPhone. Links are not opened automatically.").font(.caption)
                }
                Section("Create a QR code") {
                    TextField("Text or URL", text: $text, axis: .vertical).autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityIdentifier("qr-text")
                    Button("Generate QR code") { generate() }.disabled(text.isEmpty).accessibilityIdentifier("qr-generate")
                    if let image {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxHeight: 260).accessibilityLabel("Generated QR code")
                        Button("Share QR image") {
                            do {
                                guard let data = image.pngData() else { return }
                                share = try ExportFiles.write([("QR-code.png", data)])
                            } catch { message = error.localizedDescription }
                        }.accessibilityIdentifier("qr-share")
                    }
                }
                if busy { ProgressView("Reading on this iPhone…") }
                if let message { Text(message).accessibilityIdentifier("qr-result") }
            }
            .disabled(busy)
            .navigationTitle("QR code").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $camera) { LocalPhotoCamera { value in camera = false; if let value { read(value) } } }
            .sheet(item: $share, onDismiss: { ExportFiles.cleanExpired() }) { files in
                ShareSheet(items: files.urls, completion: { _, _ in ExportFiles.remove(files.directory) })
            }
            .onChange(of: text) { _, _ in image = nil }
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
            .onDisappear { job?.cancel() }
        }
    }
    private func generate() {
        do { image = try LocalDocumentTools.qrImage(text); message = nil }
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
    @State private var message: String?
    @State private var job: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                if let output {
                    Section("Preview") {
                        ForEach(output.urls, id: \.self) { url in
                            if let image = LocalDocumentTools.previewImage(url) { Image(uiImage: image).resizable().scaledToFit() }
                        }
                        Text("\(output.urls.count) PNG file(s). Long results are split into numbered parts.").font(.caption)

                    }
                } else {
                    Section {
                        PhotosPicker(selection: $selection, maxSelectionCount: 12, selectionBehavior: .ordered, matching: .images) { Label("Choose screenshots", systemImage: "photo.on.rectangle") }
                        Text("Choose 2–12 screenshots from top to bottom. Trim fixed headers and footers, then check each overlap.").font(.footnote)
                    }
                    if !pages.isEmpty {
                        Section("Order") {
                            ForEach(Array(pages.enumerated()), id: \.element.id) { i, _ in
                                HStack {
                                    Text("Screenshot \(i+1)")
                                    Spacer()
                                    Button { pages.swapAt(i,i-1); resetSeams() } label: { Image(systemName: "arrow.up") }.disabled(i == 0).accessibilityLabel("Move screenshot \(i+1) earlier")
                                    Button { pages.swapAt(i,i+1); resetSeams() } label: { Image(systemName: "arrow.down") }.disabled(i == pages.count-1).accessibilityLabel("Move screenshot \(i+1) later")
                                }.buttonStyle(.borderless)
                            }
                        }
                        Section("Crop and overlap") {
                            Picker("Screenshot", selection: $selected) { ForEach(pages.indices, id: \.self) { Text("Screenshot \($0+1)").tag($0) } }.accessibilityIdentifier("stitch-selected")
                            if pages.indices.contains(selected) {
                                Image(uiImage: pages[selected].image).resizable().scaledToFit().frame(maxHeight: 220)
                                LabeledContent("Trim top", value: "\(Int(pages[selected].top*100))%")
                                Slider(value: $pages[selected].top, in: 0...0.3, step: 0.001).accessibilityLabel("Trim screenshot top").onChange(of: pages[selected].top) { _, _ in resetSeams() }
                                LabeledContent("Trim bottom", value: "\(Int(pages[selected].bottom*100))%")
                                Slider(value: $pages[selected].bottom, in: 0...0.3, step: 0.001).accessibilityLabel("Trim screenshot bottom").onChange(of: pages[selected].bottom) { _, _ in resetSeams() }
                                if selected > 0 {
                                    LabeledContent("Overlap with previous", value: "\(Int(pages[selected].overlap*100))%")
                                    Slider(value: $pages[selected].overlap, in: 0...0.8, step: 0.001).accessibilityLabel("Screenshot overlap")
                                    Button("Find overlap") { detectOverlap() }
                                }
                            }
                        }

                    }
                }
                if busy { ProgressView("Preparing on this iPhone…") }
            }.disabled(busy)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        if let message { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("stitch-status") }
                        if let output {
                            HStack {
                                Button("Change seams") { ExportFiles.remove(output.directory); self.output = nil; message = nil }.buttonStyle(.bordered)
                                Button("Share long image") { share = output }.buttonStyle(PrimaryButton())
                            }
                        } else if !pages.isEmpty {
                            Button("Preview long image") { export() }.buttonStyle(PrimaryButton()).disabled(pages.count < 2)
                        }
                    }.padding().background(.regularMaterial).disabled(busy)
                }
                .navigationTitle("Stitch screenshots").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
                .interactiveDismissDisabled(busy)
                .sheet(item: $share) { files in ShareSheet(items: files.urls) }
                .onAppear { seedUITestScreenshots() }
                .onChange(of: selection) { _, items in load(items) }
                .onDisappear { job?.cancel(); if let output { ExportFiles.remove(output.directory) } }
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
        busy = true; message = nil
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
        busy = true; message = nil
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
        busy = true; message = nil; let snapshot = pages
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
