import Foundation
import UniformTypeIdentifiers

enum MediaKind: String, Codable, CaseIterable, Identifiable {
    case image = "Images", video = "Videos", audio = "Audio", file = "Other files"
    var id: Self { self }
    var icon: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .file: "doc"
        }
    }

    static func detect(_ url: URL) -> Self? {
        let fileExtension = url.pathExtension.lowercased()
        if StreamFormat(url: url) != nil { return .video }
        guard let type = UTType(filenameExtension: fileExtension) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if ["html", "htm", "php", "asp", "aspx", "jsp", "cgi"].contains(fileExtension) { return nil }
        return .file
    }
}

enum StreamFormat: String, Codable {
    case hls, dash

    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "m3u8": self = .hls
        case "mpd": self = .dash
        default: return nil
        }
    }

    init?(mimeType: String?) {
        switch mimeType?.lowercased() {
        case "application/vnd.apple.mpegurl", "application/x-mpegurl", "application/mpegurl",
             "audio/vnd.apple.mpegurl", "audio/mpegurl", "audio/x-mpegurl": self = .hls
        case "application/dash+xml": self = .dash
        default: return nil
        }
    }

    var name: String { self == .hls ? "HLS" : "DASH" }
}

enum DownloadFolderRule: String, CaseIterable, Identifiable {
    case none = "Keep files together", url = "URL", galleryTitle = "Gallery title", pageTitle = "Page title"
    var id: Self { self }

    func destination(base: URL, media: MediaCandidate) -> URL {
        let source = media.collectionURL ?? media.source ?? media.url
        let host = source.host ?? "Downloads"
        let path = media.collectionURL == nil && media.source == nil ? "" : source.path
            .split(separator: "/").joined(separator: " · ")
        let urlName = path.isEmpty ? host : host + " — " + path
        guard self != .none, let component = name(for: media, urlName: urlName) else { return base }
        return base.appending(path: component, directoryHint: .isDirectory)
    }

    func projectName(for media: MediaCandidate) -> String {
        let source = media.projectSource
        let path = source.path.split(separator: "/").joined(separator: " · ")
        let host = source.host ?? "Downloads"
        let urlName = path.isEmpty ? host : host + " — " + path
        return name(for: media, urlName: urlName) ?? host
    }

    private func name(for media: MediaCandidate, urlName: String) -> String? {
        let title: String? = switch self {
        case .none: Self.component(media.pageTitle) ?? Self.component(media.galleryTitle)
        case .url: nil
        case .galleryTitle: Self.component(media.galleryTitle)
        case .pageTitle: Self.component(media.pageTitle)
        }
        return title ?? Self.component(urlName)
    }

    private static func component(_ name: String?) -> String? {
        guard let name else { return nil }
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        var result = ""
        var size = 0
        for character in cleaned {
            let count = String(character).utf8.count
            guard size + count <= 180 else { break }
            result.append(character)
            size += count
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return result.isEmpty ? nil : result
    }
}

extension URL {
    static func web(_ input: String, assumingHTTPS: Bool = false) -> URL? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(where: \.isWhitespace) else { return nil }
        let value = assumingHTTPS && !input.contains("://") ? "https://" + input : input
        guard var parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        parts.fragment = nil
        return parts.url
    }

    var displayFilename: String {
        lastPathComponent.isEmpty ? (host ?? "download") : lastPathComponent
    }

    var isXSite: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "x.com" || host.hasSuffix(".x.com") ||
            host == "twitter.com" || host.hasSuffix(".twitter.com")
    }

    var isXSignIn: Bool {
        guard isXSite else { return false }
        let route = path.lowercased()
        return route == "/login" || route.hasPrefix("/i/flow/") || route.hasPrefix("/i/jf/onboarding")
    }
}

struct MediaCandidate: Identifiable, Codable, Hashable {
    let url: URL
    var source: URL? = nil
    var kind: MediaKind
    var suggestedFilename: String? = nil
    var requestHeaders: [String: String]? = nil
    var stream: StreamFormat? = nil
    var collectionURL: URL? = nil
    var galleryTitle: String? = nil
    var pageTitle: String? = nil
    var videoPage: Bool? = nil
    var projectURL: URL? = nil
    var projectSource: URL { projectURL ?? collectionURL ?? source ?? url }
    var id: URL { url }
    var streamFormat: StreamFormat? { stream ?? StreamFormat(url: url) }
    var name: String {
        let name = suggestedFilename ?? url.displayFilename
        if videoPage == true { return name }
        guard streamFormat != nil else { return name }
        let basename = (name as NSString).deletingPathExtension
        return (basename.isEmpty ? "stream" : basename) + ".mp4"
    }
}

struct SiteTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var host = ""
    var selector = ""
    var attribute = ""
    var nextSelector = ""
    var linkedGallerySelector: String?
    var mediaKind: MediaKind? = nil
    var pageLimit = 1
    var linkDepth: Int?

    func matches(_ url: URL) -> Bool {
        guard let hostname = url.host?.lowercased() else { return false }
        return hostname == host || hostname.hasSuffix("." + host)
    }

    static let presets: [Self] = [
        .init(name: "X", host: "x.com", selector: "img[src*='pbs.twimg.com/media'], img[data-src*='pbs.twimg.com/media'], video, video source"),
        .init(name: "Twitter", host: "twitter.com", selector: "img[src*='pbs.twimg.com/media'], img[data-src*='pbs.twimg.com/media'], video, video source"),
        .init(name: "Tumblr", host: "tumblr.com", selector: "img[src*='media.tumblr.com'], video, video source", nextSelector: "a[rel=next]", pageLimit: 3),
        .init(name: "Flickr", host: "flickr.com", selector: "img[src*='staticflickr.com'], a[href*='staticflickr.com']", nextSelector: "a[rel=next], a.pagination-next", pageLimit: 3),
        .init(name: "Reddit", host: "reddit.com", selector: "img[src*='redd.it'], a[href*='i.redd.it'], video, video source"),
        .init(name: "VK", host: "vk.com", selector: "img[src*='userapi.com'], img[src*='vkuser.net'], video, video source")
    ] + ["vipergirls.to", "viper.click"].map { host in
        SiteTemplate(name: "ViperGirls", host: host,
                     selector: ".postcontent img, .postcontent a[href], .postcontent video, .postcontent audio, .postcontent source",
                     linkedGallerySelector: ".postcontent a[href], .postcontent img[data-gallery-url], .postcontent img[data-full-src], .postcontent img[data-original]")
    }
}

enum TransferStatus: String, Codable {
    case queued = "Queued", downloading = "Downloading", paused = "Paused", retrying = "Retry scheduled", complete = "Complete", failed = "Failed"
}

struct Transfer: Codable, Identifiable {
    var id = UUID()
    var media: MediaCandidate
    let folder: URL
    var status = TransferStatus.queued
    var manuallyPaused: Bool?
    var attempts = 0
    var resumeData: Data?
    var received: Int64 = 0
    var expected: Int64 = 0
    var output: URL?
    var error: String?
    var retryDate: Date?
    var projectName: String?

    var canRetry: Bool { [.queued, .failed, .paused, .retrying].contains(status) }
    var name: String { output?.lastPathComponent ?? media.name }
    var fraction: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
    var kind: MediaKind { output.flatMap(MediaKind.detect) ?? (media.streamFormat == nil ? media.kind : .video) }
}
