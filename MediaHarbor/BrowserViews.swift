import SwiftUI

struct BrowserWorkspace: View {
    @Bindable var browser: SiteBrowser
    let add: (SourceMode) -> Void
    @State private var address = ""
    @State private var showScanOptions = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .help("Back")
                    .accessibilityLabel("Back")
                    .disabled(browser.currentURL == nil)
                Button { browser.goHome() } label: { Image(systemName: "house") }
                    .help("Go to the starting URL")
                    .accessibilityLabel("Home")
                    .disabled(browser.homeURL == nil)
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload page")
                    .accessibilityLabel("Reload")
                    .disabled(browser.currentURL == nil)
                TextField("Enter a website address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if let url = URL.web(address, assumingHTTPS: true) { browser.enterAddress(url) }
                    }
                    .accessibilityLabel("Website address")
                    .help("Enter a web address and press Return to open it")
                Button { add(.search) } label: { Image(systemName: "magnifyingglass") }
                    .help("Search for images")
                    .accessibilityLabel("Image search")
                Button { showScanOptions.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Scan settings")
                    .accessibilityLabel("Scan settings")
                    .popover(isPresented: $showScanOptions) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Scan settings").font(.headline)
                            Stepper("Pages to scan · \(browser.pageLimit)", value: $browser.pageLimit, in: 1...50)
                                .help("Set the maximum number of pages to scan in this collection")
                            Toggle("Auto-scroll during scans", isOn: $browser.autoScroll)
                                .help("Scroll the page while scanning to find media that loads further down")
                            Toggle("Follow links on the same website", isOn: $browser.followLinks)
                                .help("Explore links on the same website beyond ordinary next-page links")
                            Toggle("Follow links to known gallery domains", isOn: $browser.followLinkedGalleries)
                                .help("Look up full-size images behind links to supported gallery sites")
                            Toggle("Ignore page assets", isOn: $browser.ignorePageAssets)
                                .help("Filter common logos, avatars, icons, and loading images")
                            Text("Next-page links are followed up to the page limit. A matching template can increase the limit.")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Divider()
                            Button("Find Videos with yt-dlp") {
                                showScanOptions = false
                                browser.scan(forceVideo: true)
                            }
                            .help("Find videos, audio, and playlist entries from the current page")
                            .disabled(browser.currentURL == nil || browser.isLoading || browser.isScanning)
                        }
                        .padding(16)
                        .frame(width: 290)
                    }
                Button {
                    if browser.isScanning { browser.stopScan() } else { browser.scan() }
                } label: {
                    Label(browser.isScanning ? "Stop Scan" : "Scan Page",
                          systemImage: browser.isScanning ? "stop.fill" : "viewfinder")
                }
                .buttonStyle(.glassProminent)
                .help(browser.isScanning ? "Stop looking for files" : "Find downloadable files on the current page")
                .disabled(browser.currentURL == nil || browser.isLoading)
            }
            .padding(14)
            .onChange(of: browser.currentURL, initial: true) { _, url in
                address = url?.absoluteString ?? ""
            }
            Divider()
            if browser.currentURL == nil {
                ContentUnavailableView {
                    Label("Open a website", systemImage: "globe")
                } description: {
                    Text("Browse, sign in if needed, and scan the page for downloadable media.")
                } actions: {
                    Button("Open Website") { add(.website) }.buttonStyle(.glassProminent)
                }
            } else {
                HSplitView {
                    BrowserPane(webView: browser.webView).frame(minWidth: 340)
                    results.frame(minWidth: 260, idealWidth: 330)
                }
            }
        }
    }

    private var results: some View {
        let items = browser.visible
        let count = items.filter { browser.selected.contains($0.url) }.count
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Discovered files").font(.headline)
                    Spacer()
                    if browser.isLoading || browser.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Text(items.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(browser.message)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("File type", selection: $browser.kindFilter) {
                    Text("All types").tag(nil as MediaKind?)
                    ForEach(MediaKind.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
                .help("Show only the chosen type of discovered file")
            }
            .padding(14)
            Divider()

            if items.isEmpty {
                ContentUnavailableView("No results yet", systemImage: "tray")
                    .frame(maxHeight: .infinity)
            } else {
                List(items) { item in
                    Toggle(isOn: Binding(get: { browser.selected.contains(item.url) },
                                         set: { _ in browser.toggle(item.url) })) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(1)
                                Text(item.videoPage == true ? "yt-dlp" : item.streamFormat.map { $0.name + " stream" } ?? item.url.host ?? "")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: item.kind.icon).foregroundStyle(Color.accentColor)
                        }
                    }
                    .help(item.url.absoluteString)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Button(count == items.count && count > 0 ? "Deselect All" : "Select All") {
                    browser.selectVisible(count != items.count)
                }
                .help("Change the selection for all visible results")
                .disabled(items.isEmpty)
                Spacer()
                Button(count == 0 ? "Add to Queue" : "Queue \(count.formatted())") {
                    Task { await browser.queueSelected() }
                }
                .buttonStyle(.glassProminent)
                .help("Add the selected visible files to Downloads")
                .disabled(count == 0 || browser.isResolvingLinkedGalleries)
            }
            .padding(12)
        }
    }
}

struct TemplatesView: View {
    private enum TemplateSection: String, CaseIterable, Identifiable {
        case gallery = "gallery-dl Sites", video = "yt-dlp Sites", web = "Web Rules"
        var id: Self { self }
    }

    @Bindable var browser: SiteBrowser
    let openSite: (URL, Bool) -> Void
    @State private var editing: SiteTemplate?
    @State private var selectedSite: GallerySite?
    @State private var showAuthentication = false
    @State private var section = TemplateSection.gallery
    @State private var siteSearch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                PageHeading(title: "Site templates", detail: "Browse supported sites or create a web page scanning rule.")
                Button {
                    showAuthentication = true
                } label: {
                    Label("Authentication", systemImage: "key")
                }
                .buttonStyle(.glass)
                .help("Import session cookies or connect a supported account")
                Button {
                    section = .web
                    editing = SiteTemplate()
                } label: {
                    Label("New Template", systemImage: "plus")
                }
                .help("Create a rule for finding media on a website")
                .buttonStyle(.glassProminent)
            }
            .padding(.horizontal, 26)

            HStack {
                Picker("Template source", selection: $section) {
                    ForEach(TemplateSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                if section != .web {
                    TextField("Search sites or domains", text: $siteSearch)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 225)
                }
            }
            .padding(.horizontal, 26)

            if section != .web {
                siteList
            } else {
                rulesList
            }
        }
        .padding(.top, 19)
        .sheet(item: $editing) { draft in
            TemplateEditor(template: draft) { saved in
                if let index = browser.templates.firstIndex(where: { $0.id == saved.id }) {
                    browser.templates[index] = saved
                } else {
                    browser.templates.insert(saved, at: 0)
                }
            }
        }
        .sheet(item: $selectedSite) { site in
            GallerySiteDetail(site: site) { url in openSite(url, section == .video) }
        }
        .sheet(isPresented: $showAuthentication) {
            GalleryAuthenticationView(gallery: browser.gallery)
        }
    }

    private var siteList: some View {
        let search = siteSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = section == .video ? (YTDLPIntegration.catalog?.sites ?? []) : browser.gallery.sites
        let sites = catalog.filter { site in
            search.isEmpty || site.name.localizedCaseInsensitiveContains(search) ||
                site.hosts.contains { $0.localizedCaseInsensitiveContains(search) }
        }
        return List(sites) { site in
            Button {
                selectedSite = site
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "globe").foregroundStyle(Color.accentColor).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(site.name).font(.callout.weight(.medium))
                        Text(site.hosts.isEmpty ? "Video and audio URLs" : site.hosts.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if site.oauth { Label("OAuth", systemImage: "key").font(.caption).foregroundStyle(.secondary) }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
        .padding(.horizontal, 12)
        .overlay {
            if sites.isEmpty { ContentUnavailableView("No matching sites", systemImage: "magnifyingglass") }
        }
    }

    private var rulesList: some View {
        List {
                Section("Your templates") {
                    if browser.templates.isEmpty {
                        Text("Create a template to add support for a site or override a built-in template.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 7)
                    }
                    ForEach(browser.templates) { template in
                        row(template, builtin: false)
                            .contextMenu {
                                Button("Edit") { editing = template }
                                Button("Delete", role: .destructive) { browser.templates.removeAll { $0.id == template.id } }
                            }
                    }
                }
                Section("Built-in templates") {
                    ForEach(SiteTemplate.presets) { row($0, builtin: true) }
                }
        }
        .listStyle(.inset)
        .padding(.horizontal, 12)
    }

    private func row(_ template: SiteTemplate, builtin: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "globe").foregroundStyle(Color.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(template.name).font(.callout.weight(.medium))
                Text(template.host).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(builtin ? "Customize…" : "Edit…") {
                var draft = template
                if builtin { draft.id = UUID() }
                editing = draft
            }
            .buttonStyle(.glass)
        }
        .padding(.vertical, 5)
    }
}

private struct TemplateEditor: View {
    @State var template: SiteTemplate
    let save: (SiteTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading(title: "Edit site template", detail: "Rules apply to the hostname and its subdomains.")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                field("Name", prompt: "Gallery", text: $template.name)
                field("Hostname", prompt: "example.com", text: $template.host)
                field("Media selector", prompt: "article img, a[download]", text: $template.selector)
                field("URL attribute", prompt: "Automatic · src, href, or lazy image URL", text: $template.attribute)
                field("Next page selector", prompt: "Automatic · a[rel=next]", text: $template.nextSelector)
                field("Linked gallery selector", prompt: "Optional · a[href]:has(img)", text: Binding(
                    get: { template.linkedGallerySelector ?? "" },
                    set: { template.linkedGallerySelector = $0 }
                ))
                GridRow {
                    Text("File type hint").foregroundStyle(.secondary)
                    Picker("File type hint", selection: $template.mediaKind) {
                        Text("Automatic").tag(nil as MediaKind?)
                        ForEach(MediaKind.allCases) { Text($0.rawValue).tag(Optional($0)) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Page limit").foregroundStyle(.secondary)
                    Stepper("\(template.pageLimit) pages", value: $template.pageLimit, in: 1...50)
                }
            }
            Text("Use a selector to limit which links are checked for a matching gallery domain. Previews are kept if the gallery yields no images.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save Template") {
                    var result = template
                    result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let host = result.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !result.name.isEmpty,
                          let url = URL.web(host, assumingHTTPS: true), let name = url.host,
                          url.path.isEmpty || url.path == "/", url.query == nil, url.port == nil else {
                        error = "Enter a name and a hostname, such as example.com."
                        return
                    }
                    result.host = name
                    result.selector = result.selector.trimmingCharacters(in: .whitespacesAndNewlines)
                    result.attribute = result.attribute.trimmingCharacters(in: .whitespacesAndNewlines)
                    result.nextSelector = result.nextSelector.trimmingCharacters(in: .whitespacesAndNewlines)
                    let linked = result.linkedGallerySelector?.trimmingCharacters(in: .whitespacesAndNewlines)
                    result.linkedGallerySelector = linked?.isEmpty == false ? linked : nil
                    save(result)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(25)
        .frame(width: 585)
    }

    private func field(_ label: String, prompt: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }
}
