import AppKit
import Foundation
import Observation
import SwiftUI
import WebKit

enum SearchEngine: String, CaseIterable, Identifiable {
    case bing = "Bing Images", google = "Google Images"
    case yandex = "Yandex Images", duckDuckGo = "DuckDuckGo Images", yahoo = "Yahoo Images"
    var id: Self { self }

    func address(query: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "https"
        let parameters: [(String, String)]
        switch self {
        case .bing:
            parts.host = "www.bing.com"
            parts.path = "/images/search"
            parameters = [("q", query)]
        case .google:
            parts.host = "www.google.com"
            parts.path = "/search"
            parameters = [("q", query), ("udm", "2")]
        case .yandex:
            parts.host = "yandex.com"
            parts.path = "/images/search"
            parameters = [("text", query)]
        case .duckDuckGo:
            parts.host = "duckduckgo.com"
            parts.path = "/"
            parameters = [("q", query), ("ia", "images"), ("iax", "images")]
        case .yahoo:
            parts.host = "images.search.yahoo.com"
            parts.path = "/search/images"
            parameters = [("p", query)]
        }
        parts.queryItems = parameters.map { URLQueryItem(name: $0.0, value: $0.1) }
        return parts.url
    }

    func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        switch self {
        case .bing: return (host == "bing.com" || host.hasSuffix(".bing.com")) && url.path.hasPrefix("/images")
        case .google: return (host == "google.com" || host.hasSuffix(".google.com")) && url.path == "/search"
        case .yandex: return (host == "yandex.com" || host.hasSuffix(".yandex.com") ||
                               host == "yandex.ru" || host.hasSuffix(".yandex.ru")) && url.path.hasPrefix("/images")
        case .duckDuckGo: return host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com")
        case .yahoo: return host.hasSuffix(".yahoo.com") && url.path.hasPrefix("/search/images")
        }
    }
}

struct BrowserPane: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

private struct ScanResult: Decodable {
    var media: [MediaCandidate]
    var pages: [URL]
    var exploration: [URL]?
    var pageTitle: String?
    var galleryTitle: String?
    var galleries: [LinkedGallery]?
    var replacedPreviews: [URL]?
}

private struct LinkedGallery: Decodable {
    let url: URL
    let previews: [URL]

    var directOriginal: URL? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return switch host {
        case "imx.to": imxOriginal
        case "imgbox.com": imgboxOriginal
        case "pixhost.cc", "pixhost.to", "pixhost.org": pixhostOriginal(domain: host)
        default: nil
        }
    }

    private var imxOriginal: URL? {
        let landing = url.pathComponents
        guard landing.count == 3, landing[1] == "i",
              landing[2].range(of: #"^[a-zA-Z0-9]+$"#, options: .regularExpression) != nil else { return nil }
        for preview in previews {
            let parts = preview.pathComponents
            guard preview.host?.lowercased() == "image.imx.to", parts.count == 7,
                  parts[1] == "u", parts[2] == "t",
                  parts[3].range(of: #"^\d{4}$"#, options: .regularExpression) != nil,
                  parts[4].range(of: #"^\d{2}$"#, options: .regularExpression) != nil,
                  parts[5].range(of: #"^\d{2}$"#, options: .regularExpression) != nil,
                  preview.deletingPathExtension().lastPathComponent == landing[2],
                  MediaKind.detect(preview) == .image else { continue }
            return imageURL(host: "image.imx.to", path: "/u/i/" + parts[3...].joined(separator: "/"))
        }
        return nil
    }

    private var imgboxOriginal: URL? {
        guard url.path.range(of: #"^/[A-Za-z0-9]{8}/?$"#, options: .regularExpression) != nil else { return nil }
        let imageID = url.lastPathComponent
        for preview in previews {
            guard let host = preview.host?.lowercased(),
                  host.range(of: #"^thumbs[0-9]+\.imgbox\.com$"#, options: .regularExpression) != nil,
                  preview.path.range(of: #"^/[a-f0-9]{2}/[a-f0-9]{2}/[A-Za-z0-9]{8}_t\.[A-Za-z0-9]+$"#,
                                     options: .regularExpression) != nil,
                  preview.deletingPathExtension().lastPathComponent == imageID + "_t",
                  MediaKind.detect(preview) == .image else { continue }
            let path = preview.deletingPathExtension().deletingLastPathComponent().path + "/" + imageID
            return imageURL(host: "images" + host.dropFirst("thumbs".count), path: path + "_o." + preview.pathExtension)
        }
        return nil
    }

    private func pixhostOriginal(domain: String) -> URL? {
        guard url.path.range(of: #"^/show/[0-9]+/[0-9]+_[^/]+$"#, options: .regularExpression) != nil else { return nil }
        let imagePath = url.path.dropFirst("/show/".count)
        for preview in previews {
            guard let host = preview.host?.lowercased(), host.hasSuffix("." + domain),
                  let shard = host.split(separator: ".").first,
                  shard.range(of: #"^t[0-9]+$"#, options: .regularExpression) != nil,
                  host == "\(shard).\(domain)", preview.path == "/thumbs/" + imagePath,
                  MediaKind.detect(preview) == .image else { continue }
            return imageURL(host: "img" + shard.dropFirst() + "." + domain, path: "/images/" + imagePath)
        }
        return nil
    }

    private func imageURL(host: String, path: String) -> URL? {
        var original = URLComponents()
        original.scheme = "https"
        original.host = host
        original.path = path
        return original.url
    }
}

private struct PageDiscovery {
    var pages: [URL] = []
    var exploration: [URL] = []
    var galleries: [LinkedGallery] = []
    var images: Set<URL> = []
    var pageTitle: String?
    var galleryTitle: String?
}

private struct LinkedImageCollection {
    let url: URL
    let pageTitle: String?
    let galleryTitle: String?

    func apply(to candidate: inout MediaCandidate) {
        candidate.collectionURL = url
        candidate.pageTitle = pageTitle
        candidate.galleryTitle = galleryTitle
    }
}

private enum ScanError: LocalizedError {
    case noPage, timeout, missingScript
    var errorDescription: String? {
        switch self {
        case .noPage: "Open a website in the browser first."
        case .timeout: "The page took too long to load."
        case .missingScript: "The media scanner could not be loaded."
        }
    }
}

@MainActor @Observable
final class SiteBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let gallery = GalleryIntegration()
    private let crawler: WKWebView
    private let transfers: Transfers
    private var pending: CheckedContinuation<Void, Error>?
    private var navigation: WKNavigation?
    private var linkedOrigin: URL?
    private var timeout: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var scanOnLoad: WKNavigation?
    private var browserNavigation: WKNavigation?
    private var queueFirstScan = false
    private var xSignIn: (target: URL?, autoQueue: Bool)?
    private var xAutoQueue = false
    private var scheduledSource: URL?
    private var browserPageLoaded = false
    private var galleryHeaders: [URL: [String: String]] = [:]
    private var galleryStreamCookies: [URL: [StreamCookie]] = [:]
    private var browserResourceSince = 0.0
    @ObservationIgnored private var urlObservation: NSKeyValueObservation?
    private(set) var currentURL: URL?
    private(set) var homeURL: URL?
    private(set) var isLoading = false
    private(set) var isScanning = false
    private(set) var isResolvingLinkedGalleries = false
    private(set) var found: [MediaCandidate] = []
    private(set) var selected: Set<URL> = []
    private(set) var message = "Open a website or search for images to find downloadable files."
    private var searchEngine: SearchEngine?
    private var prefersVideo = false
    @ObservationIgnored private lazy var extractionScript = Bundle.main.url(forResource: "Extract", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    var autoScroll = true
    var followLinks = false
    var followLinkedGalleries = false
    var ignorePageAssets = true {
        didSet { UserDefaults.standard.set(ignorePageAssets, forKey: "ignorePageAssets") }
    }
    var pageLimit = 5
    var kindFilter: MediaKind?
    var templates: [SiteTemplate] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(templates) {
                UserDefaults.standard.set(data, forKey: "templates")
            }
        }
    }

    init(transfers: Transfers, dataStore: WKWebsiteDataStore = .default()) {
        self.transfers = transfers
        func makeBrowser() -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = dataStore
            return WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        }
        webView = makeBrowser()
        crawler = makeBrowser()
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        crawler.navigationDelegate = self
        ignorePageAssets = UserDefaults.standard.object(forKey: "ignorePageAssets") as? Bool ?? true
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, !self.isLoading, !self.webView.isLoading,
                      let url = self.webView.url, url != self.currentURL else { return }
                if !self.handleXLocation(url) {
                    if self.currentURL?.path != url.path {
                        self.browserResourceSince = Date().timeIntervalSince1970 * 1_000 - 800
                        if self.currentURL?.isXSite == true { self.stopScan() }
                    }
                    self.currentURL = url
                }
            }
        }
        if let data = UserDefaults.standard.data(forKey: "templates"),
           let saved = try? JSONDecoder().decode([SiteTemplate].self, from: data) {
            templates = saved
        }
    }

    var visible: [MediaCandidate] { found.filter { kindFilter == nil || $0.kind == kindFilter } }

    func toggle(_ url: URL) {
        if selected.remove(url) == nil { selected.insert(url) }
    }

    func selectVisible(_ select: Bool) {
        let urls = visible.map(\.url)
        if select { selected.formUnion(urls) } else { selected.subtract(urls) }
    }

    func open(_ url: URL, search: SearchEngine? = nil, scan: Bool = false, autoQueue: Bool = false,
              ytDLP: Bool = false) {
        homeURL = url
        searchEngine = search
        prefersVideo = ytDLP
        found = []
        selected = []
        galleryHeaders = [:]
        galleryStreamCookies = [:]
        kindFilter = search == nil ? nil : .image
        navigate(url, scan: scan, autoQueue: autoQueue)
    }

    func enterAddress(_ url: URL) {
        if homeURL == nil { open(url) } else { navigate(url) }
    }

    func goHome() {
        if let homeURL { navigate(homeURL) }
    }

    private func navigate(_ url: URL, scan: Bool = false, autoQueue: Bool = false) {
        stopScan()
        xSignIn = nil
        xAutoQueue = url.isXSite && autoQueue
        currentURL = url
        browserPageLoaded = false
        isLoading = true
        message = "Loading \(url.host ?? "page")…"
        queueFirstScan = autoQueue
        let token = webView.load(URLRequest(url: url))
        browserNavigation = token
        scanOnLoad = scan ? token : nil
        scheduledSource = scan ? url : nil
        if token == nil { isLoading = false }
    }

    func stopScan() {
        scanTask?.cancel()
    }

    func recommendedTemplate(for url: URL) -> String {
        let rules = websiteRules(for: url)
        if let custom = rules.custom { return "\(custom.name) · Custom Web Rule" }
        if rules.linkedSelector == nil {
            if let site = GallerySite.bestMatch(for: url, in: gallery.sites)
                ?? (url.isXSite ? gallery.sites.first { $0.id == "twitter" } : nil) {
                return "\(site.name) · gallery-dl"
            }
            if let site = GallerySite.bestMatch(for: url, in: YTDLPIntegration.catalog?.sites ?? []) {
                return "\(site.name) · yt-dlp"
            }
        }
        if let preset = rules.preset { return "\(preset.name) · Built-in Web Rule" }
        return "Standard browser scan"
    }

    private func websiteRules(for url: URL) -> (custom: SiteTemplate?, preset: SiteTemplate?, linkedSelector: String?) {
        let custom = templates.first { $0.matches(url) }
        let preset = SiteTemplate.presets.first { $0.matches(url) }
        let linkedSelector = custom?.linkedGallerySelector ?? preset?.linkedGallerySelector ?? (followLinkedGalleries
            ? "a[href], img[data-gallery-url], img[data-full-src], img[data-original]" : nil)
        return (custom, preset, linkedSelector)
    }

    func scan(extractorSource: URL? = nil, forceVideo: Bool = false) {
        guard !isScanning, !isLoading, let url = (browserPageLoaded ? webView.url : currentURL) else { return }
        let importedXTarget = url.isXSignIn ? xSignIn?.target.flatMap { gallery.hasImportedCookies(for: $0) ? $0 : nil } : nil
        if url.isXSignIn, importedXTarget == nil, handleXLocation(url) { return }
        isScanning = true
        let videoOnly = forceVideo || prefersVideo
        let rules = websiteRules(for: url)
        let customTemplate = videoOnly ? nil : rules.custom
        let template = customTemplate ?? rules.preset
        let xMedia = url.isXSite && customTemplate == nil
        let search = searchEngine.flatMap { $0.matches(url) ? $0 : nil }
        let linkedSelector = search == nil && !videoOnly ? rules.linkedSelector : nil
        let useHandoffs = linkedSelector != nil && browserPageLoaded
        isResolvingLinkedGalleries = useHandoffs
        let limit = search == nil ? max(pageLimit, template?.pageLimit ?? 1) : 1
        let scrolling = autoScroll
        let linkDepth = template?.linkDepth.map { max(0, min(10, $0)) } ?? (followLinks ? limit - 1 : 0)
        let collection = importedXTarget ?? extractorSource ?? url
        let autoQueue = queueFirstScan || (url.isXSite && xAutoQueue)
        queueFirstScan = false
        message = "Scanning \(url.host ?? "page")…"
        scanTask = Task {
            defer {
                isScanning = false
                isResolvingLinkedGalleries = false
                scanTask = nil
                startScheduledScan()
            }
            do {
                let pageTitle: String?
                if browserPageLoaded, !url.isXSignIn {
                    let title = try? await webView.callAsyncJavaScript(
                        "return (document.title || '').trim().slice(0, 500)",
                        arguments: [:], contentWorld: .defaultClient)
                    pageTitle = (title as? String).flatMap { $0.isEmpty ? nil : $0 }
                } else {
                    pageTitle = nil
                }
                try Task.checkCancellation()
                var extractorNote: String?
                if !useHandoffs, !videoOnly, search == nil, customTemplate == nil, !gallery.sites.isEmpty {
                    message = "Checking \(collection.host ?? "the site") with gallery-dl…"
                    let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                    do {
                        let outcome = try await gallery.scan(collection, browserCookies: cookies) { candidate, headers, streamCookies in
                            var candidate = candidate
                            candidate.collectionURL = collection
                            candidate.pageTitle = pageTitle
                            mergeGalleryMedia(candidate, headers: headers, streamCookies: streamCookies)
                        }
                        if outcome.count > 0 {
                            if browserPageLoaded, !url.isXSignIn,
                               let result = try? await extract(webView, template: nil, search: nil, follow: false, xMedia: xMedia) {
                                try Task.checkCancellation()
                                merge(result.media.filter { $0.streamFormat != nil }, source: url, collection: collection,
                                      pageTitle: pageTitle ?? result.pageTitle, galleryTitle: result.galleryTitle)
                            }
                            message = "gallery-dl found \(outcome.count.formatted()) files."
                            if autoQueue { xAutoQueue = false; await queueSelected() }
                            if let note = outcome.note { message += " " + note }
                            return
                        }
                        extractorNote = outcome.note
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        extractorNote = error.localizedDescription
                    }
                }
                if !useHandoffs, (search == nil || videoOnly), customTemplate == nil, YTDLPIntegration.catalog != nil {
                    message = "Checking \(collection.host ?? "the site") with yt-dlp…"
                    let browserCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                    let cookies = gallery.videoCookies(for: collection, browserCookies: browserCookies)
                    do {
                        let outcome = try await YTDLPIntegration.scan(collection, cookies: cookies, allowGeneric: videoOnly) { candidate, headers in
                            var candidate = candidate
                            candidate.collectionURL = collection
                            candidate.pageTitle = pageTitle
                            mergeGalleryMedia(candidate, headers: headers, streamCookies: [])
                        }
                        if outcome.count > 0 {
                            message = "yt-dlp found \(outcome.count.formatted()) media \(outcome.count == 1 ? "item" : "items")."
                            if autoQueue { xAutoQueue = false; await queueSelected() }
                            return
                        }
                        extractorNote = outcome.note ?? extractorNote
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        extractorNote = error.localizedDescription
                    }
                }
                if videoOnly {
                    message = extractorNote ?? "yt-dlp found no downloadable video or audio on this page."
                    return
                }
                if url.isXSignIn {
                    message = extractorNote ?? "No files found with the imported cookies. Sign in to X here and try again."
                    return
                }
                if !browserPageLoaded {
                    message = extractorNote ?? "The browser could not load the page, and gallery-dl found no files."
                    return
                }
                let initial = try await scanPage(webView, source: url, template: template, search: search,
                                                 follow: linkDepth > 0, scrolling: scrolling, xMedia: xMedia,
                                                 collection: collection, pageTitle: pageTitle, linkedSelector: linkedSelector)
                var pendingPages = initial.pages.map { (url: $0, depth: 0) }
                    + initial.exploration.map { (url: $0, depth: 1) }
                var galleries = initial.galleries
                var seen: Set<URL> = [url]
                var count = 1
                var skipped = 0
                while count < limit, !pendingPages.isEmpty, found.count < 5000 {
                    try Task.checkCancellation()
                    let next = pendingPages.removeFirst()
                    guard seen.insert(next.url).inserted else { continue }
                    count += 1
                    message = "Scanning page \(count) of up to \(limit)…"
                    do {
                        try await loadForScan(next.url)
                        guard let destination = crawler.url, destination.host == url.host,
                              destination.scheme == url.scheme, destination.port == url.port else {
                            skipped += 1
                            continue
                        }
                        let discovery = try await scanPage(crawler, source: destination, template: template,
                                                       search: nil, follow: next.depth < linkDepth, scrolling: scrolling, xMedia: xMedia,
                                                       collection: collection, pageTitle: pageTitle, linkedSelector: linkedSelector)
                        let nextDepth = pendingPages.firstIndex { $0.depth > next.depth } ?? pendingPages.endIndex
                        pendingPages.insert(contentsOf: discovery.pages.map { ($0, next.depth) }, at: nextDepth)
                        pendingPages.append(contentsOf: discovery.exploration.map { ($0, next.depth + 1) })
                        galleries.append(contentsOf: discovery.galleries)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        skipped += 1
                    }
                }
                let linked = try await resolveLinkedGalleries(galleries, scrolling: scrolling,
                    collection: LinkedImageCollection(url: collection, pageTitle: initial.pageTitle, galleryTitle: initial.galleryTitle))
                message = found.isEmpty
                    ? (url.isXSite ? "No media links found on this X page. Open a post with media or a profile’s Media tab, then scan again."
                       : "No downloadable links found. Sign in if needed, scroll to load more media, or adjust the site template.")
                    : "Found \(found.count.formatted()) files across \(count - skipped) scanned \(count - skipped == 1 ? "page" : "pages")."
                if skipped > 0 { message += " \(skipped) could not be scanned." }
                if linked.images > 0 { message += " Found \(linked.images) linked originals." }
                if linked.pages > 0 { message += " Opened \(linked.pages) linked \(linked.pages == 1 ? "gallery" : "galleries")." }
                if found.isEmpty, let extractorNote { message += " " + extractorNote }
                if autoQueue && !found.isEmpty {
                    xAutoQueue = false
                    await queueSelected()
                }
            } catch is CancellationError {
                if !isLoading && xSignIn == nil && scanOnLoad == nil {
                    message = "Scan stopped. \(found.count.formatted()) files found."
                }
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }

    func queueSelected() async {
        let chosen = visible.filter { selected.contains($0.url) }.map { candidate in
            var candidate = candidate
            candidate.projectURL = homeURL ?? currentURL
            return candidate
        }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard !Task.isCancelled else { return }
        transfers.importCookies(cookies, for: chosen.map(\.url))
        let headers = galleryHeaders.filter { selected.contains($0.key) }
        var streamCookies = gallery.importedStreamCookies(for: chosen.filter { $0.streamFormat != nil }.map(\.url))
            .merging(galleryStreamCookies.filter { selected.contains($0.key) }) { $0 + $1 }
        for candidate in chosen where candidate.videoPage == true {
            streamCookies[candidate.url] = gallery.videoCookies(for: candidate.url, browserCookies: cookies)
        }
        let count = transfers.enqueue(chosen, privateHeaders: headers, streamCookies: streamCookies)
        message = count == 0 ? "These files are already in the queue." : "Added \(count.formatted()) files to the queue."
    }

    func syncCookies(for urls: [URL]) async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        transfers.importCookies(cookies, for: urls)
    }

    private func merge(_ media: [MediaCandidate], source: URL, collection: URL? = nil,
                       pageTitle: String? = nil, galleryTitle: String? = nil) {
        var urls = Set(found.map(\.url))
        for var candidate in media where found.count < 5000 {
            guard let url = URL.web(candidate.url.absoluteString), urls.insert(url).inserted else { continue }
            candidate.source = source
            candidate.collectionURL = collection ?? source
            candidate.pageTitle = pageTitle
            candidate.galleryTitle = galleryTitle
            found.append(candidate)
            selected.insert(url)
        }
    }

    private func mergeGalleryMedia(_ media: MediaCandidate, headers: [String: String], streamCookies: [StreamCookie]) {
        let publicNames: Set<String> = ["accept", "accept-language", "origin", "referer", "user-agent"]
        let privateNames: Set<String> = ["authorization", "cookie"]
        var media = media
        let clean = headers.filter { !$0.value.contains(where: \.isNewline) }
        media.requestHeaders = clean.filter { publicNames.contains($0.key.lowercased()) }
        let credentials = clean.filter { privateNames.contains($0.key.lowercased()) }
        galleryHeaders[media.url] = credentials.isEmpty ? nil : credentials
        galleryStreamCookies[media.url] = streamCookies.isEmpty ? nil : streamCookies
        if let index = found.firstIndex(where: { $0.url == media.url }) {
            found[index] = media
        } else if found.count < 5000 {
            found.append(media)
            selected.insert(media.url)
        }
    }

    private func removePreviews(_ urls: Set<URL>, preserving originals: Set<URL>) {
        guard !urls.isEmpty else { return }
        let previews = urls.subtracting(originals)
        let removed = found.filter { $0.kind == .image && previews.contains($0.url) }.map(\.url)
        guard !removed.isEmpty else { return }
        let removedURLs = Set(removed)
        found.removeAll { removedURLs.contains($0.url) }
        selected.subtract(removedURLs)
        for url in removedURLs {
            galleryHeaders[url] = nil
            galleryStreamCookies[url] = nil
        }
    }

    private func resolveLinkedGalleries(_ links: [LinkedGallery], scrolling: Bool,
                                        collection: LinkedImageCollection) async throws -> (pages: Int, images: Int) {
        guard !links.isEmpty else { return (0, 0) }
        let groups = Dictionary(grouping: links, by: \.url)
        let direct = try await resolveDirectOriginals(links, groups: groups, collection: collection)
        let hosts = Set(gallery.sites.flatMap(\.hosts))
        let singleImageHosts = Set(gallery.sites.filter {
            $0.linkedImages == true && $0.examples.count == 1 && $0.examples["image"] != nil
        }.flatMap(\.hosts))
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let imagePages = try await resolveLinkedImagePages(links, groups: groups, direct: direct, cookies: cookies, collection: collection)
        var seen: Set<URL> = []
        var resolvedImages = Set(direct.values).union(imagePages.values.flatMap { $0 })
        let originalCount = resolvedImages.count
        var attempts = 0
        var resolved = 0
        for link in links {
            try Task.checkCancellation()
            guard attempts < 25, found.count < 5000 else { break }
            guard direct[link.url] == nil, imagePages[link.url] == nil,
                  let address = URL.web(link.url.absoluteString), seen.insert(address).inserted,
                  let host = address.host?.lowercased() else { continue }
            let custom = templates.first { $0.matches(address) }
            let rule = custom ?? SiteTemplate.presets.first { $0.matches(address) }
            let supported = hosts.contains { host == $0 || host.hasSuffix("." + $0) }
            guard rule != nil || supported else { continue }
            attempts += 1
            message = "Scanning linked gallery on \(host)…"
            do {
                let previews = Set(groups[link.url, default: []].flatMap(\.previews))
                let singleImage = singleImageHosts.contains { host == $0 || host.hasSuffix("." + $0) }
                let originals = try await scanLinkedGallery(address, rule: rule, useExtractor: custom == nil && supported,
                                                           cookies: cookies, scrolling: scrolling,
                                                           collection: singleImage ? collection : nil).subtracting(previews)
                guard !originals.isEmpty else { continue }
                resolved += 1
                resolvedImages.formUnion(originals)
                removePreviews(previews, preserving: resolvedImages)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keep the previews when the destination cannot be scanned.
            }
        }
        return (resolved, originalCount)
    }

    private func resolveLinkedImagePages(_ links: [LinkedGallery], groups: [URL: [LinkedGallery]],
                                         direct: [URL: URL], cookies: [HTTPCookie],
                                         collection: LinkedImageCollection) async throws -> [URL: Set<URL>] {
        let domains = Set(gallery.sites.filter { $0.linkedImages == true }.flatMap(\.hosts))
        var seen: Set<URL> = []
        var batches: [String: [URL]] = [:]
        for link in links {
            guard seen.count < 100 else { break }
            let address = link.url
            guard direct[address] == nil, let host = address.host?.lowercased(),
                  domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                  !templates.contains(where: { $0.matches(address) }),
                  seen.insert(address).inserted else { continue }
            batches[host, default: []].append(address)
        }
        var resolved: [URL: Set<URL>] = [:]
        let previews = groups.mapValues { Set($0.flatMap(\.previews)) }
        defer {
            let replaced = Set(resolved.keys.flatMap { previews[$0, default: []] })
            removePreviews(replaced, preserving: Set(direct.values).union(resolved.values.flatMap { $0 }))
        }
        for host in batches.keys.sorted() {
            try Task.checkCancellation()
            guard let addresses = batches[host], let first = addresses.first else { continue }
            let sources = Set(addresses)
            message = "Looking up \(addresses.count.formatted()) linked images on \(host)…"
            do {
                _ = try await gallery.scan(first, browserCookies: cookies, linkedImages: addresses) { candidate, headers, streamCookies in
                    guard let source = candidate.source, candidate.kind == .image, sources.contains(source),
                          !previews[source, default: []].contains(candidate.url) else { return }
                    var candidate = candidate
                    collection.apply(to: &candidate)
                    mergeGalleryMedia(candidate, headers: headers, streamCookies: streamCookies)
                    if found.contains(where: { $0.url == candidate.url }) {
                        resolved[source, default: []].insert(candidate.url)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The regular linked-page scan can still try these URLs.
            }
        }
        return resolved
    }

    private func resolveDirectOriginals(_ links: [LinkedGallery], groups: [URL: [LinkedGallery]],
                                         collection: LinkedImageCollection) async throws -> [URL: URL] {
        var seen: Set<URL> = []
        let pairs = links.compactMap { link -> (landing: URL, original: URL)? in
            guard seen.insert(link.url).inserted, !templates.contains(where: { $0.matches(link.url) }),
                  let original = groups[link.url]?.lazy.compactMap(\.directOriginal).first else { return nil }
            return (link.url, original)
        }
        guard !pairs.isEmpty else { return [:] }
        message = "Verifying \(pairs.count.formatted()) full-size linked images…"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let verified = await withTaskGroup(of: (URL, URL)?.self, returning: [URL: URL].self) { group in
            var pending = pairs.makeIterator()
            for _ in 0..<6 {
                guard let pair = pending.next() else { break }
                group.addTask { await Self.verifyLinkedImage(pair, session: session) }
            }
            var verified: [URL: URL] = [:]
            while let result = await group.next() {
                if let (landing, original) = result { verified[landing] = original }
                if !Task.isCancelled, let pair = pending.next() {
                    group.addTask { await Self.verifyLinkedImage(pair, session: session) }
                }
            }
            return verified
        }
        try Task.checkCancellation()
        var replaced: [URL: URL] = [:]
        let verifiedOriginals = Set(verified.values)
        for (landing, _) in pairs {
            guard let original = verified[landing] else { continue }
            let previews = Set(groups[landing, default: []].flatMap(\.previews))
            let index = found.firstIndex { $0.kind == .image && previews.contains($0.url) && !verifiedOriginals.contains($0.url) }
            if !found.contains(where: { $0.url == original }) {
                guard found.count < 5000 || index != nil else { continue }
                let preview = index.map { found[$0] }
                let candidate = MediaCandidate(url: original, source: landing, kind: .image,
                                               requestHeaders: ["Referer": landing.absoluteString],
                                               collectionURL: collection.url,
                                               galleryTitle: collection.galleryTitle, pageTitle: collection.pageTitle)
                if let index, let preview {
                    found[index] = candidate
                    if selected.remove(preview.url) != nil { selected.insert(original) }
                    galleryHeaders[preview.url] = nil
                    galleryStreamCookies[preview.url] = nil
                } else {
                    found.append(candidate)
                    selected.insert(original)
                }
            }
            replaced[landing] = original
        }
        let originals = Set(replaced.values)
        let previews = Set(replaced.keys.flatMap { groups[$0, default: []].flatMap(\.previews) })
        removePreviews(previews, preserving: originals)
        return replaced
    }

    private nonisolated static func verifyLinkedImage(_ pair: (landing: URL, original: URL),
                                                       session: URLSession) async -> (URL, URL)? {
        var request = URLRequest(url: pair.original)
        request.httpMethod = "HEAD"
        request.setValue(pair.landing.absoluteString, forHTTPHeaderField: "Referer")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.mimeType?.hasPrefix("image/") == true, let resolved = http.url else { return nil }
        let sameFile = resolved.host == pair.original.host && resolved.path == pair.original.path
        let imxRedirect = pair.original.host == "image.imx.to" && resolved.host == "i.imx.to"
            && resolved.path == String(pair.original.path.dropFirst("/u".count))
        guard sameFile || imxRedirect else { return nil }
        return (pair.landing, pair.original)
    }

    private func scanLinkedGallery(_ address: URL, rule: SiteTemplate?, useExtractor: Bool,
                                   cookies: [HTTPCookie], scrolling: Bool, collection: LinkedImageCollection?) async throws -> Set<URL> {
        var originals: Set<URL> = []
        if useExtractor {
            do {
                _ = try await gallery.scan(address, browserCookies: cookies) { candidate, headers, streamCookies in
                    var candidate = candidate
                    candidate.collectionURL = address
                    collection?.apply(to: &candidate)
                    mergeGalleryMedia(candidate, headers: headers, streamCookies: streamCookies)
                    if candidate.kind == .image { originals.insert(candidate.url) }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Try the browser when the extractor is unavailable.
            }
            if !originals.isEmpty {
                return originals.intersection(found.lazy.filter { $0.kind == .image }.map(\.url))
            }
        }
        linkedOrigin = address
        defer { linkedOrigin = nil }
        var pages = [address]
        var seen: Set<URL> = []
        let limit = min(10, rule?.pageLimit ?? 1)
        var title: String?
        while !pages.isEmpty, seen.count < limit, found.count < 5000 {
            try Task.checkCancellation()
            let page = pages.removeFirst()
            guard withinLinkedSite(page, origin: address), seen.insert(page).inserted else { continue }
            do {
                try await loadForScan(page)
                guard let destination = crawler.url, withinLinkedSite(destination, origin: address) else { continue }
                if title == nil { title = crawler.title }
                let result = try await scanPage(crawler, source: destination, template: rule, search: nil,
                                                follow: false, scrolling: scrolling, xMedia: false,
                                                collection: collection?.url ?? address, pageTitle: title,
                                                linkedImageCollection: collection)
                originals.formUnion(result.images)
                pages.append(contentsOf: result.pages)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        let discovered = Set(found.lazy.filter { $0.kind == .image }.map(\.url))
        return originals.intersection(discovered)
    }

    private func withinLinkedSite(_ url: URL, origin: URL) -> Bool {
        guard let address = URL.web(url.absoluteString), let host = address.host?.lowercased(),
              let startingHost = origin.host?.lowercased() else { return false }
        let normalized = { (host: String) in host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        let sameScheme = address.scheme == origin.scheme || (origin.scheme == "http" && address.scheme == "https")
        return sameScheme && normalized(host) == normalized(startingHost) && address.port == origin.port
    }

    private func scanPage(_ view: WKWebView, source: URL, template: SiteTemplate?, search: SearchEngine?,
                          follow: Bool, scrolling: Bool, xMedia: Bool, collection: URL, pageTitle: String?,
                          linkedSelector: String? = nil,
                          linkedImageCollection: LinkedImageCollection? = nil) async throws -> PageDiscovery {
        var discovery = PageDiscovery()
        var seen: Set<URL> = []
        var explored: Set<URL> = []
        var replaced: Set<URL> = []
        var galleryPreviews: [URL: Set<URL>] = [:]
        var galleryOrder: [URL] = []
        var stationary = 0
        var previousMetrics: [Int] = []
        let steps = scrolling ? 20 : (xMedia ? 10 : 0)
        var foundMedia = false
        for step in 0...steps {
            try Task.checkCancellation()
            let result = try await extract(view, template: template, search: search, follow: follow, xMedia: xMedia,
                                           linkedSelector: linkedSelector)
            try Task.checkCancellation()
            discovery.pageTitle = discovery.pageTitle ?? pageTitle ?? result.pageTitle
            discovery.galleryTitle = discovery.galleryTitle ?? result.galleryTitle
            if !result.media.isEmpty { foundMedia = true }
            replaced.formUnion(result.replacedPreviews ?? [])
            let media = result.media.filter { !replaced.contains($0.url) }
            removePreviews(replaced, preserving: [])
            merge(media, source: source, collection: collection,
                  pageTitle: linkedImageCollection == nil ? pageTitle ?? result.pageTitle : linkedImageCollection?.pageTitle,
                  galleryTitle: linkedImageCollection == nil ? result.galleryTitle : linkedImageCollection?.galleryTitle)
            discovery.images.formUnion(media.lazy.filter { $0.kind == .image }.map(\.url))
            discovery.pages.append(contentsOf: result.pages.filter { seen.insert($0).inserted })
            discovery.exploration.append(contentsOf: (result.exploration ?? []).filter { explored.insert($0).inserted })
            for link in result.galleries ?? [] {
                if galleryPreviews[link.url] == nil { galleryOrder.append(link.url) }
                galleryPreviews[link.url, default: []].formUnion(link.previews)
            }
            guard step < steps, found.count < 5000 else { break }
            if xMedia && !foundMedia && step < 10 {
                try await Task.sleep(for: .milliseconds(400))
                continue
            }
            guard scrolling else { break }
            let metrics = try await view.callAsyncJavaScript("""
                const root = document.scrollingElement;
                if (!root) return [];
                const nested = document.elementsFromPoint(innerWidth / 2, innerHeight / 2)
                    .find(element => element.clientHeight >= innerHeight / 2 &&
                        element.scrollHeight > element.clientHeight + 8 &&
                        /^(auto|scroll)$/.test(getComputedStyle(element).overflowY));
                const target = root.scrollHeight > root.clientHeight + 8 ? root : (nested || root);
                target.scrollBy({top: Math.max(100, Math.floor(target.clientHeight * 0.85)), behavior: 'instant'});
                return [Math.round(target.scrollTop), target.scrollHeight, target.clientHeight];
                """, arguments: [:], contentWorld: .defaultClient) as? [Int] ?? []
            if metrics == previousMetrics { stationary += 1 } else { stationary = 0 }
            if stationary >= 3 { break }
            previousMetrics = metrics
            try await Task.sleep(for: .milliseconds(400))
        }
        discovery.galleries = galleryOrder.map { LinkedGallery(url: $0, previews: Array(galleryPreviews[$0] ?? [])) }
        return discovery
    }

    private func extract(_ view: WKWebView, template: SiteTemplate?, search: SearchEngine?, follow: Bool,
                         xMedia: Bool, linkedSelector: String? = nil) async throws -> ScanResult {
        guard let script = extractionScript else { throw ScanError.missingScript }
        guard view.url != nil else { throw ScanError.noPage }
        let galleryHosts = linkedSelector == nil ? [] :
            Array(Set(templates.map(\.host) + SiteTemplate.presets.map(\.host) + gallery.sites.flatMap(\.hosts)))
        let settings: [String: Any] = [
            "selector": template?.selector ?? "",
            "attribute": template?.attribute ?? "",
            "next": template?.nextSelector ?? "",
            "kind": template?.mediaKind?.rawValue ?? "",
            "search": search?.rawValue ?? "",
            "follow": follow,
            "xMedia": xMedia,
            "ignoreComponents": ignorePageAssets,
            "linkedGalleries": linkedSelector ?? "",
            "galleryHosts": galleryHosts,
            "resourceSince": view === webView ? browserResourceSince : 0
        ]
        let value = try await view.callAsyncJavaScript(script, arguments: ["settings": settings], contentWorld: .defaultClient)
        guard let value, JSONSerialization.isValidJSONObject(value) else { return ScanResult(media: [], pages: []) }
        return try JSONDecoder().decode(ScanResult.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func loadForScan(_ url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                navigation = crawler.load(URLRequest(url: url))
                guard navigation != nil else {
                    finishNavigation(ScanError.noPage)
                    return
                }
                timeout = Task {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    finishNavigation(ScanError.timeout)
                    crawler.stopLoading()
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.finishNavigation(CancellationError())
                self.crawler.stopLoading()
            }
        }
    }

    func webView(_ view: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard view === crawler, let origin = linkedOrigin, navigationAction.targetFrame?.isMainFrame == true else { return .allow }
        guard let url = navigationAction.request.url, withinLinkedSite(url, origin: origin) else { return .cancel }
        return .allow
    }

    private func finishNavigation(_ error: Error? = nil) {
        timeout?.cancel()
        timeout = nil
        navigation = nil
        let continuation = pending
        pending = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if view === webView {
            if scanOnLoad !== navigation {
                scanOnLoad = nil
                scheduledSource = nil
                if browserNavigation !== navigation { queueFirstScan = false }
            }
            browserNavigation = navigation
            stopScan()
            isLoading = true
            browserPageLoaded = false
            browserResourceSince = Date().timeIntervalSince1970 * 1_000 - 800
        }
    }

    func webView(_ view: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if view === crawler, let origin = linkedOrigin, navigationResponse.isForMainFrame {
            guard let response = navigationResponse.response as? HTTPURLResponse,
                  let url = response.url, withinLinkedSite(url, origin: origin),
                  (200...299).contains(response.statusCode) else { return .cancel }
            return .allow
        }
        guard view === webView, navigationResponse.isForMainFrame,
              let response = navigationResponse.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode), let url = response.url,
              let address = URL.web(url.absoluteString) else { return .allow }
        let disposition = response.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let mime = response.mimeType ?? ""
        let stream = StreamFormat(mimeType: mime) ?? StreamFormat(url: address)
        guard stream != nil || !navigationResponse.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") ||
                ["image/", "audio/", "video/"].contains(where: { mime.hasPrefix($0) }) else { return .allow }
        let filename = response.suggestedFilename ?? address.lastPathComponent
        let kind = stream != nil ? MediaKind.video : mime.hasPrefix("image/") ? .image : mime.hasPrefix("audio/") ? .audio :
            mime.hasPrefix("video/") ? .video : MediaKind.detect(URL(filePath: filename)) ?? .file
        merge([MediaCandidate(url: address, kind: kind, stream: stream)], source: currentURL ?? address)
        let queue = queueFirstScan
        scanOnLoad = nil
        queueFirstScan = false
        isLoading = false
        currentURL = address
        message = "Found a direct file link."
        if queue { await queueSelected() }
        return .cancel
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        if view === crawler {
            if navigation === self.navigation { finishNavigation() }
        } else if browserNavigation === navigation {
            isLoading = false
            browserPageLoaded = true
            if let url = view.url, handleXLocation(url) { return }
            currentURL = view.url
            message = "Scroll to load more media, or scan this page."
            if scanOnLoad === navigation { startScheduledScan() }
        }
    }

    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if view === crawler {
            if navigation === self.navigation { finishNavigation(error) }
        } else if browserNavigation === navigation {
            isLoading = false
            if (error as NSError).code != NSURLErrorCancelled {
                message = error.localizedDescription
                if scanOnLoad === navigation && !gallery.sites.isEmpty {
                    startScheduledScan()
                    return
                }
            }
            if scanOnLoad === navigation { scanOnLoad = nil }
            queueFirstScan = false
        }
    }

    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView(view, didFail: navigation, withError: error)
    }

    func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url, URL.web(url.absoluteString) != nil {
            view.load(action.request)
        }
        return nil
    }

    func webView(_ view: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(space.authenticationMethod),
              view === webView else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if let credential = challenge.proposedCredential, challenge.previousFailureCount == 0 {
            transfers.setCredential(credential, for: space)
            completionHandler(.useCredential, credential)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(space.host)"
        alert.informativeText = "Enter the username and password requested by this website."
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        let username = NSTextField(frame: NSRect(x: 0, y: 36, width: 270, height: 24))
        username.placeholderString = "Username"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 4, width: 270, height: 24))
        password.placeholderString = "Password"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 64))
        fields.addSubview(username)
        fields.addSubview(password)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = username
        if alert.runModal() == .alertFirstButtonReturn {
            let credential = URLCredential(user: username.stringValue, password: password.stringValue, persistence: .forSession)
            transfers.setCredential(credential, for: space)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func startScheduledScan() {
        guard scanOnLoad != nil, !isLoading, !isScanning else { return }
        scanOnLoad = nil
        let source = scheduledSource
        scheduledSource = nil
        scan(extractorSource: source)
    }

    private func handleXLocation(_ url: URL) -> Bool {
        if url.isXSignIn {
            if xSignIn == nil {
                let target = [currentURL, homeURL].compactMap { $0 }.first { $0.isXSite && !$0.isXSignIn }
                xSignIn = (target, xAutoQueue)
            }
            stopScan()
            scanOnLoad = nil
            currentURL = url
            message = "Sign in to X here. The scan will resume after you sign in."
            if let target = xSignIn?.target, gallery.hasImportedCookies(for: target), !isScanning {
                scan(extractorSource: target)
            }
            return true
        }
        guard url.isXSite, let resume = xSignIn else { return false }
        xSignIn = nil
        if let target = resume.target, target.path != url.path || target.query != url.query {
            navigate(target, scan: true, autoQueue: resume.autoQueue)
        } else {
            currentURL = url
            xAutoQueue = resume.autoQueue
            scanOnLoad = browserNavigation
            message = "Signed in to X. Scanning the page…"
            startScheduledScan()
        }
        return true
    }
}
