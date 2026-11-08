import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class AppLifecycle: NSObject, NSApplicationDelegate {
    weak var transfers: Transfers?

    func applicationWillTerminate(_ notification: Notification) {
        transfers?.stopVideoTasks()
    }
}

@main
struct MediaHarborApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @Environment(\.openWindow) private var openWindow
    @State private var transfers: Transfers
    @State private var browser: SiteBrowser
    @State private var updates = AppUpdates()

    init() {
        let transfers = Transfers()
        _transfers = State(initialValue: transfers)
        _browser = State(initialValue: SiteBrowser(transfers: transfers))
    }

    var body: some Scene {
        Window("Media Harbor", id: "main") {
            MainWindow(transfers: transfers, browser: browser)
                .frame(minWidth: 940, minHeight: 620)
                .onAppear { lifecycle.transfers = transfers }
                .task { await updates.checkOnLaunch(canInstall: canInstallUpdate) }
        }
        .defaultSize(width: 1160, height: 740)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Media Harbor") { openWindow(id: "about") }
            }
            CommandGroup(replacing: .help) {
                Button("Media Harbor Help") { openWindow(id: "help") }
                    .keyboardShortcut("?", modifiers: .command)
            }
        }

        Window("Media Harbor Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 650, height: 660)

        Window("About Media Harbor", id: "about") {
            AboutView(galleryVersion: browser.gallery.version)
        }
        .defaultSize(width: 520, height: 530)

        Settings { PreferencesView(transfers: transfers, updates: updates, canInstallUpdate: canInstallUpdate) }
    }

    private func canInstallUpdate() -> Bool {
        !browser.isLoading && !browser.isScanning && !transfers.hasActiveDownloads
    }
}

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case downloads = "Downloads", browser = "Site Browser", gallery = "Gallery", templates = "Templates"
    var id: Self { self }
    var icon: String {
        switch self {
        case .downloads: "arrow.down.circle"
        case .browser: "globe"
        case .gallery: "photo.on.rectangle.angled"
        case .templates: "slider.horizontal.3"
        }
    }
}

enum SourceMode: String, CaseIterable, Identifiable {
    case website = "Website", links = "URL List", search = "Image Search"
    var id: Self { self }
    var icon: String {
        switch self {
        case .website: "globe"
        case .links: "list.bullet.rectangle"
        case .search: "magnifyingglass"
        }
    }
}

struct MainWindow: View {
    let transfers: Transfers
    let browser: SiteBrowser
    @Environment(\.openWindow) private var openWindow
    @State private var section: WorkspaceSection? = .downloads
    @State private var sourceMode: SourceMode?
    @State private var notice: String?
    @State private var showsNotice = false

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("Workspace") {
                    ForEach(WorkspaceSection.allCases) { item in
                        Label(item.rawValue, systemImage: item.icon)
                            .badge(item == .downloads ? transfers.items.filter { $0.status == .downloading }.count : 0)
                            .tag(item)
                    }
                }
                Section("Support") {
                    Button { openWindow(id: "help") } label: {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Open the Media Harbor user guide")
                    Button { openWindow(id: "about") } label: {
                        Label("About", systemImage: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .help("See the app version, system requirements, and dependencies")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 175, ideal: 192, max: 225)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save location").font(.caption2).foregroundStyle(.secondary)
                        Text(transfers.folder.lastPathComponent)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        openFolder(transfers.folder)
                    } label: {
                        Image(systemName: "arrow.up.forward")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .help("Open download folder")
                }
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                .padding(12)
            }
        } detail: {
            Group {
                switch section ?? .downloads {
                case .downloads:
                    QueueView(transfers: transfers, browser: browser) { sourceMode = $0 } openProject: { address in
                        browser.open(address)
                        section = .browser
                    }
                case .browser: BrowserWorkspace(browser: browser) { sourceMode = $0 }
                case .gallery: GalleryView(transfers: transfers)
                case .templates:
                    TemplatesView(browser: browser) { url, ytDLP in
                        browser.open(url, scan: true, ytDLP: ytDLP)
                        section = .browser
                    }
                }
            }
            .navigationTitle((section ?? .downloads).rawValue)
            .toolbar {
                if transfers.hasUnapprovedDownloads {
                    ToolbarItem {
                        Button {
                            transfers.startQueue()
                        } label: {
                            Label("Start Queue", systemImage: "play.fill")
                        }
                        .help("Start the files currently waiting in the queue")
                    }
                }
                ToolbarItem {
                    Button {
                        transfers.togglePause()
                    } label: {
                        Label(transfers.isPaused ? "Resume Queue" : "Pause Queue",
                              systemImage: transfers.isPaused ? "play.fill" : "pause.fill")
                    }
                    .help(transfers.isPaused ? "Resume all downloads" : "Pause all downloads")
                    .disabled(transfers.items.allSatisfy { [.complete, .failed].contains($0.status) } && !transfers.isPaused)
                }
                ToolbarItem {
                    Button {
                        sourceMode = .website
                    } label: {
                        Label("New Download", systemImage: "plus")
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("n")
                    .help("Add a website, a list of links, or an image search")
                }
            }
        }
        .sheet(item: $sourceMode) { mode in
            AddSourceView(mode: mode, transfers: transfers, browser: browser) { target in
                section = target
            } report: { message in
                notice = message
                showsNotice = true
            }
        }
        .alert("Media Harbor", isPresented: $showsNotice) {
            Button("OK") {}
        } message: {
            Text(notice ?? "")
        }
    }

    private func openFolder(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch {
            notice = error.localizedDescription
            showsNotice = true
        }
    }
}

struct PageHeading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 31, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PreferencesView: View {
    @Bindable var transfers: Transfers
    let updates: AppUpdates
    let canInstallUpdate: () -> Bool

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Save to") {
                    Button(transfers.folder.lastPathComponent + "…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.directoryURL = transfers.folder
                        if panel.runModal() == .OK, let folder = panel.url { transfers.folder = folder }
                    }
                    .help(transfers.folder.path)
                }
                Stepper("Simultaneous downloads · \(transfers.connections)", value: $transfers.connections, in: 1...12)
                    .help("Set how many files can download at the same time")
                Stepper("Automatic retries · \(transfers.retries)", value: $transfers.retries, in: 0...8)
                    .help("Set how many times an interrupted or failed download is retried automatically")
                Toggle("Automatically start queued downloads", isOn: $transfers.autoStart)
                    .help("Start files when they enter the queue. Turn off to start them manually.")
                Picker("Create folders by", selection: $transfers.folderRule) {
                    ForEach(DownloadFolderRule.allCases) { Text($0.rawValue).tag($0) }
                }
                .help("Choose how source pages or galleries are grouped into folders")
                Text("Title-based folders use the source URL when a title is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            UpdateSettings(updates: updates, canInstall: canInstallUpdate)
        }
        .formStyle(.grouped)
        .frame(width: 530, height: 520)
    }
}
