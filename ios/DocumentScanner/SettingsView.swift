import SwiftUI
import StoreKit
import UniformTypeIdentifiers
import MessageUI

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
    @Environment(\.openURL) private var openURL
    private func restoreFromTrash(_ doc: ScanDocument) {
        store.restore(doc)
        if store.problem == nil { AppToast.show("Restored to your documents", symbol: "arrow.uturn.backward") }
    }
    private func backupCreated() {
        store.perform { try store.recordBackupCreated() }
        AppToast.show("Backup saved", symbol: "externaldrive.fill.badge.checkmark")
    }
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
                    if let message = subscription.message { Text(L(message)).font(.caption) }
                    if subscription.statusText != "Pro is active" && subscription.statusText != "Free" {
                        Text(L(subscription.statusText)).font(.caption).foregroundStyle(.secondary)
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
                Section("Language") {
                    Picker("Language", selection: Binding(get: { AppLanguage.current }, set: { AppLanguage.choose($0) })) {
                        ForEach(AppLanguage.allCases) { Text(verbatim: $0.nativeName).tag($0) }
                    }
                    .accessibilityIdentifier("language-picker")
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
                                    Text(L(doc.title)).font(.headline)
                                    Text("\(max(0,30-Int(Date().timeIntervalSince(doc.deletedAt ?? Date())/86400))) days remaining").font(.caption).foregroundStyle(.secondary)
                                    HStack { Button("Restore") { restoreFromTrash(doc) }.buttonStyle(.bordered); Spacer(); Button("Delete permanently", role: .destructive) { pendingDelete = doc }.buttonStyle(.bordered) }
                                }.padding(.vertical, 6)
                            }
                        }.navigationTitle("Trash")
                    }
                }
                Section("Privacy") {
                    Link("Privacy policy", destination: AppInfo.privacyPolicyURL).accessibilityIdentifier("settings-privacy-policy")
                    NavigationLink("Privacy details") { PrivacyView() }
                    if !subscription.isPro, AdConsent.privacyOptionsRequired {
                        Button("Ad privacy choices") { AdConsent.presentPrivacyOptions() }
                            .accessibilityIdentifier("settings-ad-privacy")
                    }
                    Toggle("App lock", isOn: Binding(get: { lock.enabled }, set: { value in Task { await lock.setEnabled(value) } })).disabled(lock.authenticating)
                    Text("Use Face ID, Touch ID or your device passcode. App lock also hides documents in the app switcher.").font(.caption)
                    if let message = lock.message { Text(L(message)).foregroundStyle(.secondary) }
                }
                Section("Text recognition") {
                    NavigationLink("Supported languages") { RecognitionLanguagesView() }
                }
                Section("Backup") {
                    Toggle("Include saved reusable signatures", isOn: $includeSignatures).disabled(backupBusy)
                    Text("Signatures already placed in documents stay in document backups. Unused saved signatures are excluded unless selected.").font(.caption)
                    Button("Export library backup") { backupWarning = true }.disabled(backupBusy)
                    if backupBusy { ProgressView(backupProgress); Button("Cancel backup") { backupTask?.cancel() } }
                    if let date = store.manifest.lastBackupCreated { LabeledContent("Last backup created", value: date.appFormatted(date: .abbreviated, time: .shortened)) }
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
                    Button {
                        // Back to a fresh install's first run: the full intro, then the
                        // first-scan ask, tip and celebration as a new user sees them.
                        let defaults = UserDefaults.standard
                        for key in [OnboardingFlags.startScan, OnboardingFlags.scanTip, OnboardingFlags.firstScanPending] { defaults.removeObject(forKey: key) }
                        dismiss()
                        Task { try? await Task.sleep(for: .seconds(0.4)); defaults.set(false, forKey: "scanner-onboarding-v1") }
                    } label: { Label("Replay first-run intro", systemImage: "play.rectangle") }
                        .accessibilityIdentifier("dev-replay-intro")
                } header: { Text("Developer") } footer: { Text("Debug builds only. Switches the app between the free and Pro layouts without buying. App Store follows the real purchase.") }
                #endif
                Section("About") {
                    LabeledContent(AppInfo.name, value: "\(AppInfo.version) (\(AppInfo.build))").accessibilityIdentifier("settings-version")
                    NavigationLink { SupportView() } label: {
                        Label { Text(L("Contact support")).foregroundStyle(.primary) } icon: { Image(systemName: "envelope").foregroundStyle(TK.blue) }
                    }.accessibilityIdentifier("settings-support")
                    Button { openURL(AppInfo.reviewURL) } label: { SettingsLinkRow(title: "Rate the app", symbol: "star") }.buttonStyle(.plain).accessibilityIdentifier("settings-rate")
                    ShareLink(item: AppInfo.storeURL, message: Text(L("HushScan scans documents and keeps them on your iPhone."))) {
                        SettingsLinkRow(title: "Share the app", symbol: "square.and.arrow.up")
                    }.buttonStyle(.plain).accessibilityIdentifier("settings-share")
                    Link("Terms of Use", destination: AppInfo.termsURL)
                }
                if let feedback { Section { Text(L(feedback)) } }
            }
            .scrollContentBackground(subscription.isPro ? .hidden : .automatic)
            .background { if subscription.isPro { ProPageBackground(band: 50) } }
            .toolbarBackground(subscription.isPro ? .hidden : .automatic, for: .navigationBar)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(backupBusy) } }
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
                if completed { backupCreated() }
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
                            Text(L(doc.title)).font(.headline).foregroundStyle(Design.ink)
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
            if let problem = store.problem { Text(L(problem)).foregroundStyle(.red) }
        }
        .navigationTitle("Unfinished scans")
        .alert("Move this unfinished scan to Trash?", isPresented: $confirmingTrash, presenting: pendingTrash) { doc in
            Button("Move to Trash", role: .destructive) { trashWithUndo(store, doc) }
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
                if let error { Text(L(error)).foregroundStyle(.secondary) }
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
                    Label(L(folder), systemImage: "folder.fill").lineLimit(1)
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
            if let problem { Text(L(problem)).font(.footnote).foregroundStyle(.red) }
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

// MARK: - Contact support

/// What a support message is about. The raw value is the English label.
enum SupportTopic: String, CaseIterable, Identifiable {
    case billing = "Subscription & billing", scan = "Scan quality", tool = "A tool isn't working", idea = "Feature idea", other = "Something else"
    var id: String { rawValue }
}

/// Contact support: pick a topic, write the message, send it from the iPhone's mail app.
/// Nothing is sent from the app itself, so no address or message is stored anywhere but the person's own mail.
struct SupportView: View {
    @EnvironmentObject private var subscription: SubscriptionStore
    @Environment(\.openURL) private var openURL
    @State private var topic: SupportTopic?
    @State private var message = ""
    @State private var includeInfo = true
    @State private var composing = false
    @State private var noMail = false
    @State private var sent = false
    @FocusState private var typing: Bool
    private var ready: Bool { topic != nil && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        ToolPage(title: "What can we help with?", subtitle: "Write to us and we usually reply within 2 business days.") {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Topic")
                VStack(spacing: 8) {
                    ForEach(SupportTopic.allCases) { item in
                        Button { topic = item } label: {
                            HStack {
                                Text(L(item.rawValue)).font(.system(size: 16, weight: .medium)).foregroundStyle(TK.grey900)
                                Spacer()
                                Image(systemName: topic == item ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20)).foregroundStyle(topic == item ? TK.blue : TK.grey300)
                            }
                            .padding(.horizontal, 16).frame(minHeight: 52)
                            .background(topic == item ? TK.blueSoft : TK.grey50, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(topic == item ? .isSelected : [])
                        .accessibilityIdentifier("support-topic-\(item)")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Message")
                ZStack(alignment: .topLeading) {
                    if message.isEmpty {
                        Text(L("What happened, and what did you expect?")).font(.system(size: 16)).foregroundStyle(TK.grey400)
                            .padding(.horizontal, 16).padding(.vertical, 14).allowsHitTesting(false)
                    }
                    TextEditor(text: $message).focused($typing)
                        .font(.system(size: 16)).foregroundStyle(TK.grey900)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .frame(minHeight: 150)
                        .accessibilityIdentifier("support-message")
                }
                .background(TK.grey50, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(typing ? TK.blue : TK.grey200, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $includeInfo) { Text(L("Include app and device info")).font(.system(size: 16, weight: .medium)).foregroundStyle(TK.grey900) }
                    .tint(TK.blue).accessibilityIdentifier("support-include-info")
                Text(L("Only the app version, iOS version, iPhone model, language and plan. No documents or their text."))
                    .font(.system(size: 13)).foregroundStyle(TK.grey600).fixedSize(horizontal: false, vertical: true)
                if includeInfo {
                    Text(verbatim: Self.deviceInfo(pro: subscription.isPro)).font(.system(size: 13, design: .monospaced)).foregroundStyle(TK.grey500)
                }
            }
            if sent { ToastMessage(text: "Thanks. Your message is on its way.", symbol: "checkmark.circle.fill", tint: TK.teal) }
            Button { openURL(AppInfo.supportURL) } label: {
                Label(L("Read common questions"), systemImage: "questionmark.circle").font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.blue)
            }
            .accessibilityIdentifier("support-faq")
        } actions: {
            Button(L("Send by email")) { typing = false; send() }
                .buttonStyle(CTAButtonStyle()).disabled(!ready)
                .accessibilityIdentifier("support-send")
        }
        .navigationTitle(L("Contact support"))
        .sheet(isPresented: $composing) {
            MailComposer(to: AppInfo.supportEmail, subject: subject, body: mailBody) { result in
                composing = false
                if result == .sent { sent = true; message = ""; topic = nil }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $noMail) { NoMailSheet(message: mailBody).presentationDetents([.medium]) }
    }
    private var subject: String { "\(AppInfo.name) · \(L(topic?.rawValue ?? SupportTopic.other.rawValue))" }
    private var mailBody: String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return includeInfo ? text + "\n\n—\n" + Self.deviceInfo(pro: subscription.isPro) : text
    }
    private func send() {
        if MFMailComposeViewController.canSendMail() { composing = true; return }
        // Another mail app (Gmail, Outlook) may be the default; otherwise copy and paste.
        var parts = URLComponents()
        parts.scheme = "mailto"; parts.path = AppInfo.supportEmail
        parts.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: mailBody)]
        guard let url = parts.url else { noMail = true; return }
        openURL(url) { accepted in if !accepted { noMail = true } }
    }
    /// One line a person can read before sending: app, iOS, iPhone model, language, plan.
    static func deviceInfo(pro: Bool) -> String {
        var system = utsname(); uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return "\(AppInfo.name) \(AppInfo.version) (\(AppInfo.build)) · iOS \(UIDevice.current.systemVersion) · \(model) · \(Locale.preferredLanguages.first ?? "-") · \(pro ? "Pro" : "Free")"
    }
}

/// No mail account on this iPhone: copy the address and the message instead.
private struct NoMailSheet: View {
    let message: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("No email app is set up")).font(.system(size: 22, weight: .bold)).foregroundStyle(TK.grey900)
            Text(L("Copy the address and your message, then send them from any email app.")).font(.system(size: 15)).foregroundStyle(TK.grey600)
            Text(verbatim: AppInfo.supportEmail).font(.system(size: 17, weight: .semibold)).foregroundStyle(TK.grey900).textSelection(.enabled)
            if let copied { ToastMessage(text: copied, symbol: "checkmark.circle.fill", tint: TK.teal) }
            Spacer(minLength: 0)
            Button(L("Copy email address")) { UIPasteboard.general.string = AppInfo.supportEmail; copied = "Copied" }.buttonStyle(CTAButtonStyle())
            Button(L("Copy message")) { UIPasteboard.general.string = message; copied = "Copied" }.buttonStyle(SecondaryCTAStyle())
            Button(L("Close")) { dismiss() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey600).frame(maxWidth: .infinity)
        }
        .padding(24)
    }
}

/// The system mail composer, filled in.
struct MailComposer: UIViewControllerRepresentable {
    let to: String
    let subject: String
    let body: String
    let done: (MFMailComposeResult) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let mail = MFMailComposeViewController()
        mail.mailComposeDelegate = context.coordinator
        mail.setToRecipients([to]); mail.setSubject(subject); mail.setMessageBody(body, isHTML: false)
        return mail
    }
    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}
    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let done: (MFMailComposeResult) -> Void
        init(done: @escaping (MFMailComposeResult) -> Void) { self.done = done }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) { done(result) }
    }
}

/// A plain settings row with a chevron, for rows that open something.
struct SettingsLinkRow: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack {
            Label { Text(L(title)).foregroundStyle(.primary) } icon: { Image(systemName: symbol).foregroundStyle(TK.blue) }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(TK.grey400)
        }
        .contentShape(Rectangle())
    }
}
