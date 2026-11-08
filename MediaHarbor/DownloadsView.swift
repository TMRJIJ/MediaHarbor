import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct AddSourceView: View {
    @State var mode: SourceMode
    let transfers: Transfers
    let browser: SiteBrowser
    let didAdd: (WorkspaceSection) -> Void
    let report: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var address = ""
    @State private var list = ""
    @State private var query = ""
    @State private var engine = SearchEngine.bing
    @State private var autoQueue = false
    @State private var error: String?
    @State private var importing = false

    private var websiteURL: URL? { URL.web(address, assumingHTTPS: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(title: "New download", detail: "Choose where to collect your files.")
            Picker("Source type", selection: $mode) {
                ForEach(SourceMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: mode) { error = nil }
            switch mode {
            case .website:
                TextField("https://example.com/gallery", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                if let websiteURL {
                    LabeledContent("Recommended template", value: browser.recommendedTemplate(for: websiteURL))
                        .font(.callout)
                        .help("Suggested from the website address and your scan settings. The app checks the page when scanning.")
                }
                Text("Scan a page or forum thread. You can sign in through the browser and scan again.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Automatically queue the files found on the first scan", isOn: $autoQueue)
                    .help("Queue the first scan’s results as soon as the scan finishes")
            case .links:
                TextEditor(text: $list)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 135)
                    .padding(4)
                    .background(.background, in: .rect(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }
                    .focused($focused)
                    .accessibilityLabel("Download URLs")
                HStack {
                    Text("Paste one URL per line, or import a text file.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Import…") { importing = true }
                        .help("Load a UTF-8 text file with one URL per line")
                }
            case .search:
                TextField("Search for images", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                Picker("Search engine", selection: $engine) {
                    ForEach(SearchEngine.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(mode == .links ? "Add to Queue" : mode == .search ? "Search" : "Open and Scan", action: submit)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 530)
        .onAppear { focused = true }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .utf8PlainText]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                list = try String(contentsOf: url, encoding: .utf8)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    private func submit() {
        switch mode {
        case .website:
            guard let url = websiteURL else {
                error = "Enter a valid website address."
                return
            }
            browser.open(url, scan: true, autoQueue: autoQueue)
            didAdd(.browser)
        case .links:
            let entries = list.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            let urls = entries.compactMap { URL.web($0) }
            guard !urls.isEmpty else { error = "Enter at least one HTTP or HTTPS link."; return }
            guard urls.count == entries.count else {
                error = "\(entries.count - urls.count) invalid links. Check that each line contains one HTTP or HTTPS URL."
                return
            }
            Task {
                await browser.syncCookies(for: urls)
                let count = transfers.enqueue(urls.map { MediaCandidate(url: $0, kind: MediaKind.detect($0) ?? .file) },
                                              streamCookies: browser.gallery.importedStreamCookies(for: urls))
                if count == 0 { report("Those links are already in the queue.") }
            }
            didAdd(.downloads)
        case .search:
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, let url = engine.address(query: term) else { error = "Enter a search term."; return }
            browser.open(url, search: engine, scan: true)
            didAdd(.browser)
        }
        dismiss()
    }
}

private enum QueueFilter: String, CaseIterable, Identifiable {
    case all = "All", active = "In progress", finished = "Completed", failed = "Failed"
    var id: Self { self }

    func matches(_ transfer: Transfer) -> Bool {
        switch self {
        case .all: true
        case .active: ![.complete, .failed].contains(transfer.status)
        case .finished: transfer.status == .complete
        case .failed: transfer.status == .failed
        }
    }
}

struct QueueView: View {
    private enum Selection: Hashable {
        case project(URL), file(UUID)
    }

    private enum QueueAction {
        case remove(URL), trashProject(URL), trashFile(URL)

        var title: String {
            switch self {
            case .remove: "Remove this project from the queue?"
            case .trashProject: "Move this project’s saved files to Trash?"
            case .trashFile: "Move this file to Trash?"
            }
        }

        var message: String {
            switch self {
            case .remove: "Active transfers will be canceled. Saved files will be kept."
            case .trashProject: "This removes the project from the queue and moves its saved files to Trash."
            case .trashFile: "This removes the saved file from the queue and Gallery."
            }
        }

        var actionLabel: String {
            if case .remove = self { return "Remove Project" }
            return "Move to Trash"
        }
    }

    let transfers: Transfers
    let browser: SiteBrowser
    let add: (SourceMode) -> Void
    let openProject: (URL) -> Void
    @State private var filter = QueueFilter.all
    @State private var selection: Selection?
    @State private var expanded: Set<URL> = []
    @State private var previewURL: URL?
    @State private var confirmClear = false
    @State private var pendingAction: QueueAction?
    @State private var actionError: String?
    @State private var archiving: Set<URL> = []
    private let typeWidth: CGFloat = 78
    private let statusWidth: CGFloat = 110
    private let actionsWidth: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeading(title: "Download queue", detail: "Collect media from websites, search results, and lists of links.")
                .padding(.horizontal, 26)
            if let error = transfers.storageError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).padding(.horizontal, 26)
            }
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).padding(.horizontal, 26)
            }
            if transfers.items.isEmpty {
                emptyQueue
            } else {
                queue
            }
        }
        .padding(.top, 19)
        .alert("Clear the download queue?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Queue", role: .destructive) {
                transfers.clearQueue()
                selection = nil
                expanded.removeAll()
            }
        } message: {
            Text("This cancels active downloads and removes all queue entries. Saved files and Gallery items are kept.")
        }
        .alert(pendingAction?.title ?? "", isPresented: Binding(get: { pendingAction != nil }, set: {
            if !$0 { pendingAction = nil }
        }), presenting: pendingAction) { action in
            Button("Cancel", role: .cancel) {}
            Button(action.actionLabel, role: .destructive) {
                perform(action)
            }
        } message: { action in
            Text(action.message)
        }
        .quickLookPreview($previewURL)
    }

    private var emptyQueue: some View {
        VStack(spacing: 23) {
            Spacer(minLength: 0)
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(width: 94, height: 94)
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.13)), in: .rect(cornerRadius: 28))
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Start a collection").font(.system(size: 26, weight: .semibold))
                Text("Choose a source to find and download files in bulk.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach(SourceMode.allCases) { mode in
                    Button { add(mode) } label: {
                        Label(mode.rawValue, systemImage: mode.icon).padding(6)
                    }
                    .buttonStyle(.glass)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 23)
                .fill(.quaternary.opacity(0.35))
                .overlay { RoundedRectangle(cornerRadius: 23).strokeBorder(.quaternary.opacity(0.8)) }
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 24)
    }

    private var queue: some View {
        let items = transfers.items
        let filtered = items.filter(filter.matches)
        let projects = Dictionary(grouping: items) { $0.media.projectSource }
        let visibleProjects = Dictionary(grouping: filtered) { $0.media.projectSource }
        let names = transfers.projectNamesForQueue()
        var seen: Set<URL> = []
        let projectOrder = items.map(\.media.projectSource).filter { seen.insert($0).inserted && visibleProjects[$0] != nil }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                metric("Active", items.filter { $0.status == .downloading }.count, "arrow.down")
                metric("Waiting", items.filter { [.queued, .paused, .retrying].contains($0.status) }.count, "clock")
                metric("Completed", items.filter { $0.status == .complete }.count, "checkmark")
            }
            .padding(.horizontal, 26)
            HStack {
                Picker("Show downloads", selection: $filter) {
                    ForEach(QueueFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Text("\(filtered.count.formatted()) files").font(.caption).foregroundStyle(.secondary)
                Button("Clear Queue…") { confirmClear = true }
                    .help("Cancel active downloads and clear the list while keeping saved files")
            }
            .padding(.horizontal, 26)

            if filtered.isEmpty {
                ContentUnavailableView("No \(filter.rawValue.lowercased()) downloads", systemImage: "tray")
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(projectOrder, id: \.self) { source in
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(source) }, set: { isExpanded in
                            if isExpanded { expanded.insert(source) } else { expanded.remove(source) }
                        })) {
                            fileHeading
                            ForEach(visibleProjects[source, default: []]) { transfer in
                                row(transfer)
                                    .tag(Selection.file(transfer.id))
                                    .contextMenu { actions(transfer, menu: true) }
                            }
                        } label: {
                            projectRow(source, name: names[source] ?? source.displayFilename, items: projects[source, default: []])
                        }
                        .tag(Selection.project(source))
                    }
                }
                .listStyle(.inset)
                .padding(.horizontal, 13)
            }
        }
    }

    private func projectRow(_ source: URL, name: String, items: [Transfer]) -> some View {
        let startable = items.filter(transfers.canStartInProject)
        let retryable = items.filter { [.failed, .retrying].contains($0.status) }
        let active = items.filter { $0.status == .downloading }
        let completed = items.filter { $0.status == .complete }.count
        let hasSavedFiles = !transfers.savedProjectFiles(source).isEmpty
        let progress = (Double(completed) + active.compactMap(\.fraction).reduce(0, +)) / Double(max(1, items.count))
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline).lineLimit(1)
                Text("\(completed.formatted()) of \(items.count.formatted()) complete · \(source.host ?? source.absoluteString)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(source.absoluteString)
            Spacer()
            if !active.isEmpty {
                Group {
                    if active.contains(where: { $0.fraction == nil }) {
                        ProgressView()
                    } else {
                        ProgressView(value: progress)
                    }
                }
                .progressViewStyle(.linear)
                .frame(width: 105)
                .accessibilityLabel("Project download progress")
            }
            Button { openProject(source) } label: { Label("Open in Site Browser", systemImage: "globe") }
                .help("Return to the link for this project")
            Button {
                Task {
                    await browser.syncCookies(for: startable.map(\.media.url))
                    transfers.startProject(source)
                }
            } label: {
                Label("Start Project", systemImage: "play.fill")
            }
            .help("Start or resume this project’s waiting files")
            .disabled(startable.isEmpty)
            Button {
                Task {
                    await browser.syncCookies(for: retryable.map(\.media.url))
                    transfers.retryProject(source)
                }
            } label: {
                Label("Retry project", systemImage: "arrow.clockwise")
            }
            .help("Retry this project’s failed or interrupted downloads")
            .disabled(retryable.isEmpty)
            Menu {
                Button("Compress Project…") { compressProject(source, name: name) }
                    .disabled(archiving.contains(source) || !hasSavedFiles)
                Button("Remove Project from Queue…") { pendingAction = .remove(source) }
                Button("Move Project to Trash…", role: .destructive) { pendingAction = .trashProject(source) }
                    .disabled(!hasSavedFiles || !transfers.canTrashProject(source) || archiving.contains(source))
            } label: {
                Label("Project Actions", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .help("Compress, remove, or delete this project")
            if archiving.contains(source) {
                ProgressView().controlSize(.small).accessibilityLabel("Compressing project")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
    }

    private var fileHeading: some View {
        HStack(spacing: 12) {
            Text("File")
            Spacer(minLength: 10)
            Text("File Type").frame(width: typeWidth, alignment: .leading)
            Text("Status").frame(width: statusWidth, alignment: .trailing)
            Color.clear.frame(width: actionsWidth, height: 1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
    }

    private func perform(_ action: QueueAction) {
        actionError = nil
        switch action {
        case .remove(let source):
            transfers.removeProject(source)
            expanded.remove(source)
            selection = nil
        case .trashProject(let source):
            actionError = transfers.trashProject(source)
            expanded.remove(source)
            selection = nil
        case .trashFile(let url):
            if previewURL == url { previewURL = nil }
            actionError = transfers.trashSavedFile(url)
        }
    }

    private func compressProject(_ source: URL, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = name + ".zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let files = transfers.savedProjectFiles(source)
        actionError = nil
        archiving.insert(source)
        Task {
            defer { archiving.remove(source) }
            do {
                try await Task.detached(priority: .utility) {
                    try ProjectArchive.write(files, to: destination)
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func metric(_ title: String, _ count: Int, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(count.formatted()).font(.system(size: 19, weight: .semibold, design: .monospaced))
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(13)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 13))
    }

    private func row(_ transfer: Transfer) -> some View {
        HStack(spacing: 12) {
            Group {
                if transfer.kind == .image, let output = transfer.output {
                    LocalImage(url: output, pixels: 112)
                } else {
                    Image(systemName: transfer.kind.icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 48, height: 40)
            .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 9))
            .clipShape(.rect(cornerRadius: 9))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(transfer.error ?? (transfer.media.videoPage == true ? "yt-dlp" : nil)
                     ?? transfer.media.streamFormat.map { $0.name + " stream" } ?? transfer.media.url.host ?? "")
                    .font(.caption)
                    .foregroundStyle(transfer.status == .failed ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .help(transfer.error ?? transfer.media.url.absoluteString)
            }
            Spacer(minLength: 10)
            let fileExtension = (transfer.output ?? transfer.media.url).pathExtension
            Text(fileExtension.isEmpty || transfer.media.videoPage == true && transfer.output == nil
                 ? transfer.kind.rawValue : fileExtension.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: typeWidth, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Text(transfers.finalizingVideos.contains(transfer.id) ? "Saving video" : transfer.status.rawValue)
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if transfer.status == .downloading {
                    if let fraction = transfer.fraction {
                        ProgressView(value: fraction).accessibilityLabel("Download progress")
                    } else {
                        ProgressView().progressViewStyle(.linear)
                        if transfer.media.streamFormat != nil, transfer.received > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: transfer.received, countStyle: .file))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else if transfer.status == .complete {
                    Text(ByteCountFormatter.string(fromByteCount: transfer.received, countStyle: .file))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: statusWidth, alignment: .trailing)
            HStack(spacing: 10) { actions(transfer, menu: false) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(width: actionsWidth, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func actions(_ transfer: Transfer, menu: Bool) -> some View {
        switch transfer.status {
        case .complete:
            if let output = transfer.output {
                Button { previewURL = output } label: {
                    Label("Preview", systemImage: "eye")
                }
                .help("Preview the downloaded file with Quick Look")
                Button { NSWorkspace.shared.activateFileViewerSelecting([output]) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show in Finder")
                if menu {
                    Button("Open File") { NSWorkspace.shared.open(output) }
                    Button("Move File to Trash…", role: .destructive) { pendingAction = .trashFile(output) }
                }
            }
        case .queued where transfers.needsStart(transfer):
            Button { transfers.retry(transfer.id) } label: {
                Label("Start", systemImage: "play.fill")
            }
            .help("Start download")
        case .downloading, .queued:
            if transfer.status == .downloading, transfer.media.streamFormat != nil {
                Button { transfers.saveStream(transfer.id) } label: {
                    Label("Stop & Save", systemImage: "stop.circle")
                }
                .help("Stop recording and save the video so far")
                .disabled(transfers.finalizingVideos.contains(transfer.id) || transfer.received == 0)
            }
            Button { transfers.pause(transfer.id) } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .help(transfer.media.streamFormat == nil ? "Pause download" : "Pause stream. Resuming starts a new recording.")
            .disabled(transfers.finalizingVideos.contains(transfer.id))
        case .paused, .failed, .retrying:
            Button {
                Task {
                    await browser.syncCookies(for: [transfer.media.url])
                    transfers.retry(transfer.id)
                }
            } label: {
                Label(transfer.status == .paused ? "Resume" : "Retry", systemImage: transfer.status == .paused ? "play.fill" : "arrow.clockwise")
            }
            .help(transfer.status == .paused ? "Resume download" : "Retry download")
            .disabled(transfers.isPaused)
        }
        if menu {
            Divider()
            Button("Copy Source URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transfer.media.url.absoluteString, forType: .string)
            }
            Button("Remove from Queue", role: .destructive) { transfers.remove(transfer.id) }
        }
    }
}

enum ProjectArchive {
    nonisolated static func write(_ sources: [URL], to destination: URL) throws {
        let files = FileManager.default
        let available = sources.filter {
            $0.isFileURL && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard !available.isEmpty else { throw Failure.noFiles }
        let outputPath = destination.resolvingSymlinksInPath().standardizedFileURL
        guard !sources.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == outputPath }) else {
            throw Failure.overwritesInput
        }
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: destination.deletingLastPathComponent(), create: true)
        defer { try? files.removeItem(at: work) }
        let contents = work.appending(path: "Files", directoryHint: .isDirectory)
        let archive = work.appending(path: "Project.zip")
        try files.createDirectory(at: contents, withIntermediateDirectories: false)
        for source in available {
            let extensionName = source.pathExtension
            let suffix = extensionName.isEmpty ? "" : "." + extensionName
            let name = source.deletingPathExtension().lastPathComponent
            var target = contents.appending(component: source.lastPathComponent)
            var copy = 2
            while files.fileExists(atPath: target.path) {
                target = contents.appending(component: "\(name) (\(copy))\(suffix)")
                copy += 1
            }
            do { try files.linkItem(at: source, to: target) }
            catch { try files.copyItem(at: source, to: target) }
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", contents.path, archive.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.compression }
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: archive)
        } else {
            try files.moveItem(at: archive, to: destination)
        }
    }

    private enum Failure: LocalizedError {
        case noFiles, overwritesInput, compression

        var errorDescription: String? {
            switch self {
            case .noFiles: "No saved project files are available to compress."
            case .overwritesInput: "Choose a ZIP location different from the project’s saved files."
            case .compression: "The project could not be compressed."
            }
        }
    }
}
