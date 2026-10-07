import SwiftUI
import StoreKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var subscription: SubscriptionStore
    @EnvironmentObject var lock: AppLock
    @Environment(\.dismiss) var dismiss
    let resumeDraft: (UUID) -> Void
    @State private var share: SharedFile?
    @State private var paywall = false
    @State private var backupWarning = false
    @State private var importing = false
    @State private var keepBoth = false
    @State private var includeSignatures = false
    @State private var backupBusy = false
    @State private var backupProgress = "Creating backup…"
    @State private var backupTask: Task<Void,Never>?
    @State private var folder = ""
    @State private var addingFolder = false
    @State private var feedback: String?
    @State private var pendingDelete: ScanDocument?
    @State private var showingTour = false
    @State private var manageSubscription = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    MembershipBanner(explore: { paywall = true }, manage: { manageSubscription = true })
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    ProBenefitsCard()
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    Button("Restore purchases") { Task { await subscription.restore() } }.disabled(subscription.busy)
                    if let message = subscription.message { Text(message).font(.caption) }
                    if subscription.statusText != "Pro is active" && subscription.statusText != "Free" {
                        Text(subscription.statusText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Label("Saved on this iPhone", systemImage: "iphone")
                    Text("Scanning, PDF creation, and text recognition work offline. Keep a separate backup before deleting the app or changing phones.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Take a quick tour") { showingTour = true }
                }
                Section {
                    AutoExportRow(openPaywall: { paywall = true })
                } header: { Text("Auto-save") } footer: {
                    Text("Each new scan is also saved as a PDF in the folder you choose. Pick a folder in iCloud Drive, Dropbox or Google Drive to back it up there.")
                }
                Section("Library") {
                    NavigationLink {
                        UnfinishedScansView(resume: resumeDraft)
                    } label: { Text("Unfinished scans (\(store.drafts.count))") }
                        .accessibilityIdentifier("unfinished-scans")
                    NavigationLink("Folders") {
                        List { ForEach(store.manifest.folders, id: \.self) { Text($0) }; Button("New folder") { addingFolder = true } }.navigationTitle("Folders")
                    }
                    NavigationLink("Trash (\(store.trash.count))") {
                        List {
                            if store.trash.isEmpty { Text("Trash is empty").foregroundStyle(.secondary) }
                            else { Text("Items are permanently removed after 30 days.").font(.caption).foregroundStyle(.secondary) }
                            ForEach(store.trash) { doc in
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(doc.title).font(.headline)
                                    Text("\(max(0,30-Int(Date().timeIntervalSince(doc.deletedAt ?? Date())/86400))) days remaining").font(.caption).foregroundStyle(.secondary)
                                    HStack { Button("Restore") { store.restore(doc) }.buttonStyle(.bordered); Spacer(); Button("Delete permanently", role: .destructive) { pendingDelete = doc }.buttonStyle(.bordered) }
                                }.padding(.vertical, 6)
                            }
                        }.navigationTitle("Trash")
                    }
                }
                Section("Privacy") {
                    NavigationLink("Privacy details") { PrivacyView() }
                    Toggle("App lock", isOn: Binding(get: { lock.enabled }, set: { value in Task { await lock.setEnabled(value) } })).disabled(lock.authenticating)
                    Text("Use Face ID, Touch ID or your device passcode. App lock also hides documents in the app switcher.").font(.caption)
                    if let message = lock.message { Text(message).foregroundStyle(.secondary) }
                }
                Section("Text recognition") {
                    NavigationLink("Supported languages") { RecognitionLanguagesView() }
                }
                Section("Backup") {
                    Toggle("Include saved reusable signatures", isOn: $includeSignatures).disabled(backupBusy)
                    Text("Signatures already placed in documents stay in document backups. Unused saved signatures are excluded unless selected.").font(.caption)
                    Button("Export library backup") { backupWarning = true }.disabled(backupBusy)
                    if backupBusy { ProgressView(backupProgress); Button("Cancel backup") { backupTask?.cancel() } }
                    if let date = store.manifest.lastBackupCreated { LabeledContent("Last backup created", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    Toggle("Keep both when restoring duplicates", isOn: $keepBoth).disabled(backupBusy)
                    Button("Restore library backup") { importing = true }.disabled(backupBusy)
                    Text("Existing documents are preserved. Choose whether duplicate documents are skipped or restored as copies. Backups are streamed to disk; enough free space for the exported archive is required.").font(.caption).foregroundStyle(.secondary)
                }
                #if DEBUG
                Section {
                    Picker("Act as", selection: Binding(get: { SubscriptionStore.devPlan }, set: { subscription.setDevPlan($0) })) {
                        Text("App Store").tag("")
                        Text("Free").tag("free")
                        Text("Pro").tag("pro")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("dev-plan-picker")
                    LabeledContent("Showing", value: subscription.isPro ? "Pro layout" : "Free layout")
                    Button("Show first-run intro again") {
                        UserDefaults.standard.set(false, forKey: "scanner-onboarding-v1")
                        dismiss()
                    }.accessibilityIdentifier("dev-replay-intro")
                } header: { Text("Developer") } footer: { Text("Debug builds only. Switches the app between the free and Pro layouts without buying. App Store follows the real purchase.") }
                #endif
                Section("About this build") {
                    Text("Pageframe · 0.1.0")
                    Text("Development preview. Subscription purchases launched through the Xcode StoreKit configuration are test purchases.").font(.subheadline).foregroundStyle(.secondary)
                }
                if let feedback { Section { Text(feedback) } }
            }
            .scrollContentBackground(subscription.isPro ? .hidden : .automatic)
            .background { if subscription.isPro { ProPageBackground(band: 50) } }
            .toolbarBackground(subscription.isPro ? .hidden : .automatic, for: .navigationBar)
            .toolbarColorScheme(subscription.isPro ? .dark : nil, for: .navigationBar)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(backupBusy).tint(subscription.isPro ? .white : nil) } }
            .interactiveDismissDisabled(backupBusy)
            .fullScreenCover(isPresented: $showingTour) { OnboardingView(onFinish: { _ in showingTour = false }, replay: true) }
            .alert("New folder", isPresented: $addingFolder) { TextField("Folder name", text: $folder); Button("Create") { store.perform { try store.addFolder(folder) }; folder = "" }; Button("Cancel", role: .cancel) {} }
            .confirmationDialog("Export an unencrypted backup?", isPresented: $backupWarning) { Button("Export backup") {
                backupBusy = true; backupProgress = "Creating backup…"
                backupTask = Task {
                    defer { backupBusy = false }
                    do { share = SharedFile(url:try await store.exportBackupAsync(includeSignatures:includeSignatures)) }
                    catch is CancellationError { feedback = "Backup canceled. Your library is unchanged." }
                    catch { feedback = error.localizedDescription }
                }
            } } message: { Text("This file is not password protected. Anyone with the file can read your documents. Store it somewhere you trust.") }
            .confirmationDialog("Permanently delete this document?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete permanently", role: .destructive) { if let doc = pendingDelete { store.perform { try store.permanentlyDelete(doc) } }; pendingDelete = nil }
            } message: { Text("This cannot be undone.") }
            .sheet(isPresented: $paywall) { PaywallView() }
            .manageSubscriptionsSheet(isPresented: $manageSubscription)
            .sheet(item: $share) { file in ShareSheet(items: [file.url], completion: { completed, error in
                if completed { store.perform { try store.recordBackupCreated() } }
                if let error { feedback = error.localizedDescription }
                try? FileManager.default.removeItem(at: file.url)
            }) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                do {
                    let url = try result.get(); backupBusy = true; backupProgress = "Checking and restoring backup…"
                    backupTask = Task {
                        defer { backupBusy = false }
                        do { try await store.importBackupAsync(url,keepBoth:keepBoth); feedback = "Backup restored. Existing documents were preserved." }
                        catch { feedback = "Backup wasn't restored. Nothing in your library was changed. " + error.localizedDescription }
                    }
                } catch { feedback = error.localizedDescription }
            }
        }
    }
}

private struct UnfinishedScansView: View {
    @EnvironmentObject var store: LibraryStore
    let resume: (UUID) -> Void
    @State private var pendingTrash: ScanDocument?
    @State private var confirmingTrash = false
    var body: some View {
        List {
            if store.drafts.isEmpty { Text("No unfinished scans").foregroundStyle(.secondary) }
            ForEach(store.drafts.sorted { $0.updatedAt > $1.updatedAt }) { doc in
                HStack(spacing: 12) {
                    Button { resume(doc.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(doc.title).font(.headline).foregroundStyle(Design.ink)
                            Text("\(doc.pages.count) pages · Not exported yet").font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("resume-draft-" + doc.id.uuidString)
                    Button { pendingTrash = doc; confirmingTrash = true } label: {
                        Image(systemName: "trash").foregroundStyle(.red).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("Move \(doc.title) to Trash")
                        .accessibilityIdentifier("trash-document-" + doc.id.uuidString)
                        .disabled(!store.storageAvailable)
                }
            }
            if let problem = store.problem { Text(problem).foregroundStyle(.red) }
        }
        .navigationTitle("Unfinished scans")
        .alert("Move this unfinished scan to Trash?", isPresented: $confirmingTrash, presenting: pendingTrash) { doc in
            Button("Move to Trash", role: .destructive) { store.moveToTrash(doc) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Your scanned pages can be restored from Settings → Trash.") }
    }
}

private struct RecognitionLanguagesView: View {
    @State private var languages: [String] = []
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Text("Languages are detected automatically. Text recognition works offline on this iPhone.")
                Text("Available languages depend on your iOS version. Other documents can still be scanned, but their text may not be recognized.").font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Available on this iPhone") {
                if let error { Text(error).foregroundStyle(.secondary) }
                else if languages.isEmpty { ProgressView() }
                ForEach(languages, id: \.self) { Text($0) }
            }
        }
        .navigationTitle("Text languages")
        .task {
            do {
                let identifiers = try await Task.detached { try TextRecognition.supportedLanguages() }.value
                let locale = Locale(identifier: "en")
                languages = Array(Set(identifiers.map { code in
                    let base = String(code.split(separator: "-")[0])
                    let name = locale.localizedString(forLanguageCode: base) ?? code
                    if code.contains("Hans") { return name + " (Simplified)" }
                    if code.contains("Hant") { return name + " (Traditional)" }
                    return name
                })).sorted()
            } catch { self.error = "The language list couldn't be loaded. Please try again." }
        }
    }
}


/// Choose a folder (iCloud Drive, Dropbox, Google Drive or on this iPhone) that receives every new scan.
struct AutoExportRow: View {
    @EnvironmentObject private var subscription: SubscriptionStore
    let openPaywall: () -> Void
    @State private var picking = false
    @State private var folder = AutoExport.folderName
    @State private var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let folder {
                HStack {
                    Label(folder, systemImage: "folder.fill").lineLimit(1)
                    Spacer()
                    Button("Change") { picking = true }.buttonStyle(.borderless)
                    Button("Turn off", role: .destructive) { AutoExport.clear(); self.folder = nil }.buttonStyle(.borderless)
                }
            } else {
                Button {
                    if subscription.isPro { picking = true } else { openPaywall() }
                } label: {
                    HStack {
                        Label("Save new scans to a folder", systemImage: "folder.badge.plus")
                        if !subscription.isPro { Spacer(); ProBadge() }
                    }
                }.accessibilityIdentifier("auto-export-choose")
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                do { try AutoExport.setFolder(url); folder = AutoExport.folderName; problem = nil }
                catch { problem = error.localizedDescription }
            case .failure(let error): problem = error.localizedDescription
            }
        }
    }
}

/// Copies finished PDFs into a folder the person picked, using a security-scoped bookmark.
enum AutoExport {
    private static let bookmarkKey = "autoExportFolderBookmark"
    private static let nameKey = "autoExportFolderName"
    static var folderName: String? { UserDefaults.standard.data(forKey: bookmarkKey) == nil ? nil : UserDefaults.standard.string(forKey: nameKey) }
    static func setFolder(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: nameKey)
    }
    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey); UserDefaults.standard.removeObject(forKey: nameKey)
    }
    /// Writes "<title>.pdf" (or "<title> 2.pdf" …) into the chosen folder. Silent no-op when off.
    @discardableResult
    static func export(_ data: Data, title: String) -> Bool {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return false }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return false }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        if stale, let fresh = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        let base = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        let name = base.isEmpty ? "Scan" : base
        var target = folder.appendingPathComponent(name + ".pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) && n < 1000 { target = folder.appendingPathComponent("\(name) \(n).pdf"); n += 1 }
        var wrote = false
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordError) { url in
            wrote = (try? data.write(to: url, options: .atomic)) != nil
        }
        return wrote
    }
}
